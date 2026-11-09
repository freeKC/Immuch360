package app.alextran.immich.images

import java.nio.ByteBuffer

/**
 * The encoded images Flutter's engine decodes with codecs of its own: JPEG, PNG, GIF, WebP, BMP and ICO. Any other
 * buffer the engine hands to Android's ImageDecoder through FlutterJNI.decodeImage, which allocates the full size
 * bitmap and aborts the app on any exception other than an IOException (an OutOfMemoryError on a large HEIF, AVIF or
 * raw photo: the crash M1 of the Meta Quest store, 8 November 2026). So the fallback of [RemoteImagesImpl] hands
 * Flutter the encoded bytes of the first kind only. Each check is as strict as the engine's codec, or stricter, and
 * follows encoded_image_probe.dart on the Dart side: the tests of both read the same table of first bytes.
 */
object EngineImageFormats {
  /** How many first bytes are read */
  const val PROBE_LENGTH = 64

  private val BMP_INFO_HEADER_SIZES = setOf(12, 16, 40, 52, 56, 64, 108, 124)

  /** Whether [head] (its first [length] bytes, at most [PROBE_LENGTH] read) starts as a format the engine decodes */
  fun isEngineDecodable(head: ByteArray, length: Int = head.size): Boolean {
    val n = minOf(length, head.size, PROBE_LENGTH)
    fun at(offset: Int, vararg bytes: Int): Boolean =
      offset + bytes.size <= n && bytes.indices.all { head[offset + it].toInt() and 0xFF == bytes[it] }
    fun ascii(offset: Int, text: String): Boolean = at(offset, *text.map { it.code }.toIntArray())

    // In the order of the Dart probe: an ISO BMFF box of 256 or 512 bytes starts as an icon does
    return when {
      at(0, 0xFF, 0xD8, 0xFF) -> true
      at(0, 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) -> true
      ascii(0, "GIF87a") || ascii(0, "GIF89a") -> true
      ascii(0, "RIFF") && ascii(8, "WEBPVP") -> true
      ascii(4, "ftyp") -> false
      ascii(0, "BM") -> n >= 18 && littleEndianInt(head, 14) in BMP_INFO_HEADER_SIZES
      // An icon or a cursor, holding at least one image
      else -> n >= 6 && at(0, 0x00, 0x00) && (at(2, 0x01, 0x00) || at(2, 0x02, 0x00)) &&
        (head[4].toInt() != 0 || head[5].toInt() != 0)
    }
  }

  /** Whether the first [length] bytes of [buffer] (from its index 0, its position left alone) start as one */
  fun isEngineDecodable(buffer: ByteBuffer, length: Int): Boolean {
    val n = minOf(length, buffer.capacity(), PROBE_LENGTH)
    val head = ByteArray(n) { buffer.get(it) }
    return isEngineDecodable(head, n)
  }

  /**
   * Whether [head] starts as a TIFF does (II*\0, MM\0*) or as the raw files built like one (Olympus IIRO, IIRS, MMOR,
   * Panasonic IIU\0): an orientation in its first IFD that Android's decoder of the embedded preview leaves out
   */
  fun hasTiffHeader(head: ByteArray, length: Int = head.size): Boolean {
    val n = minOf(length, head.size)
    if (n < 4) return false
    val text = String(head, 0, 4, Charsets.ISO_8859_1)
    return text == "II*\u0000" || text == "MM\u0000*" || text == "IIRO" || text == "IIRS" || text == "MMOR" ||
      text == "IIU\u0000"
  }

  private fun littleEndianInt(bytes: ByteArray, offset: Int): Int =
    (bytes[offset].toInt() and 0xFF) or
      ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
      ((bytes[offset + 2].toInt() and 0xFF) shl 16) or
      ((bytes[offset + 3].toInt() and 0xFF) shl 24)
}
