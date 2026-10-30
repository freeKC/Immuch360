package app.alextran.immich

import io.flutter.plugin.common.BinaryMessenger
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The sideways pushes of the thumbstick of a Meta Quest controller in the 2D window, as scroll events: which way, the
 * scrolls too small to count, and one page per push however many scrolls it sends (see [StickPushDetector]).
 */
class QuestStickPagingTest {
  private val rearm = StickPushDetector.REARM_MS

  /** Keeps the handler set for each channel, as the messenger of the Flutter engine does */
  private class RecordingMessenger : BinaryMessenger {
    val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler?>()

    override fun send(channel: String, message: ByteBuffer?) {}

    override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}

    override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
      handlers[channel] = handler
    }
  }

  @Test
  fun `the paging channel is made on a Meta Quest only, never on a phone or a TV`() {
    val elsewhere = RecordingMessenger()
    assertNull(QuestStickPaging.attach(elsewhere, horizonOs = false))
    assertTrue(elsewhere.handlers.isEmpty())

    val quest = RecordingMessenger()
    val paging = QuestStickPaging.attach(quest, horizonOs = true)
    assertNotNull(paging)
    assertNotNull(quest.handlers["immuch360/quest_stick"])
    paging!!.dispose()
    assertNull(quest.handlers["immuch360/quest_stick"])
  }

  /** The scrolls of one push held [durationMs] from [startMs], one every 16 ms as a frame would send them */
  private fun StickPushDetector.hold(horizontal: Float, startMs: Long, durationMs: Long): List<StickPush> =
    (startMs..startMs + durationMs step 16).map { onScroll(horizontal, 0f, it) }

  @Test
  fun `a push to the right goes to the next asset, to the left to the previous one`() {
    assertEquals(StickPush.NEXT, StickPushDetector().onScroll(1f, 0f, 0L))
    assertEquals(StickPush.PREVIOUS, StickPushDetector().onScroll(-1f, 0f, 0L))
    assertEquals(1, StickPush.NEXT.step)
    assertEquals(-1, StickPush.PREVIOUS.step)
    assertEquals(0, StickPush.HOLD.step)
  }

  @Test
  fun `a push held pages once, the scrolls that follow are taken without paging`() {
    val detector = StickPushDetector()

    val pushes = detector.hold(0.8f, startMs = 1000L, durationMs = 2000L)

    assertEquals(StickPush.NEXT, pushes.first())
    assertEquals(List(pushes.size - 1) { StickPush.HOLD }, pushes.drop(1))
  }

  @Test
  fun `the next push pages once the stick was still for the rearm delay`() {
    val detector = StickPushDetector()
    val last = detector.hold(1f, startMs = 0L, durationMs = 160L).size.let { 16L * (it - 1) }

    // Within the delay, the same push still
    assertEquals(StickPush.HOLD, detector.onScroll(1f, 0f, last + rearm))
    // Past it from the scroll before, a new push
    assertEquals(StickPush.NEXT, detector.onScroll(1f, 0f, last + 2 * rearm + 1))
  }

  @Test
  fun `a push the other way pages at once`() {
    val detector = StickPushDetector()

    assertEquals(StickPush.NEXT, detector.onScroll(1f, 0f, 0L))
    assertEquals(StickPush.PREVIOUS, detector.onScroll(-1f, 0f, 40L))
    assertEquals(StickPush.HOLD, detector.onScroll(-1f, 0f, 56L))
  }

  @Test
  fun `scrolls within the deadzone are taken without paging, and do not keep a push held`() {
    val detector = StickPushDetector()
    val small = StickPushDetector.DEADZONE / 2

    assertEquals(StickPush.HOLD, detector.onScroll(small, 0f, 0L))
    assertEquals(StickPush.HOLD, detector.onScroll(-small, 0f, 16L))
    assertEquals(StickPush.NEXT, detector.onScroll(StickPushDetector.DEADZONE, 0f, 32L))
    // The stick coming back to the middle, or resting a little off it, sends small scrolls for a long while: the push
    // still ends REARM_MS after its last real scroll
    val noise = detector.hold(small, startMs = 48L, durationMs = 1000L)
    assertEquals(List(noise.size) { StickPush.HOLD }, noise)
    assertEquals(StickPush.NEXT, detector.onScroll(1f, 0f, 48L + 1000L + 16L))
  }

  @Test
  fun `a mostly vertical scroll, or none, is left to the page`() {
    val detector = StickPushDetector()

    assertEquals(StickPush.IGNORE, detector.onScroll(0f, 1f, 0L))
    assertEquals(StickPush.IGNORE, detector.onScroll(0.5f, -1f, 16L))
    assertEquals(StickPush.IGNORE, detector.onScroll(0f, 0f, 32L))
    // And it does not count as a push: the first sideways one still pages
    assertEquals(StickPush.NEXT, detector.onScroll(1f, 0.5f, 48L))
  }

  @Test
  fun `reset forgets the push held`() {
    val detector = StickPushDetector()
    assertEquals(StickPush.NEXT, detector.onScroll(1f, 0f, 0L))

    detector.reset()

    assertEquals(StickPush.NEXT, detector.onScroll(1f, 0f, 16L))
  }
}
