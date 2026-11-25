package app.alextran.immich.immersive

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The background and the transition of the photos of a flat screen (issue 19, the choices of 19 November 2026). */
class SlideshowLookTest {
  private val frameNanos = 1_000_000_000L / 90

  @Test
  fun `the names of the app give the choices, an unknown one the default`() {
    assertEquals(SlideshowBackground.BLACK, SlideshowBackground.ofWire("black"))
    assertEquals(SlideshowBackground.BLURRED, SlideshowBackground.ofWire("blurred"))
    assertEquals(SlideshowBackground.PASSTHROUGH, SlideshowBackground.ofWire("passthrough"))
    assertEquals(SlideshowBackground.BLURRED, SlideshowBackground.ofWire("aurora"))
    assertEquals(SlideshowBackground.BLURRED, SlideshowBackground.ofWire(null))
    assertEquals(SlideshowTransition.NONE, SlideshowTransition.ofWire("none"))
    assertEquals(SlideshowTransition.CROSS_FADE, SlideshowTransition.ofWire("crossFade"))
    assertEquals(SlideshowTransition.SLIDE, SlideshowTransition.ofWire("slide"))
    assertEquals(SlideshowTransition.CROSS_FADE, SlideshowTransition.ofWire("zoom"))
  }

  @Test
  fun `the buttons go through every choice and come back`() {
    var background = SlideshowBackground.BLACK
    val seen = mutableListOf<SlideshowBackground>()
    repeat(3) {
      seen += background
      background = background.next
    }
    assertEquals(SlideshowBackground.entries, seen)
    assertEquals(SlideshowBackground.BLACK, background)
    assertEquals(SlideshowTransition.CROSS_FADE, SlideshowTransition.NONE.next)
    assertEquals(SlideshowTransition.SLIDE, SlideshowTransition.CROSS_FADE.next)
    assertEquals(SlideshowTransition.NONE, SlideshowTransition.SLIDE.next)
    assertEquals("slideshowBackground_passthrough", SlideshowBackground.PASSTHROUGH.labelKey)
    assertEquals("slideshowTransition_crossFade", SlideshowTransition.CROSS_FADE.labelKey)
  }

  @Test
  fun `the passthrough is on for a photo of a flat screen with Your room only`() {
    val room = SlideshowLook(background = SlideshowBackground.PASSTHROUGH)
    assertTrue(room.passthrough(screenPhoto = true))
    assertFalse("a sphere or a video keeps its own surroundings", room.passthrough(screenPhoto = false))
    assertFalse(SlideshowLook(background = SlideshowBackground.BLURRED).passthrough(screenPhoto = true))
    assertFalse(SlideshowLook(background = SlideshowBackground.BLACK).passthrough(screenPhoto = true))
    assertTrue(SlideshowLook().blurred)
  }

  @Test
  fun `a cross fade lays the next photo over the one shown, which goes in the second half only`() {
    val start = PhotoTransition.frameAt(SlideshowTransition.CROSS_FADE, 1, 0f)
    assertEquals(0f, start.incomingAlpha, 1e-6f)
    assertEquals(1f, start.outgoingAlpha, 1e-6f)
    assertFalse(start.done)
    val half = PhotoTransition.frameAt(SlideshowTransition.CROSS_FADE, 1, 0.5f)
    assertEquals(0.5f, half.incomingAlpha, 1e-6f)
    assertEquals("the photo shown is still whole at the middle", 1f, half.outgoingAlpha, 1e-6f)
    assertEquals(0f, half.incomingShift, 0f)
    val end = PhotoTransition.frameAt(SlideshowTransition.CROSS_FADE, 1, 1f)
    assertEquals(1f, end.incomingAlpha, 1e-6f)
    assertEquals(0f, end.outgoingAlpha, 1e-6f)
    assertTrue(end.done)
    // Never a step back
    var before = PhotoTransition.frameAt(SlideshowTransition.CROSS_FADE, 1, 0f)
    for (i in 1..100) {
      val now = PhotoTransition.frameAt(SlideshowTransition.CROSS_FADE, 1, i / 100f)
      assertTrue(now.incomingAlpha >= before.incomingAlpha)
      assertTrue(now.outgoingAlpha <= before.outgoingAlpha)
      before = now
    }
  }

