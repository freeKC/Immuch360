package app.alextran.immich.relief

import java.util.concurrent.CancellationException
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

// relief-v1 on the Meta Quest: the right eye of a flat photo made from its estimated depth, so that the stereo quad
// shows it in relief (design-final 2026-10-26, sections 2.4 and 3.4). The computers make the same right eye in Dart
// (lib/desktop/ai/relief); the two are held to the golden fixture
// mobile/test/fixtures/ai_immersive/relief_golden_v1.json that .github/desktop/ai/make_relief_golden.py writes, whose
// header is the reference of the algorithm. Plain JVM code, without Android, so that the unit tests run it as the
// headset does.

/** The settings and constants of relief-v1, the values of ReliefV1 in lib/domain/models/ai_immersive */
object ReliefV1 {
  const val PIPELINE = "relief-v1"

  /** Width of the whole relief, from the nearest to the farthest, as a fraction of the width of the eye */
  const val PARALLAX = 0.02

  /** The normalised depth that stays in place: the middle of the relief is on the plane of the quad */
  const val CONVERGENCE = 0.5

  /** Two neighbours whose depths differ by more than this are not joined: the gap between them is a hole */
  const val LINK_THRESHOLD = 0.04

  /** The foreground grows by this many values of the map on each side (a window of 5 x 5) */
  const val DILATION_RADIUS = 2
  const val DILATION_WINDOW = 2 * DILATION_RADIUS + 1

  const val LOW_PERCENTILE = 2
  const val HIGH_PERCENTILE = 98

  /** lowRelief when `p98 - p2` is under this fraction of p98 */
  const val LOW_RELIEF_RATIO = 0.1

  /** hiddenAreas when more than this fraction of the pixels were filled */
  const val HIDDEN_AREAS_RATIO = 0.05

  /** dark when the mean Rec. 709 luma of the photo is under this, out of 255 */
  const val DARK_LUMA = 20.0

  /** The right eye looks for a cancellation once every this many rows */
  const val CANCEL_CHECK_ROWS = 64
}

/** The warnings relief-v1 raises on a photo, in the order of Immuch360:QualityFlags */
enum class ReliefFlag(val xmp: String) {
  /** Little depth found: the relief may be weak */
  LOW_RELIEF("lowRelief"),

  /** Many pixels hidden in the photo were filled in */
  HIDDEN_AREAS("hiddenAreas"),

  /** A dark photo: the relief may be wrong */
  DARK("dark"),
}

/**
 * A depth map normalised by step 1 of relief-v1: [values] from 0 (far) to 1 (near), [width] x [height] row after row,
 * [p2] and [p98] the percentiles of the raw map, [lowRelief] the first flag
 */
class NormalizedDepth(
  val width: Int,
  val height: Int,
  val values: DoubleArray,
  val p2: Double,
  val p98: Double,
  val lowRelief: Boolean,
)

/** What relief-v1 says of a right eye it made */
class RightEye(val filledPixels: Int, val meanLuma: Double, val flags: List<ReliefFlag>)

/** Gives the row [y] of a picture as ARGB pixels in [out], as Bitmap.getPixels does */
fun interface PixelRowReader {
  fun read(y: Int, out: IntArray)
}

/** Takes the row [y] of a picture as ARGB pixels, as Bitmap.setPixels does; [row] is reused for the next row */
fun interface PixelRowWriter {
  fun write(y: Int, row: IntArray)
}

/**
 * relief-v1, step by step in the order of make_relief_golden.py and in double precision, so that every comparison that
 * decides a hole or an occlusion goes the same way as in Python and in Dart.
 *
 * The left eye is the photo itself and is never written. The right eye is made row by row: only a few rows of doubles
 * are held besides the map, whatever the size of the photo.
 */
object ReliefSynthesizer {
  /** The value of rank `max(1, (percent * n + 99) / 100)` of [sorted], ranks from 1 (nearest rank) */
  fun percentile(sorted: DoubleArray, percent: Int): Double {
    require(sorted.isNotEmpty())
    val rank = max(1L, (percent.toLong() * sorted.size + 99) / 100)
    return sorted[(rank - 1).toInt()]
  }

  /** Step 1 on the float map the model gives */
  fun normalize(depth: FloatArray, width: Int, height: Int): NormalizedDepth =
    normalize(DoubleArray(depth.size) { depth[it].toDouble() }, width, height)

