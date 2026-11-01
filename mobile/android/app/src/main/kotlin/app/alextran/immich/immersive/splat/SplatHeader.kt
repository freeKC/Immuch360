package app.alextran.immich.immersive.splat

import java.io.ByteArrayInputStream
import java.io.EOFException
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.GZIPInputStream

// Gaussian splat files of other tools in the Meta Quest (lot S5, decision D7 of design-final 2026-10-27): what the
// head of a file says before anything else of it is read. The viewer reads the head of the file again (it wins over
// the gaussianSplat JSON of the request), weighs it with SplatGate, reduces it with SplatReducer when it holds more
// gaussians than the headset takes, and only then hands it to the splat module of the Meta Spatial SDK.
//
// SPZ (Niantic Labs, MIT, https://github.com/nianticlabs/spz): versions 1 to 3 are one gzip stream that starts with a
// 16 byte header, little endian: magic 0x5053474e ("NGSP"), version, number of points, degree of the spherical
// harmonics (0 to 3), fractional bits of the fixed point positions (1 to 23 from version 2 on), flags, a reserved byte
// at 0. Version 4 starts with a clear header of 32 bytes: the same first fields (degree 0 to 4), the number of ZSTD
// streams, the offset of their table of contents, 12 reserved bytes at 0; the table gives the compressed and the
// decompressed size of each stream (8 bytes each), one stream for each array that is not empty, in the order of
// versions 1 to 3, holding the arrays of version 3, the streams ending with the file (README and load-spz.cc of the
// repository, read on 1 November 2026). PLY of 3D Gaussian Splatting: binary little endian, one element
// vertex with x y z, f_dc_0 to 2, opacity, scale_0 to 2, rot_0 to 3, and 0, 9, 24 or 45 f_rest_* for the degrees 0 to
// 3, all of them floats or doubles. Pure JVM, tested by SplatHeaderTest on the fixtures of
// .github/desktop/ai/make_splat_fixtures.py.

/** The formats of the splat files the headset reads, as the gaussianSplat JSON names them */
internal enum class SplatFormat(val json: String) {
  SPZ("spz"),
  PLY("ply");

  companion object {
    fun of(json: String?): SplatFormat? = entries.firstOrNull { it.json == json }
  }
}

/** Why a file is not opened as a splat */
internal enum class SplatFileProblem {
  /** Neither SPZ nor PLY, or a PLY of a mesh or a point cloud (no opacity, scales and rotations of gaussians) */
  NOT_A_SPLAT,

  /** The compressed PLY of SuperSplat and PlayCanvas (element chunk, packed_* properties) */
  COMPRESSED_PLY,

  /** A PLY written in ASCII or big endian, with values not stored as floats, or with harmonics past degree 3 */
  UNSUPPORTED_PLY,

  /** An SPZ of a version after 4 */
  NEWER_SPZ,

  /**
   * A wrong magic, a reserved field set, a stream or rows cut short, a header past [SplatHeader.HEAD_BYTES], a table
   * of contents of version 4 that does not match the arrays of the header or the length of the file
   */
  DAMAGED,
}

/** A property of the vertex element of a PLY: its [name], its [type], its [size] in bytes, its [offset] in a row */
internal data class PlyProperty(val name: String, val type: String, val size: Int, val offset: Int) {
  /** A 4 or 8 byte float: the only types the reducer reads (positions, opacity, scales) and the module was seen to read */
  val isFloat: Boolean
    get() = type == "float" || type == "float32" || type == "double" || type == "float64"
}

/** What the head of a file says */
internal sealed interface SplatProbe {
  /**
   * The SPZ of Niantic, gzip ([isZstd] false, versions 1 to 3) or ZSTD (version 4, read in the quest flavour and
   * written again as version 2 like the others, SplatReducer)
   */
  data class Spz(
    val version: Int,
    override val gaussians: Long,
    override val shDegree: Int,
    val fractionalBits: Int,
    val flags: Int,
    /** The ZSTD streams of version 4 and the offset of their table of contents; 0 before */
    val streams: Int = 0,
    val tocOffset: Long = 0,
  ) : SplatHead {
    override val format: SplatFormat
      get() = SplatFormat.SPZ

    override val formatVersion: Int
      get() = version

    val isZstd: Boolean
      get() = version >= 4

    /** The bytes of one point in each attribute array, in the order of the file (version 4 has the arrays of 3) */
    val positionBytes: Int
      get() = if (version == 1) 6 else 9

    val rotationBytes: Int
      get() = if (version >= 3) 4 else 3

    val shBytes: Int
      get() = 3 * SplatHeader.shCoefficients(shDegree)
  }

