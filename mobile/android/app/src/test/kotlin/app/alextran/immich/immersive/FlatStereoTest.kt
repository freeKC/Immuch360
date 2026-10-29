package app.alextran.immich.immersive

import com.meta.spatial.runtime.StereoMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Flat 3D media: the eyes of a frame and their shape. */
class FlatStereoTest {
  @Test
  fun `the formats Flutter sends are read, an unknown one is none`() {
    assertEquals(FlatFormat.SBS, FlatFormat.parse("sbs"))
    assertEquals(FlatFormat.HALF_SBS, FlatFormat.parse("halfSbs"))
    assertEquals(FlatFormat.TB, FlatFormat.parse("tb"))
    assertEquals(FlatFormat.HALF_TB, FlatFormat.parse("halfTb"))
    assertNull(FlatFormat.parse(null))
    assertNull(FlatFormat.parse("mvhevc"))
  }

  @Test
  fun `side by side frames split in two columns, stacked ones in two rows`() {
    val sbs = FlatStereo.eyes(FlatFormat.SBS, 3841, 1080)
    assertEquals(FlatStereo.Region(0, 0, 1920, 1080), sbs.first)
    assertEquals(FlatStereo.Region(1920, 0, 1920, 1080), sbs.second)
    val tb = FlatStereo.eyes(FlatFormat.HALF_TB, 1920, 1080)
    assertEquals(FlatStereo.Region(0, 0, 1920, 540), tb.first)
    assertEquals(FlatStereo.Region(0, 540, 1920, 540), tb.second)
  }

  @Test
  fun `squeezed eyes show with the shape of the whole frame`() {
    assertEquals(16f / 9f, FlatStereo.eyeAspect(FlatFormat.SBS, 3840, 1080), 1e-4f)
    assertEquals(16f / 9f, FlatStereo.eyeAspect(FlatFormat.HALF_SBS, 1920, 1080), 1e-4f)
    assertEquals(16f / 9f, FlatStereo.eyeAspect(FlatFormat.TB, 1920, 2160), 1e-4f)
    assertEquals(16f / 9f, FlatStereo.eyeAspect(FlatFormat.HALF_TB, 1920, 1080), 1e-4f)
    assertEquals(16f / 9f, FlatStereo.eyeAspect(FlatFormat.SBS, 0, 0), 1e-4f)
  }

  @Test
  fun `squeezed eyes are stretched back on the texture, within its limits`() {
    val halfSbs = FlatStereo.eyes(FlatFormat.HALF_SBS, 1920, 1080).first
    assertEquals(1920 to 1080, FlatStereo.eyeSize(FlatFormat.HALF_SBS, halfSbs, 16f / 9f, 2560, 4088))
    val halfTb = FlatStereo.eyes(FlatFormat.HALF_TB, 1920, 1080).first
    assertEquals(1920 to 1080, FlatStereo.eyeSize(FlatFormat.HALF_TB, halfTb, 16f / 9f, 2560, 4088))
    val large = FlatStereo.eyes(FlatFormat.SBS, 7680, 2160).first
    assertEquals(2560 to 1440, FlatStereo.eyeSize(FlatFormat.SBS, large, 16f / 9f, 2560, 4088))
  }

  @Test
  fun `the video layer shows each eye its half in 3D, the first eye in 2D`() {
    assertEquals(StereoMode.LeftRight, FlatStereo.stereoModeFor(FlatFormat.HALF_SBS, threeD = true))
    assertEquals(StereoMode.MonoLeft, FlatStereo.stereoModeFor(FlatFormat.SBS, threeD = false))
    assertEquals(StereoMode.UpDown, FlatStereo.stereoModeFor(FlatFormat.TB, threeD = true))
    assertEquals(StereoMode.MonoUp, FlatStereo.stereoModeFor(FlatFormat.HALF_TB, threeD = false))
  }