  /**
   * Step 1: `d = (D - p2) / (p98 - p2)`, clamped to [0, 1], 0.5 everywhere when `p98 - p2` is not positive. A value
   * that is not finite (a model that went wrong) is left out of the percentiles and becomes 1 for +infinity, 0 for
   * -infinity and 0.5 for NaN, as on the computers (lib/desktop/ai/relief/relief_map.dart); a map with no finite value
   * is taken as flat.
   */
  fun normalize(depth: DoubleArray, width: Int, height: Int): NormalizedDepth {
    require(width > 0 && height > 0 && depth.size == width * height) { "a map of $width x $height" }
    val finite = depth.filter { it.isFinite() }.toDoubleArray()
    if (finite.isEmpty()) {
      return NormalizedDepth(width, height, DoubleArray(depth.size) { 0.5 }, 0.0, 0.0, true)
    }
    finite.sort()
    val p2 = percentile(finite, ReliefV1.LOW_PERCENTILE)
    val p98 = percentile(finite, ReliefV1.HIGH_PERCENTILE)
    val spread = p98 - p2
    val lowRelief = spread <= 0 || spread < ReliefV1.LOW_RELIEF_RATIO * abs(p98)
    if (spread <= 0) {
      return NormalizedDepth(width, height, DoubleArray(depth.size) { 0.5 }, p2, p98, lowRelief)
    }
    val values =
      DoubleArray(depth.size) { i ->
        val v = (depth[i] - p2) / spread
        when {
          v.isNaN() -> 0.5
          v < 0.0 -> 0.0
          v > 1.0 -> 1.0
          else -> v
        }
      }
    return NormalizedDepth(width, height, values, p2, p98, lowRelief)
  }

  /**
   * Step 2: each value becomes the largest of the 5 x 5 window around it, cut at the edges. Done as a maximum over the
   * rows then over the columns, which picks the same value.
   */
  fun dilate(values: DoubleArray, width: Int, height: Int): DoubleArray {
    require(width > 0 && height > 0 && values.size == width * height) { "a map of $width x $height" }
    val radius = ReliefV1.DILATION_RADIUS
    val across = DoubleArray(values.size)
    for (y in 0 until height) {
      val row = y * width
      for (x in 0 until width) {
        var best = values[row + x]
        for (xx in max(0, x - radius)..min(width - 1, x + radius)) {
          if (values[row + xx] > best) best = values[row + xx]
        }
        across[row + x] = best
      }
    }
    val out = DoubleArray(values.size)
    for (y in 0 until height) {
      for (x in 0 until width) {
        var best = across[y * width + x]
        for (yy in max(0, y - radius)..min(height - 1, y + radius)) {
          if (across[yy * width + x] > best) best = across[yy * width + x]
        }
        out[y * width + x] = best
      }
    }
    return out
  }

  /**
   * Step 3: the dilated [map] of [mapWidth] x [mapHeight] read in bilinear at the centre of each pixel of an eye of
   * [eyeWidth] x [eyeHeight], one row at a time, the edges repeated
   */
  class EyeDepth(
    private val map: DoubleArray,
    private val mapWidth: Int,
    private val mapHeight: Int,
    private val eyeWidth: Int,
    private val eyeHeight: Int,
  ) {
    private val left = IntArray(eyeWidth)
    private val right = IntArray(eyeWidth)
    private val fx = DoubleArray(eyeWidth)

    init {
      require(mapWidth > 0 && mapHeight > 0 && map.size == mapWidth * mapHeight) { "a map of $mapWidth x $mapHeight" }
      require(eyeWidth > 0 && eyeHeight > 0) { "an eye of $eyeWidth x $eyeHeight" }
      for (x in 0 until eyeWidth) {
        val u = (x + 0.5) * mapWidth / eyeWidth - 0.5
        val x0 = floor(u)
        fx[x] = u - x0
        left[x] = clamp(x0.toInt(), mapWidth)
        right[x] = clamp(x0.toInt() + 1, mapWidth)
      }
    }

    /** The depth of each pixel of the row [y] of the eye, in [out] */
    fun row(y: Int, out: DoubleArray) {
      val v = (y + 0.5) * mapHeight / eyeHeight - 0.5
      val y0 = floor(v)
      val fy = v - y0
      val top = clamp(y0.toInt(), mapHeight) * mapWidth
      val bottom = clamp(y0.toInt() + 1, mapHeight) * mapWidth
      for (x in 0 until eyeWidth) {
        val a = map[top + left[x]]
        val b = map[top + right[x]]
        val e = map[bottom + left[x]]
        val f = map[bottom + right[x]]
        val upper = a + (b - a) * fx[x]
        val lower = e + (f - e) * fx[x]
        out[x] = upper + (lower - upper) * fy
      }
    }

    private fun clamp(i: Int, size: Int) = min(size - 1, max(0, i))
  }