  /** A PLY of gaussians, binary little endian: its rows of [rowBytes] start at [headerBytes] */
  data class Ply(
    override val gaussians: Long,
    override val shDegree: Int,
    /** What a comment of the header names as the tool that made it, null when none does */
    val tool: String?,
    val headerBytes: Int,
    val rowBytes: Int,
    val properties: List<PlyProperty>,
  ) : SplatHead {
    override val format: SplatFormat
      get() = SplatFormat.PLY

    override val formatVersion: Int
      get() = 1

    fun property(name: String): PlyProperty? = properties.firstOrNull { it.name == name }

    fun offsetOf(name: String): Int? = property(name)?.offset
  }

  /** Not opened, for [problem]; [detail] for the log */
  data class Refused(val problem: SplatFileProblem, val detail: String) : SplatProbe
}

/** A splat the headset may open: its format, its version, its gaussians and the degree of its spherical harmonics */
internal sealed interface SplatHead : SplatProbe {
  val format: SplatFormat
  val formatVersion: Int
  val gaussians: Long
  val shDegree: Int
}

internal object SplatHeader {
  /** The bytes of the head the probe reads: the PLY headers of the usual tools take a few hundred */
  const val HEAD_BYTES = 65536

  /** "NGSP", little endian */
  const val SPZ_MAGIC = 0x5053474e

  /** The longest tool name kept from a comment */
  const val MAX_TOOL_LENGTH = 60

  /** The PLY properties a splat must have */
  val REQUIRED_PLY = listOf(
    "x", "y", "z", "f_dc_0", "f_dc_1", "f_dc_2", "opacity", "scale_0", "scale_1", "scale_2",
    "rot_0", "rot_1", "rot_2", "rot_3",
  )

  /**
   * The counts of f_rest_* properties the splat module was seen to read, and the degree of the spherical harmonics
   * each gives: 0 to 3 (Quest 3, 31 October 2026). Any other count, degree 4 (72) among them, is refused
   */
  val PLY_REST_DEGREES = mapOf(0 to 0, 9 to 1, 24 to 2, 45 to 3)

  /** The fractional bits a 24 bit fixed point position of an SPZ of version 2 to 4 can have */
  val SPZ_FRACTIONAL_BITS = 1..23

  private val TOOL_COMMENT =
    Regex("^(?:generated|exported|created|made|written|saved)\\s+(?:by|with|from|using|in)\\s+(.+)$", RegexOption.IGNORE_CASE)

  private val PLY_SIZES =
    mapOf(
      "char" to 1, "uchar" to 1, "int8" to 1, "uint8" to 1,
      "short" to 2, "ushort" to 2, "int16" to 2, "uint16" to 2,
      "int" to 4, "uint" to 4, "int32" to 4, "uint32" to 4, "float" to 4, "float32" to 4,
      "double" to 8, "float64" to 8,
    )

  /** The coefficients of the spherical harmonics past the first, for [degree]: 0, 3, 8, 15, 24 */
  fun shCoefficients(degree: Int): Int = (degree + 1) * (degree + 1) - 1

  /**
   * The decompressed size of each stream of a version 4 file of [count] points of degree [shDegree] holding [streams]
   * streams, in the order of the file: positions, alphas, colours, scales, rotations, harmonics. Niantic's writer
   * leaves an empty array out, so 5 streams without harmonics and 6 with them; a sixth stream that is empty is taken
   * too (the file of the owner's kit of 31 October 2026 has one). Null for any other count of streams
   */
  fun v4StreamSizes(count: Long, shDegree: Int, streams: Int): LongArray? {
    val arrays = longArrayOf(9 * count, count, 3 * count, 3 * count, 4 * count, 3L * shCoefficients(shDegree) * count)
    return when {
      streams == arrays.size -> arrays
      streams == arrays.size - 1 && arrays.last() == 0L -> arrays.copyOf(streams)
      else -> null
    }
  }

  /** The head of [file] (its first [HEAD_BYTES]) probed with its length */
  fun read(file: File): SplatProbe {
    val head = file.inputStream().use { readUpTo(it, HEAD_BYTES) }
    return probe(head, file.length())
  }

