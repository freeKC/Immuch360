#ifndef RUNNER_CLIPBOARD_CHANNEL_H_
#define RUNNER_CLIPBOARD_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// The channel immuch360/clipboard (lib/desktop/clipboard/desktop_clipboard.dart):
// writeFiles puts files on the clipboard of Windows as Explorer does (CF_HDROP,
// with "Preferred DropEffect" set to copy) and, for a photo, its picture
// (CF_DIB and "PNG", made by Dart); it answers the sequence number of the
// clipboard after the write. holds tells whether that number is still the
// clipboard's: nothing was copied since. [owner] is the window of the app,
// which owns what it puts there; the data stays once the app quits.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateClipboardChannel(flutter::BinaryMessenger* messenger, HWND owner);

#endif  // RUNNER_CLIPBOARD_CHANNEL_H_
