#ifndef RUNNER_CLIPBOARD_CHANNEL_H_
#define RUNNER_CLIPBOARD_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// The channel immuch360/clipboard (lib/desktop/clipboard/desktop_clipboard.dart)
// on the CLIPBOARD selection of GTK, X11 or Wayland alike. writeFiles offers
// the files as x-special/gnome-copied-files ("copy" then their URIs, what
// Nautilus, Nemo and Caja paste) and text/uri-list (Dolphin, Thunar, browsers,
// mail and chat programs), and for a photo image/png, its picture made by Dart;
// it answers the number of that write. holds tells whether the app still owns
// the selection with that write: nothing was copied since. The app serves the
// data while it runs, as every Linux program does.
FlMethodChannel* clipboard_channel_new(FlBinaryMessenger* messenger);

// The text of x-special/gnome-copied-files for [uris]: "copy", then one URI a
// line, no line end after the last. Freed with g_free.
gchar* clipboard_gnome_copied_files(const gchar* const* uris);

#endif  // RUNNER_CLIPBOARD_CHANNEL_H_
