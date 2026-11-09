package app.alextran.immich.core

import android.app.ActivityManager.RunningAppProcessInfo
import android.app.ApplicationExitInfo
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AppHealthTest {
  @get:Rule val temporary = TemporaryFolder()

  @Test
  fun `reports the ends that are not the choice of the user`() {
    assertTrue(AppHealth.isWorthReporting(ApplicationExitInfo.REASON_ANR))
    assertTrue(AppHealth.isWorthReporting(ApplicationExitInfo.REASON_LOW_MEMORY))
    assertTrue(AppHealth.isWorthReporting(ApplicationExitInfo.REASON_CRASH_NATIVE))
    assertFalse(AppHealth.isWorthReporting(ApplicationExitInfo.REASON_USER_REQUESTED))
    assertFalse(AppHealth.isWorthReporting(ApplicationExitInfo.REASON_EXIT_SELF))
    assertFalse(AppHealth.isWorthReporting(ApplicationExitInfo.REASON_PACKAGE_UPDATED))
  }

  @Test
  fun `an end by a signal names it, a native abort apart from the low memory killer`() {
    // The splat module of build 38 aborted the app on an SPZ of version 3: signal 6, not the low memory killer
    assertEquals(
      "a native abort (signal 6, SIGABRT): a native library stopped the app",
      AppHealth.reasonName(ApplicationExitInfo.REASON_SIGNALED, 6),
    )
    assertEquals(
      "killed by signal 9 (SIGKILL, often the low memory killer)",
      AppHealth.reasonName(ApplicationExitInfo.REASON_SIGNALED, 9),
    )
    assertEquals("killed by signal 15", AppHealth.reasonName(ApplicationExitInfo.REASON_SIGNALED, 15))
    assertEquals("killed for low memory", AppHealth.reasonName(ApplicationExitInfo.REASON_LOW_MEMORY))
    val abort = AppHealth.reasonName(ApplicationExitInfo.REASON_SIGNALED, 6)
    val text = AppHealth.describeExit(abort, 0L, null, 470 * 1024, 571 * 1024)
    assertTrue(text, text.contains(": $abort, memory PSS 470 MB"))
  }

  @Test
  fun `a stall says where the main thread was`() {
    val dart = AppHealth.describeStall(4200, listOf("android.os.MessageQueue.nativePollOnce(Native Method)"), "Memory: x.")
    assertTrue(dart, dart.startsWith("The main thread did not answer for 4.2 s, busy in native code (Dart"))
    assertTrue(dart.contains("  at android.os.MessageQueue.nativePollOnce(Native Method)"))

    val java = AppHealth.describeStall(3000, listOf("java.io.FileInputStream.read(FileInputStream.java:1)"), "")
    assertTrue(java, java.contains("3.0 s, in Java code"))
  }

  @Test
  fun `details that cannot be read give a notice, an Error included, so that the end is still reported`() {
    assertEquals("Threads at the ANR", AppHealth.detailsOrNotice { "Threads at the ANR" })
    assertNull(AppHealth.detailsOrNotice { null })
    assertEquals(
      "The details of this end could not be read (OutOfMemoryError).",
      AppHealth.detailsOrNotice { throw OutOfMemoryError("Failed to allocate a 8388624 byte allocation") },
    )
    assertEquals(
      "The details of this end could not be read (StackOverflowError).",
      AppHealth.detailsOrNotice { throw StackOverflowError() },
    )
  }

  @Test
  fun `an end gives its reason, its memory and the trace of an ANR`() {
    val details = "Threads at the ANR:\n\"main\""
    val text = AppHealth.describeExit("not responding (ANR)", 0L, "Input dispatching timed out", 512_000, 640_000, details = details)

    assertTrue(text, text.contains(": not responding (ANR) (Input dispatching timed out), memory PSS 500 MB, RSS 625 MB"))
    assertTrue(text, text.endsWith("\nThreads at the ANR:\n\"main\""))
  }

  @Test
  fun `says where the app stood when it ended`() {
    assertEquals("in the foreground", AppHealth.importanceName(RunningAppProcessInfo.IMPORTANCE_FOREGROUND))
    assertEquals("visible", AppHealth.importanceName(RunningAppProcessInfo.IMPORTANCE_VISIBLE))
    assertEquals("in the background, cached", AppHealth.importanceName(RunningAppProcessInfo.IMPORTANCE_CACHED))
    assertEquals("in the background, running a service", AppHealth.importanceName(RunningAppProcessInfo.IMPORTANCE_SERVICE))
    assertEquals("in the foreground, screen off", AppHealth.importanceName(325))
    assertEquals("importance 42", AppHealth.importanceName(42))
    assertNull(AppHealth.importanceName(0))
  }

  @Test
  fun `an end names the build that ran, where the app stood and its last known state, then the details`() {
    val text =
      AppHealth.describeExit(
        reason = "native crash",
        timestamp = 0L,
        description = "crash",
        pssKb = 470 * 1024,
        rssKb = 571 * 1024,
        importance = RunningAppProcessInfo.IMPORTANCE_CACHED,
        build = "3030042 quest",
        state = "route=AssetViewerRoute bg",
        details = "Signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault address 0x18",
      )

    assertTrue(
      text,
      text.endsWith(
        ": native crash (crash), in the background, cached, memory PSS 470 MB, RSS 571 MB [Immuch360 3030042 quest]\n" +
          "Last known state: route=AssetViewerRoute bg\n" +
          "Signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault address 0x18",
      ),
    )
    // A report stays within the size of a pending file
    val long = AppHealth.describeExit("crash", 0L, null, 0, 0, details = "x".repeat(100_000))
    assertEquals(AppHealth.MAX_REPORT_BYTES, long.toByteArray().size)
  }

  @Test
  fun `the state summary carries the build, cut at 128 bytes on a whole character`() {
    // 21 bytes before the accents, then 2 bytes each: the cut at 128 falls inside one, which is left out whole
    val summary = AppHealth.stateSummary("3030042 quest", "route=x" + "é".repeat(100))

    assertEquals(127, summary.size)
    assertFalse(summary.toString(Charsets.UTF_8).contains('\uFFFD'))
    val read = AppHealth.readStateSummary(summary)
    assertEquals("3030042 quest", read.build)
    assertEquals("route=x" + "é".repeat(53), read.state)

    val stateless = AppHealth.readStateSummary(AppHealth.stateSummary("3030042 phone", ""))
    assertEquals("3030042 phone", stateless.build)
    assertNull(stateless.state)
    // A summary of another form, or none
    assertNull(AppHealth.readStateSummary("route=x".toByteArray()).build)
    assertEquals("route=x", AppHealth.readStateSummary("route=x".toByteArray()).state)
    assertNull(AppHealth.readStateSummary(null).state)
  }

  @Test
  fun `a Java crash goes with the crash end that came at most 30 s after it`() {
    val folder = temporary.newFolder("app_health")
    val file = File(folder, JavaCrashRecorder.FILE_NAME)

    JavaCrashRecorder.write(folder, "main", IllegalStateException("boom"), 100_000L)
    // An end 31 s later is not its own, nor is any later end: the file goes
    assertNull(JavaCrashRecorder.take(folder, 131_000L))
    assertFalse(file.exists())

    JavaCrashRecorder.write(folder, "OkHttp Dispatcher", IllegalStateException("boom"), 200_000L)
    // An end before the crash leaves it for a later one
    assertNull(JavaCrashRecorder.take(folder, 199_000L))
    assertTrue(file.exists())
    val text = JavaCrashRecorder.take(folder, 230_000L)!!
    assertTrue(text, text.startsWith("Java crash on the thread \"OkHttp Dispatcher\":\njava.lang.IllegalStateException: boom"))
    assertFalse(file.exists())

    JavaCrashRecorder.write(folder, "main", IllegalStateException("boom"), 300_000L)
    JavaCrashRecorder.discardBefore(folder, 300_000L)
    assertTrue(file.exists())
    JavaCrashRecorder.discardBefore(folder, 300_001L)
    assertFalse(file.exists())
  }

  @Test
  fun `the report of an end stays on disk until Flutter has written it, 20 at most`() {
    val folder = temporary.newFolder("pending")

    for (i in 1..22) {
      assertTrue(PendingReports.write(folder, PendingReports.id(1_000L * i, 4000 + i), "end $i"))
    }

    val kept = PendingReports.load(folder)
    assertEquals(AppHealth.MAX_PENDING_FILES, kept.size)
    assertEquals("3000-4003.txt" to "end 3", kept.first())
    assertEquals("22000-4022.txt" to "end 22", kept.last())
    // Read again: still there, only Flutter's answer deletes them; a name that is not an id is left alone
    assertEquals(20, PendingReports.load(folder).size)
    val outside = File(temporary.root, "outside.txt").apply { writeText("not a report") }
    PendingReports.delete(folder, listOf("3000-4003.txt", "4000-4004.txt", "../outside.txt"))
    assertEquals(18, PendingReports.load(folder).size)
    assertEquals("5000-4005.txt", PendingReports.load(folder).first().first)
    assertTrue(outside.exists())
  }
}