  @Test
  fun `the flat video screen is as wide as its angle at its distance, as high as one eye is`() {
    val (width, height) = FlatStereo.screenSize(16f / 9f, angleDeg = 60f, distance = 2f)
    // 2 x 2 m x tan(30 degrees)
    assertEquals(2.3094f, width, 1e-3f)
    assertEquals(2.3094f * 9f / 16f, height, 1e-3f)
    // A taller eye, a taller screen: the width stays the angle
    val (portraitWidth, portraitHeight) = FlatStereo.screenSize(3f / 4f, angleDeg = 60f, distance = 2f)
    assertEquals(width, portraitWidth, 1e-4f)
    assertEquals(width * 4f / 3f, portraitHeight, 1e-3f)
    // A size the player has not told yet: 16:9
    assertEquals(height, FlatStereo.screenSize(0f, angleDeg = 60f, distance = 2f).second, 1e-4f)
  }

  @Test
  fun `a photo of two eyes one above the other goes on the quad each eye in its own half`() {
    val split = FlatStereoPhoto.split(FlatFormat.TB, 4000, 6000)!!
    assertEquals(FlatStereo.Region(0, 0, 4000, 3000), split.left)
    assertEquals(FlatStereo.Region(0, 3000, 4000, 3000), split.right)
    // A 4:3 eye within the eye limits of the quad (2560 x 4088)
    assertEquals(2560 to 1920, split.eyeWidth to split.eyeHeight)
    // Both eyes on the texture stay within the limit of the headset
    val (width, height) = StereoComposer.textureSize(split.eyeWidth, split.eyeHeight)
    assertTrue(width <= ImmersiveMedia.MAX_TEXTURE_WIDTH && height <= ImmersiveMedia.MAX_TEXTURE_HEIGHT)
  }

  @Test
  fun `squeezed stacked eyes of a photo show twice as tall as they are stored`() {
    val split = FlatStereoPhoto.split(FlatFormat.HALF_TB, 1920, 1080)!!
    assertEquals(FlatStereo.Region(0, 540, 1920, 540), split.right)
    assertEquals(1920 to 1080, split.eyeWidth to split.eyeHeight)
  }

  @Test
  fun `a frame too small for two eyes is none`() {
    assertNull(FlatStereoPhoto.split(FlatFormat.TB, 100, 1))
    assertNull(FlatStereoPhoto.split(FlatFormat.SBS, 1, 100))
    assertNull(FlatStereoPhoto.split(FlatFormat.TB, 0, 0))
  }

  @Test
  fun `the decoder samples a photo down by powers of two, never below the size an eye shows at`() {
    // Fits as it is: two 1920 x 1080 eyes
    assertEquals(1, FlatStereoPhoto.sampleSize(FlatFormat.TB, 1920, 2160))
    // Two 8000 x 6000 eyes shown 2560 wide: 2 gives 4000, 4 would give 2000
    assertEquals(2, FlatStereoPhoto.sampleSize(FlatFormat.TB, 8000, 12000))
    // Squeezed: 7680 x 2160 stored per eye, 7680 x 4320 shown, 2560 wide on the quad: 2 gives 3840
    assertEquals(2, FlatStereoPhoto.sampleSize(FlatFormat.HALF_TB, 7680, 4320))
    // Side by side the same way
    assertEquals(4, FlatStereoPhoto.sampleSize(FlatFormat.SBS, 24000, 4000))
    // Nothing to decode
    assertEquals(1, FlatStereoPhoto.sampleSize(FlatFormat.TB, 0, 0))
  }

  @Test
  fun `a photo halved one row or one column short of the eye it shows is decoded whole`() {
    // Two 5120 x 2881 eyes shown 2560 x 1441: halved, 1440 rows, one short
    assertEquals(1, FlatStereoPhoto.sampleSize(FlatFormat.SBS, 10240, 2881))
    // Two 5119 x 8176 eyes shown 2560 x 4088: halved, 2559 columns of the eye, one short, whatever the frame width
    assertEquals(1, FlatStereoPhoto.sampleSize(FlatFormat.SBS, 10238, 2 * StereoHeicDecoder.MAX_EYE_HEIGHT))
  }
}