  /**
   * The right eye of the photo [left] ([width] x [height] ARGB pixels) in [out], from its [map] normalised by step 1
   * ([NormalizedDepth.values], or a map of the cache), steps 2 to 7. [lowRelief] is the flag of step 1, which the map
   * no longer tells. [holes] receives the mask of the filled pixels of each row, for the tests.
   *
   * @throws CancellationException when [cancelled] says so, checked every [ReliefV1.CANCEL_CHECK_ROWS] rows
   */
  fun rightEye(
    left: IntArray,
    width: Int,
    height: Int,
    map: DoubleArray,
    mapWidth: Int,
    mapHeight: Int,
    out: IntArray,
    parallax: Double = ReliefV1.PARALLAX,
    convergence: Double = ReliefV1.CONVERGENCE,
    lowRelief: Boolean = false,
    cancelled: () -> Boolean = { false },
    holes: ((Int, BooleanArray) -> Unit)? = null,
  ): RightEye {
    require(width > 0 && height > 0 && left.size >= width * height) { "a photo of $width x $height" }
    require(out.size >= width * height) { "an eye of $width x $height" }
    require(out !== left) { "the left eye is never written" }
    return rightEye(
      width,
      height,
      map,
      mapWidth,
      mapHeight,
      read = { y, row -> left.copyInto(row, 0, y * width, (y + 1) * width) },
      write = { y, row -> row.copyInto(out, y * width, 0, width) },
      parallax = parallax,
      convergence = convergence,
      lowRelief = lowRelief,
      cancelled = cancelled,
      holes = holes,
    )
  }

  /** [rightEye] reading the photo and writing the eye one row at a time, each row read once and in order */
  fun rightEye(
    width: Int,
    height: Int,
    map: DoubleArray,
    mapWidth: Int,
    mapHeight: Int,
    read: PixelRowReader,
    write: PixelRowWriter,
    parallax: Double = ReliefV1.PARALLAX,
    convergence: Double = ReliefV1.CONVERGENCE,
    lowRelief: Boolean = false,
    cancelled: () -> Boolean = { false },
    holes: ((Int, BooleanArray) -> Unit)? = null,
  ): RightEye {
    require(width > 0 && height > 0) { "a photo of $width x $height" }
    val eye = EyeDepth(dilate(map, mapWidth, mapHeight), mapWidth, mapHeight, width, height)
    val row = RowWork(width)
    val pixels = IntArray(width)
    var filled = 0
    var luma = 0.0
    for (y in 0 until height) {
      if (y % ReliefV1.CANCEL_CHECK_ROWS == 0 && cancelled()) throw CancellationException("relief cancelled")
      read.read(y, pixels)
      // Added one pixel after the other, as the reference does
      for (x in 0 until width) {
        val p = pixels[x]
        luma += 0.2126 * ((p shr 16) and 0xFF) + 0.7152 * ((p shr 8) and 0xFF) + 0.0722 * (p and 0xFF)
      }
      eye.row(y, row.depth)
      filled += row.project(pixels, parallax, convergence)
      holes?.invoke(y, row.hole)
      write.write(y, row.out)
    }
    val meanLuma = luma / (width.toLong() * height)
    return RightEye(filled, meanLuma, flags(lowRelief, filled, width, height, meanLuma))
  }

  /**
   * The flags of step 8 in their order: [lowRelief] from step 1, hiddenAreas past 5 % of the pixels filled (not at
   * 5 %), dark under a mean luma of 20 (not at 20), as reliefFlags does on the computers (relief_flags.dart)
   */
  fun flags(lowRelief: Boolean, filledPixels: Int, width: Int, height: Int, meanLuma: Double): List<ReliefFlag> =
    buildList {
      if (lowRelief) add(ReliefFlag.LOW_RELIEF)
      if (filledPixels > ReliefV1.HIDDEN_AREAS_RATIO * width * height) add(ReliefFlag.HIDDEN_AREAS)
      if (meanLuma < ReliefV1.DARK_LUMA) add(ReliefFlag.DARK)
    }

