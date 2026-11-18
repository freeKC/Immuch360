package app.alextran.immich.immersive

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The time of each photo of the slideshow of a flat screen (issue 19, point 2). */
class SlideshowClockTest {
  @Test
  fun `a photo counts from its final view, never from the request`() {
    val clock = SlideshowClock(5_000L)
    clock.play(0L)
    clock.photoChanged(0L)
    assertFalse("waiting for its picture", clock.isDue(60_000L))
    clock.finalViewShown(60_000L)
    assertFalse(clock.isDue(64_999L))
    assertTrue(clock.isDue(65_000L))
  }

  @Test
  fun `a relief is waited for, the flat photo does not count, its 3D does`() {
    val clock = SlideshowClock(5_000L)
    clock.play(0L)
    clock.photoChanged(1_000L)
    // The flat photo shows at 1.2 s, its relief at 3.4 s: only then the time starts
    assertFalse(clock.isDue(6_300L))
    clock.finalViewShown(3_400L)
    assertFalse(clock.isDue(8_399L))
    assertTrue(clock.isDue(8_400L))
  }

  @Test
  fun `a grip held and the viewer behind the system stop the time, a panel button starts it again from nothing`() {
    val clock = SlideshowClock(5_000L)
    clock.play(0L)
    clock.finalViewShown(0L)
    clock.hold(SlideshowClock.Hold.GRIP, true, 2_000L)
    assertFalse(clock.isDue(30_000L))
    clock.hold(SlideshowClock.Hold.GRIP, false, 30_000L)
    assertTrue(clock.isDue(33_000L))
    clock.restartPhoto(33_000L)
    assertFalse(clock.isDue(37_999L))
    clock.hold(SlideshowClock.Hold.BACKGROUND, true, 34_000L)
    clock.hold(SlideshowClock.Hold.GRIP, true, 35_000L)
    clock.hold(SlideshowClock.Hold.BACKGROUND, false, 50_000L)
    assertFalse("the grip still holds", clock.isDue(60_000L))
    clock.hold(SlideshowClock.Hold.GRIP, false, 60_000L)
    assertTrue(clock.isDue(64_000L))
  }

  @Test
  fun `pause stops it, play starts the photo shown again, no next ends it`() {
    val clock = SlideshowClock(5_000L)
    assertFalse("not started", clock.isDue(10_000L))
    clock.play(0L)
    clock.finalViewShown(0L)
    clock.pause(4_000L)
    assertFalse(clock.isDue(20_000L))
    assertFalse(clock.playing)
    clock.play(20_000L)
    assertFalse("from nothing again", clock.isDue(24_000L))
    assertTrue(clock.isDue(25_000L))
    clock.noNext(25_000L)
    assertFalse(clock.playing)
    assertFalse(clock.isDue(90_000L))
  }

  @Test
  fun `too warm turns the rest of the slideshow to 2D, said once`() {
    val clock = SlideshowClock()
    assertFalse(clock.twoD)
    assertTrue(clock.tooWarm())
    assertTrue(clock.twoD)
    assertFalse(clock.tooWarm())
  }

  @Test
  fun `the app's duration in seconds, 5 s by default`() {
    assertEquals(5_000L, SlideshowClock.photoMsOf(0L))
    assertEquals(5_000L, SlideshowClock.photoMsOf(-3L))
    assertEquals(8_000L, SlideshowClock.photoMsOf(8L))
    assertEquals(5_000L, SlideshowClock().photoMs)
  }
}
