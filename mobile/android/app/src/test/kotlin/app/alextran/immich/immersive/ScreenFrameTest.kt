package app.alextran.immich.immersive

import com.meta.spatial.core.Vector3
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The box of the flat screen the user set, which the next photos take with "Keep size and place" on (issue 19, points
 * 1 and 2): contained in it, at its place, and kept between openings by its size, distance and elevation.
 */
class ScreenFrameTest {
  private val eyes = Vector3(0f, 1.6f, 0f)
  private val ahead = ScreenPlace(eyes, 0f, 1.6f, 2f)
  private val oneBounds = FlatScreenGeometry.frameBounds(twoEyes = false, estimatedRelief = false)

  @Test
  fun `a 3 by 2 photo fills a 3 by 2 box, a 2 by 3 photo is as tall and centred at the same place`() {
    val frame = ScreenFrame.of(ahead, 60f, 1.5f)
    assertEquals(FlatScreenGeometry.width(60f, 2f), frame.widthM, 1e-4f)
    assertEquals(frame.widthM / 1.5f, frame.heightM, 1e-4f)
    assertEquals(60f, frame.angleFor(1.5f, oneBounds), 1e-3f)

    val portrait = frame.angleFor(2f / 3f, oneBounds)
    val portraitWidth = FlatScreenGeometry.width(portrait, frame.place.distance)
    assertEquals(frame.heightM, portraitWidth / (2f / 3f), 1e-3f)
    assertTrue(portrait < 60f)
    // The place is the box's: the photo is centred there, never moved
    assertEquals(ahead, frame.place)
  }

  @Test
  fun `a square photo is as tall as a landscape box and as wide as a portrait one`() {
    val landscape = ScreenFrame(ahead, 3f, 2f)
    assertEquals(2f, landscape.containedWidth(1f), 1e-6f)
    val portrait = ScreenFrame(ahead, 2f, 3f)
    assertEquals(2f, portrait.containedWidth(1f), 1e-6f)
    // An unknown shape counts as 16:9
    assertEquals(landscape.containedWidth(16f / 9f), landscape.containedWidth(0f), 1e-6f)
  }

  @Test
  fun `a photo of two eyes keeps its comfort bound in a box larger than it, one picture goes past the Size bounds`() {
    val big = ScreenFrame.of(ahead.at(0.75f), 150f, 1.5f)
    val twoEyes = FlatScreenGeometry.frameBounds(twoEyes = true, estimatedRelief = false)
    assertEquals(90f, big.angleFor(1.5f, twoEyes), 0f)
    assertEquals(60f, big.angleFor(1.5f, FlatScreenGeometry.frameBounds(twoEyes = true, estimatedRelief = true)), 0f)
    assertEquals(150f, big.angleFor(1.5f, oneBounds), 1e-2f)
    assertEquals(FlatScreenGeometry.NEAR_MAX_DEG, oneBounds.endInclusive, 0f)
  }

  @Test
  fun `the box kept between openings keeps its size, distance and elevation, and faces the new gaze`() {
    val raised = ScreenPlace(eyes, 30f, eyes.y + 0.5f, 2.5f)
    val frame = ScreenFrame(raised, 2.4f, 1.6f)
    val saved = frame.saved()
    assertEquals(0.2f, saved.elevation, 1e-6f)
    assertTrue(saved.isValid)

    val otherEyes = Vector3(1f, 1.5f, 1f)
    val placed = saved.placedInFront(otherEyes, Vector3(1f, 0f, 0f))
    assertEquals(2.4f, placed.widthM, 0f)
    assertEquals(1.6f, placed.heightM, 0f)
    assertEquals(2.5f, placed.place.distance, 0f)
    assertEquals(90f, placed.place.yawDeg, 1e-3f)
    assertEquals(otherEyes.y + 0.5f, placed.place.height, 1e-5f)
    assertEquals(0.2f, placed.elevation, 1e-5f)
  }

  @Test
  fun `a damaged entry of the preferences is no box`() {
    assertFalse(SavedScreenFrame(0f, 1f, 2f, 0f).isValid)
    assertFalse(SavedScreenFrame(1f, Float.NaN, 2f, 0f).isValid)
    assertFalse(SavedScreenFrame(1f, 1f, 30f, 0f).isValid)
    assertFalse(SavedScreenFrame(1f, 1f, 2f, Float.POSITIVE_INFINITY).isValid)
    // An elevation past the reach of a grab is brought back to it
    val placed = SavedScreenFrame(1f, 1f, 2f, 5f).placedInFront(eyes, Vector3(0f, 0f, 1f))
    assertEquals(FlatScreenGeometry.MAX_ELEVATION, placed.elevation, 1e-5f)
  }
}
