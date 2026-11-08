package app.alextran.immich.images

import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The formats the fallback of RemoteImagesImpl may hand to Flutter's engine. The table is the one of
 * encoded_image_probe_test.dart (the same names, the same bytes): the engine takes a buffer here exactly when the Dart
 * probe tells one of the engine's own kinds (JPEG, PNG, GIF, WebP, BMP, ICO).
 */
class EngineImageFormatsTest {
  private fun ascii(text: String): List<Int> = text.map { it.code }

  // An ISO BMFF file type box (its size, ftyp, the major brand, a minor version, the compatible brands), then a box
  private fun ftyp(major: String, vararg compatible: String): List<Int> {
    val size = 16 + 4 * compatible.size
    return listOf(size ushr 24 and 0xFF, size ushr 16 and 0xFF, size ushr 8 and 0xFF, size and 0xFF) +
      ascii("ftyp$major") + listOf(0, 0, 0, 0) + compatible.flatMap { ascii(it) } + listOf(0, 0, 0, 0x24) +
      ascii("meta")
  }

  private val table: List<Triple<String, List<Int>, Boolean>> = listOf(
    Triple("JPEG JFIF", listOf(0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10) + ascii("JFIF") + 0, true),
    Triple("JPEG Exif", listOf(0xFF, 0xD8, 0xFF, 0xE1, 0x12, 0x34) + ascii("Exif") + listOf(0, 0), true),
    Triple("PNG", listOf(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13) + ascii("IHDR"), true),
    Triple("GIF87a", ascii("GIF87a") + listOf(1, 0, 1, 0, 0x80, 0, 0), true),
    Triple("GIF89a", ascii("GIF89a") + listOf(1, 0, 1, 0, 0x80, 0, 0), true),
    Triple("WebP lossy", ascii("RIFF") + listOf(0x24, 0, 0, 0) + ascii("WEBPVP8 ") + listOf(0x18, 0, 0, 0), true),
    Triple("WebP lossless", ascii("RIFF") + listOf(0x24, 0, 0, 0) + ascii("WEBPVP8L") + listOf(0x18, 0, 0, 0), true),
    Triple("WebP extended", ascii("RIFF") + listOf(0x24, 0, 0, 0) + ascii("WEBPVP8X") + listOf(0x0A, 0, 0, 0), true),
    Triple(
      "BMP",
      ascii("BM") + listOf(0x36, 0, 0, 0, 0, 0, 0, 0, 0x36, 0, 0, 0, 40, 0, 0, 0, 1, 0, 0, 0),
      true,
    ),
    Triple("ICO", listOf(0, 0, 1, 0, 1, 0, 16, 16, 0, 0, 1, 0, 32, 0), true),
    Triple("CUR", listOf(0, 0, 2, 0, 1, 0, 32, 32, 0, 0, 1, 0, 1, 0), true),
    Triple("HEIC of an iPhone", ftyp("heic", "mif1", "heic"), false),
    Triple("HEIC spatial photo of an iPhone", ftyp("heic", "mif1", "MiHE", "MiPr", "miaf", "MiHB", "heic"), false),
    Triple("HEIC heix", ftyp("heix", "mif1", "heix"), false),
    Triple("HEIF mif1 with heic", ftyp("mif1", "mif1", "heic"), false),
    Triple("HEIF sequence msf1", ftyp("msf1", "msf1", "hevc"), false),
    Triple("AVIF", ftyp("avif", "mif1", "miaf", "MA1B"), false),
    Triple("AVIF sequence", ftyp("avis", "avis", "msf1", "miaf", "MA1B"), false),
    Triple("AVIF mif1 with avif", ftyp("mif1", "mif1", "avif", "miaf"), false),
    Triple("Canon CR3", ftyp("crx ", "crx ", "isom"), false),
    Triple("MP4 video", ftyp("isom", "isom", "iso2", "avc1", "mp41"), false),
    Triple("QuickTime video", ftyp("qt  ", "qt  "), false),
    Triple("TIFF little endian", ascii("II") + listOf(0x2A, 0, 8, 0, 0, 0, 0x10, 0), false),
    Triple("TIFF big endian", ascii("MM") + listOf(0, 0x2A, 0, 0, 0, 8, 0, 0x10), false),
    Triple("DNG", ascii("II") + listOf(0x2A, 0, 8, 0, 0, 0, 0x1C, 0, 0xFE, 0), false),
    Triple("Canon CR2", ascii("II") + listOf(0x2A, 0, 0x10, 0, 0, 0) + ascii("CR") + listOf(2, 0), false),
    Triple("Olympus ORF", ascii("IIRO") + listOf(8, 0, 0, 0, 0x14, 0), false),
    Triple("Panasonic RW2", ascii("IIU") + listOf(0, 0x18, 0, 0, 0, 0x88, 0xE7), false),
    Triple("Fuji RAF", ascii("FUJIFILMCCD-RAW 0201FF383501"), false),
    Triple("Canon CRW", ascii("II") + listOf(0x1A, 0, 0, 0) + ascii("HEAPCCDR") + listOf(1, 0), false),
    Triple("Sigma X3F", ascii("FOVb") + listOf(0, 0, 2, 0, 0x10, 0), false),
    Triple("JPEG XL bare", listOf(0xFF, 0x0A, 0xFA, 0x7F, 0x01, 0x90), false),
    Triple(
      "JPEG XL container",
      listOf(0, 0, 0, 0x0C) + ascii("JXL ") + listOf(0x0D, 0x0A, 0x87, 0x0A, 0, 0, 0, 0x14) + ascii("ftypjxl "),
      false,
    ),
    Triple("SVG", ascii("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\"/>"), false),
    Triple("SVG after a byte order mark", listOf(0xEF, 0xBB, 0xBF) + ascii("<?xml version=\"1.0\"?><svg/>"), false),
    Triple("HTML page", ascii("\r\n  <!DOCTYPE html><html><body>Not found</body></html>"), false),
    Triple("JSON", ascii("{\"message\":\"Asset not found\",\"statusCode\":404}"), false),
    Triple("empty", emptyList(), false),
    Triple("one byte of a JPEG", listOf(0xFF), false),
    Triple("two bytes of a JPEG", listOf(0xFF, 0xD8), false),
    Triple("three bytes of a PNG", listOf(0x89, 0x50, 0x4E), false),
    Triple("BM and no BMP header", ascii("BMW of my neighbour, a photo"), false),
    Triple("an icon of no image", listOf(0, 0, 1, 0, 0, 0, 16, 16), false),
    Triple("WBMP", listOf(0, 0, 0x40, 0x40, 0xFF, 0xFF), false),
    Triple("random bytes", listOf(0x13, 0x37, 0xC0, 0xDE, 0x42, 0x99, 0x01, 0x7E, 0x55, 0xAA, 0x10, 0x20), false),
  )

