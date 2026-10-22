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

  // Tells Dart when the session locks or unlocks and when the display goes
  // off or on (lib/desktop/window/session_presence.dart): the Spatial page
  // closes the webcam while nobody can be in front of the computer.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      session_channel_;
  HPOWERNOTIFY display_notification_ = nullptr;
  bool session_notification_ = false;

  // The files of later starts handled before that channel was made, sent on
  // it once it is (OnCreate).
  flutter::EncodableList early_hand_overs_;

  // Hands the command line a second start sent with WM_COPYDATA to Dart, and
  // brings this window to the front.
  void OnHandOver(const COPYDATASTRUCT& data);

  // Hands the files and folders dropped on the window to Dart, on the channel
  // of the later starts.
  void OnDropFiles(HDROP drop);

  // Sends one of "locked", "unlocked", "displayOff", "displayOn" to Dart.
  void SendPresence(const char* message);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
