package app.alextran.immich.immersive.splat

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.BitSet
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.ln1p
import kotlin.math.max

/** A splat file that cannot be read as its head said, for [problem] */
internal class SplatReadException(val problem: SplatFileProblem, message: String) : IOException(message)

/** The reading was cancelled (another media, the end of the viewer) */
internal class SplatCancelledException : IOException("cancelled")

/**
 * What a first reading of a splat gives: the score of each gaussian (see [SplatReducer.scan]) and the positions of a
 * sample of them, every [SplatReducer.SAMPLE_LIMIT]th or so, for the placement: the index of each in [sampleIndices],
 * its x, y, z in [samplePositions], in the numbers of the file.
 */
internal class SplatScan(val scores: FloatArray, val sampleIndices: IntArray, val samplePositions: FloatArray) {
  val sampleCount: Int
    get() = sampleIndices.size
}

/**
 * The reduction of a splat that holds more gaussians than the headset takes (lot S5, design of 30 October 2026): the
 * strongest of them kept, in the same format, the others left out. Without it nearly no capture of a real place would
 * open: most hold more than 150 000 gaussians.
 *
 * 1. The score of a gaussian is its opacity times its volume, compared as a logarithm: ln(opacity) plus its three log
 *    scales. An SPZ stores the opacity as a byte (value / 255) and the scales as bytes (value / 16 - 10); a PLY the
 *    opacity as a logit (ln(sigmoid(o)) = -ln(1 + e^-o)) and the scales as natural logarithms. An opacity of 0 counts
 *    as 1e-6; a score that is not a number comes last.
 * 2. The [keep] largest scores are kept, a tie going to the lower index, so that the same file always gives the same
 *    splat ([select]).
 * 3. The file is written again in its format, the kept gaussians in their order: a PLY by rows under its header with
 *    the new count, its bytes untouched; an SPZ attribute by attribute (each array keeps the entries of the kept
 *    points) in a new gzip stream, always as version 2, the only version the splat module of the headset reads
 *    (SplatModuleFormat): its header with version 2, the new count and the flag of extensions cleared (none is
 *    copied). The arrays of versions 1 to 3 are the same but two, recoded the way the public description of the
 *    format gives them (nianticlabs/spz, MIT): the float16 positions of version 1 as 24 bit fixed point with the
 *    fractional bits of its header, floor(v * 2^bits + 0.5); the rotations of version 3, 4 bytes of "smallest three",
 *    as the 3 bytes of version 2 (the quaternion normalised, w made positive, x, y, z as floor(q * 127.5 + 128)).
 *    Everything else is copied byte for byte. The source is then read to the end of its gzip stream, so that the CRC
 *    and the length of each member are checked: a source cut, short of its data or damaged stops with
 *    [SplatFileProblem.DAMAGED], and the module only ever gets one clean member written here. A version 4 SPZ (ZSTD)
 *    is not read here: the gate refuses it.
 *
 * Two readings of the file in streams, never the file in memory: the scores (4 bytes a gaussian) and, for an SPZ, its
 * opacities (1 byte a gaussian) are what stays. The heuristic is a first one, to be judged in the headset; it is the
 * one of the design. Pure JVM, tested by SplatReducerTest against make_splat_fixtures.py.
 */
internal object SplatReducer {
  /** About this many positions are sampled for the placement, at a fixed stride */
  const val SAMPLE_LIMIT = 65_536

  /** The points read at a time, and between two checks of the cancellation */
  private const val CHUNK = 4096

  /** The fractional bits of the positions Niantic's writer gives, for a version 1 header that says none */
  const val DEFAULT_FRACTIONAL_BITS = 12

  private val SQRT_HALF = Math.sqrt(0.5)

  private const val MIN_OPACITY = 1e-6
  private val LOG_MIN_OPACITY = ln(MIN_OPACITY)

