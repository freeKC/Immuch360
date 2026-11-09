package app.alextran.immich.images

import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** A size in pixels */
data class DecodeSize(val width: Int, val height: Int)

/**
 * The sizes the native decoders ask of ImageDecoder for an image of [width] x [height] pixels (the size its header
 * tells): never larger than the image, at most [MAX_PIXEL_SIZE] on the long side, the aspect ratio kept. [factor]
 * shrinks the result on each side, 0.5 for the one retry after an OutOfMemoryError (a quarter of the memory).
 */
object NativeDecodeSize {
  /**
   * The largest size that fits in [maxWidth] x [maxHeight] (0 or less for no bound on that side): the rule of
   * NativeImageDecodeApi, a 2:1 panorama kept whole in the box of a 360° view
   */
  fun fit(width: Int, height: Int, maxWidth: Int, maxHeight: Int, factor: Double = 1.0): DecodeSize {
    if (width <= 0 || height <= 0) return DecodeSize(width, height)
    var scale = 1.0
    if (maxWidth > 0) scale = min(scale, maxWidth.toDouble() / width)
    if (maxHeight > 0) scale = min(scale, maxHeight.toDouble() / height)
    val fitted = DecodeSize(
      bounded((width * scale).roundToInt(), maxWidth),
      bounded((height * scale).roundToInt(), maxHeight),
    )
    return shrunk(longSideBounded(width, height, fitted), factor)
  }

  /**
   * The smallest size that covers [targetWidth] x [targetHeight] (0 for the full size): the rule of decodeBitmap with
   * exactSize, which RemoteImagesImpl decodes the thumbnails and previews of the server with
   */
  fun cover(width: Int, height: Int, targetWidth: Int, targetHeight: Int, factor: Double = 1.0): DecodeSize {
    if (width <= 0 || height <= 0) return DecodeSize(width, height)
    var size = DecodeSize(width, height)
    if (targetWidth > 0 && targetHeight > 0) {
      val scale = min(1.0, max(targetWidth.toDouble() / width, targetHeight.toDouble() / height))
      if (scale < 1) {
        size = DecodeSize(ceil(width * scale).toInt(), ceil(height * scale).toInt())
      }
    }
    return shrunk(longSideBounded(width, height, size), factor)
  }

  private fun bounded(value: Int, bound: Int): Int = max(1, if (bound > 0) min(value, bound) else value)

  // At most MAX_PIXEL_SIZE on the long side, from the full size, as decodeBitmap bounds it
  private fun longSideBounded(width: Int, height: Int, size: DecodeSize): DecodeSize {
    if (max(size.width, size.height) <= MAX_PIXEL_SIZE) return size
    val bound = MAX_PIXEL_SIZE.toDouble() / max(width, height)
    return DecodeSize(max(1, (width * bound).roundToInt()), max(1, (height * bound).roundToInt()))
  }

  private fun shrunk(size: DecodeSize, factor: Double): DecodeSize =
    if (factor >= 1.0) size
    else DecodeSize(max(1, (size.width * factor).roundToInt()), max(1, (size.height * factor).roundToInt()))
}