  /** What [head], the first bytes of a file of [fileLength] bytes, says; only its first [HEAD_BYTES] are read */
  fun probe(head: ByteArray, fileLength: Long): SplatProbe {
    val bytes = if (head.size > HEAD_BYTES) head.copyOf(HEAD_BYTES) else head
    return when {
      bytes.size >= 2 && bytes[0] == 0x1f.toByte() && bytes[1] == 0x8b.toByte() -> probeGzipSpz(bytes)
      bytes.size >= 4 && littleInt(bytes, 0) == SPZ_MAGIC -> probeClearSpz(bytes, fileLength)
      startsWith(bytes, "ply\n") || startsWith(bytes, "ply\r\n") -> probePly(bytes, fileLength)
      else -> SplatProbe.Refused(SplatFileProblem.NOT_A_SPLAT, "neither SPZ nor PLY")
    }
  }

  /** The tool a comment of a PLY names ("Generated by Postshot"), null when it names none */
  fun toolOf(comment: String): String? {
    val name = TOOL_COMMENT.matchEntire(comment.trim())?.groupValues?.get(1)?.trim() ?: return null
    if (name.isEmpty()) return null
    return name.take(MAX_TOOL_LENGTH).trim()
  }

  private fun probeGzipSpz(bytes: ByteArray): SplatProbe {
    val header = ByteArray(16)
    try {
      GZIPInputStream(ByteArrayInputStream(bytes)).use { input ->
        var read = 0
        while (read < header.size) {
          val n = input.read(header, read, header.size - read)
          if (n < 0) throw EOFException("the stream ends before the header")
          read += n
        }
      }
    } catch (e: IOException) {
      return SplatProbe.Refused(SplatFileProblem.DAMAGED, "gzip stream cut or damaged: ${e.message}")
    }
    if (littleInt(header, 0) != SPZ_MAGIC) return SplatProbe.Refused(SplatFileProblem.DAMAGED, "gzip without NGSP")
    val version = littleInt(header, 4)
    val count = littleInt(header, 8).toLong() and 0xffffffffL
    val degree = header[12].toInt() and 0xff
    val fractional = header[13].toInt() and 0xff
    val flags = header[14].toInt() and 0xff
    val reserved = header[15].toInt() and 0xff
    return when {
      version > 4 -> SplatProbe.Refused(SplatFileProblem.NEWER_SPZ, "SPZ version $version")
      version !in 1..3 -> SplatProbe.Refused(SplatFileProblem.DAMAGED, "SPZ version $version in gzip")
      reserved != 0 -> SplatProbe.Refused(SplatFileProblem.DAMAGED, "reserved byte $reserved")
      count == 0L -> SplatProbe.Refused(SplatFileProblem.DAMAGED, "no point")
      degree > 3 -> SplatProbe.Refused(SplatFileProblem.DAMAGED, "degree $degree")
      // Version 1 stores its positions as float16 and never reads them (SplatReducer.fractionalBitsOf)
      version >= 2 && fractional !in SPZ_FRACTIONAL_BITS ->
        SplatProbe.Refused(SplatFileProblem.DAMAGED, "$fractional fractional bits")
      else -> SplatProbe.Spz(version, count, degree, fractional, flags)
    }
  }

