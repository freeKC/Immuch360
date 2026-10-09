#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "app_identity.h"
#include "crash_dumps.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

// The first copy reads what it is handed against its own current folder: an
// argument naming a file or a folder from the folder this start was made in
// (immuch360.exe IMG_0001.insp in a terminal) is given with its full path,
// which only this start can work out. Anything else (an option, a link, a
// path that does not exist) goes as typed.
std::string WithFullPath(const std::string& argument) {
  if (argument.empty() || argument[0] == '-') {
    return argument;
  }
  const int wide_length =
      ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argument.c_str(),
                            static_cast<int>(argument.size()), nullptr, 0);
  if (wide_length <= 0) {
    return argument;
  }
  std::wstring wide(wide_length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argument.c_str(),
                        static_cast<int>(argument.size()), wide.data(),
                        wide_length);
  const DWORD needed = ::GetFullPathNameW(wide.c_str(), 0, nullptr, nullptr);
  if (needed == 0) {
    return argument;
  }
  std::wstring full(needed, L'\0');
  const DWORD written =
      ::GetFullPathNameW(wide.c_str(), needed, full.data(), nullptr);
  if (written == 0 || written >= needed) {
    return argument;
  }
  full.resize(written);
  if (::GetFileAttributesW(full.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return argument;
  }
  return Utf8FromUtf16(full.c_str());
}

// A second start of the app (a file opened with it while it runs) gives its
// command line to the running one, brings that window to the front and
// quits: one copy of the database and of the network share per user.
void HandOverToRunningInstance(const std::vector<std::string>& arguments) {
  HWND running = nullptr;
  // The first copy may still be creating its window
  for (int attempt = 0; attempt < 25 && running == nullptr; attempt++) {
    running = ::FindWindowW(IMMUCH360_WINDOW_CLASS_W, nullptr);
    if (running == nullptr) {
      ::Sleep(200);
    }
  }
  if (running == nullptr) {
    return;
  }
  DWORD running_process = 0;
  ::GetWindowThreadProcessId(running, &running_process);
  ::AllowSetForegroundWindow(running_process);

  // The arguments, UTF-8, each ended by a zero byte
  std::string payload;
  for (const std::string& argument : arguments) {
    payload.append(WithFullPath(argument));
    payload.push_back('\0');
  }
  COPYDATASTRUCT data;
  data.dwData = IMMUCH360_HAND_OVER_TAG;
  data.cbData = static_cast<DWORD>(payload.size());
  data.lpData = payload.empty() ? nullptr : payload.data();
  DWORD_PTR result = 0;
  ::SendMessageTimeoutW(running, WM_COPYDATA, 0,
                        reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG,
                        5000, &result);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Before anything else can crash
  InstallCrashDumps(CrashDumpFolder());

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // Kept for the life of the process; the system releases it at exit
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, FALSE, IMMUCH360_INSTANCE_MUTEX_W);
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HandOverToRunningInstance(command_line_arguments);
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  int exit_code = EXIT_SUCCESS;
  {
    FlutterWindow window(project);
    Win32Window::Point origin(10, 10);
    Win32Window::Size size(1280, 720);
    if (window.Create(IMMUCH360_PRODUCT_NAME_W, origin, size)) {
      window.SetQuitOnClose(true);

      ::MSG msg;
      while (::GetMessage(&msg, nullptr, 0, 0)) {
        ::TranslateMessage(&msg);
        ::DispatchMessage(&msg);
      }
    } else {
      exit_code = EXIT_FAILURE;
    }
    // The close guard ends the loop with PostQuitMessage while the window, the
    // engine and the plugins still exist (flutter_window.cpp): they go here,
    // at the end of this block, while COM is still there for the objects they
    // release (the share sheet's DataTransferManager, the engine's
    // DirectManipulation), never after it.
  }

  ::CoUninitialize();
  return exit_code;
}
