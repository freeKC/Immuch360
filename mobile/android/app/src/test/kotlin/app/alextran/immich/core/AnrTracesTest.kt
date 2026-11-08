package app.alextran.immich.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AnrTracesTest {
  private val app = "/data/app/~~Xy12Zw==/com.aprogsys.immuch360-Ab34Cd==/base.apk"

  /** An ANR trace as Android writes it, shortened: the dump of the threads of the app when it stopped answering */
  private val trace =
    """
    Subject: Input dispatching timed out (MainActivity does not have a focused window)

    RssHwmKb: 612340
    RssKb: 598000

    ----- pid 4242 at 2026-11-02 10:00:00.123456789+0100 -----
    Cmd line: com.aprogsys.immuch360
    ABI: 'arm64'

    DALVIK THREADS (41):
    "main" prio=5 tid=1 Native
      | group="main" sCount=1 ucsCount=0 flags=1 obj=0x72a1b2c8 self=0xb400007d6d2c1380
      | sysTid=4242 nice=-10 cgrp=top-app sched=0/0 handle=0x7e8e5ca4f8
      native: #00 pc 000000000009c4b4  /apex/com.android.runtime/lib64/bionic/libc.so (__epoll_pwait+4)
      native: #01 pc 0000000001a3c2c0  $app!libapp.so (offset 0x3988000) (BuildId: 3f3463a721a991e5)
      native: #02 pc 00000000005b9d20  $app!libflutter.so (offset 0x58d0000) (BuildId: fdf0a0a6f673cdcf)
      at android.os.MessageQueue.nativePollOnce(Native method)
      at android.os.Looper.loop(Looper.java:288)

    "Signal Catcher" daemon prio=10 tid=2 Runnable
      | group="system" sCount=0 ucsCount=0 flags=0 obj=0x13f80258 self=0xb400007d6d2c3c00
      native: #00 pc 00000000004ec5d8  /apex/com.android.art/lib64/libart.so (art::SignalCatcher::Run(void*)+128)

    "ReferenceQueueDaemon" daemon prio=5 tid=8 Waiting
      at java.lang.Object.wait(Native method)
      at java.lang.Daemons${'$'}ReferenceQueueDaemon.runInternal(Daemons.java:239)

    "HeapTaskDaemon" daemon prio=5 tid=9 WaitingForTaskProcessor
      at dalvik.system.VMRuntime.runHeapTasks(Native method)

    "OkHttp https://photos.example.org/..." prio=5 tid=31 Runnable
      at okhttp3.internal.connection.RealCall${'$'}AsyncCall.run(RealCall.kt:517)

    "binder:4242_2" prio=5 tid=12 Native
      native: #00 pc 00000000000a0b48  /apex/com.android.runtime/lib64/bionic/libc.so (__ioctl+8)

    "1.raster" sysTid=4300
      native: #00 pc 000000000009c4b4  /apex/com.android.runtime/lib64/bionic/libc.so (__epoll_pwait+4)
      native: #01 pc 0000000000123456  $app!libflutter.so (offset 0x58d0000)

    ----- end 4242 -----
    """.trimIndent()

  @Test
  fun `keeps the subject, the main thread with its native frames and the threads of the app`() {
    val text = AnrTraces.extract(trace)!!
    val lines = text.lines()

    assertEquals("Subject: Input dispatching timed out (MainActivity does not have a focused window)", lines[0])
    assertEquals("\"main\" prio=5 tid=1 Native", lines[2])
    assertTrue(text, text.contains("  native: #01 pc 0000000001a3c2c0  base.apk!libapp.so (offset 0x3988000)"))
    assertTrue(text, text.contains("  at android.os.Looper.loop(Looper.java:288)\n\n\"OkHttp (a URL)\" prio=5 tid=31"))
    assertTrue(text, text.contains("\"1.raster\" sysTid=4300\n"))
    assertTrue(text, text.endsWith("base.apk!libflutter.so (offset 0x58d0000)"))
  }

  @Test
  fun `leaves out the threads of the system and what is not a thread`() {
    val text = AnrTraces.extract(trace)!!

    val leftOut = listOf("Signal Catcher", "ReferenceQueueDaemon", "HeapTaskDaemon", "binder:", "RssKb", "Cmd line")
    for (left in leftOut + "end 4242") {
      assertFalse(left, text.contains(left))
    }
    assertFalse(text, text.contains("/data/app"))
    assertFalse(text, text.contains("photos.example.org"))
  }

  @Test
  fun `keeps 200 lines at most, 100 of them for the main thread`() {
    val main = "\"main\" prio=5 tid=1 Native\n" + (1..150).joinToString("\n") { "  at app.alextran.immich.M.f$it(M.kt:$it)" }
    val workers =
      (1..30).joinToString("\n\n") { n ->
        "\"androidx.work-$n\" prio=5 tid=${100 + n} Waiting\n" +
          (1..9).joinToString("\n") { "  at androidx.work.impl.Worker.step$it(Worker.kt:$it)" }
      }

    val lines = AnrTraces.extract("Subject: Broadcast of Intent\n\n$main\n\n$workers\n")!!.lines()

    assertEquals(AnrTraces.MAX_LINES, lines.size)
    assertEquals("  (51 more lines)", lines[2 + AnrTraces.MAX_MAIN_LINES])
    assertTrue(lines.last(), lines.last().matches(Regex("""\(cut: \d+ more lines\)""")))
  }

  @Test
  fun `a trace without a thread nor a subject gives nothing`() {
    assertNull(AnrTraces.extract("----- pid 1 -----\nnothing here"))
  }
}
