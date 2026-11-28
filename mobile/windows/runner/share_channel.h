#ifndef RUNNER_SHARE_CHANNEL_H_
#define RUNNER_SHARE_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

#include "share_sheet.h"

// The channel immuch360/share (lib/desktop/share/system_share_sheet.dart):
// "Share with Windows…" of the Share menu of the app, through ShareSheet.
// - isSupported: DataTransferManager.IsSupported (false on Windows Server
//   2022, true on Windows 10 and 11);
// - shareFiles {paths, title}: opens the files, then the share window of
//   [window]; answers the number of the share, or an error whose code is the
//   step that failed and whose message is the HRESULT and its text, with
//   {hresult, index} in its details (the index of the file for "file");
// - then calls "event" {share, event, detail} on the channel: "requested"
//   once the window took the files, "target" with the program chosen,
//   "completed", "destroyed" once it let them go;
// - observeNextRequest {paths} (the tests of the desktop workflow): calls
//   "observed" {elapsedMs, existing} at the next request of a share that is
//   not of this channel (share_plus's), with how many of [paths] existed then;
//   foreground (the same tests): whether the window of the app is in front.
class ShareChannel {
 public:
  ShareChannel(flutter::BinaryMessenger* messenger, HWND window);
  ~ShareChannel();

  ShareChannel(const ShareChannel&) = delete;
  ShareChannel& operator=(const ShareChannel&) = delete;

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<ShareSheet> sheet_;
};

#endif  // RUNNER_SHARE_CHANNEL_H_
