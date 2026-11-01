#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <shellapi.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Brings to Dart the command lines of later starts of the app (main.cpp).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      instance_channel_;

  // Where Dart tells that the window closes (OnClosing).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // The window closes: a later start of the app is not handed over to this
  // copy, which waits for its end instead (main.cpp).
  bool closing_ = false;

  // The files of later starts handled before that channel was made, sent on
  // it once it is (OnCreate).
  flutter::EncodableList early_hand_overs_;

  // Hands the command line a second start sent with WM_COPYDATA to Dart, and
  // brings this window to the front.
  void OnHandOver(const COPYDATASTRUCT& data);

  // Hands the files and folders dropped on the window to Dart, on the channel
  // of the later starts.
  void OnDropFiles(HDROP drop);

  // The window closes, once Dart decided it (the close guard): the window
  // hides at once, and the process ends within seconds whatever still runs
  // (close_watchdog.h), while Dart ends its own work.
  void OnClosing();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
