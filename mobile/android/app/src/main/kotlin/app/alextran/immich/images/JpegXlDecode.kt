package app.alextran.immich.images

import android.graphics.Bitmap
import android.util.Log
import app.alextran.immich.NativeBuffer
import app.alextran.immich.NativeImage
import app.alextran.immich.checkAllocated
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Pixels the core decoded: RGBA_8888, premultiplied, in sRGB, in a malloc buffer of [rowBytes] x [height] bytes */
data class CorePixels(val pointer: Long, val width: Int, val height: Int, val rowBytes: Int) {
  /** As the decoded images of the pigeon APIs: {pointer, width, height, rowBytes} */
  fun toMap(): Map<String, Long> =
    mapOf(
      "pointer" to pointer,
      "width" to width.toLong(),
      "height" to height.toLong(),
      "rowBytes" to rowBytes.toLong(),
    )
}

/**
 * JPEG XL, which neither Android nor Flutter's engine decodes, through the Rust core of upstream
 * (native_core_ffi, NativeImage.decode): the thumbnails and previews of an Immich 3.4.0 server whose admin picked JPEG
 * XL, and the JPEG XL originals. Used by RemoteImagesImpl (the photos of the server), NativeImageDecodeImpl (the
 * guarded images: shares, files opened from another app) and the viewers of the Quest (ImmersiveMedia), on every
 * Android version and ABI the core is built for (armeabi-v7a included). The rules of the other native decodes apply:
 * never more than [MAX_PIXEL_SIZE] on the long side, and one retry at half the size when the core gives nothing (its
 * buffers come from calloc, so a lack of memory is a null answer, never an abort).
 */
object JpegXlDecode {
  private const val TAG = "JpegXlDecode"

  private val CONTAINER = intArrayOf(0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A)

  /** Whether [head] (its first [length] bytes) starts as JPEG XL: a bare codestream (FF 0A) or the container */
  fun isJpegXl(head: ByteArray, length: Int = head.size): Boolean {
    val n = minOf(length, head.size)
    fun at(vararg bytes: Int): Boolean = bytes.size <= n && bytes.indices.all { head[it].toInt() and 0xFF == bytes[it] }
    return at(0xFF, 0x0A) || at(*CONTAINER)
  }

  /** Whether the [length] bytes at [pointer] start as JPEG XL */
  fun isJpegXl(pointer: Long, length: Int): Boolean {
    if (pointer == 0L || length < 2) return false
    val head = ByteArray(minOf(length, CONTAINER.size))
    NativeBuffer.wrap(pointer, length).get(head)
    return isJpegXl(head)
  }

  /**
   * The long side the core is given for a decode that must fit in [maxWidth] x [maxHeight] (0 or less for no bound
   * on that side): the larger bound, never above [MAX_PIXEL_SIZE], times [factor] (0.5 for the retry). The side the
   * image is not long on may still pass its bound: [fitsWithin] tells, and the callers scale down then.
   */
  fun longSide(maxWidth: Int, maxHeight: Int, factor: Double = 1.0): Int {
    val bound = max(maxWidth, maxHeight)
    val side = if (bound <= 0) MAX_PIXEL_SIZE else min(bound, MAX_PIXEL_SIZE)
    return max(1, (side * factor).roundToInt())
  }

  /** Whether [width] x [height] fits in [maxWidth] x [maxHeight] (0 or less for no bound on that side) */
  fun fitsWithin(width: Int, height: Int, maxWidth: Int, maxHeight: Int): Boolean =
    (maxWidth <= 0 || width <= maxWidth) && (maxHeight <= 0 || height <= maxHeight)

  /**
   * The JPEG XL of [length] bytes at [pointer] decoded by the core to cover [targetWidth] x [targetHeight] (0 for the
   * full size) within [maxPixelSize] on the long side; once more at half the size when the core gives nothing and
   * [cancelled] was not set. Null when it did not decode, or once cancelled ([NativeImage.cancel] on [cancelled]).
   */
  fun decode(
    pointer: Long,
    length: Int,
    targetWidth: Int,
    targetHeight: Int,
    maxPixelSize: Int,
    cancelled: ByteBuffer = ByteBuffer.allocateDirect(1),
  ): CorePixels? {
    if (pointer == 0L || length <= 0) return null
    decodeOnce(pointer, length, targetWidth, targetHeight, maxPixelSize, cancelled)?.let { return it }
    if (cancelled.get(0).toInt() != 0) return null
    Log.w(TAG, "JPEG XL of $length bytes: no image from the core at ${targetWidth}x$targetHeight, again at half")
    return decodeOnce(pointer, length, targetWidth / 2, targetHeight / 2, max(1, maxPixelSize / 2), cancelled)
  }

