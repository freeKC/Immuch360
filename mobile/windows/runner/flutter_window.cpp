#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "app_identity.h"
#include "flutter/generated_plugin_registrant.h"

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  if (instance_channel_ && !arguments.empty()) {
    instance_channel_->InvokeMethod(
        "openFiles",
        std::make_unique<flutter::EncodableValue>(std::move(arguments)));
  }
}
