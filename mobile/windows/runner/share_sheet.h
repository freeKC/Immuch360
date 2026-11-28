#ifndef RUNNER_SHARE_SHEET_H_
#define RUNNER_SHARE_SHEET_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

// The share window of Windows (DataTransferManager through
// IDataTransferManagerInterop, the way a Win32 program that has no package
// reaches it) for files of this computer. No Flutter here: the channel
// (share_channel.h) and the probe of the desktop workflow use it alike.
//
// Unlike share_plus 10.1.4, whose Windows code answers Dart before the window
// asks for its data and logs nothing, each step tells its HRESULT:
// - the files are opened as StorageFile objects before the window shows, so a
//   file that is missing or cannot be read fails at once, with its reason;
// - the window asks for the data later, from the message loop
//   (DataRequested): it gets the files as storage items, read only;
// - once a program is chosen (TargetApplicationChosen), once it says it is
//   done (OperationCompleted), and once the data package is let go
//   (Destroyed, also when the window is closed without a choice), an event
//   tells it. Every event comes on the thread that made this object.
class ShareSheet {
 public:
  // [event] is "requested" (detail: the number of files given), "target"
  // (detail: the name of the program chosen), "completed" (detail: the
  // operation, 1 for a copy) or "destroyed"; [share] is the number Show gave.
  using EventHandler = std::function<void(int64_t share, const std::string& event, const std::wstring& detail)>;

  // [window] is the top level window of the app, which the share window is
  // shown for; [on_event] gets every event.
  ShareSheet(HWND window, EventHandler on_event);
  ~ShareSheet();

  ShareSheet(const ShareSheet&) = delete;
  ShareSheet& operator=(const ShareSheet&) = delete;

  // Whether Windows says it can share here (DataTransferManager.IsSupported);
  // [hr] tells why it could not be asked, which counts as not supported.
  bool IsSupported(HRESULT* hr);

  // What failed in Show: [step] names it ("activation", "window", "file",
  // "show"), [hr] is its HRESULT, [index] the file for "file"
  struct Failure {
    std::string step;
    HRESULT hr = S_OK;
    int index = -1;
  };

  // Opens the share window for [paths] (absolute) under [title]. Returns the
  // number of this share, which its events carry, or 0 with [failure] filled.
  int64_t Show(const std::vector<std::wstring>& paths, const std::wstring& title, Failure* failure);

  // For the probe and the tests of the desktop workflow: the share window is
  // shown for [paths] exactly as share_plus 10.1.4 does it, the files opened
  // only once the window asks (DataRequested); [on_request] then tells how
  // many of them could still be opened and the HRESULT of the first that
  // could not. Returns the HRESULT of ShowShareUIForWindow.
  HRESULT ShowLikeSharePlus(const std::vector<std::wstring>& paths,
                            std::function<void(int opened, HRESULT first_error)> on_request);

  // For the tests of the desktop workflow: at the next request of the share
  // window that is not a share of this object (share_plus's), [on_request]
  // tells how long after this call it came and how many of [paths] still
  // existed then. Returns the HRESULT of reaching the DataTransferManager.
  // [manager_changed] tells whether the DataTransferManager Windows gave
  // this time is another object than the one of the last share.
  HRESULT ObserveNextRequest(const std::vector<std::wstring>& paths,
                             std::function<void(double elapsed_ms, int existing)> on_request,
                             bool* manager_changed = nullptr);

  // Runs [task] later on the thread of this object (from any thread)
  void Post(std::function<void()> task);

  // The message an HRESULT stands for, in the language of the user
  static std::wstring MessageOf(HRESULT hr);

 private:
  struct State;
  std::shared_ptr<State> state_;
};

#endif  // RUNNER_SHARE_SHEET_H_
