package app.alextran.immich.images

import android.app.ActivityManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.exifinterface.media.ExifInterface
import app.alextran.immich.NativeBuffer
import java.util.concurrent.Executors

/** The code of the error of a decode that failed, an OutOfMemoryError included (see ImageDecodeException in Dart) */
const val UNDECODABLE_IMAGE = "UndecodableImage"

/**
 * [this] decoded by ImageDecoder at the size [sizeOf] gives for its full size, in software and in sRGB, as decodeBitmap
 * does; [header] gets the full size its header tells, for the logs of a failure
 */
@RequiresApi(Build.VERSION_CODES.P)
fun ImageDecoder.Source.decodeBitmapSized(header: IntArray, sizeOf: (Int, Int) -> DecodeSize): Bitmap =
  ImageDecoder.decodeBitmap(this) { decoder, info, _ ->
    header[0] = info.size.width
    header[1] = info.size.height
    val size = sizeOf(info.size.width, info.size.height)
    if (size.width != info.size.width || size.height != info.size.height) {
      decoder.setTargetSize(size.width, size.height)
    }
    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
    decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
  }

/**
 * What the logs and Dart are told of a decode that failed with [error]: its class and message, the size of the image
 * ([header], 0 when its header was not read), the [target] asked, the [bytes] of the file, and the memory of the app and
 * of the device when [context] is given
 */
fun describeDecodeFailure(
  error: Throwable,
  header: IntArray,
  target: String,
  bytes: Int,
  context: Context?,
): String {
  val runtime = Runtime.getRuntime()
  val memory = context?.let {
    val info = ActivityManager.MemoryInfo()
    (it.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager)?.getMemoryInfo(info)
    ", device ${info.availMem shr 20} MB free${if (info.lowMemory) " (low)" else ""}"
  } ?: ""
  return "${error.javaClass.name}: ${error.message}, image ${header[0]}x${header[1]}, asked $target, $bytes bytes, " +
    "Java heap ${runtime.totalMemory() shr 20} of ${runtime.maxMemory() shr 20} MB$memory"
}

/**
 * The native decoder of NativeImageDecodeApi: the encoded images Flutter's engine has no codec of its own for (HEIF,
 * AVIF, the raw files, JPEG XL), which the engine would decode at their full size through FlutterJNI.decodeImage and
 * abort the app on an OutOfMemoryError (crash M1 of the Meta Quest store, 8 November 2026). Here the bytes stay where
 * Dart put them (no copy into the Java heap), the size is bounded, an OutOfMemoryError gets one retry at half the size,
 * and every failure is an error of the call, never an exception that reaches the engine.
 */
class NativeImageDecodeImpl(context: Context) : NativeImageDecodeApi {
  private val ctx: Context = context.applicationContext

  companion object {
    private const val TAG = "NativeImageDecode"

    // Shared by every engine of the process, as the decode pool of RemoteImagesImpl: two decodes at once
    private val executor = Executors.newFixedThreadPool(2)
  }

  override fun decodeEncoded(
    pointer: Long,
    length: Long,
    maxWidth: Long,
    maxHeight: Long,
    callback: (Result<Map<String, Long>>) -> Unit
  ) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P || pointer == 0L || length <= 0 || length > Int.MAX_VALUE) {
      val reason = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) "no ImageDecoder before Android 9" else "no bytes"
      callback(Result.failure(FlutterError(UNDECODABLE_IMAGE, "$reason, $length bytes", null)))
      return
    }
    executor.execute {
      val header = IntArray(2)
      val target = "${maxWidth}x$maxHeight"
      val result = try {
        Result.success(decode(pointer, length.toInt(), maxWidth.toInt(), maxHeight.toInt(), header, 1.0))
      } catch (_: OutOfMemoryError) {
        // A quarter of the memory may be there when the whole was not
        try {
          Result.success(decode(pointer, length.toInt(), maxWidth.toInt(), maxHeight.toInt(), header, 0.5))
        } catch (retry: Throwable) {
          failure(retry, header, "$target then half", length.toInt())
        }
      } catch (error: Throwable) {
        failure(error, header, target, length.toInt())
      }
      callback(result)
    }
  }

  private fun failure(error: Throwable, header: IntArray, target: String, bytes: Int): Result<Map<String, Long>> {
    val message = describeDecodeFailure(error, header, target, bytes, ctx)
    Log.w(TAG, "Not decoded: $message")
    return Result.failure(FlutterError(UNDECODABLE_IMAGE, message, null))
  }

  @RequiresApi(Build.VERSION_CODES.P)
  private fun decode(
    pointer: Long,
    length: Int,
    maxWidth: Int,
    maxHeight: Int,
    header: IntArray,
    factor: Double,
  ): Map<String, Long> {
    val head = ByteArray(minOf(length, EngineImageFormats.PROBE_LENGTH))
    NativeBuffer.wrap(pointer, length).get(head)
    // A raw file built like a TIFF decodes to its embedded preview, without the orientation of its container
    val orientation = if (EngineImageFormats.hasTiffHeader(head)) {
      readRawOrientation(NativeBuffer.wrap(pointer, length), length)
    } else {
      ExifInterface.ORIENTATION_NORMAL
    }
    val turned = when (orientation) {
      ExifInterface.ORIENTATION_TRANSPOSE,
      ExifInterface.ORIENTATION_ROTATE_90,
      ExifInterface.ORIENTATION_TRANSVERSE,
      ExifInterface.ORIENTATION_ROTATE_270 -> true
      else -> false
    }
    // The bounds of the upright picture: a picture turned a quarter decodes in the bounds turned too
    val (boundWidth, boundHeight) = if (turned) maxHeight to maxWidth else maxWidth to maxHeight
    val source = ImageDecoder.createSource(NativeBuffer.wrap(pointer, length))
    val bitmap = source.decodeBitmapSized(header) { width, height ->
      NativeDecodeSize.fit(width, height, boundWidth, boundHeight, factor)
    }
    return if (orientation == ExifInterface.ORIENTATION_NORMAL || orientation == ExifInterface.ORIENTATION_UNDEFINED) {
      bitmap.toNativeBuffer()
    } else {
      rotateToNativeBuffer(bitmap, orientation)
    }
  }
}
