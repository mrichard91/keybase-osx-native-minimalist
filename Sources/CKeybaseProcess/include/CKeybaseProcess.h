#ifndef CKEYBASEPROCESS_H
#define CKEYBASEPROCESS_H

#include <sys/types.h>
#include <stddef.h>

// All strings and descriptor tables are prepared before fork. The child performs
// only system calls before execve; no Swift or Objective-C runs after fork.
int kb_spawn_piped(const char *executable, char *const argv[], char *const envp[],
                   pid_t *pid, int *input, int *output, int *error_output);
// action: 0 = login, 1 = signup, 2 = logout. No free-form command is accepted.
int kb_spawn_account(const char *executable, int action, char *const envp[],
                     pid_t *pid, int *terminal);
int kb_terminal_echo_enabled(int terminal);
int kb_terminal_disable_echo(int terminal);
// 0: still running, 1: reaped, -1: wait failed. Exit status includes 128 + signal.
int kb_process_poll(pid_t pid, int *exit_status);
// Observe exit without reaping: reserves the PID while pipe output is drained.
int kb_process_peek(pid_t pid, int *exit_status);
void kb_process_kill(pid_t pid);
void kb_process_interrupt(pid_t pid);
void kb_process_reap(pid_t pid);

#endif
