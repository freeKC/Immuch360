package app.alextran.immich.immersive

import com.meta.spatial.core.Vector3
import kotlin.math.tan
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The texture and the quad of a spatial photo (section 5.8 of the design). */
class StereoComposerTest {
  @Test
  fun `no disparity keeps both eyes whole`() {
    assertEquals(StereoComposer.Crop(leftStart = 0, rightStart = 0, width = 3072), StereoComposer.crop(3072, 0))
  }

  @Test
  fun `a positive disparity pushes the scene back`() {
    // s = 200 / 10000 * 3072 / 2 = 30.72, 31 pixels: the left eye keeps its right part, the right eye its left part
    assertEquals(StereoComposer.Crop(leftStart = 62, rightStart = 0, width = 3010), StereoComposer.crop(3072, 200))
  }

  @Test
  fun `a negative disparity brings the scene forward`() {
    // s = 1000 / 10000 * 3072 / 2 = 153.6, 154 pixels
    assertEquals(StereoComposer.Crop(leftStart = 0, rightStart = 308, width = 2764), StereoComposer.crop(3072, -1000))
  }

  @Test
  fun `a disparity past 2000 is clamped`() {
    // As 2000: s = 0.2 * 3072 / 2 = 307.2, 307 pixels
    assertEquals(StereoComposer.Crop(leftStart = 614, rightStart = 0, width = 2458), StereoComposer.crop(3072, 2500))
    assertEquals(StereoComposer.crop(3072, -2000), StereoComposer.crop(3072, -9000))
  }

  @Test
  fun `the texture holds both eyes in their gutters`() {
    assertEquals(2 * (2764 + 8) to 3072 + 8, StereoComposer.textureSize(2764, 3072))
  }

  @Test
  fun `the quad starts at 0_8 of the field of view of the camera, within 35 and 60 degrees`() {
    assertEquals(48f, StereoComposer.initialAngle(60f), 1e-4f)
    assertEquals(48f, StereoComposer.initialAngle(null))
    assertEquals(60f, StereoComposer.initialAngle(120f))
    assertEquals(35f, StereoComposer.initialAngle(30f))
  }

  @Test
  fun `the quad is as wide as its angle at 2 m, as tall as the eyes say`() {
    for ((fov, angle) in listOf(60f to 48f, null to 48f, 120f to 60f)) {
      val start = StereoComposer.initialAngle(fov)
      assertEquals("fov $fov", angle, start, 1e-4f)
      val (width, height) = StereoComposer.quadSize(start, 3072, 3072)
      val expected = (2 * 2.0 * tan(Math.toRadians(angle / 2.0))).toFloat()
      assertEquals("fov $fov", expected, width, 1e-4f)
      // A square eye in its gutters is square
      assertEquals("fov $fov", width, height, 1e-4f)
    }
    // 60 degrees at 2 m: 2.309 m wide
    assertEquals(2.3094f, StereoComposer.quadSize(60f, 3072, 3072).first, 1e-3f)
    // A 4:3 eye after a crop for the disparity: the height follows the eye with its gutters
    val (width, height) = StereoComposer.quadSize(48f, 2764, 2304)
    assertEquals(width * (2304 + 8) / (2764 + 8), height, 1e-4f)
  }

  @Test
  fun `the thumbstick changes the angle by 6 degrees within 30 and 90`() {
    assertEquals(54f, StereoComposer.nextAngle(48f, 1))
    assertEquals(42f, StereoComposer.nextAngle(48f, -1))
    assertEquals(90f, StereoComposer.nextAngle(88f, 1))
    assertEquals(30f, StereoComposer.nextAngle(33f, -1))
  }

  @Test
  fun `fits an eye within the texture limits, its aspect kept`() {
    assertEquals(2560 to 2560, StereoComposer.fitWithin(3072, 3072, 2560, 4088))
    assertEquals(2000 to 1000, StereoComposer.fitWithin(2000, 1000, 2560, 4088))
    assertEquals(2555 to 4088, StereoComposer.fitWithin(3000, 4800, 2560, 4088))
  }