  @Test
  fun `a slide brings the next photo from the right and the previous one from the left`() {
    val next0 = PhotoTransition.frameAt(SlideshowTransition.SLIDE, 1, 0f)
    assertEquals(PhotoTransition.SLIDE_DISTANCE, next0.incomingShift, 1e-6f)
    assertEquals(0f, next0.outgoingShift, 1e-6f)
    val next1 = PhotoTransition.frameAt(SlideshowTransition.SLIDE, 1, 1f)
    assertEquals(0f, next1.incomingShift, 1e-6f)
    assertEquals(-PhotoTransition.SLIDE_DISTANCE, next1.outgoingShift, 1e-6f)
    assertEquals(0f, next1.outgoingAlpha, 1e-6f)
    val previous0 = PhotoTransition.frameAt(SlideshowTransition.SLIDE, -1, 0f)
    assertEquals(-PhotoTransition.SLIDE_DISTANCE, previous0.incomingShift, 1e-6f)
    val previous1 = PhotoTransition.frameAt(SlideshowTransition.SLIDE, -1, 1f)
    assertEquals(PhotoTransition.SLIDE_DISTANCE, previous1.outgoingShift, 1e-6f)
    // The two photos never overlap: the gap between them stays the distance of the slide
    for (i in 0..20) {
      val f = PhotoTransition.frameAt(SlideshowTransition.SLIDE, 1, i / 20f)
      assertEquals(PhotoTransition.SLIDE_DISTANCE, f.incomingShift - f.outgoingShift, 1e-5f)
    }
  }

  @Test
  fun `the blurred background goes out and comes back once, with the copy of the next photo at the middle`() {
    assertEquals(1f, PhotoTransition.frameAt(SlideshowTransition.CROSS_FADE, 1, 0f).backdropAlpha, 1e-6f)
    assertEquals(0f, PhotoTransition.frameAt(SlideshowTransition.CROSS_FADE, 1, 0.5f).backdropAlpha, 1e-6f)
    assertEquals(1f, PhotoTransition.frameAt(SlideshowTransition.SLIDE, 1, 1f).backdropAlpha, 1e-6f)
    val transition = PhotoTransition(SlideshowTransition.CROSS_FADE, 1)
    var middles = 0
    var now = 0L
    while (true) {
      val f = transition.frame(now)
      if (f.atMiddle) middles++
      if (f.done) break
      now += frameNanos
    }
    assertEquals(1, middles)
  }

  @Test
  fun `the progress follows the time of the frames, so a late frame never slows the transition`() {
    val transition = PhotoTransition(SlideshowTransition.CROSS_FADE, 1)
    val start = 5_000_000_000L
    assertFalse(transition.started)
    assertEquals(0f, transition.frame(start).incomingAlpha, 1e-6f)
    assertTrue(transition.started)
    // One frame late by 350 ms: the transition is at its middle, not one frame further
    val late = transition.frame(start + 350_000_000L)
    assertEquals(0.5f, late.incomingAlpha, 1e-6f)
    assertTrue(late.atMiddle)
    val end = transition.frame(start + 700_000_000L)
    assertTrue(end.done)
    assertEquals(3, transition.frames)
    assertEquals(700L, transition.elapsedMs)
    assertEquals(350_000_000L, transition.longestGapNanos)
  }

  @Test
  fun `at the display rate a cross fade takes its time in as many frames, and says so in the log`() {
    val transition = PhotoTransition(SlideshowTransition.CROSS_FADE, 1)
    var now = 0L
    while (!transition.frame(now).done) now += frameNanos
    // 700 ms at 90 frames a second: 64 frames after the first one
    assertEquals(65, transition.frames)
    assertEquals(frameNanos, transition.longestGapNanos)
    assertEquals(
      "photo transition crossFade: 65 frames in 711 ms (90.0 a second), longest gap 11.1 ms",
      transition.summary(),
    )
  }

  @Test
  fun `no transition is done at its first frame`() {
    val transition = PhotoTransition(SlideshowTransition.NONE, 1)
    val f = transition.frame(0L)
    assertTrue(f.done)
    assertEquals(1f, f.incomingAlpha, 0f)
    assertEquals(0f, f.outgoingAlpha, 0f)
  }

  @Test
  fun `smoothstep starts and ends slowly`() {
    assertEquals(0f, PhotoTransition.ease(-1f), 0f)
    assertEquals(0f, PhotoTransition.ease(0f), 0f)
    assertEquals(0.5f, PhotoTransition.ease(0.5f), 1e-6f)
    assertEquals(1f, PhotoTransition.ease(1f), 0f)
    assertEquals(1f, PhotoTransition.ease(2f), 0f)
    assertTrue(PhotoTransition.ease(0.1f) < 0.1f)
    assertTrue(PhotoTransition.ease(0.9f) > 0.9f)
  }
}
