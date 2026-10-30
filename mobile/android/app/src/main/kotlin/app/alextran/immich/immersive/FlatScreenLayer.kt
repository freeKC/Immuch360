package app.alextran.immich.immersive

import com.meta.spatial.runtime.LayerFilters
import com.meta.spatial.runtime.StereoMode

/**
 * The compositor quad layer of the flat photos, and the filters of the flat screens: a photo of the stereo quad drawn
 * on the Surface of a quad layer is sampled once by the compositor, straight to the display, with its super sampling
 * and sharpening, where the quad mesh goes through the eye buffer first: a sharper photo. The idea and its first
 * version are Gaurav Mukherjee's (gmfun/Immuch360, branch quest/flat-3d, commit d47f56f6a), redone on our quad code:
 * the Surface holds both eyes side by side, each stretched over its half (the quad gives it its shape back), or one
 * picture over the whole Surface; the setting "Sharper flat screens (experimental)", on by default, turns the layer
 * and the filters off, the photos then going on the quad mesh as before. Pure, unit tested.
 */
internal object FlatScreenLayer {
  /**
   * The Surface of the photo layer: two square eyes of 2048 pixels, about twice the pixels of the display a screen 60
   * degrees wide covers on a Quest 3, or one picture of 4096 x 2048 for a photo of one eye.
   */
  const val SURFACE_WIDTH_PX = 4096
  const val SURFACE_HEIGHT_PX = 2048

  /**
   * The filters the compositor is asked for on a flat screen: with [sharp], the quality super sampling for a picture
   * larger than the pixels of the display it covers and the quality sharpening for a smaller one, the compositor
   * picking the one that applies (AUTO_FILTER); none without.
   */
  fun filters(sharp: Boolean): Int = if (sharp) LayerFilters.HIGHEST_QUALITY or LayerFilters.AUTO_FILTER else 0

  /**
   * Where each eye goes on the Surface: the left and the right half for [twoEyes], the whole Surface twice for one
   * picture.
   */
  fun eyeRegions(twoEyes: Boolean): Pair<FlatStereo.Region, FlatStereo.Region> =
    if (twoEyes) {
      val half = SURFACE_WIDTH_PX / 2
      FlatStereo.Region(0, 0, half, SURFACE_HEIGHT_PX) to FlatStereo.Region(half, 0, half, SURFACE_HEIGHT_PX)
    } else {
      FlatStereo.Region(0, 0, SURFACE_WIDTH_PX, SURFACE_HEIGHT_PX).let { it to it }
    }

  /** Where eye [eye] (0 left, 1 right) of [eyeWidth] x [eyeHeight] lies on the texture of StereoComposer.compose. */
  fun sourceRegion(eye: Int, eyeWidth: Int, eyeHeight: Int): FlatStereo.Region {
    val gutter = StereoComposer.GUTTER
    return FlatStereo.Region(eye * (eyeWidth + 2 * gutter) + gutter, gutter, eyeWidth, eyeHeight)
  }

  /** LeftRight for two eyes in 3D, the left one for both in 2D (MonoLeft), the whole Surface for one picture. */
  fun stereoMode(twoEyes: Boolean, threeD: Boolean): StereoMode =
    when {
      !twoEyes -> StereoMode.None
      threeD -> StereoMode.LeftRight
      else -> StereoMode.MonoLeft
    }

  /**
   * Width and height in meters of the layer for an eye of [eyeWidth] x [eyeHeight] [angleDeg] wide at [distance]: the
   * picture itself, without the gutters the mesh shows nor any black around it.
   */
  fun quadSize(angleDeg: Float, eyeWidth: Int, eyeHeight: Int, distance: Float): Pair<Float, Float> {
    val width = FlatScreenGeometry.width(angleDeg, distance)
    return width to width * eyeHeight / eyeWidth.coerceAtLeast(1)
  }

  /**
   * Whether a photo of the stereo quad of [kind] shows on the layer: with [sharp], an Apple spatial photo, a side by
   * side photo, a flat 3D photo, a photo on the big screen and one whose JSON does not read (shown flat); never a
   * relief made in the headset, whose 2.5D mesh needs the quad behind it, nor the preview of a 3D scene.
   */
  fun showsOnLayer(kind: StereoPhotoKind?, sharp: Boolean): Boolean =
    sharp &&
      when (kind) {
        is StereoPhotoKind.DepthRelief,
        is StereoPhotoKind.VolumetricScene -> false
        else -> true
      }
}
