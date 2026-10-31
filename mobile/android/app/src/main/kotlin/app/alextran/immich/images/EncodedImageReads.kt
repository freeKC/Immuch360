package app.alextran.immich.images

import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.channels.Channels

/** A file of the device larger than the app reads whole at once (see [EncodedImageReads.limitFor]) */
class EncodedImageTooLargeException(message: String) : IOException(message)

/**
 * The encoded files of the device the app reads whole, for the decoders of Dart (a TIFF, which Android does not
 * decode): read straight into the native buffer Dart takes, never through the Java heap, and refused before they are
 * read when they are larger than the device can hold.
 */
object EncodedImageReads {
  private const val MEGABYTE = 1L shl 20

  /**
   * Most bytes read at once on a device of [totalMemoryBytes]: a sixteenth of its memory, 128 MB on a TV of 2 GB,
   * 512 MB at most (what the Dart TIFF decoder reads on a Meta Quest 3 of 8 GB), 64 MB at least
   */
  fun limitFor(totalMemoryBytes: Long): Long =
    (totalMemoryBytes / 16).coerceIn(64 * MEGABYTE, 512 * MEGABYTE)

  /** Throws [EncodedImageTooLargeException] when a file of [length] bytes is more than [limit] */
  fun checkLength(length: Long, limit: Long) {
    if (length > limit) {
      throw EncodedImageTooLargeException("$length bytes is more than this device reads at once ($limit)")
    }
  }

  /**
   * Reads [input] into [buffer] until it is full or [input] ends, calling [checkCancelled] before each read (it throws
   * to stop); the number of bytes read
   */
  fun readFully(input: InputStream, buffer: ByteBuffer, checkCancelled: () -> Unit): Int {
    val channel = Channels.newChannel(input)
    while (buffer.hasRemaining()) {
      checkCancelled()
      if (channel.read(buffer) < 0) {
        break
      }
    }
    return buffer.position()
  }
}