  /** Reads [input], a file whose head is [head], from its start: the scores and the sample of the positions */
  fun scan(
    input: InputStream,
    head: SplatHead,
    sampleLimit: Int = SAMPLE_LIMIT,
    cancelled: () -> Boolean = { false },
  ): SplatScan {
    val count = countOf(head)
    val stride = maxOf(1, (count + sampleLimit - 1) / sampleLimit)
    val samples = (count + stride - 1) / stride
    val sampleIndices = IntArray(samples) { it * stride }
    val samplePositions = FloatArray(3 * samples)
    val scores = FloatArray(count)
    when (head) {
      is SplatProbe.Spz -> {
        if (head.isZstd) throw SplatReadException(SplatFileProblem.NEWER_SPZ, "ZSTD is not read here")
        input.use { raw ->
          val reader = Reader(GZIPInputStream(BufferedInputStream(raw, 1 shl 16), 1 shl 16))
          reader.skip(16)
          // Positions: float16 in version 1, 24 bit fixed point after
          val positionBytes = head.positionBytes
          val scale = 1.0 / (1 shl head.fractionalBits)
          val chunk = ByteArray(CHUNK * positionBytes)
          var i = 0
          while (i < count) {
            if (cancelled()) throw SplatCancelledException()
            val n = minOf(CHUNK, count - i)
            reader.read(chunk, n * positionBytes)
            for (k in 0 until n) {
              val index = i + k
              if (index % stride != 0) continue
              val s = 3 * (index / stride)
              for (axis in 0 until 3) {
                val at = k * positionBytes + axis * (positionBytes / 3)
                samplePositions[s + axis] =
                  if (head.version == 1) halfToFloat(chunk, at) else (fixed24(chunk, at) * scale).toFloat()
              }
            }
            i += n
          }
          val alphas = ByteArray(count)
          reader.read(alphas, count)
          reader.skip(3L * count)
          val scales = ByteArray(CHUNK * 3)
          i = 0
          while (i < count) {
            if (cancelled()) throw SplatCancelledException()
            val n = minOf(CHUNK, count - i)
            reader.read(scales, 3 * n)
            for (k in 0 until n) {
              val alpha = (alphas[i + k].toInt() and 0xff) / 255.0
              var score = ln(max(alpha, MIN_OPACITY))
              for (axis in 0 until 3) score += (scales[3 * k + axis].toInt() and 0xff) / 16.0 - 10.0
              scores[i + k] = clean(score)
            }
            i += n
          }
        }
      }
      is SplatProbe.Ply -> {
        val x = floatReader(head, "x")
        val y = floatReader(head, "y")
        val z = floatReader(head, "z")
        val opacity = floatReader(head, "opacity")
        val s0 = floatReader(head, "scale_0")
        val s1 = floatReader(head, "scale_1")
        val s2 = floatReader(head, "scale_2")
        input.use { raw ->
          val reader = Reader(BufferedInputStream(raw, 1 shl 16))
          reader.skip(head.headerBytes.toLong())
          val row = head.rowBytes
          val chunk = ByteArray(CHUNK * row)
          val buffer = ByteBuffer.wrap(chunk).order(ByteOrder.LITTLE_ENDIAN)
          var i = 0
          while (i < count) {
            if (cancelled()) throw SplatCancelledException()
            val n = minOf(CHUNK, count - i)
            reader.read(chunk, n * row)
            for (k in 0 until n) {
              val base = k * row
              val index = i + k
              if (index % stride == 0) {
                val s = 3 * (index / stride)
                samplePositions[s] = x(buffer, base).toFloat()
                samplePositions[s + 1] = y(buffer, base).toFloat()
                samplePositions[s + 2] = z(buffer, base).toFloat()
              }
              val o = opacity(buffer, base)
              // ln(sigmoid(o)), steady for a large negative o
              val logAlpha = if (o > -30) -ln1p(exp(-o)) else o
              scores[index] = clean(max(logAlpha, LOG_MIN_OPACITY) + s0(buffer, base) + s1(buffer, base) + s2(buffer, base))
            }
            i += n
          }
        }
      }
    }
    return SplatScan(scores, sampleIndices, samplePositions)
  }

