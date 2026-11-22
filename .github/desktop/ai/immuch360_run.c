// SPDX-License-Identifier: MIT
// Copyright (c) 2026 FreeKC (Immuch360)
//
// immuch360-run: starts a program of Immuch360 Desktop (the engines of the AI features, the FFmpeg program of the 3D
// videos, the AV2 decoder) so that it never outlives the app (design-final 2026-10-27, section 4.5, point 3). Dart
// cannot act between the fork and the exec of Process.start, so the app starts this launcher, which makes sure the
// program dies with the app, lowers its priority when asked, and becomes the program by execv: the same process id,
// nothing left behind.
//  - Linux: the kernel kills it when its parent goes (PR_SET_PDEATHSIG, kept across execv). Built with
//    stable-diffusion.cpp, COLMAP, Brush and the FFmpeg program by their jobs and shipped in the same archives.
//  - macOS (lot L10 of the desktop parity plan, 21 November 2026), which has no such signal: before the execv, a
//    watcher is forked off, a grandchild that the double fork leaves to launchd (no zombie under the program). It
//    keeps none of the files of the app open and waits in a kqueue for the end of the app or of the program
//    (EVFILT_PROC, NOTE_EXIT): the app gone, it kills the program (SIGKILL); the program gone, it ends. Built
//    universal by a build phase of mobile/macos/Runner.xcodeproj into Contents/MacOS of the app, signed ad hoc.
//
//   immuch360-run --parent PID [--nice N] [--] PROGRAM [ARGUMENT]...
//
// PID is the process id of the app: if the app is already gone when the launcher starts watching it, the launcher
// stops there (Linux), or the watcher kills the program at once (macOS).
// Exit codes of its own: 2 bad arguments, 125 the app is gone, 126 the watch could not be set, 127 no such program.
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <fcntl.h>
#include <sys/event.h>
#include <sys/wait.h>
#elif defined(__linux__)
#include <sys/prctl.h>
#else
#error "immuch360-run is built for Linux and macOS"
#endif

static int number(const char *text, long *value) {
  char *end = NULL;
  errno = 0;
  *value = strtol(text, &end, 10);
  return errno == 0 && end != text && *end == '\0';
}

#if defined(__APPLE__)
// The watcher: the end of [app] kills [program], the end of [program] ends it. It never returns.
static void watch(pid_t app, pid_t program) {
  // Nothing of the app kept open: its pipes must close with the program, not with the watcher
  int null = open("/dev/null", O_RDWR);
  if (null >= 0) {
    dup2(null, STDIN_FILENO);
    dup2(null, STDOUT_FILENO);
    dup2(null, STDERR_FILENO);
  }
  long limit = sysconf(_SC_OPEN_MAX);
  if (limit < 0 || limit > 65536) {
    limit = 65536;
  }
  for (int fd = STDERR_FILENO + 1; fd < limit; fd++) {
    close(fd);
  }
  // Out of the group of the app: a Ctrl-C in a terminal reaches the program, never its watcher alone
  setsid();
  int queue = kqueue();
  if (queue < 0) {
    _exit(1);
  }
  struct kevent change;
  // The program first: gone already, nothing to watch. Then the app: gone already, the program goes too
  EV_SET(&change, program, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
  if (kevent(queue, &change, 1, NULL, 0, NULL) < 0) {
    _exit(0);
  }
  EV_SET(&change, app, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
  if (kevent(queue, &change, 1, NULL, 0, NULL) < 0) {
    kill(program, SIGKILL);
    _exit(0);
  }
  for (;;) {
    struct kevent event;
    int count = kevent(queue, NULL, 0, &event, 1, NULL);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count > 0 && (pid_t)event.ident == app) {
      kill(program, SIGKILL);
    }
    _exit(0);
  }
}

// Forks the watcher off (fork, fork, the middle one ends at once); 0 once it runs
static int start_watcher(pid_t app) {
  pid_t program = getpid();
  pid_t middle = fork();
  if (middle < 0) {
    return -1;
  }
  if (middle == 0) {
    pid_t watcher = fork();
    if (watcher == 0) {
      watch(app, program);
    }
    _exit(watcher < 0 ? 1 : 0);
  }
  int status = 0;
  while (waitpid(middle, &status, 0) < 0) {
    if (errno != EINTR) {
      return -1;
    }
  }
  return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}
#endif

int main(int argc, char **argv) {
  long parent = 0, nice_value = 0;
  int at = 1;
  while (at < argc && strncmp(argv[at], "--", 2) == 0 && strcmp(argv[at], "--") != 0) {
    if (at + 1 < argc && strcmp(argv[at], "--parent") == 0 && number(argv[at + 1], &parent) && parent > 0) {
      at += 2;
    } else if (at + 1 < argc && strcmp(argv[at], "--nice") == 0 && number(argv[at + 1], &nice_value)) {
      at += 2;
    } else {
      break;
    }
  }
  if (at < argc && strcmp(argv[at], "--") == 0) {
    at++;
  }
  if (parent == 0 || at >= argc) {
    fprintf(stderr, "usage: immuch360-run --parent PID [--nice N] [--] PROGRAM [ARGUMENT]...\n");
    return 2;
  }
#if defined(__APPLE__)
  if ((long)getppid() != parent) {
    return 125;
  }
  if (start_watcher((pid_t)parent) != 0) {
    perror("immuch360-run: watcher");
    return 126;
  }
#else
  if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0) {
    perror("immuch360-run: prctl");
    return 126;
  }
  if ((long)getppid() != parent) {
    return 125;
  }
#endif
  if (nice_value != 0 && setpriority(PRIO_PROCESS, 0, (int)nice_value) != 0) {
    perror("immuch360-run: setpriority");
  }
  execv(argv[at], argv + at);
  fprintf(stderr, "immuch360-run: %s: %s\n", argv[at], strerror(errno));
  return 127;
}
