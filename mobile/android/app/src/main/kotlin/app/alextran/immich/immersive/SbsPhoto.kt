package app.alextran.immich.immersive

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.util.Log
import kotlinx.serialization.json.JsonObject

/**
 * The sbsPhoto request (design-final 2026-10-26, sections 3.8 and 4.1): a flat photo holding two eyes side by side,
 * which eye is on the left half of the frame, whether each eye takes half of the frame (full) or both are squeezed
 * into the width of one (half), and what the file says of itself. Our files (their Immuch360 XMP) say the relief was
 * estimated and the left eye is the original photo; the file of another tool says nothing, and the quad claims
 * nothing about it either.
 */
internal data class SbsPhotoSpec(val layout: Layout, val eyes: Eyes, val origin: Origin, val leftEye: LeftEye) {
  enum class Layout(val json: String) {
    LEFT_RIGHT("leftRight"),
    RIGHT_LEFT("rightLeft"),
  }

  enum class Eyes(val json: String) {
    FULL("full"),
    HALF("half"),
  }

  enum class Origin(val json: String) {
    ESTIMATED_DEPTH("estimatedDepth"),
    GENERATED_CONTENT("generatedContent"),
    UNKNOWN("unknown"),
  }

  enum class LeftEye(val json: String) {
    ORIGINAL("original"),
    UNKNOWN("unknown"),
  }

  companion object {
    const val KIND = "sbsPhoto"
    const val VERSION = 1

    /**
     * The request of [root], null for another version or a layout or a width this build cannot show. An origin or a
     * left eye it does not know reads as unknown, as the Dart side reads them: the photo still shows in 3D, without a
     * word about how it was made.
     */
    fun fromJson(root: JsonObject): SbsPhotoSpec? {
      if (root.string("kind") != KIND || root.integer("version") != VERSION) return null
      val layout = root.string("layout").let { value -> Layout.values().firstOrNull { it.json == value } }
      val eyes = root.string("eyes").let { value -> Eyes.values().firstOrNull { it.json == value } }
      if (layout == null || eyes == null) return null
      return SbsPhotoSpec(
        layout = layout,
        eyes = eyes,
        origin = root.string("origin").let { value -> Origin.values().firstOrNull { it.json == value } }
          ?: Origin.UNKNOWN,
        leftEye = root.string("leftEye").let { value -> LeftEye.values().firstOrNull { it.json == value } }
          ?: LeftEye.UNKNOWN,
      )
    }
  }
}

/**
 * Where the eyes of a decoded side by side frame lie and how big they show: the columns of the left eye from
 * [leftStart] and of the right eye from [rightStart], each [storedWidth] wide and [height] high, shown at [eyeWidth] x
 * [eyeHeight] (twice as wide as stored for half width eyes, within the limits of an eye on the quad).
 */
internal data class SbsSplit(
  val leftStart: Int,
  val rightStart: Int,
  val storedWidth: Int,
  val height: Int,
  val eyeWidth: Int,
  val eyeHeight: Int,
)

/**
 * A side by side photo on the stereo quad: decoded with a power of two sample size so that each eye still covers the
 * size it shows at (2560 wide at most, as an eye of a spatial photo), cut in its two eyes, and drawn on the texture of
 * [StereoComposer] (each eye in its gutter, the left one on the left). The frame is read as stored: the EXIF
 * orientation is not applied, the eyes lie in the pixels as the file holds them (as the probe of the Dart side reads
 * them). Pure but [decode] and [compose].
 */
internal object SbsPhoto {
  /** The width an eye of [frameWidth] x [frameHeight] shows at, before the limits of the quad. */
  private fun shownWidth(frameWidth: Int, spec: SbsPhotoSpec): Int {
    val stored = frameWidth / 2
    return if (spec.eyes == SbsPhotoSpec.Eyes.HALF) 2 * stored else stored
  }

  /**
   * The eyes of a frame of [frameWidth] x [frameHeight] as decoded, null when it is too small to hold two. An odd
   * width leaves the middle column out: each eye starts at its outer edge.
   */
  fun split(frameWidth: Int, frameHeight: Int, spec: SbsPhotoSpec): SbsSplit? {
    val stored = frameWidth / 2
    if (stored < 1 || frameHeight < 1) return null
    val leftHalf = 0
    val rightHalf = frameWidth - stored
    val (leftStart, rightStart) =
      when (spec.layout) {
        SbsPhotoSpec.Layout.LEFT_RIGHT -> leftHalf to rightHalf
        SbsPhotoSpec.Layout.RIGHT_LEFT -> rightHalf to leftHalf
      }
    val (eyeWidth, eyeHeight) =
      StereoComposer.fitWithin(
        shownWidth(frameWidth, spec),
        frameHeight,
        StereoHeicDecoder.MAX_EYE_WIDTH,
        StereoHeicDecoder.MAX_EYE_HEIGHT,
      )
    return SbsSplit(leftStart, rightStart, stored, frameHeight, eyeWidth, eyeHeight)
  }

  /**
   * The largest power of two the decoder may sample a frame of [frameWidth] x [frameHeight] down by, so that each eye
   * is still at least as large as it shows: the quad then only scales down.
   */
  fun sampleSize(frameWidth: Int, frameHeight: Int, spec: SbsPhotoSpec): Int {
    val target = split(frameWidth, frameHeight, spec) ?: return 1
    val shown = shownWidth(frameWidth, spec)
    var sample = 1
    while (shown / (2 * sample) >= target.eyeWidth && frameHeight / (2 * sample) >= target.eyeHeight) sample *= 2
    return sample
  }

  /**
   * The texture of the side by side photo of [bytes] for the quad, and the size of its eyes; null when it cannot be
   * decoded or holds no two eyes. Off the main thread. Logs the sizes and the sample size, for the headset checks.
   */
  fun decode(bytes: ByteArray, spec: SbsPhotoSpec): Pair<Bitmap, SbsSplit>? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
      Log.w(TAG, "side by side photo: unreadable image ${bounds.outMimeType}, ${bytes.size} bytes")
      return null
    }
    val sample = sampleSize(bounds.outWidth, bounds.outHeight, spec)
    val options =
      BitmapFactory.Options().apply {
        inSampleSize = sample
        inPreferredConfig = Bitmap.Config.ARGB_8888
        inScaled = false
      }
    val frame = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
    try {
      // From the frame as decoded: the decoder rounds its sizes its own way
      val split = split(frame.width, frame.height, spec) ?: return null
      Log.i(
        TAG,
        "side by side photo: ${bounds.outMimeType} ${bounds.outWidth}x${bounds.outHeight}, inSampleSize $sample, " +
          "decoded ${frame.width}x${frame.height}, ${spec.eyes} eyes ${spec.layout}, left from ${split.leftStart}, " +
          "right from ${split.rightStart}, each ${split.storedWidth} wide, shown ${split.eyeWidth}x${split.eyeHeight}",
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
  fun compose(frame: Bitmap, split: SbsSplit): Bitmap {
    val (width, height) = StereoComposer.textureSize(split.eyeWidth, split.eyeHeight)
    val texture = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    texture.eraseColor(Color.BLACK)
    val canvas = Canvas(texture)
    val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    val gutter = StereoComposer.GUTTER
    val cell = split.eyeWidth + 2 * gutter
    for ((start, left) in listOf(split.leftStart to gutter, split.rightStart to cell + gutter)) {
      canvas.drawBitmap(
        frame,
        Rect(start, 0, start + split.storedWidth, split.height),
        Rect(left, gutter, left + split.eyeWidth, gutter + split.eyeHeight),
        paint,
      )
    }
    return texture
  }
}
