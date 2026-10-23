package app.alextran.immich.djilink

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.ByteArrayInputStream
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** A capture played on its own thread: damaged files, a stop while it waits, and an unload */
class CapturePlayerTest {
  private val uncaught: MutableList<Throwable> = Collections.synchronizedList(mutableListOf())
  private var previousHandler: Thread.UncaughtExceptionHandler? = null

  @Before
  fun catchWhatTheThreadsThrow() {
    previousHandler = Thread.getDefaultUncaughtExceptionHandler()
    Thread.setDefaultUncaughtExceptionHandler { _, error -> uncaught.add(error) }
  }

  @After
  fun restoreTheHandler() {
    Thread.setDefaultUncaughtExceptionHandler(previousHandler)
  }

  private val frame = EnvelopeDecoder.encode(
    Channels.CONTROL_PRIMARY,
    P3Decoder.build(
      senderType = DeviceTypes.FLIGHT_CONTROLLER,
      receiverType = DeviceTypes.APPLICATION,
      sequence = 1,
      commandSet = CommandSets.FLIGHT_CONTROLLER,
      commandId = 67,
      body = ByteArray(8),
    ),
  )

  private fun entry(offset: Long, length: Int, atMs: Long, direction: CaptureDirection = CaptureDirection.IN) =
    CaptureEntry(offset, length, direction, atMs * 1_000_000, 1_700_000_000_000L + atMs)

  /** A player whose waits return at once, so that a test plays a capture in no time */
  private fun instantPlayer() = CapturePlayer(Any(), clockNs = { 0L }, sleepNs = { })

  private fun playToTheEnd(player: CapturePlayer, capture: LoadedCapture, onRead: () -> Unit = {}): Int {
    val ended = CountDownLatch(1)
    var ends = 0
    player.play(capture, 0, onNewStream = {}, onRead = onRead, onEnd = { ends += 1; ended.countDown() })
    assertTrue("the playback ends", ended.await(5, TimeUnit.SECONDS))
    Thread.sleep(50)
    return ends
  }

  @Test
  fun aNegativeOrOversizeLengthIsRejectedWithTheNumberOfItsLine() {
    val csv = listOf(
      "offset,length,direction,monotonic_ns,wall_ms",
      "0,${frame.size},in,1000000,1",
      "0,-1,in,2000000,2",
      "0,3000000000,in,3000000,3",
      "-5,4,in,4000000,4",
      "4,${frame.size},in,5000000,5",
      "0,4,open,6000000,6",
      "0,4,in,-7,7",
      "not,a,line",
      "",
    ).joinToString("\n")
    val reading = CaptureReplay.readIndex(csv, fileBytes = frame.size.toLong())
    assertEquals(listOf(3, 4, 5, 6, 7, 8, 9), reading.rejectedLines)
    assertTrue(reading.damaged)
    assertEquals(1, reading.entries.size)
    assertEquals(frame.size, reading.entries[0].length)
    // The older reader leaves the rejected lines out as well, so no caller ever sees a negative length
    assertEquals(reading.entries, CaptureReplay.parseIndex(csv, fileBytes = frame.size.toLong()))
    assertTrue(CaptureReplay.parseIndex(csv).all { it.length >= 0 })
  }

  @Test
  fun anIndexThatFitsItsFileIsNotDamaged() {
    val csv = "offset,length,direction,monotonic_ns,wall_ms\n0,0,open,1,1\n0,${frame.size},in,2,2\n" +
      "${frame.size},500,gap,3,3\n${frame.size},0,close,4,4\n"
    val reading = CaptureReplay.readIndex(csv, fileBytes = frame.size.toLong())
    assertFalse(reading.damaged)
    assertEquals(listOf("open", "in", "gap", "close"), reading.entries.map { it.direction.word })
    assertEquals(500L, reading.entries[2].skippedBytes)
  }

