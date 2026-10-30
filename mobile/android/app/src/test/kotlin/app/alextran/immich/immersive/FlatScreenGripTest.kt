package app.alextran.immich.immersive

import app.alextran.immich.immersive.ScreenGrip.Event
import com.meta.spatial.runtime.ButtonBits
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The grips on a flat screen (FreeKC's mapping of 29 October, on an idea of Gaurav Mukherjee, gmfun/Immuch360 branch
 * quest/flat-3d): a short press shows or hides the info panel, a grip held past HOLD_MS while it points at the screen
 * grabs it, both grips held stretch it, and a release ends what it started.
 */
class FlatScreenGripTest {
  private val left = ButtonBits.ButtonSqueezeL
  private val right = ButtonBits.ButtonSqueezeR
  private val grip = ScreenGrip()

  /** Every side points at the screen unless said otherwise. */
  private fun step(nowMs: Long, held: Int, pointing: Set<GripSide> = GripSide.entries.toSet()): List<Event> =
    grip.update(nowMs, held) { it in pointing }

  @Test
  fun `a short press of either grip shows or hides the panel, on its release`() {
    for (bit in listOf(left, right)) {
      val grip = ScreenGrip()
      assertEquals(emptyList<Event>(), grip.update(1000, bit) { true })
      assertEquals(emptyList<Event>(), grip.update(1000 + ScreenGrip.HOLD_MS - 1, bit) { true })
      assertEquals(listOf(Event.TogglePanel), grip.update(1000 + ScreenGrip.HOLD_MS - 1, 0) { true })
      assertNull(grip.grabbing)
    }
  }

  @Test
  fun `a short press away from the screen shows or hides the panel too`() {
    assertEquals(emptyList<Event>(), step(0, right, pointing = emptySet()))
    assertEquals(listOf(Event.TogglePanel), step(120, 0, pointing = emptySet()))
  }

  @Test
  fun `a grip held past the hold time while it points at the screen grabs it, and its release lets it go`() {
    assertEquals(emptyList<Event>(), step(0, right))
    assertEquals(emptyList<Event>(), step(ScreenGrip.HOLD_MS - 1, right))
    assertEquals(listOf(Event.GrabStart(GripSide.RIGHT)), step(ScreenGrip.HOLD_MS, right))
    assertEquals(GripSide.RIGHT, grip.grabbing)
    // Held on: nothing new, the viewer moves the screen with the ray every frame
    assertEquals(emptyList<Event>(), step(2000, right))
    assertEquals(listOf(Event.GrabEnd(GripSide.RIGHT)), step(2100, 0))
    assertNull(grip.grabbing)
  }

  @Test
  fun `the release of a grab never shows or hides the panel`() {
    step(0, left)
    step(400, left)
    val events = step(500, 0)
    assertFalse(Event.TogglePanel in events)
  }

  @Test
  fun `a grip held away from the screen does nothing, then grabs once the ray reaches the screen`() {
    step(0, left, pointing = emptySet())
    assertEquals(emptyList<Event>(), step(600, left, pointing = emptySet()))
    assertNull(grip.grabbing)
    assertEquals(listOf(Event.GrabStart(GripSide.LEFT)), step(700, left, pointing = setOf(GripSide.LEFT)))
  }

  @Test
  fun `a long press away from the screen released there does nothing at all`() {
    step(0, left, pointing = emptySet())
    step(500, left, pointing = emptySet())
    assertEquals(emptyList<Event>(), step(600, 0, pointing = emptySet()))
  }

  @Test
  fun `only the side that points at the screen grabs it`() {
    step(0, left, pointing = setOf(GripSide.RIGHT))
    assertEquals(emptyList<Event>(), step(ScreenGrip.HOLD_MS, left, pointing = setOf(GripSide.RIGHT)))
    assertNull(grip.grabbing)
  }

  @Test
  fun `both grips held stretch the screen, a press of the second one is never a short press`() {
    step(0, left)
    assertEquals(listOf(Event.StretchStart), step(100, left or right))
    assertTrue(grip.stretching)
    // Released quickly, neither grip shows or hides the panel
    assertEquals(listOf(Event.StretchEnd), step(150, right))
    assertFalse(grip.stretching)
    assertEquals(emptyList<Event>(), step(200, 0))
  }