  private fun probeClearSpz(bytes: ByteArray, fileLength: Long): SplatProbe {
    if (bytes.size < 8) return SplatProbe.Refused(SplatFileProblem.DAMAGED, "clear SPZ header cut")
    val version = littleInt(bytes, 4)
    if (version > 4) return SplatProbe.Refused(SplatFileProblem.NEWER_SPZ, "SPZ version $version")
    if (version != 4) return SplatProbe.Refused(SplatFileProblem.DAMAGED, "clear SPZ header of version $version")
    if (bytes.size < 32) return SplatProbe.Refused(SplatFileProblem.DAMAGED, "clear SPZ header cut")
    val count = littleInt(bytes, 8).toLong() and 0xffffffffL
    val degree = bytes[12].toInt() and 0xff
    val fractional = bytes[13].toInt() and 0xff
    val flags = bytes[14].toInt() and 0xff
    val streams = bytes[15].toInt() and 0xff
    val toc = littleInt(bytes, 16).toLong() and 0xffffffffL
    val reserved = (20 until 32).any { bytes[it].toInt() != 0 }
    val sizes = v4StreamSizes(count, degree, streams)
    return when {
      reserved -> SplatProbe.Refused(SplatFileProblem.DAMAGED, "reserved bytes set")
      count == 0L -> SplatProbe.Refused(SplatFileProblem.DAMAGED, "no point")
      degree > 4 -> SplatProbe.Refused(SplatFileProblem.DAMAGED, "degree $degree")
      fractional !in SPZ_FRACTIONAL_BITS -> SplatProbe.Refused(SplatFileProblem.DAMAGED, "$fractional fractional bits")
      streams == 0 -> SplatProbe.Refused(SplatFileProblem.DAMAGED, "no stream")
      sizes == null -> SplatProbe.Refused(SplatFileProblem.DAMAGED, "$streams streams for degree $degree")
      toc < 32 || toc + 16L * streams > fileLength ->
        SplatProbe.Refused(SplatFileProblem.DAMAGED, "table of contents at $toc out of the file")
      else ->
        tocProblem(bytes, toc, sizes, fileLength)?.let { SplatProbe.Refused(SplatFileProblem.DAMAGED, it) }
          ?: SplatProbe.Spz(version, count, degree, fractional, flags, streams, toc)
    }
  }

  /**
   * What is wrong with the table of contents of a version 4 file at [toc] of its head [bytes], null when each stream
   * decompresses to the size of its array ([sizes]) and the streams end with the file of [fileLength] bytes, as
   * Niantic's reader asks. A table past the head (extensions of more than 64 KiB) is left to the reading of the file
   * (SplatReducer), which checks the same
   */
  private fun tocProblem(bytes: ByteArray, toc: Long, sizes: LongArray, fileLength: Long): String? {
    val end = toc + 16L * sizes.size
    if (end > bytes.size) return null
    val table = ByteBuffer.wrap(bytes, toc.toInt(), 16 * sizes.size).order(ByteOrder.LITTLE_ENDIAN)
    var streamsEnd = end
    for (i in sizes.indices) {
      val compressed = table.long
      val decompressed = table.long
      if (decompressed != sizes[i]) return "stream $i of $decompressed bytes, ${sizes[i]} expected"
      if (compressed < 0 || compressed > fileLength - streamsEnd) return "stream $i runs past the end of the file"
      streamsEnd += compressed
    }
    return if (streamsEnd != fileLength) "the streams end at $streamsEnd, the file at $fileLength" else null
  }

