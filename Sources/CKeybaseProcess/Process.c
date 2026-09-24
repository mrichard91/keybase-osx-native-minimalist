#include "CKeybaseProcess.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static int prepare_fd(int fd) {
    if (fd < 3) {
        int replacement = fcntl(fd, F_DUPFD_CLOEXEC, 3);
        close(fd);
        return replacement;
    }
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) == -1) { close(fd); return -1; }
    return fd;
}

static int make_pipe(int fds[2]) {
    if (pipe(fds) == -1) return -1;
    fds[0] = prepare_fd(fds[0]);
    fds[1] = prepare_fd(fds[1]);
    if (fds[0] < 0 || fds[1] < 0) {
        if (fds[0] >= 0) close(fds[0]);
        if (fds[1] >= 0) close(fds[1]);
        fds[0] = -1; fds[1] = -1;
        return -1;
    }
    return 0;
}

static int descriptor_limit(void) {
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur < 1048576)
        return (int)limit.rlim_cur;
    return 1048576;
}

static void close_inherited(int limit) {
    for (int fd = 3; fd < limit; ++fd) close(fd);
}

static void child_signals(void) {
    // The GUI can block signals on its threads; do not pass that state to Go.
    sigset_t empty;
    sigemptyset(&empty);
    sigprocmask(SIG_SETMASK, &empty, NULL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
}

static void nonblocking(int fd) {
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    fcntl(fd, F_SETNOSIGPIPE, 1);
}

static int spawn_native(const char *executable, char *const argv[], char *const envp[],
                        int input, int output, int error_output, const char *directory,
                        pid_t *pid) {
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int result = posix_spawn_file_actions_init(&actions);
    if (result) { errno = result; return -1; }
    result = posix_spawnattr_init(&attributes);
    if (result) { posix_spawn_file_actions_destroy(&actions); errno = result; return -1; }
    sigset_t empty, defaults;
    sigemptyset(&empty);
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGPIPE);
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK |
                  POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT;
    if (!(result = posix_spawnattr_setflags(&attributes, flags)) &&
        !(result = posix_spawnattr_setpgroup(&attributes, 0)) &&
        !(result = posix_spawnattr_setsigmask(&attributes, &empty)) &&
        !(result = posix_spawnattr_setsigdefault(&attributes, &defaults)) &&
        !(result = posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO)) &&
        !(result = posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO)) &&
        !(result = posix_spawn_file_actions_adddup2(&actions, error_output, STDERR_FILENO)) &&
        (!directory || !(result = posix_spawn_file_actions_addchdir_np(&actions, directory))))
        result = posix_spawn(pid, executable, &actions, &attributes, argv, envp);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    if (result) { errno = result; return -1; }
    return 0;
}

int kb_spawn_piped(const char *executable, char *const argv[], char *const envp[],
                   pid_t *pid, int *input, int *output, int *error_output) {
    int in[2] = {-1, -1}, out[2] = {-1, -1}, err[2] = {-1, -1};
    if (make_pipe(in) || make_pipe(out) || make_pipe(err)) goto failure;
    pid_t child;
    if (spawn_native(executable, argv, envp, in[0], out[1], err[1], NULL, &child)) goto failure;
    close(in[0]); close(out[1]); close(err[1]);
    nonblocking(in[1]); nonblocking(out[0]); nonblocking(err[0]);
    *pid = child; *input = in[1]; *output = out[0]; *error_output = err[0];
    return 0;
failure: {
    int saved = errno;
    if (in[0] >= 0) close(in[0]); if (in[1] >= 0) close(in[1]);
    if (out[0] >= 0) close(out[0]); if (out[1] >= 0) close(out[1]);
    if (err[0] >= 0) close(err[0]); if (err[1] >= 0) close(err[1]);
    errno = saved; return -1;
}}

int kb_spawn_quiet(const char *executable, char *const argv[], char *const envp[],
                   const char *working_directory, pid_t *pid) {
    int null_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (null_fd < 0) return -1;
    null_fd = prepare_fd(null_fd);
    if (null_fd < 0) return -1;
    int result = spawn_native(executable, argv, envp, null_fd, null_fd, null_fd, working_directory, pid);
    int saved = errno;
    close(null_fd);
    errno = saved;
    return result;
}

