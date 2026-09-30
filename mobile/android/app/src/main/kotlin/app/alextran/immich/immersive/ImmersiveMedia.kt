package app.alextran.immich.immersive

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.util.Log
import java.io.File
import kotlin.math.min
import kotlin.math.roundToInt

/** Every log line of the immersive viewer uses this tag: `adb logcat -s Immuch360`. */
internal const val TAG = "Immuch360"

/** Where Horizon OS ships the Spatial SDK runtime (libossdk) or declares it as a public native library. */
private val ossdkPaths =
  listOf(
    "/system/lib64/libossdk.oculus.so",
    "/system_ext/lib64/libossdk.oculus.so",
    "/product/lib64/libossdk.oculus.so",
    "/vendor/lib64/libossdk.oculus.so",
    "/system/etc/public.libraries-oculus.txt",
  )

private val horizonOs: Boolean by lazy {
  val manufacturer = Build.MANUFACTURER.orEmpty()
  val byBuild =
    manufacturer.equals("Oculus", ignoreCase = true) ||
      manufacturer.equals("Meta", ignoreCase = true) ||
      Build.MODEL.orEmpty().startsWith("Quest", ignoreCase = true)
  val ossdk = ossdkPaths.firstOrNull { path -> runCatching { File(path).exists() }.getOrDefault(false) }
  Log.i(TAG, "Horizon OS: ${byBuild || ossdk != null} (manufacturer=$manufacturer, model=${Build.MODEL}, ossdk=$ossdk)")
  byBuild || ossdk != null
}

/** True on a Meta Quest: Oculus or Meta build, Quest model, or the Spatial SDK runtime present. */
internal fun isHorizonOsDevice(): Boolean = horizonOs

/** Helpers of the immersive viewer that do not touch the Spatial SDK. */
internal object ImmersiveMedia {
  /** Texture limit of the Quest GPU (Adreno), per side. */
  const val MAX_TEXTURE_WIDTH = 8192
  const val MAX_TEXTURE_HEIGHT = 4096

  /**
   * Largest H.264 frame the Quest 3 hardware decoder (XR2 Gen 2) plays at full speed, long side and
   * short side. A 5760x2880 H.264 video (level 6.0) decodes at about 17 fps with block artifacts, while
   * HEVC at the same size plays fine.
   */
  const val MAX_AVC_LONG_SIDE = 4096
  const val MAX_AVC_SHORT_SIDE = 2304

  private const val MIME_AVC = "video/avc"

  private val originalPath = Regex("/assets/([^/?#]+)/original(?=$|[?#])")

  /** ".../assets/{id}/original?edited=true" gives ".../assets/{id}/thumbnail?size=preview&edited=true". */
  fun previewUrlFor(originalUrl: String): String? {
    val match = originalPath.find(originalUrl) ?: return null
    val base = originalUrl.substring(0, match.range.first) + "/assets/${match.groupValues[1]}/thumbnail"
    val query = originalUrl.substring(match.range.last + 1).removePrefix("?")
    return base + "?size=preview" + if (query.isNotEmpty()) "&$query" else ""
  }

  /** ".../assets/{id}/original?..." gives ".../assets/{id}/video/playback". */
  fun playbackUrlFor(originalUrl: String): String? {
    val match = originalPath.find(originalUrl) ?: return null
    return originalUrl.substring(0, match.range.first) + "/assets/${match.groupValues[1]}/video/playback"
  }

  /**
   * True for an H.264 video larger than 4096x2304 in either orientation: its long side above 4096 or
   * its short side above 2304. An unknown side (-1) never counts as too large.
   */
  fun exceedsAvcDecoder(mimeType: String?, width: Int, height: Int): Boolean =
    mimeType.equals(MIME_AVC, ignoreCase = true) &&
      (maxOf(width, height) > MAX_AVC_LONG_SIDE || minOf(width, height) > MAX_AVC_SHORT_SIDE)

  /** Smallest power of two sample size so that the decoded image fits in maxWidth x maxHeight. */
  fun sampleSizeFor(width: Int, height: Int, maxWidth: Int, maxHeight: Int): Int {
    if (width <= 0 || height <= 0) return 1
    var sample = 1
    while ((width + sample - 1) / sample > maxWidth || (height + sample - 1) / sample > maxHeight) {
      sample *= 2
    }
    return sample
  }

  fun decodeFile(file: File): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.absolutePath, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
      Log.w(TAG, "unreadable image ${bounds.outMimeType}, ${file.length()} bytes")
      return null
    }
    return BitmapFactory.decodeFile(file.absolutePath, optionsFor(bounds))?.let(::fitWithin)
  }

  fun decodeBytes(bytes: ByteArray): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
      Log.w(TAG, "unreadable image ${bounds.outMimeType}, ${bytes.size} bytes")
      return null
    }
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, optionsFor(bounds))?.let(::fitWithin)
  }

  private fun optionsFor(bounds: BitmapFactory.Options): BitmapFactory.Options {
    val sample = sampleSizeFor(bounds.outWidth, bounds.outHeight, MAX_TEXTURE_WIDTH, MAX_TEXTURE_HEIGHT)
    Log.d(TAG, "decode ${bounds.outMimeType} ${bounds.outWidth}x${bounds.outHeight} inSampleSize=$sample")
    return BitmapFactory.Options().apply {
      inSampleSize = sample
      inPreferredConfig = Bitmap.Config.ARGB_8888
      inScaled = false
    }
  }

  /** Safety net when the decoder rounds up: scales down so both sides fit. Recycles the input. */
  private fun fitWithin(bitmap: Bitmap): Bitmap {
    if (bitmap.width <= MAX_TEXTURE_WIDTH && bitmap.height <= MAX_TEXTURE_HEIGHT) return bitmap
    val scale = min(MAX_TEXTURE_WIDTH.toFloat() / bitmap.width, MAX_TEXTURE_HEIGHT.toFloat() / bitmap.height)
    val w = (bitmap.width * scale).roundToInt().coerceIn(1, MAX_TEXTURE_WIDTH)
    val h = (bitmap.height * scale).roundToInt().coerceIn(1, MAX_TEXTURE_HEIGHT)
    val scaled = Bitmap.createScaledBitmap(bitmap, w, h, true)
    if (scaled !== bitmap) bitmap.recycle()
    return scaled
  }

  /**
   * Looks at the first bytes of an MP4 or MOV file: true if the index (moov) comes before the media
   * data (mdat), false if mdat comes first (index at the end), null if the bytes do not tell.
   */
  fun mp4MoovBeforeMdat(data: ByteArray, length: Int): Boolean? {
    val end = minOf(length, data.size)
    var offset = 0L
    while (offset + 8 <= end) {
      val o = offset.toInt()
      var size = readUInt32(data, o)
      val header: Int
      if (size == 1L) {
        if (o + 16 > end) return null
        size = (readUInt32(data, o + 8) shl 32) or readUInt32(data, o + 12)
        header = 16
      } else {
        header = 8
      }
      when (String(data, o + 4, 4, Charsets.ISO_8859_1)) {
        "moov" -> return true
        "mdat" -> return false
      }
      if (size < header) return null
      offset += size
    }
    return null
  }

  private fun readUInt32(data: ByteArray, offset: Int): Long =
    ((data[offset].toLong() and 0xFF) shl 24) or
      ((data[offset + 1].toLong() and 0xFF) shl 16) or
      ((data[offset + 2].toLong() and 0xFF) shl 8) or
      (data[offset + 3].toLong() and 0xFF)
}
