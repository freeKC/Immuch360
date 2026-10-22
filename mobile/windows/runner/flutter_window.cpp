#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <wtsapi32.h>

#include <cstring>
#include <optional>
#include <string>

#include "app_identity.h"
#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

// GUID_CONSOLE_DISPLAY_STATE (winnt.h), written out: the header declares it
// for a library that defines it. Its notification gives 0 for a display off,
// 1 on and 2 dimmed, at once when registered and at each change.
constexpr GUID kConsoleDisplayState = {
    0x6fe69556,
    0x704a,
    0x47a0,
    {0x8f, 0x24, 0xc2, 0x8d, 0x93, 0x6f, 0xda, 0x47}};

constexpr char kSessionChannel[] = "immuch360/session";

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  // window_manager's destroy() (the close guard) ends the message loop with
  // PostQuitMessage while this window still exists. Without this, the
  // controller would go with the members, whose pointer stays set meanwhile:
  // the view's destruction sends messages to this window, MessageHandler hands
  // them to the half destroyed controller and the app crashes on every close.
  // Destroy() takes the path of a normal close instead (OnDestroy first).
  Destroy();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  instance_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          IMMUCH360_INSTANCE_CHANNEL,
          &flutter::StandardMethodCodec::GetInstance());
  // Room on that channel for the files of several later starts that come
  // before Dart listens to it: Windows starts the app once per file opened
  // with it, and a channel keeps one message by default. Flutter's control
  // channel resizes the buffer, before any message of those starts.
  flutter::MethodChannel<flutter::EncodableValue> channel_buffers(
      flutter_controller_->engine()->messenger(), "dev.flutter/channel-buffers",
      &flutter::StandardMethodCodec::GetInstance());
  channel_buffers.InvokeMethod(
      "resize",
      std::make_unique<flutter::EncodableValue>(flutter::EncodableList{
          flutter::EncodableValue(IMMUCH360_INSTANCE_CHANNEL),
          flutter::EncodableValue(1000)}));
  if (!early_hand_overs_.empty()) {
    instance_channel_->InvokeMethod(
        "openFiles",
        std::make_unique<flutter::EncodableValue>(std::move(early_hand_overs_)));
    early_hand_overs_.clear();
  }
  // The session locked and the display off, for the Spatial page's webcam:
  // the channel first, since the display's state comes at once
  session_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kSessionChannel,
          &flutter::StandardMethodCodec::GetInstance());
  session_notification_ =
      ::WTSRegisterSessionNotification(GetHandle(), NOTIFY_FOR_THIS_SESSION) !=
      FALSE;
  display_notification_ = ::RegisterPowerSettingNotification(
      GetHandle(), &kConsoleDisplayState, DEVICE_NOTIFY_WINDOW_HANDLE);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // Files dropped on the window open as a later start's do (OnDropFiles). The
  // Flutter view, a child window, takes no drop itself: Windows hands a drop on
  // it to this window, which accepts files.
  ::DragAcceptFiles(GetHandle(), TRUE);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (session_notification_) {
    ::WTSUnRegisterSessionNotification(GetHandle());
    session_notification_ = false;
  }
  if (display_notification_ != nullptr) {
    ::UnregisterPowerSettingNotification(display_notification_);
    display_notification_ = nullptr;
  }
  session_channel_ = nullptr;
  instance_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_COPYDATA: {
      const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (data != nullptr && data->dwData == IMMUCH360_HAND_OVER_TAG) {
        OnHandOver(*data);
        return TRUE;
      }
      break;
    }
    case WM_DROPFILES:
      OnDropFiles(reinterpret_cast<HDROP>(wparam));
      return 0;
    case WM_WTSSESSION_CHANGE:
      if (wparam == WTS_SESSION_LOCK) {
        SendPresence("locked");
      } else if (wparam == WTS_SESSION_UNLOCK) {
        SendPresence("unlocked");
      }
      break;
    case WM_POWERBROADCAST:
      if (wparam == PBT_POWERSETTINGCHANGE && lparam != 0) {
        const auto* setting =
            reinterpret_cast<const POWERBROADCAST_SETTING*>(lparam);
        if (setting->PowerSetting == kConsoleDisplayState &&
            setting->DataLength >= sizeof(DWORD)) {
          DWORD state = 0;
          memcpy(&state, setting->Data, sizeof(state));
          SendPresence(state == 0 ? "displayOff" : "displayOn");
        }
        return TRUE;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::OnHandOver(const COPYDATASTRUCT& data) {
  HWND window = GetHandle();
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  }
  ::SetForegroundWindow(window);

  // The arguments, UTF-8, each ended by a zero byte (main.cpp)
  flutter::EncodableList arguments;
  const char* bytes = static_cast<const char*>(data.lpData);
  std::string argument;
  for (DWORD i = 0; bytes != nullptr && i < data.cbData; i++) {
    if (bytes[i] == '\0') {
      arguments.emplace_back(argument);
      argument.clear();
    } else {
      argument.push_back(bytes[i]);
    }
  }
  if (arguments.empty()) {
    return;
  }
  if (!instance_channel_) {
    // A start handled while the view is being made
    early_hand_overs_.insert(early_hand_overs_.end(), arguments.begin(),
                             arguments.end());
    return;
  }
  instance_channel_->InvokeMethod(
      "openFiles",
      std::make_unique<flutter::EncodableValue>(std::move(arguments)));
}

void FlutterWindow::OnDropFiles(HDROP drop) {
  // The paths of the dropped files and folders, UTF-8, as a later start gives
  // them: Dart opens one file in the viewer, several or a folder as a page
  flutter::EncodableList paths;
  const UINT count = ::DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count; i++) {
    const UINT length = ::DragQueryFileW(drop, i, nullptr, 0);
    if (length == 0) {
      continue;
    }
    std::wstring path(length + 1, L'\0');
    if (::DragQueryFileW(drop, i, path.data(), length + 1) == 0) {
      continue;
    }
    path.resize(length);
    paths.emplace_back(Utf8FromUtf16(path.c_str()));
  }
  ::DragFinish(drop);
  if (instance_channel_ && !paths.empty()) {
    instance_channel_->InvokeMethod(
        "openFiles",
        std::make_unique<flutter::EncodableValue>(std::move(paths)));
  }
}

void FlutterWindow::SendPresence(const char* message) {
  if (session_channel_) {
    session_channel_->InvokeMethod(message, nullptr);
  }
}
