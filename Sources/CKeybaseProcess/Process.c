#include "CKeybaseProcess.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <termios.h>
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

int kb_spawn_piped(const char *executable, char *const argv[], char *const envp[],
                   pid_t *pid, int *input, int *output, int *error_output) {
    int in[2] = {-1, -1}, out[2] = {-1, -1}, err[2] = {-1, -1};
    if (make_pipe(in) || make_pipe(out) || make_pipe(err)) goto failure;
    int limit = descriptor_limit();
    pid_t child = fork();
    if (child == -1) goto failure;
    if (child == 0) {
        if (setpgid(0, 0) || dup2(in[0], STDIN_FILENO) == -1 ||
            dup2(out[1], STDOUT_FILENO) == -1 || dup2(err[1], STDERR_FILENO) == -1)
            _exit(126);
        close_inherited(limit);
        child_signals();
        execve(executable, argv, envp);
        const char message[] = "Unable to execute child process.\n";
        write(STDERR_FILENO, message, sizeof(message) - 1);
        _exit(127);
    }
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
    // Canonical mode lets a plain native text field submit a complete response.
    // Keep ALL responses out of the transcript, even when a user submits before
    // the CLI has switched a prompt into password mode.
    attributes.c_lflag |= ICANON | ISIG;
    attributes.c_lflag &= ~(ECHO | ECHONL);
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
