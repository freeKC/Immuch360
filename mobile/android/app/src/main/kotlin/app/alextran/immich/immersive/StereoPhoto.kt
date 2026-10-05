package app.alextran.immich.immersive

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.graphics.Rect
import android.media.MediaDataSource
import android.media.MediaMetadataRetriever
import android.os.Build
import android.util.Log
import com.meta.spatial.core.Quaternion
import com.meta.spatial.core.Vector3
import java.nio.ByteBuffer
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.tan
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.floatOrNull
import kotlinx.serialization.json.intOrNull

/**
 * The two eyes of an Apple spatial photo, as Flutter read them from its HEIF meta box (the stereoPair JSON, docs
 * 18-design-build19-sources-and-spatial.md section 5.6): the items of the left and right eyes, and where the item id of
 * pitm lies, which [StereoHeicDecoder] rewrites to have the platform decode the right eye.
 */
internal data class StereoPairSpec(
  val primaryItemId: Int,
  val leftItemId: Int,
  val rightItemId: Int,
  /** Absolute file offset of the item_ID field of pitm. */
  val pitmIdOffset: Int,
  /** 2 (pitm version 0) or 4. */
  val pitmIdBytes: Int,
  /** Size of the left eye (its ispe). */
  val width: Int,
  val height: Int,
  /** irot of the left eye, quarter turns anticlockwise; the decoder applies it. */
  val rotation: Int,
  /** In [-10000, 10000] of the eye width, half to each eye; 0 when the file does not tell. */
  val disparityAdjustment: Int,
  /** Horizontal field of view of the camera, null when unknown. */
  val horizontalFovDeg: Float?,
) {
  companion object {
    const val KIND = "heicStereoPair"
    const val VERSION = 1

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * The pair of [text], null for a missing or damaged JSON, another kind or version (a newer Flutter side), or values
     * that cannot be right: the viewer then shows the photo flat. kotlinx.serialization rather than org.json, which is
     * a stub in the JVM tests. Pure: the viewer logs a pair it could not read.
     */
    fun parse(text: String?): StereoPairSpec? {
      if (text.isNullOrBlank()) return null
      return try {
        val root = json.parseToJsonElement(text) as? JsonObject ?: return null
        fun primitive(key: String): JsonPrimitive? = (root[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }
        fun integer(key: String): Int? = primitive(key)?.takeIf { !it.isString }?.intOrNull
        if (primitive("kind")?.takeIf { it.isString }?.content != KIND || integer("version") != VERSION) return null
        val spec =
          StereoPairSpec(
            primaryItemId = integer("primaryItemId") ?: return null,
            leftItemId = integer("leftItemId") ?: return null,
            rightItemId = integer("rightItemId") ?: return null,
            pitmIdOffset = integer("pitmIdOffset") ?: return null,
            pitmIdBytes = integer("pitmIdBytes") ?: return null,
            width = integer("width") ?: return null,
            height = integer("height") ?: return null,
            rotation = (integer("rotation") ?: 0) and 3,
            disparityAdjustment = (integer("disparityAdjustment") ?: 0).coerceIn(-10000, 10000),
            horizontalFovDeg = primitive("horizontalFovDeg")?.takeIf { !it.isString }?.floatOrNull,
          )
        spec.takeIf {
          it.pitmIdBytes in setOf(2, 4) &&
            it.pitmIdOffset >= 0 &&
            it.width > 0 &&
            it.height > 0 &&
            it.leftItemId > 0 &&
            it.rightItemId > 0 &&
            it.leftItemId != it.rightItemId
        }
      } catch (e: Exception) {
        // Not JSON at all: shown flat, as an unknown kind (the viewer logs it)
        null
      }
    }
  }
}

/**
 * Decodes each eye of an Apple spatial photo. The platform decoders show the primary item of a HEIF file only: a copy
 * of the file whose pitm names the other eye decodes that eye, as libheif does with the sample of the design. When the
 * platform ignores the change (the same image comes back), [decodeRightByIndex] asks MediaMetadataRetriever for the
 * other images of the file.
 */
internal object StereoHeicDecoder {
  /** Widest eye decoded: two of them side by side stay within the 8192 pixels of the texture limit. */
  const val MAX_EYE_WIDTH = 2560

  /** Tallest eye decoded, the gutters of [StereoComposer] included within the 4096 pixels of the texture limit. */
  const val MAX_EYE_HEIGHT = ImmersiveMedia.MAX_TEXTURE_HEIGHT - 2 * StereoComposer.GUTTER

  /** Below this mean grey difference, 0..255, two decoded eyes are the same image. */
  const val SAME_IMAGE_DIFFERENCE = 0.05f

  /**
   * A copy of [file] whose primary item is [itemId]; [file] itself when it already is. Throws when the bytes at
   * pitmIdOffset do not hold primaryItemId (another file than the one Flutter read), or when [itemId] does not fit in
   * the field.
   */
  fun withPrimary(file: ByteArray, spec: StereoPairSpec, itemId: Int): ByteArray {
    val offset = spec.pitmIdOffset
    val length = spec.pitmIdBytes
    require(length == 2 || length == 4) { "pitm item id of $length bytes" }
    require(offset >= 0 && offset + length <= file.size) { "pitm item id at $offset, past the ${file.size} bytes" }
    var found = 0L
    for (i in 0 until length) found = (found shl 8) or (file[offset + i].toLong() and 0xFF)
    require(found == spec.primaryItemId.toLong()) {
      "pitm holds item $found at $offset, not the primary item ${spec.primaryItemId}"
    }
    if (itemId == spec.primaryItemId) return file
    require(itemId > 0 && (length == 4 || itemId <= 0xFFFF)) { "item $itemId does not fit in $length bytes" }
    val copy = file.copyOf()
    for (i in 0 until length) copy[offset + i] = (itemId ushr (8 * (length - 1 - i))).toByte()
    return copy
  }

  /**
   * The eye [itemId] of [file] as a software bitmap, at most [maxWidth] wide and MAX_EYE_HEIGHT tall, its aspect kept.
   * ImageDecoder (API 28, every Horizon OS) applies irot like for any HEIF.
   */
  fun decodeEye(file: ByteArray, spec: StereoPairSpec, itemId: Int, maxWidth: Int = MAX_EYE_WIDTH): Bitmap {
    check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) { "HEIF decoding needs Android 9" }
    val source = ImageDecoder.createSource(ByteBuffer.wrap(withPrimary(file, spec, itemId)))
    return ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
      decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
      val (width, height) = StereoComposer.fitWithin(info.size.width, info.size.height, maxWidth, MAX_EYE_HEIGHT)
      if (width != info.size.width || height != info.size.height) decoder.setTargetSize(width, height)
    }
  }

  /**
   * The right eye through MediaMetadataRetriever.getImageAtIndex, for a platform that decoded the left eye again
   * from the patched copy: the first image of the file that has the aspect of [left] and differs from it, scaled to
   * its size (which [decodeEye] kept within MAX_EYE_WIDTH). Null when there is none.
   */
  fun decodeRightByIndex(file: ByteArray, left: Bitmap): Bitmap? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
    val retriever = MediaMetadataRetriever()
    try {
      retriever.setDataSource(ByteArrayDataSource(file))
      val count =
        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_IMAGE_COUNT)?.toIntOrNull() ?: return null
      Log.i(TAG, "spatial photo: $count images by index")
      val params = MediaMetadataRetriever.BitmapParams().apply { preferredConfig = Bitmap.Config.ARGB_8888 }
      for (index in 0 until count) {
        val image = runCatching { retriever.getImageAtIndex(index, params) }.getOrNull() ?: continue
        val sameAspect =
          abs(image.width.toFloat() / image.height - left.width.toFloat() / left.height) < 0.01f
        if (!sameAspect) {
          Log.i(TAG, "spatial photo: image $index is ${image.width}x${image.height}, not an eye")
          image.recycle()
          continue
        }
        // The left eye was decoded within MAX_EYE_WIDTH: the same size, for the comparison and the texture
        val scaled =
          if (image.width != left.width || image.height != left.height) {
            Bitmap.createScaledBitmap(image, left.width, left.height, true).also { if (it !== image) image.recycle() }
          } else {
            image
          }
        val difference = meanDifference(left, scaled)
        Log.i(TAG, "spatial photo: image index $index differs from the left eye by $difference")
        if (difference >= SAME_IMAGE_DIFFERENCE) return scaled
        scaled.recycle()
      }
      return null
    } catch (e: Exception) {
      Log.w(TAG, "spatial photo: images by index failed: ${e.message}")
      return null
    } finally {
      runCatching { retriever.release() }
    }
  }

  /** Mean absolute grey difference of 128x96 thumbnails of [a] and [b], 0..255. */
  fun meanDifference(a: Bitmap, b: Bitmap): Float {
    val small = { bitmap: Bitmap ->
      val thumbnail = Bitmap.createScaledBitmap(bitmap, THUMBNAIL_WIDTH, THUMBNAIL_HEIGHT, true)
      val pixels = IntArray(THUMBNAIL_WIDTH * THUMBNAIL_HEIGHT)
      thumbnail.getPixels(pixels, 0, THUMBNAIL_WIDTH, 0, 0, THUMBNAIL_WIDTH, THUMBNAIL_HEIGHT)
      if (thumbnail !== bitmap) thumbnail.recycle()
      pixels
    }
    return StereoComposer.meanGreyDifference(small(a), small(b))
  }

  private const val THUMBNAIL_WIDTH = 128
  private const val THUMBNAIL_HEIGHT = 96

  /** The bytes of a file in memory for MediaMetadataRetriever. */
  private class ByteArrayDataSource(private val bytes: ByteArray) : MediaDataSource() {
    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
      if (position >= bytes.size) return -1
      val length = min(size.toLong(), bytes.size - position).toInt()
      System.arraycopy(bytes, position.toInt(), buffer, offset, length)
      return length
    }

    override fun getSize(): Long = bytes.size.toLong()

    override fun close() = Unit
  }
}

