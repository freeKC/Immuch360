package app.alextran.immich.immersive

import com.meta.spatial.runtime.StereoMode
import kotlin.math.roundToInt

/**
 * How a flat 3D media packs its eyes, as Flutter names it in the flatFormat of ImmersiveApi.open (see
 * guessFlatStereoFormat on the Flutter side): side by side or top and bottom, with eyes at the aspect of their half of
 * the frame or squeezed into it.
 */
internal enum class FlatFormat(val wire: String) {
  SBS("sbs"),
  HALF_SBS("halfSbs"),
  TB("tb"),
  HALF_TB("halfTb");

  companion object {
    /** The format Flutter sent as [wire], null for none or for one this viewer does not know (a newer Flutter side). */
    fun parse(wire: String?): FlatFormat? = entries.firstOrNull { it.wire == wire }
  }
}

/**
 * Flat 3D media on a screen in front of the user (the stereo quad for a photo, a flat video layer for a video): where
 * each eye lies in the frame and the shape it is shown with. Pure functions, unit tested.
 */
internal object FlatStereo {
  /** A rectangle of a frame, in pixels. */
  data class Region(val x: Int, val y: Int, val width: Int, val height: Int)

  /**
   * The left and the right eye of a [width] x [height] frame packed as [format]. An odd side leaves its last column or
   * row out.
   */
  fun eyes(format: FlatFormat, width: Int, height: Int): Pair<Region, Region> =
    when (format) {
      FlatFormat.SBS,
      FlatFormat.HALF_SBS -> {
        val half = width / 2
        Region(0, 0, half, height) to Region(half, 0, half, height)
      }
      FlatFormat.TB,
      FlatFormat.HALF_TB -> {
        val half = height / 2
        Region(0, 0, width, half) to Region(0, half, width, half)
      }
    }

  /**
   * Width over height of one eye as the user sees it, for a [width] x [height] frame: that of its half of the frame,
   * twice as wide for squeezed eyes side by side, twice as tall for squeezed eyes stacked (both then show with the
   * aspect of the whole frame). 16:9 for an unknown size.
   */
  fun eyeAspect(format: FlatFormat, width: Int, height: Int): Float {
    if (width <= 0 || height <= 0) return 16f / 9f
    val frame = width.toFloat() / height
    return when (format) {
      FlatFormat.SBS -> frame / 2f
      FlatFormat.TB -> frame * 2f
      FlatFormat.HALF_SBS,
      FlatFormat.HALF_TB -> frame
    }
  }

  /**
   * The size of the image of one eye on the texture, in pixels: the height of its [region] (its width for eyes squeezed
   * side by side) at the shape of [eyeAspect], within [maxWidth] x [maxHeight].
   */
  fun eyeSize(format: FlatFormat, region: Region, aspect: Float, maxWidth: Int, maxHeight: Int): Pair<Int, Int> {
    var height = region.height
    var width = (height * aspect).roundToInt()
    if (width < region.width) {
      // Stacked squeezed eyes: the full width is the detail to keep, the height grows instead
      width = region.width
      height = (width / aspect).roundToInt()
    }
    return StereoComposer.fitWithin(width.coerceAtLeast(1), height.coerceAtLeast(1), maxWidth, maxHeight)
  }

  /**
   * The stereo mode of the flat video layer: each eye its half of the frame in 3D, the left (or top) eye for both in
   * 2D.
   */
  fun stereoModeFor(format: FlatFormat, threeD: Boolean): StereoMode =
    when (format) {
      FlatFormat.SBS,
      FlatFormat.HALF_SBS -> if (threeD) StereoMode.LeftRight else StereoMode.MonoLeft
      FlatFormat.TB,
      FlatFormat.HALF_TB -> if (threeD) StereoMode.UpDown else StereoMode.MonoUp
    }
}