  @Test
  fun aReadOutsideTheFileNeverReachesTheParsersAndThePlaybackEnds() {
    val player = instantPlayer()
    val capture = LoadedCapture(
      "damaged",
      frame,
      listOf(
        entry(0, frame.size, 0),
        entry(0, -1, 10),
        entry(-3, 4, 20),
        entry(frame.size.toLong() + 10, 4, 30),
        entry(0, Int.MAX_VALUE, 40),
      ),
    )
    val ends = playToTheEnd(player, capture)
    assertEquals(1, ends)
    assertTrue("nothing escaped the player thread: $uncaught", uncaught.isEmpty())
    assertNull(player.failure)
    assertFalse(player.playing)
    // The first read and the last, cut to the end of the file, are the same whole frame
    assertEquals(2L, player.decoder.counters.frames)
  }

  @Test
  fun anErrorOnThePlayerThreadEndsThePlaybackAndIsKept() {
    val player = instantPlayer()
    val capture = LoadedCapture("broken", frame, listOf(entry(0, frame.size, 0), entry(0, frame.size, 10)))
    val ends = playToTheEnd(player, capture, onRead = { throw IllegalStateException("a parser that did not expect it") })
    assertEquals(1, ends)
    assertTrue("nothing escaped the player thread: $uncaught", uncaught.isEmpty())
    assertEquals("IllegalStateException", player.failure)
    assertFalse(player.playing)
    assertTrue("the capture stays loaded, so that the page can say where it stopped", player.loaded)
    player.unload()
    assertNull(player.failure)
    assertFalse(player.loaded)
  }

  @Test
  fun aStopDuringAWaitEndsThePlaybackAtOnce() {
    // The real clock and the real sleep: the second read is due ten seconds after the first
    val player = CapturePlayer(Any())
    val capture = LoadedCapture("long", frame + frame, listOf(entry(0, frame.size, 0), entry(frame.size.toLong(), frame.size, 10_000)))
    val firstRead = CountDownLatch(1)
    val ended = CountDownLatch(1)
    player.play(capture, 0, onNewStream = {}, onRead = { firstRead.countDown() }, onEnd = { ended.countDown() })
    assertTrue(firstRead.await(5, TimeUnit.SECONDS))
    assertTrue(player.playing)
    val before = System.nanoTime()
    player.stop()
    assertTrue(ended.await(2, TimeUnit.SECONDS))
    assertTrue("stopped well before the next read was due", System.nanoTime() - before < 2_000_000_000L)
    assertFalse(player.playing)
    assertNull("a stop is not an error", player.failure)
    assertEquals(1L, player.decoder.counters.frames)
    assertTrue(uncaught.isEmpty())
  }

  @Test
  fun anUnloadForgetsTheCaptureAndItsParsers() {
    val player = instantPlayer()
    playToTheEnd(player, LoadedCapture("one", frame, listOf(entry(0, frame.size, 0))))
    assertTrue(player.loaded)
    assertEquals(1L, player.decoder.counters.frames)
    player.unload()
    assertFalse(player.loaded)
    assertNull(player.name)
    assertEquals(0L, player.positionMs)
    assertEquals(0L, player.decoder.counters.frames)
  }

  @Test
  fun aCaptureWhoseClockGoesBackwardsHasNoNegativeDuration() {
    val player = instantPlayer()
    playToTheEnd(player, LoadedCapture("backwards", frame, listOf(entry(0, frame.size, 50), entry(0, frame.size, 10))))
    assertEquals(0L, player.durationMs)
    assertTrue(uncaught.isEmpty())
  }

  @Test
  fun aFileAboveTheBoundIsRefusedBeforeItFillsTheMemory() {
    val bytes = ByteArray(300_000) { it.toByte() }
    assertArrayEquals(bytes, readAtMost(ByteArrayInputStream(bytes), 300_000))
    val refused = runCatching { readAtMost(ByteArrayInputStream(bytes), 299_999) }.exceptionOrNull()
    assertTrue(refused is CaptureTooLargeException)
  }
}