  private fun decodeOnce(
    pointer: Long,
    length: Int,
    targetWidth: Int,
    targetHeight: Int,
    maxPixelSize: Int,
    cancelled: ByteBuffer,
  ): CorePixels? {
    val info = IntArray(3)
    val pixels = try {
      NativeImage.decode(pointer, length, targetWidth, targetHeight, maxPixelSize, cancelled, info)
    } catch (error: Throwable) {
      // A JNI failure of the glue (ThrowRuntimeExAndDefault) or no memory for its arrays: no image
      Log.w(TAG, "JPEG XL of $length bytes: ${error.javaClass.name}: ${error.message}")
      0L
    }
    if (pixels == 0L) return null
    return CorePixels(pixels, info[0], info[1], info[2])
  }

  /**
   * The JPEG XL of [length] bytes at [pointer] decoded to fit in [maxWidth] x [maxHeight] (0 or less for no bound on
   * that side), never larger than the image: the rule of NativeImageDecodeApi. The core bounds the long side
   * ([longSide]); a picture still too large on its other side is scaled down here.
   */
  fun decodeWithin(pointer: Long, length: Int, maxWidth: Int, maxHeight: Int): CorePixels? {
    val pixels = decode(pointer, length, 0, 0, longSide(maxWidth, maxHeight)) ?: return null
    if (fitsWithin(pixels.width, pixels.height, maxWidth, maxHeight)) return pixels
    val bitmap = try {
      toBitmap(pixels)
    } finally {
      NativeBuffer.free(pixels.pointer)
    }
    // toNativeBuffer recycles the bitmap
    val map = scaledWithin(bitmap, maxWidth, maxHeight).toNativeBuffer()
    return CorePixels(map["pointer"]!!, map["width"]!!.toInt(), map["height"]!!.toInt(), map["rowBytes"]!!.toInt())
  }

  /**
   * [bytes], a JPEG XL, as an ARGB_8888 bitmap that fits in [maxWidth] x [maxHeight] (the viewers of the Quest), or
   * null when the core did not decode it
   */
  fun decodeBitmap(bytes: ByteArray, maxWidth: Int, maxHeight: Int): Bitmap? {
    val input = checkAllocated(NativeBuffer.allocate(max(1, bytes.size)), bytes.size.toLong())
    val pixels = try {
      NativeBuffer.wrap(input, bytes.size).put(bytes)
      decode(input, bytes.size, 0, 0, longSide(maxWidth, maxHeight))
    } finally {
      NativeBuffer.free(input)
    }
    if (pixels == null) {
      Log.w(TAG, "JPEG XL not decoded by the core, ${bytes.size} bytes")
      return null
    }
    val bitmap = try {
      toBitmap(pixels)
    } finally {
      NativeBuffer.free(pixels.pointer)
    }
    Log.d(TAG, "JPEG XL of ${bytes.size} bytes decoded by the core at ${bitmap.width}x${bitmap.height}")
    return scaledWithin(bitmap, maxWidth, maxHeight)
  }

  // The pixels of the core in a bitmap: both are premultiplied RGBA_8888, rows of rowBytes
  private fun toBitmap(pixels: CorePixels): Bitmap {
    val bitmap = Bitmap.createBitmap(pixels.width, pixels.height, Bitmap.Config.ARGB_8888)
    bitmap.copyPixelsFromBuffer(NativeBuffer.wrap(pixels.pointer, pixels.rowBytes * pixels.height))
    return bitmap
  }

  // [bitmap] as it is when it fits in [maxWidth] x [maxHeight], else scaled down to fit (the input recycled)
  private fun scaledWithin(bitmap: Bitmap, maxWidth: Int, maxHeight: Int): Bitmap {
    if (fitsWithin(bitmap.width, bitmap.height, maxWidth, maxHeight)) return bitmap
    val size = NativeDecodeSize.fit(bitmap.width, bitmap.height, maxWidth, maxHeight)
    val scaled = Bitmap.createScaledBitmap(bitmap, size.width, size.height, true)
    if (scaled !== bitmap) bitmap.recycle()
    return scaled
  }
}
