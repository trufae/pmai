#ifndef _WIN32
#include "mai_terminal.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

int mai_process_spawn(const char *executable, char *const arguments[], char *const environment[],
    const char *cwd, int input, int output, int errors) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
  errno = ENOTSUP;
  return -1;
#else
  // Prepare everything before fork: the child may only use async-signal-safe
  // calls, since another thread can hold Swift/Foundation/libc locks.
  int streams[3] = {-1, -1, -1};
  int report[2] = {-1, -1};
  const int sources[3] = {input, output, errors};
  int error;
  for (int i = 0; i < 3; i++) {
    streams[i] = fcntl(sources[i], F_DUPFD_CLOEXEC, 3);
    if (streams[i] == -1) { goto fail; }
  }
  if (pipe(report) == -1) { goto fail; }
  for (int i = 0; i < 2; i++) {
    int fd = fcntl(report[i], F_DUPFD_CLOEXEC, 3);
    if (fd == -1) { goto fail; }
    close(report[i]);
    report[i] = fd;
  }
  const int limit = getdtablesize();
  sigset_t blocked, previous;
  sigfillset(&blocked);
  error = pthread_sigmask(SIG_SETMASK, &blocked, &previous);
  if (error != 0) { errno = error; goto fail; }
  const pid_t child = fork();
  if (child != 0) {
    error = errno;
    pthread_sigmask(SIG_SETMASK, &previous, 0);
    errno = error;
  }
  if (child == -1) { goto fail; }
  if (child == 0) {
    close(report[0]);
    if (setsid() == -1 || chdir(cwd) == -1) { goto child_fail; }
    for (int i = 0; i < 3; i++) {
      if (dup2(streams[i], i) == -1) { goto child_fail; }
    }
    // Preserve only the standard streams and the close-on-exec error report.
    if (dup2(report[1], 3) == -1) { goto child_fail; }
    report[1] = 3;
    if (fcntl(3, F_SETFD, FD_CLOEXEC) == -1) { goto child_fail; }
#ifdef SYS_close_range
    if (syscall(SYS_close_range, 4U, ~0U, 0) != 0)
#endif
    {
      for (int fd = 4; fd < limit; fd++) { close(fd); }
    }
    struct sigaction action = {0};
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    for (int number = 1; number < NSIG; number++) { sigaction(number, &action, 0); }
    sigset_t mask;
    sigemptyset(&mask);
    sigprocmask(SIG_SETMASK, &mask, 0);
    execve(executable, arguments, environment);
child_fail:
    error = errno;
    // A single int fits atomically in the pipe. EOF instead means exec succeeded.
    while (write(report[1], &error, sizeof(error)) == -1 && errno == EINTR) {}
    _exit(127);
  }
  for (int i = 0; i < 3; i++) { close(streams[i]); streams[i] = -1; }
  close(report[1]);
  report[1] = -1;
  ssize_t count;
  do { count = read(report[0], &error, sizeof(error)); } while (count == -1 && errno == EINTR);
  if (count == 0) { close(report[0]); return child; }
  if (count < 0) { error = errno; kill(child, SIGKILL); }
  close(report[0]);
  while (waitpid(child, 0, 0) == -1 && errno == EINTR) {}
  errno = error;
  return -1;
fail:
  error = errno;
  for (int i = 0; i < 3; i++) { if (streams[i] != -1) { close(streams[i]); } }
  for (int i = 0; i < 2; i++) { if (report[i] != -1) { close(report[i]); } }
  errno = error;
  return -1;
#endif
}
#endif
