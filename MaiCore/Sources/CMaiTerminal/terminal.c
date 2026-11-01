#include "mai_terminal.h"

#ifndef _WIN32
#include <errno.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

int mai_terminal_shell(int master, int slave, const char *shell, const char *cwd, char *const environment[]) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
  errno = ENOTSUP;
  return -1;
#else
  pid_t child = fork();
  if (child != 0) {
    return child;
  }
  close(master);
  if (setsid() == -1 || ioctl(slave, TIOCSCTTY, 0) == -1 || chdir(cwd) == -1) {
    _exit(127);
  }
  for (int fd = 0; fd < 3; fd++) {
    if (dup2(slave, fd) == -1) {
      _exit(127);
    }
  }
  if (slave > 2) {
    close(slave);
  }
  const int signals[] = {SIGINT, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD, SIGPIPE, SIGWINCH, SIGHUP};
  struct sigaction action = {0};
  action.sa_handler = SIG_DFL;
  sigemptyset(&action.sa_mask);
  for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
    sigaction(signals[i], &action, 0);
  }
  sigset_t mask;
  sigemptyset(&mask);
  sigprocmask(SIG_SETMASK, &mask, 0);
  char *const arguments[] = {(char *)shell, "-i", 0};
  execve(shell, arguments, environment);
  _exit(127);
#endif
}

int mai_terminal_spawn(int master, int slave, const char *shell, const char *command, char *const environment[]) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
  errno = ENOTSUP;
  return -1;
#else
  pid_t child = fork();
  if (child != 0) {
    return child;
  }
  // Keep the post-fork path in C: no Swift runtime, allocation or locks in
  // the child of a multithreaded process.
  // Only pmai keeps the master, so its exit hangs up the command's terminal.
  close(master);
  if (setsid() == -1 || ioctl(slave, TIOCSCTTY, 0) == -1) {
    _exit(127);
  }
  for (int fd = 0; fd < 3; fd++) {
    if (dup2(slave, fd) == -1) {
      _exit(127);
    }
  }
  const int signals[] = {SIGINT, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD, SIGPIPE, SIGWINCH};
  struct sigaction action = {0};
  action.sa_handler = SIG_DFL;
  sigemptyset(&action.sa_mask);
  for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
    sigaction(signals[i], &action, 0);
  }
  sigset_t mask;
  sigemptyset(&mask);
  sigprocmask(SIG_SETMASK, &mask, 0);
  // Keep a session leader around so the command's process group is not
  // orphaned: POSIX otherwise discards job-control signals such as SIGTSTP.
  child = fork();
  if (child == -1) {
    _exit(127);
  }
  if (child != 0) {
    signal(SIGTTOU, SIG_IGN);
    setpgid(child, child);
    if (tcsetpgrp(slave, child) == -1) {
      kill(child, SIGKILL);
      _exit(127);
    }
    kill(-child, SIGCONT);
    int status;
    for (;;) {
      if (waitpid(child, &status, WUNTRACED) == -1) {
        if (errno == EINTR) {
          continue;
        }
        _exit(127);
      }
      if (!WIFSTOPPED(status)) {
        break;
      }
      kill(-child, SIGSTOP);
      kill(getpid(), SIGSTOP);
      kill(-child, SIGCONT);
    }
    if (WIFSIGNALED(status)) {
      kill(getpid(), WTERMSIG(status));
    }
    _exit(WIFEXITED(status) ? WEXITSTATUS(status) : 127);
  }
  if (setpgid(0, 0) == -1) {
    _exit(127);
  }
  char *const arguments[] = {(char *)shell, "-c", (char *)command, 0};
  execve(shell, arguments, environment);
  _exit(127);
#endif
}
#endif