/**
 * The 3D or 2D choice and the angular width of a spatial photo on the quad, with the photo they belong to: its url and
 * the opening of the viewer it was shown in. Kept over a recreation of the viewer, so that the photo comes back as the
 * user left it rather than with the defaults of a new photo.
 */
internal data class StereoPhotoChoices(val url: String, val openingId: Long, val threeD: Boolean, val angleDeg: Float) {
  /**
   * These choices for the photo of [url] shown in the opening [openingId], null for any other photo or opening, which
   * starts from the defaults. The angle stays within the bounds of the thumbstick.
   */
  fun forPhoto(url: String, openingId: Long): StereoPhotoChoices? =
    if (url != this.url || openingId != this.openingId || angleDeg.isNaN()) null
    else copy(angleDeg = angleDeg.coerceIn(StereoComposer.MIN_ANGLE_DEG, StereoComposer.MAX_ANGLE_DEG))
}

/**
 * How the two eyes of a spatial photo go on the stereo quad of the viewer (section 5.8 of the design): the columns
 * each eye keeps for the disparity adjustment, the texture that holds both side by side, and the size of the quad.
 * Pure functions, but [compose].
 */
internal object StereoComposer {
  /** Black pixels around each eye, so that the mipmaps never bleed one eye into the other at the middle line. */
  const val GUTTER = 4