  private fun probePly(bytes: ByteArray, fileLength: Long): SplatProbe {
    val end = indexOf(bytes, "end_header\n".toByteArray(Charsets.US_ASCII))
    val endCr = indexOf(bytes, "end_header\r\n".toByteArray(Charsets.US_ASCII))
    val headerBytes =
      when {
        end >= 0 -> end + "end_header\n".length
        endCr >= 0 -> endCr + "end_header\r\n".length
        else -> return SplatProbe.Refused(SplatFileProblem.DAMAGED, "no end_header in the first $HEAD_BYTES bytes")
      }
    val lines = String(bytes, 0, headerBytes, Charsets.US_ASCII).split('\n').map { it.trimEnd('\r').trim() }
    var format: String? = null
    var tool: String? = null
    var vertexCount: Long? = null
    val properties = mutableListOf<PlyProperty>()
    var vertexList = false
    var inVertex = false
    var rowBytes = 0
    var unknownType: String? = null
    val others = mutableMapOf<String, Long>()
    for (line in lines.drop(1)) {
      val words = line.split(Regex("\\s+")).filter { it.isNotEmpty() }
      if (words.isEmpty()) continue
      when (words[0]) {
        "format" -> format = words.getOrNull(1)
        "comment" -> if (tool == null) tool = toolOf(line.removePrefix("comment").trim())
        "element" -> {
          val name = words.getOrNull(1) ?: return SplatProbe.Refused(SplatFileProblem.DAMAGED, "element without name")
          val count =
            words.getOrNull(2)?.toLongOrNull()
              ?: return SplatProbe.Refused(SplatFileProblem.DAMAGED, "element $name without count")
          // A count below 0 is no count: damaged, rather than a splat of -5 gaussians or a mesh of -12 faces
          if (count < 0) return SplatProbe.Refused(SplatFileProblem.DAMAGED, "element $name of $count")
          inVertex = name == "vertex"
          if (inVertex) vertexCount = count else others[name] = (others[name] ?: 0L) + count
        }
        "property" ->
          if (inVertex) {
            if (words.getOrNull(1) == "list") {
              vertexList = true
            } else {
              val type = words.getOrNull(1) ?: ""
              val name = words.getOrNull(2) ?: ""
              val size = PLY_SIZES[type]
              if (size == null) {
                unknownType = type
              } else {
                properties += PlyProperty(name, type, size, rowBytes)
                rowBytes += size
              }
            }
          }
      }
    }
    when (format) {
      "binary_little_endian" -> Unit
      "ascii",
      "binary_big_endian" -> return SplatProbe.Refused(SplatFileProblem.UNSUPPORTED_PLY, "PLY format $format")
      else -> return SplatProbe.Refused(SplatFileProblem.DAMAGED, "PLY format $format")
    }
    if ((others["chunk"] ?: 0L) > 0 || properties.any { it.name.startsWith("packed_") }) {
      return SplatProbe.Refused(SplatFileProblem.COMPRESSED_PLY, "compressed PLY")
    }
    if ((others["face"] ?: 0L) > 0 || vertexList) return SplatProbe.Refused(SplatFileProblem.NOT_A_SPLAT, "a mesh")
    val count = vertexCount ?: return SplatProbe.Refused(SplatFileProblem.NOT_A_SPLAT, "no vertex element")
    val names = properties.map { it.name }.toSet()
    val missing = REQUIRED_PLY.filter { it !in names }
    if (missing.isNotEmpty()) {
      return SplatProbe.Refused(SplatFileProblem.NOT_A_SPLAT, "no ${missing.joinToString()}: a point cloud or a mesh")
    }
    if (unknownType != null) return SplatProbe.Refused(SplatFileProblem.UNSUPPORTED_PLY, "type $unknownType")
    // Floats or doubles, what the module was seen to read, for every property of the gaussians and their harmonics
    val notFloats = properties.filter { (it.name in REQUIRED_PLY || it.name.startsWith("f_rest_")) && !it.isFloat }
    if (notFloats.isNotEmpty()) {
      return SplatProbe.Refused(
        SplatFileProblem.UNSUPPORTED_PLY,
        "not stored as floats: ${notFloats.joinToString { "${it.name} ${it.type}" }}",
      )
    }
    val rest = properties.count { it.name.startsWith("f_rest_") }
    val degree =
      PLY_REST_DEGREES[rest]
        ?: return SplatProbe.Refused(SplatFileProblem.UNSUPPORTED_PLY, "$rest f_rest properties: no degree from 0 to 3")
    if (others.values.any { it > 0 }) {
      return SplatProbe.Refused(SplatFileProblem.UNSUPPORTED_PLY, "other elements: ${others.keys.joinToString()}")
    }
    if (count == 0L) return SplatProbe.Refused(SplatFileProblem.DAMAGED, "no gaussian")
    if (headerBytes + count * rowBytes > fileLength) {
      return SplatProbe.Refused(SplatFileProblem.DAMAGED, "$count rows of $rowBytes bytes do not fit in $fileLength")
    }
    return SplatProbe.Ply(count, degree, tool, headerBytes, rowBytes, properties)
  }

  /** Up to [count] bytes from the start of [input], fewer at its end */
  fun readUpTo(input: InputStream, count: Int): ByteArray {
    val buffer = ByteArray(count)
    var read = 0
    while (read < count) {
      val n = input.read(buffer, read, count - read)
      if (n < 0) break
      read += n
    }
    return if (read == count) buffer else buffer.copyOf(read)
  }

  private fun littleInt(bytes: ByteArray, at: Int): Int = ByteBuffer.wrap(bytes, at, 4).order(ByteOrder.LITTLE_ENDIAN).int

  private fun startsWith(bytes: ByteArray, text: String): Boolean {
    val prefix = text.toByteArray(Charsets.US_ASCII)
    return bytes.size >= prefix.size && prefix.indices.all { bytes[it] == prefix[it] }
  }

  private fun indexOf(bytes: ByteArray, pattern: ByteArray): Int {
    outer@ for (i in 0..bytes.size - pattern.size) {
      for (j in pattern.indices) if (bytes[i + j] != pattern[j]) continue@outer
      return i
    }
    return -1
  }
}
