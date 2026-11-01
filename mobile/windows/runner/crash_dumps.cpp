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

// A hang at the close (close_watchdog.cpp) is reported with the threads'
// times and start addresses too: which thread waits for which matters there
constexpr MINIDUMP_TYPE kHangDumpType =
    static_cast<MINIDUMP_TYPE>(kCrashDumpType | MiniDumpWithThreadInfo);

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

// The report of a hang is written by a thread of its own too, made at start
// and waiting: a thread made at the moment of the hang may never run, since a
// new thread needs the loader of Windows, which a library being loaded held
// for 10 s at a close on 1 November 2026.
HANDLE g_hang_request = nullptr;
HANDLE g_hang_written = nullptr;

// Older reports go at start, and so do empty ones, left by a write that was
// cut, and the hang reports whose write was cut (still .tmp). The names start
// with the date and time, so they sort by age.
void PruneCrashDumps(const std::wstring& folder) {
  WIN32_FIND_DATAW found;
  HANDLE unfinished =
      ::FindFirstFileW((folder + L"\\immuch360-*.tmp").c_str(), &found);
  if (unfinished != INVALID_HANDLE_VALUE) {
    do {
      if (!(found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
        ::DeleteFileW((folder + L"\\" + found.cFileName).c_str());
      }
    } while (::FindNextFileW(unfinished, &found));
    ::FindClose(unfinished);
  }
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

// The report of a hang, immuch360-<date>-<time>-<process>-hang.dmp: written
// as .tmp and named .dmp once whole, since the process ends right after, and
// maybe before the write ended
void WriteHangDump() {
  SYSTEMTIME now;
  ::GetLocalTime(&now);
  wchar_t path[MAX_PATH * 2 + 64];
  swprintf_s(path, L"%s\\immuch360-%04u%02u%02u-%02u%02u%02u-%lu-hang.dmp",
             g_folder, now.wYear, now.wMonth, now.wDay, now.wHour,
             now.wMinute, now.wSecond, ::GetCurrentProcessId());
  wchar_t unfinished[MAX_PATH * 2 + 64];
  swprintf_s(unfinished, L"%s.tmp", path);
  HANDLE file = ::CreateFileW(unfinished, GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  const BOOL written =
      ::MiniDumpWriteDump(::GetCurrentProcess(), ::GetCurrentProcessId(),
                          file, kHangDumpType, nullptr, nullptr, nullptr);
  ::CloseHandle(file);
  if (!written || !::MoveFileExW(unfinished, path, MOVEFILE_REPLACE_EXISTING)) {
    ::DeleteFileW(unfinished);
  }
}

DWORD WINAPI HangDumpWriter(LPVOID) {
  ::WaitForSingleObject(g_hang_request, INFINITE);
  WriteHangDump();
  ::SetEvent(g_hang_written);
  return 0;
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

  // The writer of a hang report; without it a hang ends the process with no
  // report, as before
  g_hang_request = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
  g_hang_written = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (g_hang_request != nullptr && g_hang_written != nullptr) {
    HANDLE hang_writer =
        ::CreateThread(nullptr, 0, HangDumpWriter, nullptr, 0, nullptr);
    if (hang_writer != nullptr) {
      ::CloseHandle(hang_writer);
    } else {
      ::CloseHandle(g_hang_request);
      g_hang_request = nullptr;
    }
  }
  return true;
}

bool ReportHang(DWORD wait_ms) {
  if (g_hang_request == nullptr || g_hang_written == nullptr) {
    return false;
  }
  ::SetEvent(g_hang_request);
  return ::WaitForSingleObject(g_hang_written, wait_ms) == WAIT_OBJECT_0;
}