  /** The indices of the [keep] largest [scores], a tie going to the lower index; all of them when [keep] is more */
  fun select(scores: FloatArray, keep: Int): BitSet {
    val n = scores.size
    val kept = BitSet(n)
    if (keep >= n) {
      kept.set(0, n)
      return kept
    }
    if (keep <= 0) return kept
    val sorted = FloatArray(n) { cleanFloat(scores[it]) }
    sorted.sort()
    val threshold = sorted[n - keep]
    var above = 0
    for (i in 0 until n) {
      if (cleanFloat(scores[i]) > threshold) {
        kept.set(i)
        above++
      }
    }
    var remaining = keep - above
    var i = 0
    while (remaining > 0 && i < n) {
      if (cleanFloat(scores[i]) == threshold) {
        kept.set(i)
        remaining--
      }
      i++
    }
    return kept
  }

  /**
   * Writes the gaussians of [input] (a file whose head is [head]) that [kept] holds into [out], in the same format
   * (an SPZ as version 2, see the top of this object); [out] is flushed, not closed. [kept] may hold every gaussian:
   * every SPZ of versions 1 to 3 is rewritten whole so, its source read to its end
   */
  fun write(
    input: InputStream,
    head: SplatHead,
    kept: BitSet,
    out: OutputStream,
    cancelled: () -> Boolean = { false },
  ) {
    val count = countOf(head)
    val keep = kept.cardinality()
    when (head) {
      is SplatProbe.Spz -> {
        if (head.isZstd) throw SplatReadException(SplatFileProblem.NEWER_SPZ, "ZSTD is not read here")
        input.use { raw ->
          val reader = Reader(GZIPInputStream(BufferedInputStream(raw, 1 shl 16), 1 shl 16))
          val header = ByteArray(16)
          reader.read(header, 16)
          val fractional = fractionalBitsOf(head)
          ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN).putInt(4, SplatModuleFormat.SPZ_VERSION).putInt(8, keep)
          header[13] = fractional.toByte()
          header[14] = (header[14].toInt() and 0x2.inv()).toByte()
          val gzip = GZIPOutputStream(BufferedOutputStream(NoClose(out), 1 shl 16), 1 shl 16)
          gzip.write(header)
          // Positions: float16 in version 1, recoded; 24 bit fixed point in versions 2 and 3, copied
          if (head.version == 1) {
            val scale = (1 shl fractional).toDouble()
            recodeKept(reader, gzip, count, 6, 9, kept, cancelled) { from, at, to, into ->
              for (axis in 0 until 3) putFixed24(into, to + 3 * axis, halfToFloat(from, at + 2 * axis) * scale)
            }
          } else {
            copyKept(reader, gzip, count, 9, kept, cancelled)
          }
          // Alphas, colours, scales: the same in every version
          for (size in listOf(1, 3, 3)) copyKept(reader, gzip, count, size, kept, cancelled)
          // Rotations: the smallest three of version 3 recoded, the 3 bytes of versions 1 and 2 copied
          if (head.rotationBytes == 4) {
            recodeKept(reader, gzip, count, 4, 3, kept, cancelled) { from, at, to, into ->
              firstThreeOfSmallestThree(from, at, into, to)
            }
          } else {
            copyKept(reader, gzip, count, 3, kept, cancelled)
          }
          if (head.shBytes > 0) copyKept(reader, gzip, count, head.shBytes, kept, cancelled)
          // The rest of the source, to the end of its gzip stream: extensions or bytes past the data are not copied,
          // but a cut trailer or a wrong CRC means the points read may not be those that were written
          reader.drain(cancelled)
          gzip.finish()
          gzip.flush()
        }
      }
      is SplatProbe.Ply ->
        input.use { raw ->
          val reader = Reader(BufferedInputStream(raw, 1 shl 16))
          val header = ByteArray(head.headerBytes)
          reader.read(header, header.size)
          val text =
            String(header, Charsets.US_ASCII).replaceFirst(Regex("(?m)^(element\\s+vertex\\s+)\\d+"), "$1$keep")
          val buffered = BufferedOutputStream(NoClose(out), 1 shl 16)
          buffered.write(text.toByteArray(Charsets.US_ASCII))
          copyKept(reader, buffered, count, head.rowBytes, kept, cancelled)
          buffered.flush()
        }
    }
  }

  private fun copyKept(
    reader: Reader,
    out: OutputStream,
    count: Int,
    size: Int,
    kept: BitSet,
    cancelled: () -> Boolean,
  ) {
    val chunk = ByteArray(CHUNK * size)
    var i = 0
    while (i < count) {
      if (cancelled()) throw SplatCancelledException()
      val n = minOf(CHUNK, count - i)
      reader.read(chunk, n * size)
      for (k in 0 until n) if (kept[i + k]) out.write(chunk, k * size, size)
      i += n
    }
  }

  /**
   * Reads the [count] entries of [size] bytes of one array and writes those of the kept points as [outSize] bytes,
   * each recoded by [recode] (the source, its offset, the offset written, the output)
   */
  private fun recodeKept(
    reader: Reader,
    out: OutputStream,
    count: Int,
    size: Int,
    outSize: Int,
    kept: BitSet,
    cancelled: () -> Boolean,
    recode: (ByteArray, Int, Int, ByteArray) -> Unit,
  ) {
    val chunk = ByteArray(CHUNK * size)
    val written = ByteArray(CHUNK * outSize)
    var i = 0
    while (i < count) {
      if (cancelled()) throw SplatCancelledException()
      val n = minOf(CHUNK, count - i)
      reader.read(chunk, n * size)
      var to = 0
      for (k in 0 until n) {
        if (!kept[i + k]) continue
        recode(chunk, k * size, to, written)
        to += outSize
      }
      out.write(written, 0, to)
      i += n
    }
  }

  /**
   * The fractional bits of the fixed point positions written: those of the header, which version 1 does not use for
   * its float16 positions, unless they are not a number of bits a 24 bit position can hold (then 12, the writer of
   * Niantic's)
   */
  fun fractionalBitsOf(head: SplatProbe.Spz): Int =
    if (head.version != 1 || head.fractionalBits in 1..23) head.fractionalBits else DEFAULT_FRACTIONAL_BITS

  /** [value] rounded half up as a 24 bit signed little endian number at [at], held within its range */
  private fun putFixed24(into: ByteArray, at: Int, value: Double) {
    val n = Math.floor(value + 0.5).coerceIn(-8_388_608.0, 8_388_607.0).toInt()
    into[at] = n.toByte()
    into[at + 1] = (n shr 8).toByte()
    into[at + 2] = (n shr 16).toByte()
  }

  /**
   * The rotation of version 3 at [at] of [from] (4 bytes, little endian: the index of the largest component of
   * (x, y, z, w) in the top 2 bits, then for the others, from the low bits and from w down to x, a magnitude of 9 bits
   * over 1/sqrt(2) and a sign bit; the largest is what makes the quaternion unit) written as version 2 at [to] of
   * [into]: x, y, z of the normalised quaternion with w made positive, each floor(q * 127.5 + 127.5 + 0.5)
   */
  fun firstThreeOfSmallestThree(from: ByteArray, at: Int, into: ByteArray, to: Int) {
    var comp =
      (from[at].toLong() and 0xff) or ((from[at + 1].toLong() and 0xff) shl 8) or
        ((from[at + 2].toLong() and 0xff) shl 16) or ((from[at + 3].toLong() and 0xff) shl 24)
    val largest = (comp ushr 30).toInt()
    val q = DoubleArray(4)
    var squares = 0.0
    for (i in 3 downTo 0) {
      if (i == largest) continue
      val magnitude = (comp and 511L).toDouble()
      val negative = (comp ushr 9) and 1L
      comp = comp ushr 10
      q[i] = SQRT_HALF * magnitude / 511.0
      if (negative == 1L) q[i] = -q[i]
      squares += q[i] * q[i]
    }
    q[largest] = Math.sqrt(maxOf(0.0, 1.0 - squares))
    val norm = Math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3])
    val sign = if (q[3] / norm < 0) -1.0 else 1.0
    for (axis in 0 until 3) {
      val c = sign * (q[axis] / norm)
      into[to + axis] = Math.floor(c * 127.5 + 127.5 + 0.5).coerceIn(0.0, 255.0).toInt().toByte()
    }
  }

  private fun countOf(head: SplatHead): Int {
    if (head.gaussians > Int.MAX_VALUE) throw SplatReadException(SplatFileProblem.DAMAGED, "${head.gaussians} points")
    return head.gaussians.toInt()
  }

  private fun clean(score: Double): Float = if (score.isNaN()) -Float.MAX_VALUE else score.toFloat()

  private fun cleanFloat(score: Float): Float = if (score.isNaN()) Float.NEGATIVE_INFINITY else score

  /** A reader of the property [name] of a row, a float or a double */
  private fun floatReader(head: SplatProbe.Ply, name: String): (ByteBuffer, Int) -> Double {
    val property = head.property(name) ?: throw SplatReadException(SplatFileProblem.NOT_A_SPLAT, "no $name")
    val offset = property.offset
    return if (property.size == 8) { buffer, base -> buffer.getDouble(base + offset) }
    else { buffer, base -> buffer.getFloat(base + offset).toDouble() }
  }

  /** The 24 bit signed little endian number at [at] */
  private fun fixed24(bytes: ByteArray, at: Int): Int {
    val value = (bytes[at].toInt() and 0xff) or ((bytes[at + 1].toInt() and 0xff) shl 8) or (bytes[at + 2].toInt() shl 16)
    return value
  }

  /** The IEEE 754 half float, little endian, at [at] */
  private fun halfToFloat(bytes: ByteArray, at: Int): Float {
    val bits = (bytes[at].toInt() and 0xff) or ((bytes[at + 1].toInt() and 0xff) shl 8)
    val sign = if (bits and 0x8000 != 0) -1f else 1f
    val exponent = (bits shr 10) and 0x1f
    val mantissa = bits and 0x3ff
    return when (exponent) {
      0 -> sign * mantissa / 1024f * (1f / 16384f)
      0x1f -> if (mantissa == 0) sign * Float.POSITIVE_INFINITY else Float.NaN
      else -> sign * (1f + mantissa / 1024f) * Math.scalb(1f, exponent - 15)
    }
  }

  /** Reads exactly what it is asked, else stops with [SplatFileProblem.DAMAGED] */
  private class Reader(private val input: InputStream) {
    fun read(buffer: ByteArray, count: Int) {
      var read = 0
      while (read < count) {
        val n =
          try {
            input.read(buffer, read, count - read)
          } catch (e: IOException) {
            throw SplatReadException(SplatFileProblem.DAMAGED, "stream damaged: ${e.message ?: e.javaClass.simpleName}")
          }
        if (n < 0) throw SplatReadException(SplatFileProblem.DAMAGED, "the file ends too early")
        read += n
      }
    }

    fun skip(count: Long) {
      val scratch = ByteArray(1 shl 16)
      var left = count
      while (left > 0) {
        val n = minOf(left, scratch.size.toLong()).toInt()
        read(scratch, n)
        left -= n
      }
    }

    /** Reads what is left to the end of the stream; damaged as [read] is when the stream fails before its end */
    fun drain(cancelled: () -> Boolean) {
      val scratch = ByteArray(1 shl 16)
      while (true) {
        if (cancelled()) throw SplatCancelledException()
        val n =
          try {
            input.read(scratch, 0, scratch.size)
          } catch (e: IOException) {
            val why = e.message ?: e.javaClass.simpleName
            throw SplatReadException(SplatFileProblem.DAMAGED, "stream damaged after the data: $why")
          }
        if (n < 0) return
      }
    }
  }

  /** [out] whose close does nothing: the caller owns it */
  private class NoClose(private val out: OutputStream) : OutputStream() {
    override fun write(b: Int) = out.write(b)

    override fun write(b: ByteArray, off: Int, len: Int) = out.write(b, off, len)

    override fun flush() = out.flush()

    override fun close() = out.flush()
  }
}