int kb_spawn_account(const char *executable, int action, char *const envp[],
                     pid_t *pid, int *terminal) {
    const char *command;
    switch (action) {
        case 0: command = "login"; break;
        case 1: command = "signup"; break;
        case 2: command = "logout"; break;
        default: errno = EINVAL; return -1;
    }
    int master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (master < 0) return -1;
    master = prepare_fd(master);
    if (master < 0) return -1;
    if (grantpt(master) || unlockpt(master)) { close(master); return -1; }
    char *slave_name = ptsname(master);
    if (!slave_name) { close(master); return -1; }
    int slave = open(slave_name, O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (slave < 0) { close(master); return -1; }
    slave = prepare_fd(slave);
    if (slave < 0) { close(master); return -1; }
    struct termios attributes;
    if (tcgetattr(slave, &attributes)) { close(master); close(slave); return -1; }
    // Initial canonical mode maps a terminal Return (CR) to a line feed. The
    // official CLI switches to raw mode, where its line reader requires CR.
    // Disable kernel echo before any input. Keybase's raw prompt reader manages
    // its own display and suppresses software echo for password prompts.
    attributes.c_lflag |= ICANON | ISIG;
    attributes.c_lflag &= ~(ECHO | ECHONL);
    attributes.c_iflag &= ~(IGNCR | INLCR);
    attributes.c_iflag |= ICRNL;
    attributes.c_oflag |= OPOST | ONLCR;
    attributes.c_cc[VERASE] = 127;
    attributes.c_cc[VEOF] = 4;
    attributes.c_cc[VINTR] = 3;
    if (tcsetattr(slave, TCSANOW, &attributes)) { close(master); close(slave); return -1; }
    struct winsize size = {.ws_row = 36, .ws_col = 88};
    ioctl(slave, TIOCSWINSZ, &size);
    int limit = descriptor_limit();
    char *argv[] = {(char *)executable, "--no-auto-fork", "--no-debug",
                    "--app-start-mode", "minimalist", (char *)command, NULL};
    pid_t child = fork();
    if (child == -1) { close(master); close(slave); return -1; }
    if (child == 0) {
        if (setsid() == -1 || ioctl(slave, TIOCSCTTY, 0) == -1 ||
            dup2(slave, STDIN_FILENO) == -1 || dup2(slave, STDOUT_FILENO) == -1 ||
            dup2(slave, STDERR_FILENO) == -1) _exit(126);
        close_inherited(limit);
        child_signals();
        execve(executable, argv, envp);
        _exit(127);
    }
    close(slave);
    nonblocking(master);
    *pid = child; *terminal = master;
    return 0;
}

int kb_terminal_echo_enabled(int terminal) {
    struct termios attributes;
    if (tcgetattr(terminal, &attributes)) return 0; // Fail closed: secure field.
    return (attributes.c_lflag & ECHO) != 0;
}

int kb_terminal_disable_echo(int terminal) {
    struct termios attributes;
    if (tcgetattr(terminal, &attributes)) return -1;
    attributes.c_lflag &= ~(ECHO | ECHONL);
    return tcsetattr(terminal, TCSANOW, &attributes);
}

int kb_process_poll(pid_t pid, int *exit_status) {
    int status = 0;
    pid_t result = waitpid(pid, &status, WNOHANG);
    if (result == 0 || (result == -1 && errno == EINTR)) return 0;
    if (result == -1) return -1;
    *exit_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    return 1;
}

int kb_process_peek(pid_t pid, int *exit_status) {
    siginfo_t info = {0};
    int result = waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT);
    if (result == -1) return errno == EINTR ? 0 : -1;
    if (info.si_pid == 0) return 0;
    *exit_status = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status;
    return 1;
}

void kb_process_kill(pid_t pid) {
    if (pid > 0) { kill(-pid, SIGKILL); kill(pid, SIGKILL); }
}

void kb_process_interrupt(pid_t pid) {
    if (pid > 0) { kill(-pid, SIGINT); kill(pid, SIGINT); }
}

void kb_process_reap(pid_t pid) {
    if (pid <= 0) return;
    while (waitpid(pid, NULL, 0) == -1 && errno == EINTR) {}
}

void kb_process_stop(pid_t pid, int graceful_signal, int grace_milliseconds) {
    if (pid <= 0) return;
    int observed_status;
    if (kb_process_peek(pid, &observed_status) < 0) return;
    if (grace_milliseconds > 0) {
        kill(-pid, graceful_signal);
        kill(pid, graceful_signal);
        struct timespec start, now, interval = {.tv_sec = 0, .tv_nsec = 10000000};
        clock_gettime(CLOCK_MONOTONIC, &start);
        while (1) {
            int status;
            if (kb_process_peek(pid, &status) != 0) break;
            clock_gettime(CLOCK_MONOTONIC, &now);
            long long elapsed = (now.tv_sec - start.tv_sec) * 1000LL + (now.tv_nsec - start.tv_nsec) / 1000000;
            if (elapsed >= grace_milliseconds) break;
            nanosleep(&interval, NULL);
        }
    }
    // Keep the leader unreaped until the group is killed, reserving its PID.
    kb_process_kill(pid);
    kb_process_reap(pid);
}
