#include "crash_dumps.h"

#include <windows.h>

#include <dbghelp.h>
#include <shlobj.h>

#include <algorithm>
#include <cwchar>
#include <vector>

#include "app_identity.h"

namespace {

// A crash in native code (a plugin, the engine) leaves no Dart log line: a
// small minidump tells where it happened. It stays on the computer until the
// user saves it with the logs, which may end up attached to a public issue, so
// it holds as little as a stack walk needs: the threads, their registers and
// the pointers of their stacks into code and stacks (MiniDumpFilterMemory
// zeroes the rest of the stacks, where a password or a key may linger), and
// the module names without their folders (MiniDumpFilterModulePaths: the
// unpacked ZIP sits under the user's account name). No heap, no other memory.
constexpr MINIDUMP_TYPE kCrashDumpType = static_cast<MINIDUMP_TYPE>(
    MiniDumpNormal | MiniDumpFilterMemory | MiniDumpFilterModulePaths);

// The reports kept in the folder: "Save logs to a file" takes the latest ten
// (maxCrashDumpsSaved in save_to_folder.dart), and a crash at every start
// must not fill the disk
constexpr size_t kCrashDumpsKept = 10;

// The longest a crashing thread waits for the report before the process ends
constexpr DWORD kCrashDumpWaitMs = 30000;

// Worked out at start, since the crash handler must do as little as possible
wchar_t g_folder[MAX_PATH * 2] = L"";

// The report is written by a thread of its own, made at start and waiting for
// a crash, never by the crashing thread: dbghelp is single threaded, so two
// threads crashing together (two dnsapi threads in bonsoir_windows did) wrote
// two reports at once and one came out empty; the faulting stack is the one
// being described; and after a stack overflow that stack has no room left to
// run MiniDumpWriteDump in. Only the first crash is written; any other thread
// that crashes meanwhile waits for it, so the process does not end mid-write.
HANDLE g_crash_request = nullptr;
HANDLE g_crash_written = nullptr;
volatile LONG g_crashing = 0;
EXCEPTION_POINTERS* g_crash_exception = nullptr;
DWORD g_crash_thread = 0;

// Older reports go at start, and so do empty ones, left by a write that was
// cut. The names start with the date and time, so they sort by age.
void PruneCrashDumps(const std::wstring& folder) {
  WIN32_FIND_DATAW found;
  HANDLE search =
      ::FindFirstFileW((folder + L"\\immuch360-*.dmp").c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) {
    return;
  }
  std::vector<std::wstring> dumps;
  do {
    if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
      continue;
    }
    if (found.nFileSizeHigh == 0 && found.nFileSizeLow == 0) {
      ::DeleteFileW((folder + L"\\" + found.cFileName).c_str());
    } else {
      dumps.push_back(found.cFileName);
    }
  } while (::FindNextFileW(search, &found));
  ::FindClose(search);
  if (dumps.size() <= kCrashDumpsKept) {
    return;
  }
  std::sort(dumps.begin(), dumps.end());
  for (size_t i = 0; i + kCrashDumpsKept < dumps.size(); i++) {
    ::DeleteFileW((folder + L"\\" + dumps[i]).c_str());
  }
}

void WriteCrashDump(EXCEPTION_POINTERS* exception, DWORD thread) {
  SYSTEMTIME now;
  ::GetLocalTime(&now);
  wchar_t path[MAX_PATH * 2 + 64];
  // The process id keeps two crashes of the same second apart
  swprintf_s(path, L"%s\\immuch360-%04u%02u%02u-%02u%02u%02u-%lu.dmp",
             g_folder, now.wYear, now.wMonth, now.wDay, now.wHour,
             now.wMinute, now.wSecond, ::GetCurrentProcessId());
  HANDLE file = ::CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  MINIDUMP_EXCEPTION_INFORMATION info;
  info.ThreadId = thread;
  info.ExceptionPointers = exception;
  info.ClientPointers = FALSE;
  ::MiniDumpWriteDump(::GetCurrentProcess(), ::GetCurrentProcessId(), file,
                      kCrashDumpType, exception ? &info : nullptr, nullptr,
                      nullptr);
  ::CloseHandle(file);
}

DWORD WINAPI CrashDumpWriter(LPVOID) {
  ::WaitForSingleObject(g_crash_request, INFINITE);
  WriteCrashDump(g_crash_exception, g_crash_thread);
  ::SetEvent(g_crash_written);
  return 0;
}

LONG WINAPI OnUnhandledException(EXCEPTION_POINTERS* exception) {
  if (::InterlockedCompareExchange(&g_crashing, 1, 0) == 0) {
    g_crash_exception = exception;
    g_crash_thread = ::GetCurrentThreadId();
    ::SetEvent(g_crash_request);
  }
  ::WaitForSingleObject(g_crash_written, kCrashDumpWaitMs);
  return EXCEPTION_CONTINUE_SEARCH;
}

}  // namespace

std::wstring CrashDumpFolder() {
  PWSTR local_app_data = nullptr;
  if (FAILED(::SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                    &local_app_data))) {
    return L"";
  }
  std::wstring folder = std::wstring(local_app_data) + L"\\" +
                        IMMUCH360_COMPANY_NAME_W + L"\\" +
                        IMMUCH360_PRODUCT_NAME_W + L"\\crash_dumps";
  ::CoTaskMemFree(local_app_data);
  return folder;
}

bool InstallCrashDumps(const std::wstring& folder) {
  if (folder.empty() || folder.size() >= MAX_PATH * 2) {
    return false;
  }
  const int created = ::SHCreateDirectoryExW(nullptr, folder.c_str(), nullptr);
  if (created != ERROR_SUCCESS && created != ERROR_ALREADY_EXISTS &&
      created != ERROR_FILE_EXISTS) {
    return false;
  }
  PruneCrashDumps(folder);
  wcsncpy_s(g_folder, folder.c_str(), _TRUNCATE);

  g_crash_request = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
  g_crash_written = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (g_crash_request == nullptr || g_crash_written == nullptr) {
    return false;
  }
  HANDLE writer =
      ::CreateThread(nullptr, 0, CrashDumpWriter, nullptr, 0, nullptr);
  if (writer == nullptr) {
    return false;
  }
  // The thread lives as long as the process; its handle is not needed
  ::CloseHandle(writer);
  ::SetUnhandledExceptionFilter(OnUnhandledException);
  return true;
}
