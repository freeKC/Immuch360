package app.alextran.immich.immersive

import com.meta.spatial.runtime.LayerFilters
import com.meta.spatial.runtime.StereoMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The compositor quad layer of the flat photos and the filters of the flat screens (an idea of Gaurav Mukherjee,
 * gmfun/Immuch360 branch quest/flat-3d, commit d47f56f6a): what the compositor is asked for, measured here.
 */
class FlatScreenLayerTest {
  @Test
  fun `the sharp setting asks the compositor for quality super sampling and sharpening, picked per frame`() {
    val filters = FlatScreenLayer.filters(sharp = true)
    assertEquals(LayerFilters.QUALITY_SUPER_SAMPLING, filters and LayerFilters.QUALITY_SUPER_SAMPLING)
    assertEquals(LayerFilters.QUALITY_SHARPENING, filters and LayerFilters.QUALITY_SHARPENING)
    assertEquals(LayerFilters.AUTO_FILTER, filters and LayerFilters.AUTO_FILTER)
    // Not the normal ones on top of the quality ones
    assertEquals(0, filters and (LayerFilters.NORMAL_SUPER_SAMPLING or LayerFilters.NORMAL_SHARPENING))
    // The values of the SDK 0.14 (javap of LayerFilters): 2, 16 and 32
    assertEquals(50, filters)
  }

  @Test
  fun `the setting off asks for no filter`() {
    assertEquals(0, FlatScreenLayer.filters(sharp = false))
  }

  @Test
  fun `the surface holds two square eyes of 2048 pixels, or one picture twice as wide`() {
    assertEquals(4096, FlatScreenLayer.SURFACE_WIDTH_PX)
    assertEquals(2048, FlatScreenLayer.SURFACE_HEIGHT_PX)
    val (left, right) = FlatScreenLayer.eyeRegions(twoEyes = true)
    assertEquals(FlatStereo.Region(0, 0, 2048, 2048), left)
    assertEquals(FlatStereo.Region(2048, 0, 2048, 2048), right)
    val (single, same) = FlatScreenLayer.eyeRegions(twoEyes = false)
    assertEquals(FlatStereo.Region(0, 0, 4096, 2048), single)
    assertEquals(single, same)
  }

  @Test
  fun `each eye is taken from its cell of the texture, without its gutter`() {
    val gutter = StereoComposer.GUTTER
    assertEquals(FlatStereo.Region(gutter, gutter, 1600, 1200), FlatScreenLayer.sourceRegion(0, 1600, 1200))
    assertEquals(
      FlatStereo.Region(1600 + 3 * gutter, gutter, 1600, 1200),
      FlatScreenLayer.sourceRegion(1, 1600, 1200),
    )
  }

  @Test
  fun `two eyes show left and right in 3D, the left one for both in 2D, one picture as it is`() {
    assertEquals(StereoMode.LeftRight, FlatScreenLayer.stereoMode(twoEyes = true, threeD = true))
    assertEquals(StereoMode.MonoLeft, FlatScreenLayer.stereoMode(twoEyes = true, threeD = false))
    assertEquals(StereoMode.None, FlatScreenLayer.stereoMode(twoEyes = false, threeD = true))
    assertEquals(StereoMode.None, FlatScreenLayer.stereoMode(twoEyes = false, threeD = false))
  }

  @Test
  fun `the quad is the picture itself, as wide as its angle at its distance, no gutter and no black around`() {
    val (width, height) = FlatScreenLayer.quadSize(48f, 1600, 1200, 2f)
    assertEquals(FlatScreenGeometry.width(48f, 2f), width, 1e-5f)
    assertEquals(width * 0.75f, height, 1e-5f)
    val (portraitWidth, portraitHeight) = FlatScreenLayer.quadSize(24f, 1080, 1920, 1.5f)
    assertEquals(portraitWidth * 1920f / 1080f, portraitHeight, 1e-5f)
  }

  @Test
  fun `the photos of the stereo quad go on the layer with the setting on, a relief and a scene stay on the mesh`() {
    val heic = StereoPhotoKind.HeicPair(StereoPairSpec(1, 1, 2, 100, 2, 4032, 3024, 0, 0, 65f))
    val sbs =
      StereoPhotoKind.Sbs(
        SbsPhotoSpec(
          SbsPhotoSpec.Layout.LEFT_RIGHT,
          SbsPhotoSpec.Eyes.FULL,
          SbsPhotoSpec.Origin.UNKNOWN,
          SbsPhotoSpec.LeftEye.UNKNOWN,
        )
      )
    val flat = StereoPhotoKind.Flat(FlatStereoSpec(FlatFormat.TB))
    for (kind in listOf(heic, sbs, flat, null)) {
      assertTrue("$kind", FlatScreenLayer.showsOnLayer(kind, sharp = true))
      assertFalse("$kind", FlatScreenLayer.showsOnLayer(kind, sharp = false))
    }
    val relief = StereoPhotoKind.DepthRelief(DepthReliefSpec("m", 1, "id", "0".repeat(64), 0.02, 0.5, 0))
    assertFalse(FlatScreenLayer.showsOnLayer(relief, sharp = true))
  }
}
