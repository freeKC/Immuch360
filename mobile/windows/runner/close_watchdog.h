#ifndef RUNNER_CLOSE_WATCHDOG_H_
#define RUNNER_CLOSE_WATCHDOG_H_

#include <windows.h>

// The end of the process once its window closes. On 1 November 2026 the
// window froze at a close until Windows offered to end it: the engine tears
// the app down on the window's thread and waits there, without a bound, for
// whatever still runs in native code (an SMB read of a share that stopped
// answering, libmpv starting CUDA, a library being loaded). Nothing the app
// keeps needs that teardown to end: the app saved its films and wrote its
// logs before (lib/desktop/window/close_sequence.dart), and SQLite's journal
// keeps every write. So once the window closes, the process ends at the
// latest a few seconds later, with a report of where it waited
// (ReportHang, crash_dumps.h).

// Makes the thread that ends the process, which waits for a close. Called
// once at start, before anything can hold the loader of Windows: a thread
// made at the close would need it to start.
void StartCloseWatchdog();

// The window closes: the process ends |milliseconds| from now at the latest,
// or earlier when an earlier end was asked before. The report of the hang is
// written first, within a bound of its own; the process then ends without
// running anything else (TerminateProcess: an ExitProcess would wait for the
// loader too).
void EndProcessWithin(DWORD milliseconds);

#endif  // RUNNER_CLOSE_WATCHDOG_H_