  /** The disparity adjustment applied at most, of 10000 of the eye width: past it the eyes would be hard to fuse. */
  const val MAX_DISPARITY = 2000

  /** Distance of the quad from the eyes, in meters. */
  const val DISTANCE_M = 2.0f

  /** Angular width of the quad without a field of view in the file, and the bounds of the one it gives. */
  const val DEFAULT_ANGLE_DEG = 48f
  const val MIN_FILE_ANGLE_DEG = 35f
  const val MAX_FILE_ANGLE_DEG = 60f

  /** What the thumbstick changes the angular width by, within its bounds. */
  const val ANGLE_STEP_DEG = 6f
  const val MIN_ANGLE_DEG = 30f
  const val MAX_ANGLE_DEG = 90f

  /** The columns of each eye kept on the texture: from [leftStart] and [rightStart], [width] wide. */
  data class Crop(val leftStart: Int, val rightStart: Int, val width: Int)

  /**
   * The columns of each eye of [eyeWidth] pixels for the disparity adjustment [disparity] (of 10000 of the width,
   * clamped to MAX_DISPARITY): s = |d| / 10000 * W / 2 pixels, the output eye W - 2s wide. Positive pushes the scene
   * back: the left eye keeps its right part, the right eye its left part, so that the left content moves left. Negative
   * brings it forward, the other way. Half of the adjustment to each eye, in opposite directions, as Apple describes
   * dadj; the sign is checked on the headset.
   */
  fun crop(eyeWidth: Int, disparity: Int): Crop {
    val d = disparity.coerceIn(-MAX_DISPARITY, MAX_DISPARITY)
    val shift = (abs(d) / 10000.0 * eyeWidth / 2).roundToInt().coerceAtMost((eyeWidth - 1) / 2)
    val width = eyeWidth - 2 * shift
    return when {
      d > 0 -> Crop(leftStart = 2 * shift, rightStart = 0, width = width)
      d < 0 -> Crop(leftStart = 0, rightStart = 2 * shift, width = width)
      else -> Crop(leftStart = 0, rightStart = 0, width = width)
    }
  }

  /** Width and height of the texture of two eyes of [eyeWidth] x [eyeHeight], each in its own gutter. */
  fun textureSize(eyeWidth: Int, eyeHeight: Int): Pair<Int, Int> =
    2 * (eyeWidth + 2 * GUTTER) to eyeHeight + 2 * GUTTER

  /** The angular width the quad starts at: 0.8 of the field of view of the camera within 35 to 60 degrees, else 48. */
  fun initialAngle(horizontalFovDeg: Float?): Float =
    if (horizontalFovDeg == null || horizontalFovDeg <= 0f) DEFAULT_ANGLE_DEG
    else (0.8f * horizontalFovDeg).coerceIn(MIN_FILE_ANGLE_DEG, MAX_FILE_ANGLE_DEG)

