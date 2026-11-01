package app.alextran.immich.core

import android.app.ApplicationExitInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppHealthTest {
  @Test
  fun `takes the main thread out of an ANR trace`() {
    val trace =
      """
      ----- pid 4242 at 2026-10-21 12:03:04 -----
      "Signal Catcher" daemon prio=10 tid=7 Runnable
        at nothing

      "main" prio=5 tid=1 Native
        | group="main" sCount=1
        at android.os.MessageQueue.nativePollOnce(Native method)
        at android.os.Looper.loop(Looper.java:288)

      "Immuch360 watchdog" daemon prio=5 tid=30 Sleeping
      """.trimIndent()

    assertEquals(
      listOf(
        "\"main\" prio=5 tid=1 Native",
        "  | group=\"main\" sCount=1",
        "  at android.os.MessageQueue.nativePollOnce(Native method)",
        "  at android.os.Looper.loop(Looper.java:288)",
      ).joinToString("\n"),
      AppHealth.mainThreadOfTrace(trace),
    )
    assertNull(AppHealth.mainThreadOfTrace("no thread here"))
  }

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
    val text = AppHealth.describeExit(abort, 0L, null, 470 * 1024, 571 * 1024, null)
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
  fun `an end gives its reason, its memory and the trace of an ANR`() {
    val text = AppHealth.describeExit("not responding (ANR)", 0L, "Input dispatching timed out", 512_000, 640_000, "\"main\"")

    assertTrue(text, text.contains(": not responding (ANR) (Input dispatching timed out), memory PSS 500 MB, RSS 625 MB"))
    assertTrue(text, text.endsWith("Main thread at the ANR:\n\"main\""))
  }
}
