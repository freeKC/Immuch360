package app.alextran.immich.immersive

import com.meta.spatial.runtime.StereoMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
}
