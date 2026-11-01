#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "app_identity.h"
#include "close_watchdog.h"
#include "crash_dumps.h"
#include "flutter_window.h"
#include "gpu_probe.h"
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

// The longest a later start waits for a copy that is closing to end: that
// copy ends within 6 s of its close (flutter_window.cpp, close_watchdog.h)
constexpr DWORD kClosingCopyWaitMs = 10000;

// A second start of the app (a file opened with it while it runs) gives its
// command line to the running one, brings that window to the front and
// quits: one copy of the database and of the network share per user. False
// when the running copy did not take it: it is closing (it refuses then,
// flutter_window.cpp), it does not answer, or its window is gone already;
// |running_process| tells which process it was, 0 when no window was found.
bool HandOverToRunningInstance(const std::vector<std::string>& arguments,
                               DWORD* running_process) {
  *running_process = 0;
  HWND running = nullptr;
  // The first copy may still be creating its window
  for (int attempt = 0; attempt < 25 && running == nullptr; attempt++) {
    running = ::FindWindowW(IMMUCH360_WINDOW_CLASS_W, nullptr);
    if (running == nullptr) {
      ::Sleep(200);
    }
  }
  if (running == nullptr) {
    return false;
  }
  ::GetWindowThreadProcessId(running, running_process);
  ::AllowSetForegroundWindow(*running_process);

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
  const LRESULT sent = ::SendMessageTimeoutW(
      running, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data),
      SMTO_ABORTIFHUNG, 5000, &result);
  return sent != 0 && result == TRUE;
}

// The running copy did not take the command line of this start: it is
// closing, or ending. Waits for its process to end (|running_process|, 0 when
// unknown), then for the instance mutex to go, and makes it this start's.
// True when this start is the only copy now, its mutex in |instance_mutex|;
// false when another copy still runs.
bool TakeOverFromClosingInstance(DWORD running_process,
                                 HANDLE* instance_mutex) {
  // This handle would keep the mutex alive
  ::CloseHandle(*instance_mutex);
  *instance_mutex = nullptr;
  const ULONGLONG until = ::GetTickCount64() + kClosingCopyWaitMs;
  if (running_process != 0) {
    HANDLE process = ::OpenProcess(SYNCHRONIZE, FALSE, running_process);
    if (process != nullptr) {
      ::WaitForSingleObject(process, kClosingCopyWaitMs);
      ::CloseHandle(process);
    }
  }
  for (;;) {
    *instance_mutex =
        ::CreateMutexW(nullptr, FALSE, IMMUCH360_INSTANCE_MUTEX_W);
    if (*instance_mutex == nullptr) {
      return false;
    }
    if (::GetLastError() != ERROR_ALREADY_EXISTS) {
      return true;
    }
    if (::GetTickCount64() >= until) {
      return false;
    }
    ::CloseHandle(*instance_mutex);
    *instance_mutex = nullptr;
    ::Sleep(200);
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Before anything else can crash
  InstallCrashDumps(CrashDumpFolder());

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // A start of the app by itself to read the graphics cards
  // (lib/desktop/ai/gpu/gpu_probe.dart): it writes their JSON and ends here,
  // before the guard of the single instance, which would hand it to the
  // window that runs, and before any window
  std::wstring gpu_probe_output;
  if (GpuProbeRequested(&gpu_probe_output)) {
    return RunGpuProbe(gpu_probe_output);
  }

  // Kept for the life of the process; the system releases it at exit
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, FALSE, IMMUCH360_INSTANCE_MUTEX_W);
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    DWORD running_process = 0;
    if (HandOverToRunningInstance(command_line_arguments, &running_process)) {
      ::CloseHandle(instance_mutex);
      return EXIT_SUCCESS;
    }
    // A start right after a close: the closing copy does not take the files,
    // this start opens them once that copy has ended
    if (!TakeOverFromClosingInstance(running_process, &instance_mutex)) {
      // Another start came first meanwhile, or the running copy does not
      // answer: the files go to it, as before
      HandOverToRunningInstance(command_line_arguments, &running_process);
      if (instance_mutex != nullptr) {
        ::CloseHandle(instance_mutex);
      }
      return EXIT_SUCCESS;
    }
  }

  // Ends the process a few seconds after its window closes, whatever still
  // runs then (close_watchdog.h); made before the engine loads anything
  StartCloseWatchdog();

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
