package app.alextran.immich.immersive.splat

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.zip.CRC32
import java.util.zip.DataFormatException
import java.util.zip.Inflater

/**
 * What the splat module of the Meta Spatial SDK 0.14.0 reads, as measured on a Quest 3 on 31 October 2026 (bench of
 * store/m2/quest-splats-device-2026-10-31 of the research notes): a file it cannot read does not come back as a failed
 * load event, it aborts the whole process (SIGABRT in its loading thread), which no code of the app can catch. So the
 * viewer hands it nothing but what it was seen to read:
 *
 * - SPZ of version 2 only, one gzip stream holding exactly the data its header announces. Version 3 ("version not
 *   supported: 3") and version 4 (its ZSTD streams) abort, and so does a version 2 cut or short of its data
 *   ("decompressGzipped: failed", "deserializePackedGaussians: read error"); version 1 loads, but its points are not
 *   where they should be. The viewer writes every SPZ again as version 2 ([needsRewrite], SplatReducer.write, which
 *   reads the source to its end and stops on a damaged one), version 4 included: its ZSTD streams are read in the
 *   quest flavour (SplatZstd, FreeKC's report of 1 November 2026).
 * - PLY of 3D Gaussian Splatting: the module reads it by the names of its properties, in any order, float or double,
 *   SH 0 to 3, with normals or other properties; it aborts without x y z, opacity or scale_*. The probe of the viewer
 *   asks for more ([SplatHeader.REQUIRED_PLY] as floats, degrees 0 to 3, binary little endian), so every PLY it takes
 *   is read.
 *
 * Two last guards on the file the module is about to get, after the preparation wrote, renamed or copied it:
 * [checkWhole] off the main thread, as the preparation ends (an SPZ inflated to its end), and [check] (its head) on the
 * main thread just before the entity. Pure JVM, tested by SplatModuleFormatTest.
 */
internal object SplatModuleFormat {
  /** The one SPZ version the module reads */
  const val SPZ_VERSION = 2

  /** The flag of extensions of an SPZ header: the viewer clears it and copies none */
  const val SPZ_EXTENSIONS_FLAG = 0x2

  /** Whether the module reads a file whose head is [probe] without aborting */
  fun reads(probe: SplatProbe): Boolean =
    when (probe) {
      is SplatProbe.Spz -> probe.version == SPZ_VERSION && !probe.isZstd && probe.flags and SPZ_EXTENSIONS_FLAG == 0
      is SplatProbe.Ply -> true
      is SplatProbe.Refused -> false
    }

  /**
   * Whether a splat of [head] must be written again before the module reads it: every SPZ, version 2 included, since
   * one cut or short of its data aborts the module as surely as a version 3 or 4, and only a full reading finds it out
   */
  fun needsRewrite(head: SplatHead): Boolean = head is SplatProbe.Spz

  /** The bytes of the data of a version 2 SPZ of [head] once inflated: its header, then 19 bytes a point and its SH */
  fun payloadBytes(head: SplatProbe.Spz): Long = 16L + head.gaussians * (9 + 1 + 3 + 3 + 3 + head.shBytes)

  /**
   * Why [file] must not reach the module, null when it may: it is gone, its head is not one the module reads, its
   * extension is not that of its format in lower case, or it holds another count than the [gaussians] expected
   */
  fun check(file: File, gaussians: Long): String? {
    if (!file.isFile) return "no file"
    val probe =
      try {
        SplatHeader.read(file)
      } catch (e: Exception) {
        return "unreadable: ${e.message}"
      }
    if (!reads(probe)) {
      return when (probe) {
        is SplatProbe.Refused -> "refused by the probe: ${probe.detail}"
        is SplatProbe.Spz ->
          if (probe.version == SPZ_VERSION && !probe.isZstd) "SPZ with the flag of extensions"
          else "SPZ version ${probe.version}"
        is SplatProbe.Ply -> "PLY"
      }
    }
    probe as SplatHead
    if (!file.name.endsWith(".${probe.format.json}")) return "named ${file.name} for a ${probe.format.json} file"
    if (probe.gaussians != gaussians) return "${probe.gaussians} gaussians, ${gaussians} expected"
    return null
  }

  /**
   * [check], then for an SPZ the whole file: one gzip member (a header without options, as the viewer writes it), its
   * deflate stream to its end, its CRC and length, nothing after it, and exactly [payloadBytes] inside. A read of the
   * whole file, off the main thread only
   */
  fun checkWhole(file: File, gaussians: Long): String? {
    check(file, gaussians)?.let { return it }
    val probe = SplatHeader.read(file) as? SplatProbe.Spz ?: return null
    return try {
      file.inputStream().use { wholeSpz(it, payloadBytes(probe)) }
    } catch (e: IOException) {
      "unreadable: ${e.message}"
    }
  }

  private fun wholeSpz(input: InputStream, expected: Long): String? {
    val header = SplatHeader.readUpTo(input, 10)
    if (header.size < 10 || header[0] != 0x1f.toByte() || header[1] != 0x8b.toByte() || header[2] != 8.toByte()) {
      return "no gzip header"
    }
    if (header[3].toInt() != 0) return "a gzip header with options"
    val inflater = Inflater(true)
    try {
      val crc = CRC32()
      val compressed = ByteArray(1 shl 16)
      val inflated = ByteArray(1 shl 16)
      var given = 0
      var total = 0L
      while (!inflater.finished()) {
        if (inflater.needsInput()) {
          given = input.read(compressed)
          if (given < 0) return "gzip stream cut after $total bytes"
          inflater.setInput(compressed, 0, given)
        }
        val n =
          try {
            inflater.inflate(inflated)
          } catch (e: DataFormatException) {
            return "gzip stream damaged: ${e.message}"
          }
        if (n == 0 && !inflater.needsInput() && !inflater.finished()) return "gzip stream damaged"
        crc.update(inflated, 0, n)
        total += n
        if (total > expected) return "more data than ${expected} bytes"
      }
      // The trailer: what the inflater left of the last read, then the stream
      val rest = inflater.remaining
      val after = compressed.copyOfRange(given - rest, given) + SplatHeader.readUpTo(input, 9)
      if (after.size < 8) return "gzip trailer cut"
      if (after.size > 8) return "bytes after the gzip member"
      val storedCrc = littleUint(after, 0)
      val storedLength = littleUint(after, 4)
      if (storedCrc != crc.value) return "gzip CRC wrong"
      if (storedLength != total and 0xffffffffL) return "gzip length wrong"
      if (total != expected) return "$total bytes of data, $expected expected"
      return null
    } finally {
      inflater.end()
    }
  }

  private fun littleUint(bytes: ByteArray, at: Int): Long =
    (bytes[at].toLong() and 0xff) or ((bytes[at + 1].toLong() and 0xff) shl 8) or
      ((bytes[at + 2].toLong() and 0xff) shl 16) or ((bytes[at + 3].toLong() and 0xff) shl 24)
}
