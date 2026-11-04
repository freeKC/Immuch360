// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FreeKC (Immuch360)
//
// immuch360-av2, the AV2 companion of Immuch360 Desktop: the commands main.c hands over to.
#ifndef IMMUCH360_AV2_H
#define IMMUCH360_AV2_H

#include <stdint.h>

// The protocol of serve (the records of the standard input and the lines of the standard output, README.md): the
// app checks it in the --version line before it starts serve
#define AV2_PROTOCOL 1

#ifndef AV2_SOURCE_COMMIT
#define AV2_SOURCE_COMMIT "unknown"
#endif
#ifndef AV2_DAV2D_COMMIT
#define AV2_DAV2D_COMMIT "unknown"
#endif

typedef struct ServeOptions {
  const char *token;
  unsigned width, height, bits, depth;
  unsigned fps_num, fps_den;
  uint64_t frames;
  int threads;
  int full_range;
  unsigned port;
  uint64_t frame_bytes;  // 0: not checked
  unsigned long parent;  // the process the program ends with, 0: none
} ServeOptions;

int av2_probe(const char *path, int path_index, int threads);
int av2_serve(const ServeOptions *options);

#endif
