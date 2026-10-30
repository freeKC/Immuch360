package app.alextran.immich.immersive

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.util.Log
import com.meta.spatial.runtime.StereoMode
import kotlin.math.roundToInt
import kotlin.math.tan
import kotlinx.serialization.json.JsonObject

/**
 * How a flat 3D media packs its eyes, as Flutter names it in the format of the flat3d JSON (see guessFlatStereoFormat
 * on the Flutter side): side by side or top and bottom, with eyes at the aspect of their half of the frame or squeezed
 * into it.
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
   * The packing of a flat 3D video of [width] x [height] (its display size) that Flutter named [format]: eyes said full
   * but narrower than square side by side, or wider than 2.5:1 stacked, are squeezed ones, as guessFlatStereoFormat
   * reads a video on the Flutter side, which a share page can only do once its player told the frame size. [format]
   * itself for squeezed eyes and for a size not known yet.
   */
  fun videoFormat(format: FlatFormat, width: Int, height: Int): FlatFormat {
    if (width <= 0 || height <= 0) return format
    return when (format) {
      FlatFormat.SBS -> if (width / 2f / height < 1f) FlatFormat.HALF_SBS else format
      FlatFormat.TB -> if (width / (height / 2f) > 2.5f) FlatFormat.HALF_TB else format
      FlatFormat.HALF_SBS,
      FlatFormat.HALF_TB -> format
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
   * Width and height in meters of the flat video screen [angleDeg] wide at [distance], for an eye of [aspect] (width
   * over height, see [eyeAspect]); 16:9 for an aspect not known yet.
   */
  fun screenSize(aspect: Float, angleDeg: Float, distance: Float): Pair<Float, Float> {
    val width = 2f * distance * tan(Math.toRadians(angleDeg / 2.0)).toFloat()
    val shape = if (aspect > 0f) aspect else 16f / 9f
    return width to width / shape
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

/**
 * The flat3d request (the stereoPair JSON of ImmersiveApi.open for a flat 3D media told by its file name, see
 * Flat3dRequest on the Dart side and mobile/test/fixtures/ai_immersive/flat3d_contract_v1.json): how the frame packs
 * the eyes. A photo goes on the stereo quad ([StereoPhotoKind.Flat]), a video on the flat video screen.
 */
internal data class FlatStereoSpec(val format: FlatFormat) {
  companion object {
    const val KIND = "flat3d"
    const val VERSION = 1

    /** The request of [root], null for another kind or version, or a format this build does not know. */
    fun fromJson(root: JsonObject): FlatStereoSpec? {
      if (root.string("kind") != KIND || root.integer("version") != VERSION) return null
      return FlatFormat.parse(root.string("format"))?.let(::FlatStereoSpec)
    }

    /** The request [text] holds, null for none, for another kind and for what [fromJson] refuses. */
    fun parse(text: String?): FlatStereoSpec? = (StereoPhotoKind.parse(text) as? StereoPhotoKind.Flat)?.spec
  }
}

/**
 * Where the eyes of a decoded flat 3D photo lie, [left] and [right] in the frame, and the size each shows at on the
 * quad: [eyeWidth] x [eyeHeight], a squeezed eye stretched back, within the limits of an eye on the quad.
 */
internal data class FlatSplit(
  val left: FlatStereo.Region,
  val right: FlatStereo.Region,
  val eyeWidth: Int,
  val eyeHeight: Int,
)

/**
 * A flat 3D photo told by its name on the stereo quad: decoded with a power of two sample size so that each eye still
 * covers the size it shows at, cut in its two eyes as [FlatStereo.eyes] says, each drawn at the shape it is shown with
 * on the texture of [StereoComposer] (each eye in its gutter, the left one on the left), as [SbsPhoto] does for the
 * side by side photos of the sbsPhoto JSON. The frame is read as stored. Pure but [decode] and [compose].
 */
internal object FlatStereoPhoto {
  /** The eyes of a frame of [width] x [height] as decoded, null when it is too small to hold two. */
  fun split(format: FlatFormat, width: Int, height: Int): FlatSplit? {
    val (left, right) = FlatStereo.eyes(format, width, height)
    if (left.width < 1 || left.height < 1) return null
    val (eyeWidth, eyeHeight) =
      shownSize(format, width, height, StereoHeicDecoder.MAX_EYE_WIDTH, StereoHeicDecoder.MAX_EYE_HEIGHT)
    return FlatSplit(left, right, eyeWidth, eyeHeight)
  }

  /** The size an eye of a [width] x [height] frame shows at, within [maxWidth] x [maxHeight]. */
  private fun shownSize(format: FlatFormat, width: Int, height: Int, maxWidth: Int, maxHeight: Int): Pair<Int, Int> {
    val (left, _) = FlatStereo.eyes(format, width, height)
    return FlatStereo.eyeSize(format, left, FlatStereo.eyeAspect(format, width, height), maxWidth, maxHeight)
  }

  /**
   * The largest power of two the decoder may sample a frame of [width] x [height] down by, so that each eye is still at
   * least as large as it shows: the quad then only scales down.
   */
  fun sampleSize(format: FlatFormat, width: Int, height: Int): Int {
    val target = split(format, width, height) ?: return 1
    val (fullWidth, fullHeight) = shownSize(format, width, height, Int.MAX_VALUE, Int.MAX_VALUE)
    var sample = 1
    while (fullWidth / (2 * sample) >= target.eyeWidth && fullHeight / (2 * sample) >= target.eyeHeight) sample *= 2
    return sample
  }

  /**
   * The texture of the flat 3D photo of [bytes] packed as [format], and where its eyes were; null when it cannot be
   * decoded or holds no two eyes. Off the main thread. Logs the sizes and the sample size, for the headset checks.
   */
  fun decode(bytes: ByteArray, format: FlatFormat): Pair<Bitmap, FlatSplit>? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
      Log.w(TAG, "flat 3D photo: unreadable image ${bounds.outMimeType}, ${bytes.size} bytes")
      return null
    }
    val sample = sampleSize(format, bounds.outWidth, bounds.outHeight)
    val options =
      BitmapFactory.Options().apply {
        inSampleSize = sample
        inPreferredConfig = Bitmap.Config.ARGB_8888
        inScaled = false
      }
    val frame = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
    try {
      // From the frame as decoded: the decoder rounds its sizes its own way
      val split = split(format, frame.width, frame.height) ?: return null
      Log.i(
        TAG,
        "flat 3D photo: ${bounds.outMimeType} ${bounds.outWidth}x${bounds.outHeight} $format, inSampleSize $sample, " +
          "decoded ${frame.width}x${frame.height}, left ${split.left}, right ${split.right}, " +
          "shown ${split.eyeWidth}x${split.eyeHeight}",
      )
      return compose(frame, split) to split
    } finally {
      frame.recycle()
    }
  }

  /**
   * One texture with the left eye of [frame] in the left half and its right eye in the right half, each scaled to the
   * size it shows at and set in its gutter of black, as [StereoComposer.compose] lays them out. [frame] is not
   * recycled.
   */
  fun compose(frame: Bitmap, split: FlatSplit): Bitmap {
    val (width, height) = StereoComposer.textureSize(split.eyeWidth, split.eyeHeight)
    val texture = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    texture.eraseColor(Color.BLACK)
    val canvas = Canvas(texture)
    val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    val gutter = StereoComposer.GUTTER
    val cell = split.eyeWidth + 2 * gutter
    for ((eye, left) in listOf(split.left to gutter, split.right to cell + gutter)) {
      canvas.drawBitmap(
        frame,
        Rect(eye.x, eye.y, eye.x + eye.width, eye.y + eye.height),
        Rect(left, gutter, left + split.eyeWidth, gutter + split.eyeHeight),
        paint,
      )
    }
    return texture
  }
}
