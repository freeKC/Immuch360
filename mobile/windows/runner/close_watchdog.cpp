#include "close_watchdog.h"

#include <cstdlib>

#include "crash_dumps.h"

namespace {

// The longest the report of a hang may take before the process ends anyway:
// dbghelp may wait for the very lock that held the close
constexpr DWORD kHangReportWaitMs = 2000;

// When the process ends, in GetTickCount64 milliseconds; 0 until a close
SRWLOCK g_lock = SRWLOCK_INIT;
ULONGLONG g_deadline = 0;

// Set when the deadline changes
HANDLE g_changed = nullptr;

ULONGLONG Deadline() {
  ::AcquireSRWLockShared(&g_lock);
  const ULONGLONG deadline = g_deadline;
  ::ReleaseSRWLockShared(&g_lock);
  return deadline;
}

DWORD WINAPI Watch(LPVOID) {
  for (;;) {
    const ULONGLONG deadline = Deadline();
    if (deadline == 0) {
      ::WaitForSingleObject(g_changed, INFINITE);
      continue;
    }
    const ULONGLONG now = ::GetTickCount64();
    if (now >= deadline) {
      break;
    }
    ::WaitForSingleObject(g_changed, static_cast<DWORD>(deadline - now));
  }
  ReportHang(kHangReportWaitMs);
  ::TerminateProcess(::GetCurrentProcess(), EXIT_SUCCESS);
  return 0;
}

}  // namespace

void StartCloseWatchdog() {
  if (g_changed != nullptr) {
    return;
  }
  g_changed = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (g_changed == nullptr) {
    return;
  }
  HANDLE thread = ::CreateThread(nullptr, 0, Watch, nullptr, 0, nullptr);
  if (thread == nullptr) {
    // A close then ends as it did before
    ::CloseHandle(g_changed);
    g_changed = nullptr;
    return;
  }
  // The thread lives as long as the process; its handle is not needed
  ::CloseHandle(thread);
}

void EndProcessWithin(DWORD milliseconds) {
  if (g_changed == nullptr) {
    return;
  }
  const ULONGLONG deadline = ::GetTickCount64() + milliseconds;
  ::AcquireSRWLockExclusive(&g_lock);
  if (g_deadline == 0 || deadline < g_deadline) {
    g_deadline = deadline;
  }
  ::ReleaseSRWLockExclusive(&g_lock);
  ::SetEvent(g_changed);
}