  private fun bytes(values: List<Int>) = ByteArray(values.size) { values[it].toByte() }

  @Test
  fun `the engine takes the formats of its own codecs only, as the Dart probe tells them`() {
    for ((name, values, engine) in table) {
      assertEquals(name, engine, EngineImageFormats.isEngineDecodable(bytes(values)))
    }
  }

  @Test
  fun `a native buffer is read from its start, its first bytes only`() {
    for ((name, values, engine) in table) {
      val buffer = ByteBuffer.allocateDirect(values.size + 4096)
      buffer.put(bytes(values))
      // What follows is not read, whatever it is
      while (buffer.hasRemaining()) buffer.put(0x3C)
      buffer.position(17)
      assertEquals(name, engine, EngineImageFormats.isEngineDecodable(buffer, values.size))
      assertEquals(name, 17, buffer.position())
    }
  }

  @Test
  fun `a buffer shorter than it says is read to its end`() {
    val jpeg = bytes(listOf(0xFF, 0xD8, 0xFF, 0xE0))
    assertTrue(EngineImageFormats.isEngineDecodable(jpeg, 1 shl 20))
    assertFalse(EngineImageFormats.isEngineDecodable(jpeg, 2))
  }

  @Test
  fun `the raw files built like a TIFF read their orientation from the container`() {
    for ((name, values, _) in table) {
      val expected = name in setOf(
        "TIFF little endian", "TIFF big endian", "DNG", "Canon CR2", "Olympus ORF", "Panasonic RW2",
      )
      assertEquals(name, expected, EngineImageFormats.hasTiffHeader(bytes(values)))
    }
  }
}
