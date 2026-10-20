// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

// Immuch360 (IMMUCH360-NOTE.md, patch 8): the plugin does not link libmpv. The
// library is the system's, libmpv.so.2 on most distributions and libmpv.so.1
// on Ubuntu 22.04, and a plugin linked on one would not load on the other,
// taking the whole app down with it. media_kit's Dart side opens libmpv at run
// time (NativeLibrary); the functions below are looked up in that same library.

#ifndef MPV_SYMBOLS_H_
#define MPV_SYMBOLS_H_

#include "mpv/client.h"
#include "mpv/render.h"
#include "mpv/render_gl.h"

typedef struct _MpvSymbols {
  decltype(&mpv_set_option_string) set_option_string;
  decltype(&mpv_get_property) get_property;
  decltype(&mpv_free_node_contents) free_node_contents;
  decltype(&mpv_render_context_create) render_context_create;
  decltype(&mpv_render_context_set_update_callback)
      render_context_set_update_callback;
  decltype(&mpv_render_context_render) render_context_render;
  decltype(&mpv_render_context_free) render_context_free;
} MpvSymbols;

// The functions of libmpv the plugin calls, looked up once in the libmpv the
// process already opened (LIBMPV_LIBRARY_PATH, then libmpv.so, libmpv.so.2 and
// libmpv.so.1, the order of media_kit's NativeLibrary), else in the first of
// them that opens. NULL when none opens or a function is missing; the reason is
// printed once.
const MpvSymbols* mpv_symbols();

#endif  // MPV_SYMBOLS_H_
