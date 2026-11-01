#ifndef RUNNER_CRASH_DUMPS_H_
#define RUNNER_CRASH_DUMPS_H_

#include <windows.h>

#include <string>

// The folder of the crash reports of the native code: crash_dumps in the cache
// folder of the app (getApplicationCacheDirectory() on the Dart side), whose
// "Save logs to a file" collects them (lib/desktop/files/save_to_folder.dart).
// Empty when Windows does not give the local application data folder.
std::wstring CrashDumpFolder();

// From now on, a crash of the process writes a minidump into |folder|, made
// first, after the oldest and the empty reports there were removed. False when
// that could not be set up: a crash then ends the process as it would without.
bool InstallCrashDumps(const std::wstring& folder);

// Writes a report of the process as it is now, a hang being the reason, into
// the folder of InstallCrashDumps (immuch360-<date>-<time>-<process>-hang.dmp,
// which "Save logs to a file" collects with the crash reports), by the thread
// made for it there. Waits |wait_ms| at most; true when the report is written.
bool ReportHang(DWORD wait_ms);

#endif  // RUNNER_CRASH_DUMPS_H_
