// SPDX-License-Identifier: MIT
// Copyright (c) 2026 FreeKC (Immuch360)
//
// immuch360-run: starts a program of the AI features of Immuch360 Desktop on Linux so that it never outlives the app
// (design-final 2026-10-27, section 4.5, point 3). Dart cannot act between the fork and the exec of Process.start, so
// the app starts this launcher, which asks the kernel to kill it when its parent goes (PR_SET_PDEATHSIG, kept across
// execv), lowers its priority when asked, and becomes the program by execv: the same process id, nothing left behind.
// Built with stable-diffusion.cpp by the sdcpp-linux job of immuch360-desktop.yml and shipped in the same archive.
//
//   immuch360-run --parent PID [--nice N] [--] PROGRAM [ARGUMENT]...
//
// PID is the process id of the app: if the app is already gone when the signal is set, the launcher stops there.
// Exit codes of its own: 2 bad arguments, 125 the app is gone, 126 the signal could not be set, 127 no such program.
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <unistd.h>

static int number(const char *text, long *value) {
  char *end = NULL;
  errno = 0;
  *value = strtol(text, &end, 10);
  return errno == 0 && end != text && *end == '\0';
}

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
  if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0) {
    perror("immuch360-run: prctl");
    return 126;
  }
  if ((long)getppid() != parent) {
    return 125;
  }
  if (nice_value != 0 && setpriority(PRIO_PROCESS, 0, (int)nice_value) != 0) {
    perror("immuch360-run: setpriority");
  }
  execv(argv[at], argv + at);
  fprintf(stderr, "immuch360-run: %s: %s\n", argv[at], strerror(errno));
  return 127;
}
