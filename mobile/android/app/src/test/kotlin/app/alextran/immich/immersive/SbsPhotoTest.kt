package app.alextran.immich.immersive

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The two eyes of a side by side photo on the stereo quad (design-final 2026-10-26, section 3.8). */
class SbsPhotoTest {
  private fun spec(
    layout: SbsPhotoSpec.Layout = SbsPhotoSpec.Layout.LEFT_RIGHT,
    eyes: SbsPhotoSpec.Eyes = SbsPhotoSpec.Eyes.FULL,
  ) = SbsPhotoSpec(layout, eyes, SbsPhotoSpec.Origin.UNKNOWN, SbsPhotoSpec.LeftEye.UNKNOWN)

  @Test
  fun `full width eyes each take half of the frame and show at their own size`() {
    assertEquals(
      SbsSplit(leftStart = 0, rightStart = 2000, storedWidth = 2000, height = 1500, eyeWidth = 2000, eyeHeight = 1500),
      SbsPhoto.split(4000, 1500, spec()),
    )
  }

  @Test
  fun `half width eyes show twice as wide as they are stored`() {
    assertEquals(
      SbsSplit(leftStart = 0, rightStart = 960, storedWidth = 960, height = 1080, eyeWidth = 1920, eyeHeight = 1080),
      SbsPhoto.split(1920, 1080, spec(eyes = SbsPhotoSpec.Eyes.HALF)),
    )
  }

  @Test
  fun `eyes swapped in the file go back to the right eye of the user`() {
    val split = SbsPhoto.split(4000, 1500, spec(layout = SbsPhotoSpec.Layout.RIGHT_LEFT))

    // The right half of the frame is the left eye
    assertEquals(2000, split!!.leftStart)
    assertEquals(0, split.rightStart)
  }

  @Test
  fun `an odd width leaves the middle column out, each eye at its outer edge`() {
    val full = SbsPhoto.split(4001, 1500, spec())!!
    assertEquals(2000, full.storedWidth)
    assertEquals(0, full.leftStart)
    assertEquals(2001, full.rightStart)
    assertEquals(2000, full.eyeWidth)

    val swapped = SbsPhoto.split(4001, 1500, spec(layout = SbsPhotoSpec.Layout.RIGHT_LEFT))!!
    assertEquals(2001, swapped.leftStart)
    assertEquals(0, swapped.rightStart)

    val half = SbsPhoto.split(1919, 1080, spec(eyes = SbsPhotoSpec.Eyes.HALF))!!
    assertEquals(959, half.storedWidth)
    assertEquals(960, half.rightStart)
    assertEquals(1918, half.eyeWidth)
  }

  @Test
  fun `a frame too narrow for two eyes is none`() {
    assertNull(SbsPhoto.split(1, 100, spec()))
    assertNull(SbsPhoto.split(0, 100, spec()))
    assertNull(SbsPhoto.split(100, 0, spec()))
  }

  @Test
  fun `each eye stays within the eye limits of the quad, its aspect kept`() {
    // 48 Mpx side by side of a 24 Mpx photo: two 6000 x 4000 eyes, shown 2560 wide
    val wide = SbsPhoto.split(12000, 4000, spec())!!
    assertEquals(2560 to 1707, wide.eyeWidth to wide.eyeHeight)
    // Portrait eyes reach the height limit first
    val tall = SbsPhoto.split(6000, 6000, spec())!!
    assertEquals(StereoHeicDecoder.MAX_EYE_HEIGHT, tall.eyeHeight)
    assertEquals(2044, tall.eyeWidth)
    // Half width eyes are capped at their shown width
    val half = SbsPhoto.split(7680, 2160, spec(eyes = SbsPhotoSpec.Eyes.HALF))!!
    assertEquals(2560 to 720, half.eyeWidth to half.eyeHeight)
    // Both eyes on the texture stay within the limit of the headset
    for (split in listOf(wide, tall, half)) {
      val (width, height) = StereoComposer.textureSize(split.eyeWidth, split.eyeHeight)
      assertTrue(width <= ImmersiveMedia.MAX_TEXTURE_WIDTH && height <= ImmersiveMedia.MAX_TEXTURE_HEIGHT)
    }
  }

  @Test
  fun `the decoder samples the frame down by powers of two, never below the size shown`() {
    // Fits as it is
    assertEquals(1, SbsPhoto.sampleSize(4000, 1500, spec()))
    // 6000 wide eyes for 2560 shown: 2 gives 3000, 4 would give 1500
    assertEquals(2, SbsPhoto.sampleSize(12000, 4000, spec()))
    // 12000 wide eyes: 4 gives 3000
    assertEquals(4, SbsPhoto.sampleSize(24000, 8000, spec()))
    // Half width: 3840 stored, 7680 shown for 2560: 2 gives 3840 shown
    assertEquals(2, SbsPhoto.sampleSize(7680, 2160, spec(eyes = SbsPhotoSpec.Eyes.HALF)))
    // The height decides for portrait eyes: 9000 high for 4088
    assertEquals(2, SbsPhoto.sampleSize(6000, 9000, spec()))
    // Nothing to decode
    assertEquals(1, SbsPhoto.sampleSize(0, 0, spec()))
  }

  /**
   * A test card: a scene with a near post on its left and a far post on its right, seen by each eye. The near post
   * shows further right to the left eye than to the right eye (crossed disparity), the far post the other way.
   */
  private val sceneWidth = 40
  private val nearPost = 10
  private val farPost = 30
  private val disparity = 2
  private val near = 0xFFFF0000.toInt()
  private val far = 0xFF0000FF.toInt()

  /** What one eye sees, [leftEye] or the right one, [width] wide (the scene squeezed for half width eyes) */
  private fun view(leftEye: Boolean, width: Int): IntArray {
    val row = IntArray(width) { 0xFF808080.toInt() }
    val scale = width.toDouble() / sceneWidth
    val shift = if (leftEye) disparity else -disparity
    row[((nearPost + shift) * scale).toInt()] = near
    row[((farPost - shift) * scale).toInt()] = far
    return row
  }

  /** One row of a side by side frame: [layout] says which view is on its left half */
  private fun frame(layout: SbsPhotoSpec.Layout, eyes: SbsPhotoSpec.Eyes): IntArray {
    val eyeWidth = if (eyes == SbsPhotoSpec.Eyes.FULL) sceneWidth else sceneWidth / 2
    val leftView = view(leftEye = true, eyeWidth)
    val rightView = view(leftEye = false, eyeWidth)
    return if (layout == SbsPhotoSpec.Layout.LEFT_RIGHT) leftView + rightView else rightView + leftView
  }

  /** The columns of an eye of [row], as the quad takes them */
  private fun eye(row: IntArray, start: Int, width: Int) = row.copyOfRange(start, start + width)

  @Test
  fun `the near post comes out in front and the far one behind, whatever the layout`() {
    for (layout in SbsPhotoSpec.Layout.values()) {
      for (eyes in SbsPhotoSpec.Eyes.values()) {
        val row = frame(layout, eyes)
        val split = SbsPhoto.split(row.size, 1, spec(layout, eyes))!!
        val left = eye(row, split.leftStart, split.storedWidth)
        val right = eye(row, split.rightStart, split.storedWidth)
        val case = "$layout $eyes"
        // Seen further right by the left eye than by the right eye: in front of the quad
        assertTrue(case, left.indexOf(near) > right.indexOf(near))
        // Seen further left by the left eye: behind it
        assertTrue(case, left.indexOf(far) < right.indexOf(far))
      }
    }
  }
}