  /** The buffers of one row of the right eye, reused from row to row */
  private class RowWork(private val width: Int) {
    /** The depth of each pixel of the source row (step 3) */
    val depth = DoubleArray(width)
    val hole = BooleanArray(width)
    val out = IntArray(width)
    private val target = DoubleArray(width)
    private val written = DoubleArray(width)
    private val r = DoubleArray(width)
    private val g = DoubleArray(width)
    private val b = DoubleArray(width)

    /** Steps 4 to 6 on one row of the photo: [out] and [hole] filled, the number of filled pixels returned */
    fun project(pixels: IntArray, parallax: Double, convergence: Double): Int {
      val d = depth
      for (x in 0 until width) target[x] = x + (parallax * width) * (convergence - d[x])
      written.fill(Double.NEGATIVE_INFINITY)
      for (x in 0 until width) {
        val p0 = pixels[x]
        val r0 = (p0 shr 16) and 0xFF
        val g0 = (p0 shr 8) and 0xFF
        val b0 = p0 and 0xFF
        put(floor(target[x] + 0.5), d[x], r0.toDouble(), g0.toDouble(), b0.toDouble())
        if (x + 1 < width && abs(d[x] - d[x + 1]) <= ReliefV1.LINK_THRESHOLD) {
          val p1 = pixels[x + 1]
          val r1 = (p1 shr 16) and 0xFF
          val g1 = (p1 shr 8) and 0xFF
          val b1 = p1 and 0xFF
          val t0 = target[x]
          val t1 = target[x + 1]
          // The columns outside the eye are skipped, as the reference skips them one by one
          val first = max(0.0, ceil(min(t0, t1)))
          val last = min(width - 1.0, floor(max(t0, t1)))
          var column = first
          while (column <= last) {
            val a = if (t1 != t0) (column - t0) / (t1 - t0) else 0.0
            put(column, d[x] + (d[x + 1] - d[x]) * a, r0 + (r1 - r0) * a, g0 + (g1 - g0) * a, b0 + (b1 - b0) * a)
            column += 1.0
          }
        }
      }
      var filled = 0
      for (x in 0 until width) {
        hole[x] = written[x] == Double.NEGATIVE_INFINITY
        if (hole[x]) filled++
      }
      fill()
      blurAndRound()
      return filled
    }

    /** A write takes the column only when it is nearer than what is there: the first one wins on a tie */
    private fun put(column: Double, dd: Double, rr: Double, gg: Double, bb: Double) {
      if (column < 0.0 || column > width - 1.0) return
      val c = column.toInt()
      if (dd > written[c]) {
        written[c] = dd
        r[c] = rr
        g[c] = gg
        b[c] = bb
      }
    }

    /** Step 6, first half: each run of holes takes the colour of its background neighbour, black with none */
    private fun fill() {
      var x = 0
      while (x < width) {
        if (!hole[x]) {
          x++
          continue
        }
        val start = x
        while (x < width && hole[x]) x++
        val end = x - 1
        val leftSide = if (start > 0) start - 1 else -1
        val rightSide = if (end + 1 < width) end + 1 else -1
        val source =
          when {
            leftSide >= 0 && rightSide >= 0 -> if (written[leftSide] <= written[rightSide]) leftSide else rightSide
            leftSide >= 0 -> leftSide
            else -> rightSide
          }
        for (column in start..end) {
          if (source >= 0) {
            r[column] = r[source]
            g[column] = g[source]
            b[column] = b[source]
          } else {
            r[column] = 0.0
            g[column] = 0.0
            b[column] = 0.0
          }
        }
      }
    }

    /** Step 6, second half: a filled pixel is the mean of itself and its two neighbours on the filled row; rounding */
    private fun blurAndRound() {
      for (x in 0 until width) {
        if (!hole[x]) {
          out[x] = argb(r[x], g[x], b[x])
          continue
        }
        val before = max(0, x - 1)
        val after = min(width - 1, x + 1)
        out[x] =
          argb((r[before] + r[x] + r[after]) / 3, (g[before] + g[x] + g[after]) / 3, (b[before] + b[x] + b[after]) / 3)
      }
    }

    private fun argb(rr: Double, gg: Double, bb: Double) =
      (0xFF shl 24) or (toByte(rr) shl 16) or (toByte(gg) shl 8) or toByte(bb)

    private fun toByte(value: Double): Int = min(255.0, max(0.0, floor(value + 0.5))).toInt()
  }
}
