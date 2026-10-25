package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The warnings of the flight view come and go (FreeKC's rule of 25 October): in over 250 ms, held until 5 s, out over
 * 0.8 s; a new kind or a button shows them again; an error that needs an action stays. The same numbers as
 * dji_live_transient.dart.
 */
class TransientTextTest {
  @Test
  fun aWarningComesStaysFiveSecondsAndFades() {
    assertEquals(0f, TransientText.alpha(-1), 0f)
    assertEquals(0f, TransientText.alpha(0), 0f)
    assertEquals(0.5f, TransientText.alpha(125), 1e-6f)
    assertEquals(1f, TransientText.alpha(250), 0f)
    assertEquals(1f, TransientText.alpha(4_000), 0f)
    assertEquals(1f, TransientText.alpha(5_000), 0f)
    assertEquals(0.5f, TransientText.alpha(5_400), 1e-6f)
    assertEquals(0f, TransientText.alpha(5_800), 0f)
    assertEquals(0f, TransientText.alpha(60_000), 0f)
    // Kept: always there
    assertEquals(1f, TransientText.alpha(60_000, keep = true), 0f)
    assertTrue(TransientText.shown(4_999))
    assertTrue(TransientText.shown(5_000))
    assertFalse(TransientText.shown(5_001))
    assertTrue(TransientText.shown(60_000, keep = true))
  }

  @Test
  fun aNewKindShowsItAgainItsNumbersDoNot() {
    val clock = TransientClock()
    assertFalse(clock.shown(0))
    clock.follow("live", 1_000)
    assertTrue(clock.shown(5_900))
    assertFalse(clock.shown(6_100))
    // The same kind again, as every refresh does: nothing changes
    clock.follow("live", 6_100)
    assertFalse(clock.shown(6_200))
    // Another kind: five seconds more
    clock.follow("lost", 7_000)
    assertTrue(clock.shown(11_900))
    assertFalse(clock.shown(12_100))
    // Gone: not shown, whatever its clock says; back as a new kind
    clock.follow(null, 12_200)
    assertFalse(clock.shown(12_300))
    clock.follow("lost", 13_000)
    assertTrue(clock.shown(13_100))
  }

  @Test
  fun aButtonBringsItBackFromWhereItIs() {
    val clock = TransientClock()
    clock.follow("watching", 0)
    // Faded: back from nothing, five seconds from the button
    clock.recall(20_000)
    assertEquals(0f, clock.alpha(20_000), 0f)
    assertTrue(clock.shown(24_900))
    assertFalse(clock.shown(25_100))
    // Fading at half: back to full from there, never from nothing
    clock.recall(25_400)
    assertEquals(0.5f, clock.alpha(25_400), 0.01f)
    assertEquals(1f, clock.alpha(25_600), 0f)
    // Held: it stays five seconds from the button, less the fade in it skipped
    clock.recall(27_000)
    assertEquals(1f, clock.alpha(27_000), 0f)
    assertTrue(clock.shown(31_700))
    assertFalse(clock.shown(31_800))
  }
}
