#ifndef MAI_TERMINAL_H
#define MAI_TERMINAL_H

#ifdef _WIN32
#include <stdint.h>
typedef struct MaiWindowsPTY MaiWindowsPTY;
int mai_windows_pty_available(void);
MaiWindowsPTY *mai_windows_pty_create(const uint16_t *executable, const uint16_t *command,
  const uint16_t *cwd, int columns, int rows, uint32_t *error);
int mai_windows_pty_read(MaiWindowsPTY *, void *buffer, uint32_t count, uint32_t *error);
int mai_windows_pty_register_writer(MaiWindowsPTY *, uint32_t *error);
int mai_windows_pty_write(MaiWindowsPTY *, const void *buffer, uint32_t count, uint32_t *error);
void mai_windows_pty_cancel_writer(MaiWindowsPTY *);
int mai_windows_pty_resize(MaiWindowsPTY *, int columns, int rows, uint32_t *error);
// Returns 1 on exit, 0 on timeout, or -1 on error.
int mai_windows_pty_wait(MaiWindowsPTY *, uint32_t milliseconds, uint32_t *status, uint32_t *error);
void mai_windows_pty_terminate(MaiWindowsPTY *);
void mai_windows_pty_finish_input(MaiWindowsPTY *);
// Call on a lifecycle worker while a separate worker drains output.
void mai_windows_pty_close_console(MaiWindowsPTY *);
// All I/O workers must be joined before destruction.
void mai_windows_pty_destroy(MaiWindowsPTY *);
#else
// Spawn a captured command in a new session without a controlling terminal.
// Returns the child pid, or -1 with errno set (including exec/chdir failures).
int mai_process_spawn(const char *executable, char *const arguments[], char *const environment[],
  const char *cwd, int input, int output, int errors);
// Returns the child pid, or -1 with errno set. All three streams and /dev/tty
// refer to slave. The caller relays input/output through its PTY master.
int mai_terminal_spawn(int master, int slave, const char *shell, const char *command, char *const environment[]);
// A persistent interactive shell in its own session and controlling terminal.
int mai_terminal_shell(int master, int slave, const char *shell, const char *cwd, char *const environment[]);
#endif

#endif
