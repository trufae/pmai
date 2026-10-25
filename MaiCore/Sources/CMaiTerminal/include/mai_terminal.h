#ifndef MAI_TERMINAL_H
#define MAI_TERMINAL_H

#ifndef _WIN32
// Returns the child pid, or -1 with errno set. All three streams and /dev/tty
// refer to slave. The caller relays input/output through its PTY master.
int mai_terminal_spawn(int master, int slave, const char *shell, const char *command, char *const environment[]);
#endif

#endif