  /** The angular width after a push of the thumbstick, up ([step] 1) or down (-1). */
  fun nextAngle(angleDeg: Float, step: Int): Float =
    (angleDeg + step * ANGLE_STEP_DEG).coerceIn(MIN_ANGLE_DEG, MAX_ANGLE_DEG)

  /**
   * Width and height in meters of the quad that shows an eye of [eyeWidth] x [eyeHeight] (gutters included, as the
   * texture holds them) [angleDeg] wide at [distance].
   */
  fun quadSize(angleDeg: Float, eyeWidth: Int, eyeHeight: Int, distance: Float = DISTANCE_M): Pair<Float, Float> {
    val width = 2f * distance * tan(Math.toRadians(angleDeg / 2.0)).toFloat()
    return width to width * (eyeHeight + 2 * GUTTER) / (eyeWidth + 2 * GUTTER)
  }

  /**
   * The rotation of the quad in front of a user who looks along [gaze] (horizontal, normalized): lookRotation(gaze),
   * as for the panels. The Spatial SDK is left handed (Vector3.Right +x, Up +y, Forward +z) and lookRotation sends the
   * local +z along the gaze and the local +x to the right of the user (Up x gaze). SceneMesh.singleSidedQuad grows u
   * along its +x, so the user sees the eyes the right way round, from the side opposite to its +z normal.
   * lookRotation(-gaze) would show its +z side instead: each eye mirrored, which inverts the depth.
   */
  fun quadRotation(gaze: Vector3): Quaternion = Quaternion.lookRotation(gaze)

  /** [width] x [height] scaled down to fit within [maxWidth] x [maxHeight], its aspect kept; as it is when it fits. */
  fun fitWithin(width: Int, height: Int, maxWidth: Int, maxHeight: Int): Pair<Int, Int> {
    if (width <= maxWidth && height <= maxHeight) return width to height
    val scale = min(maxWidth.toDouble() / width, maxHeight.toDouble() / height)
    return (width * scale).roundToInt().coerceIn(1, maxWidth) to (height * scale).roundToInt().coerceIn(1, maxHeight)
  }

  /** Mean absolute difference of the grey levels of two lists of ARGB pixels of the same size, 0..255. */
  fun meanGreyDifference(a: IntArray, b: IntArray): Float {
    require(a.size == b.size && a.isNotEmpty()) { "${a.size} and ${b.size} pixels" }
    var total = 0.0
    for (i in a.indices) total += abs(grey(a[i]) - grey(b[i]))
    return (total / a.size).toFloat()
  }

  private fun grey(pixel: Int): Double =
    0.299 * ((pixel shr 16) and 0xFF) + 0.587 * ((pixel shr 8) and 0xFF) + 0.114 * (pixel and 0xFF)

  /**
   * One texture with [left] in the left half and [right] in the right half, each cropped for the disparity of [crop]
   * and set in its gutter of black. [right] must have the size of [left]. Neither is recycled.
   */
  fun compose(left: Bitmap, right: Bitmap, crop: Crop): Bitmap {
    val height = left.height
    val (width, textureHeight) = textureSize(crop.width, height)
    val texture = Bitmap.createBitmap(width, textureHeight, Bitmap.Config.ARGB_8888)
    texture.eraseColor(Color.BLACK)
    val canvas = Canvas(texture)
    val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    val cell = crop.width + 2 * GUTTER
    canvas.drawBitmap(
      left,
      Rect(crop.leftStart, 0, crop.leftStart + crop.width, height),
      Rect(GUTTER, GUTTER, GUTTER + crop.width, GUTTER + height),
      paint,
    )
    canvas.drawBitmap(
      right,
      Rect(crop.rightStart, 0, crop.rightStart + crop.width, height),
      Rect(cell + GUTTER, GUTTER, cell + GUTTER + crop.width, GUTTER + height),
      paint,
    )
    return texture
  }

  /** English labels of the stereo photo mode, for a key Flutter did not send. */
  private val defaultLabels =
    mapOf(
      LABEL_3D to "3D",
      LABEL_2D to "2D (left eye)",
      LABEL_NO_NAVIGATION to "Previous and next are not available for spatial photos yet",
      LABEL_SECOND_EYE_FAILED to "The second eye could not be decoded: shown in 2D",
    )

  const val LABEL_3D = "spatial3d"
  const val LABEL_2D = "spatial2d"
  const val LABEL_NO_NAVIGATION = "spatialNoNavigation"
  const val LABEL_SECOND_EYE_FAILED = "spatialSecondEyeFailed"

  /** Label of [key] from the translated [labels], the English one when it is missing or blank. */
  fun label(labels: Map<String, String>, key: String): String =
    labels[key]?.takeIf { it.isNotBlank() } ?: defaultLabels[key] ?: key
}