  @Test
  fun `both grips pressed on the same frame stretch at once`() {
    assertEquals(listOf(Event.StretchStart), step(0, left or right))
    assertEquals(emptyList<Event>(), step(1000, left or right))
    assertEquals(listOf(Event.StretchEnd), step(1100, 0))
    assertEquals(emptyList<Event>(), step(1200, 0))
  }

  @Test
  fun `the second grip during a grab turns it into a stretch, and its release grabs nothing again`() {
    step(0, right)
    assertEquals(listOf(Event.GrabStart(GripSide.RIGHT)), step(ScreenGrip.HOLD_MS, right))
    assertEquals(listOf(Event.GrabEnd(GripSide.RIGHT), Event.StretchStart), step(500, left or right))
    assertNull(grip.grabbing)
    assertEquals(listOf(Event.StretchEnd), step(900, right))
    // The grip still held went into the stretch: it waits for its release, which does nothing
    assertEquals(emptyList<Event>(), step(2000, right))
    assertNull(grip.grabbing)
    assertEquals(emptyList<Event>(), step(2100, 0))
  }

  @Test
  fun `a grip pressed again while the other is still held stretches again`() {
    step(0, left or right)
    step(300, left)
    assertEquals(listOf(Event.StretchStart), step(400, left or right))
  }

  @Test
  fun `cancel ends a grab and the grips still held do nothing until they are released`() {
    step(0, right)
    step(ScreenGrip.HOLD_MS, right)
    assertEquals(listOf(Event.GrabEnd(GripSide.RIGHT)), grip.cancel())
    assertNull(grip.grabbing)
    assertEquals(emptyList<Event>(), step(1000, right))
    assertEquals(emptyList<Event>(), step(1100, 0))
    // Then a short press works again
    step(1200, right)
    assertEquals(listOf(Event.TogglePanel), step(1300, 0))
  }

  @Test
  fun `cancel ends a stretch, and a short press cut by it shows nothing`() {
    step(0, left or right)
    assertEquals(listOf(Event.StretchEnd), grip.cancel())
    assertFalse(grip.stretching)
    assertEquals(emptyList<Event>(), step(50, 0))
    step(100, left)
    assertEquals(emptyList<Event>(), grip.cancel())
    assertEquals(emptyList<Event>(), step(150, 0))
  }

  @Test
  fun `a grip already held when a flat screen shows does nothing until it is released`() {
    // Pressed while a sphere showed, where it toggled the panel on its press: no second toggle on its release
    assertEquals(emptyList<Event>(), grip.reset(right))
    assertEquals(emptyList<Event>(), step(100, right))
    assertEquals(emptyList<Event>(), step(500, right))
    assertNull(grip.grabbing)
    assertEquals(emptyList<Event>(), step(600, 0))
    step(700, right)
    assertEquals(listOf(Event.TogglePanel), step(800, 0))
  }

  @Test
  fun `reset ends a grab or a stretch, and forgets a grip released meanwhile`() {
    step(0, right)
    step(ScreenGrip.HOLD_MS, right)
    assertEquals(listOf(Event.GrabEnd(GripSide.RIGHT)), grip.reset(0))
    assertNull(grip.grabbing)
    // Pressed again later: a short press as any other
    step(1000, left)
    assertEquals(listOf(Event.TogglePanel), step(1100, 0))
    step(1200, left or right)
    assertEquals(listOf(Event.StretchEnd), grip.reset(left or right))
    assertEquals(emptyList<Event>(), step(1300, 0))
  }

  @Test
  fun `the other buttons change nothing`() {
    val others = ButtonBits.ButtonA or ButtonBits.ButtonTriggerR or ButtonBits.ButtonThumbRU
    assertEquals(emptyList<Event>(), step(0, others))
    assertEquals(emptyList<Event>(), step(1000, others))
    assertEquals(emptyList<Event>(), step(1100, 0))
  }
}
