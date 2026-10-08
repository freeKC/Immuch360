#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <dbghelp.h>
#include <shlobj.h>

#include <cwchar>
#include <string>
#include <vector>

#include "app_identity.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

// Where the crash reports of the native code go: the cache folder of the app
// (getApplicationCacheDirectory() on the Dart side), whose "Save logs to a
// file" collects them. Worked out at start, since the crash handler must do as
// little as possible.
wchar_t g_crash_dump_folder[MAX_PATH * 2] = L"";

void PrepareCrashDumpFolder() {
  PWSTR local_app_data = nullptr;
  if (FAILED(::SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                    &local_app_data))) {
    return;
  }
  std::wstring folder = std::wstring(local_app_data) + L"\\" +
                        IMMUCH360_COMPANY_NAME_W + L"\\" +
                        IMMUCH360_PRODUCT_NAME_W + L"\\crash_dumps";
  ::CoTaskMemFree(local_app_data);
  const int created = ::SHCreateDirectoryExW(nullptr, folder.c_str(), nullptr);
  if (created != ERROR_SUCCESS && created != ERROR_ALREADY_EXISTS &&
      created != ERROR_FILE_EXISTS) {
    return;
  }
  wcsncpy_s(g_crash_dump_folder, folder.c_str(), _TRUNCATE);
}

// A crash in native code (a plugin, the engine) leaves no Dart log line: a
// small minidump (the threads and their stacks, not the memory of the app)
// tells where it happened. It stays on the computer until the user saves it.
LONG WINAPI WriteCrashDump(EXCEPTION_POINTERS* exception) {
  if (g_crash_dump_folder[0] == L'\0') {
    return EXCEPTION_CONTINUE_SEARCH;
  }
  SYSTEMTIME now;
  ::GetLocalTime(&now);
  wchar_t path[MAX_PATH * 2 + 64];
  swprintf_s(path, L"%s\\immuch360-%04u%02u%02u-%02u%02u%02u.dmp",
             g_crash_dump_folder, now.wYear, now.wMonth, now.wDay, now.wHour,
             now.wMinute, now.wSecond);
  HANDLE file = ::CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file != INVALID_HANDLE_VALUE) {
    MINIDUMP_EXCEPTION_INFORMATION info;
    info.ThreadId = ::GetCurrentThreadId();
    info.ExceptionPointers = exception;
    info.ClientPointers = FALSE;
    ::MiniDumpWriteDump(::GetCurrentProcess(), ::GetCurrentProcessId(), file,
                        MiniDumpNormal, exception ? &info : nullptr, nullptr,
                        nullptr);
    ::CloseHandle(file);
  }
  return EXCEPTION_CONTINUE_SEARCH;
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
    payload.append(argument);
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
  PrepareCrashDumpFolder();
  ::SetUnhandledExceptionFilter(WriteCrashDump);

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

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(IMMUCH360_PRODUCT_NAME_W, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
