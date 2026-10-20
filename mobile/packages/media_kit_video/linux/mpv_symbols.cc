// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

// Immuch360 (IMMUCH360-NOTE.md, patch 8): see mpv_symbols.h.

#include "include/media_kit_video/mpv_symbols.h"

#include <dlfcn.h>
#include <glib.h>

#include <cstdlib>

static void* mpv_symbols_open_library() {
  const char* names[] = {
      getenv("LIBMPV_LIBRARY_PATH"),
      "libmpv.so",
      "libmpv.so.2",
      "libmpv.so.1",
  };
  // The library media_kit's Dart side opened first: RTLD_NOLOAD only finds a
  // library that is already in the process.
  for (const char* name : names) {
    if (name != NULL && name[0] != '\0') {
      void* library = dlopen(name, RTLD_LAZY | RTLD_NOLOAD);
      if (library != NULL) {
        return library;
      }
    }
  }
  for (const char* name : names) {
    if (name != NULL && name[0] != '\0') {
      void* library = dlopen(name, RTLD_LAZY);
      if (library != NULL) {
        return library;
      }
    }
  }
  return NULL;
}

template <typename T>
static bool mpv_symbols_find(void* library, const char* name, T* function) {
  *function = reinterpret_cast<T>(dlsym(library, name));
  if (*function == NULL) {
    g_printerr("media_kit: libmpv has no %s.\n", name);
    return false;
  }
  return true;
}

static const MpvSymbols* mpv_symbols_load() {
  void* library = mpv_symbols_open_library();
  if (library == NULL) {
    g_printerr("media_kit: libmpv could not be opened: %s\n", dlerror());
    return NULL;
  }
  // The library is never closed: the players use it until the process ends
  static MpvSymbols symbols;
  // Every function looked up, so that each missing one is printed
  bool found = true;
  found = mpv_symbols_find(library, "mpv_set_option_string",
                           &symbols.set_option_string) && found;
  found = mpv_symbols_find(library, "mpv_get_property",
                           &symbols.get_property) && found;
  found = mpv_symbols_find(library, "mpv_free_node_contents",
                           &symbols.free_node_contents) && found;
  found = mpv_symbols_find(library, "mpv_render_context_create",
                           &symbols.render_context_create) && found;
  found = mpv_symbols_find(library, "mpv_render_context_set_update_callback",
                           &symbols.render_context_set_update_callback) &&
          found;
  found = mpv_symbols_find(library, "mpv_render_context_render",
                           &symbols.render_context_render) && found;
  found = mpv_symbols_find(library, "mpv_render_context_free",
                           &symbols.render_context_free) && found;
  return found ? &symbols : NULL;
}

const MpvSymbols* mpv_symbols() {
  // Initialised once, by the first caller, thread safe (C++11)
  static const MpvSymbols* symbols = mpv_symbols_load();
  return symbols;
}