  @Test
  fun `the grey difference of two images`() {
    val black = IntArray(4) { 0xFF000000.toInt() }
    val white = IntArray(4) { 0xFFFFFFFF.toInt() }
    assertEquals(0f, StereoComposer.meanGreyDifference(black, black.copyOf()), 1e-4f)
    assertEquals(255f, StereoComposer.meanGreyDifference(black, white), 1e-3f)
    val half = intArrayOf(0xFFFFFFFF.toInt(), 0xFFFFFFFF.toInt(), 0xFF000000.toInt(), 0xFF000000.toInt())
    assertEquals(127.5f, StereoComposer.meanGreyDifference(black, half), 1e-3f)
  }

  @Test
  fun `the quad faces the user as the panels do, its eyes the right way round`() {
    // The gaze, and the right of the user in the left handed space of the Spatial SDK (x right, y up, z forward)
    val cases =
      listOf(
        Vector3(0f, 0f, 1f) to Vector3(1f, 0f, 0f),
        Vector3(1f, 0f, 0f) to Vector3(0f, 0f, -1f),
        Vector3(0f, 0f, -1f) to Vector3(-1f, 0f, 0f),
        Vector3(-0.6f, 0f, 0.8f) to Vector3(0.8f, 0f, 0.6f),
      )
    for ((gaze, right) in cases) {
      val rotation = StereoComposer.quadRotation(gaze)
      // u grows along the +x of SceneMesh.singleSidedQuad: to the right of the user, not mirrored
      assertVector("u axis for gaze $gaze", right, rotation * Vector3(1f, 0f, 0f))
      assertVector("up for gaze $gaze", Vector3(0f, 1f, 0f), rotation * Vector3(0f, 1f, 0f))
      // Its +z normal along the gaze: the user sees the other side, which the double sided material shows
      assertVector("normal for gaze $gaze", gaze, rotation * Vector3(0f, 0f, 1f))
    }
  }

  @Test
  fun `the choices on a spatial photo come back for that photo of that opening only`() {
    val choices = StereoPhotoChoices("https://server/photo.heic", 7L, threeD = false, angleDeg = 66f)
    assertEquals(choices, choices.forPhoto("https://server/photo.heic", 7L))
    assertNull(choices.forPhoto("https://server/other.heic", 7L))
    assertNull(choices.forPhoto("https://server/photo.heic", 8L))
  }

  @Test
  fun `a restored angle stays within the bounds of the thumbstick`() {
    val wide = StereoPhotoChoices("u", 1L, threeD = true, angleDeg = 120f)
    assertEquals(90f, wide.forPhoto("u", 1L)?.angleDeg)
    assertEquals(30f, wide.copy(angleDeg = 10f).forPhoto("u", 1L)?.angleDeg)
    assertNull(wide.copy(angleDeg = Float.NaN).forPhoto("u", 1L))
  }

  private fun assertVector(message: String, expected: Vector3, actual: Vector3) {
    assertEquals("$message x", expected.x, actual.x, 1e-4f)
    assertEquals("$message y", expected.y, actual.y, 1e-4f)
    assertEquals("$message z", expected.z, actual.z, 1e-4f)
  }

  @Test
  fun `labels fall back to English`() {
    assertEquals("3D", StereoComposer.label(emptyMap(), StereoComposer.LABEL_3D))
    assertEquals("2D (œil gauche)", StereoComposer.label(mapOf("spatial2d" to "2D (œil gauche)"), "spatial2d"))
    assertEquals(
      "The second eye could not be decoded: shown in 2D",
      StereoComposer.label(mapOf("spatialSecondEyeFailed" to " "), StereoComposer.LABEL_SECOND_EYE_FAILED),
    )
  }
}
