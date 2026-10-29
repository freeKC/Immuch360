package app.alextran.immich.immersive

import app.alextran.immich.relief.ReliefMap
import app.alextran.immich.relief.ReliefPreprocess
import app.alextran.immich.relief.ReliefV1
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

// The 2.5D view of a relief on the Meta Quest (design-final 2026-10-26, section 3.3, lot A11): the photo on a grid
// moved by its depth map, so that the scene answers the head as well as the eyes. Experimental, offered on the 3D
// button of the quad next to the stereo view, which stays the default until FreeKC's comfort session. Plain JVM code,
// without Android nor the Spatial SDK: the viewer hands the arrays to a TriangleMesh (ImmersiveViewerActivity), the
// unit tests read them as they are.

/**
 * Where the photo of a relief stands in front of the eyes at the start pose: on the plane of the quad at [distance]
 * meters, [width] x [height] meters (the photo only, its gutters left out), with the settings of relief-v1 the request
 * gave
 */
internal data class ReliefView(
  val distance: Double,
  val width: Double,
  val height: Double,
  val parallax: Double = ReliefV1.PARALLAX,
  val convergence: Double = ReliefV1.CONVERGENCE,
) {
  companion object {
    /** The photo of the quad [angleDeg] wide that shows an eye of [eyeWidth] x [eyeHeight] (StereoComposer.quadSize) */
    fun forQuad(angleDeg: Float, eyeWidth: Int, eyeHeight: Int, parallax: Double, convergence: Double): ReliefView {
      val (quadWidth, quadHeight) = StereoComposer.quadSize(angleDeg, eyeWidth, eyeHeight)
      val gutters = 2.0 * StereoComposer.GUTTER
      return ReliefView(
        distance = StereoComposer.DISTANCE_M.toDouble(),
        width = quadWidth.toDouble() * eyeWidth / (eyeWidth + gutters),
        height = quadHeight.toDouble() * eyeHeight / (eyeHeight + gutters),
        parallax = parallax,
        convergence = convergence,
      )
    }
  }
}

/**
 * The mesh of the 2.5D view of [map], the depth map of a relief (0 far, 1 near), as the quad would show its photo:
 * 1. **A grid** of [columns] x [rows] vertices over the photo, one every [STEP] values of the map (173 x 131 for the
 *    686 x 518 map of the model), at most [MAX_COLUMNS] x [MAX_ROWS] whatever the map, so that one mesh of
 *    [MAX_VERTICES] vertices and [MAX_INDICES] indices serves every photo. The vertex (i, j) shows the point
 *    (i / (columns - 1), j / (rows - 1)) of the photo, from its top left corner, and its depth d is the map read in
 *    bilinear there, at the centres of its values, the edges repeated, as relief-v1 reads it.
 * 2. **Exact from the start pose.** Each vertex lies on the ray from the eyes at the start pose through its point of
 *    the photo on the plane of the quad: from there the mesh is the photo, pixel for pixel. Its depth along the gaze
 *    is Z, with `1 / Z = 1 / D + a * parallax * width * (d - convergence) / (IPD_M * D)`: two eyes IPD_M apart see the
 *    disparity relief-v1 gives the right eye (parallax * width * (convergence - d) on the plane of the quad), so the
 *    2.5D view keeps the relief of the stereo one, its middle on the plane of the quad. Z stays within [MIN_DEPTH_M]
 *    and [MAX_DEPTH_M].
 * 3. **Breaks left out.** A cell of the grid over two neighbouring values of the map that differ by more than
 *    relief-v1's LINK_THRESHOLD (the jump relief-v1 does not join either) has no triangle: no skin stretched between a
 *    person and the wall behind. The viewer puts the photo again on a backdrop just behind the farthest vertex
 *    ([farthest]), which shows through those gaps: from the start pose nothing is missing.
 * 4. **The relief fades with the head.** a, from 0 to 1, is the [attenuation] for the distance of the head from the
 *    start pose: the whole relief within FULL_RELIEF_M, none from FLAT_M, a smooth step between, without plateaus. The
 *    viewer moves the vertices again ([needsUpdate]) before a change could show.
 *
 * The positions are in the frame of the start pose: the eyes at the origin, +x to the right, +y up, +z along the gaze
 * (the frame StereoComposer.quadRotation gives). The texture is the one of the quad, both eyes side by side in their
 * gutters: the mesh reads the left eye, the photo itself, with the stereo mode None.
 */
internal class ReliefMesh(private val map: ReliefMap) {
  companion object {
    /** Values of the map between two vertices */
    const val STEP = 4

    /** The grid of the 686 x 518 map of the model, the largest the mesh takes */
    const val MAX_COLUMNS = (ReliefPreprocess.INPUT_WIDTH + STEP / 2) / STEP + 1
    const val MAX_ROWS = (ReliefPreprocess.INPUT_HEIGHT + STEP / 2) / STEP + 1
    const val MAX_VERTICES = MAX_COLUMNS * MAX_ROWS
    const val MAX_INDICES = 6 * (MAX_COLUMNS - 1) * (MAX_ROWS - 1)

    /** The distance between the eyes the relief is matched to, the mean of adults */
    const val IPD_M = 0.063

    /** The whole relief while the head stays this close to the start pose */
    const val FULL_RELIEF_M = 0.15

    /** No relief left from this far on: the mesh is the flat photo */
    const val FLAT_M = 0.60

    /** The nearest and the farthest a vertex goes, whatever the settings */
    const val MIN_DEPTH_M = 0.5
    const val MAX_DEPTH_M = 50.0

    /** The vertices move again once the attenuation changed by this much, and at both ends */
    const val ATTENUATION_STEP = 0.005

    /** The relief kept with the head [headDistance] meters from the start pose: 1, then a smooth step down to 0 */
    fun attenuation(headDistance: Double): Double {
      val t = ((headDistance - FULL_RELIEF_M) / (FLAT_M - FULL_RELIEF_M)).coerceIn(0.0, 1.0)
      return 1.0 - t * t * (3.0 - 2.0 * t)
    }

    /** Whether the vertices placed for the attenuation [shown] must move for [next] */
    fun needsUpdate(shown: Double, next: Double): Boolean =
      abs(next - shown) >= ATTENUATION_STEP || (next != shown && (next == 0.0 || next == 1.0))

    private fun gridSize(values: Int, max: Int): Int = ((values + STEP / 2) / STEP + 1).coerceIn(2, max)
  }

  val columns: Int = gridSize(map.width, MAX_COLUMNS)
  val rows: Int = gridSize(map.height, MAX_ROWS)
  val vertexCount: Int
    get() = columns * rows

  // The depth of each vertex, row after row
  private val depths = DoubleArray(columns * rows)

  // The cells drawn, (columns - 1) x (rows - 1) row after row
  private val kept = BooleanArray((columns - 1) * (rows - 1))

  // The depths of the nearest and of the farthest vertex
  private val nearValue: Double
  private val farValue: Double

  init {
    val xs = DoubleArray(columns) { i -> i.toDouble() / (columns - 1) * map.width - 0.5 }
    val ys = DoubleArray(rows) { j -> j.toDouble() / (rows - 1) * map.height - 0.5 }
    for (j in 0 until rows) {
      for (i in 0 until columns) depths[j * columns + i] = bilinear(xs[i], ys[j])
    }
    nearValue = depths.max()
    farValue = depths.min()
    val across = breaksAcross()
    val down = breaksDown()
    for (j in 0 until rows - 1) {
      val top = clampIndex(floor(ys[j]).toInt(), map.height)
      val bottom = clampIndex(ceil(ys[j + 1]).toInt(), map.height)
      for (i in 0 until columns - 1) {
        val left = clampIndex(floor(xs[i]).toInt(), map.width)
        val right = clampIndex(ceil(xs[i + 1]).toInt(), map.width)
        kept[j * (columns - 1) + i] = !hasBreak(across, down, left, right, top, bottom)
      }
    }
  }

  /** The normalised depth of the vertex [vertex], 0 far, 1 near */
  fun depth(vertex: Int): Double = depths[vertex]

  /**
   * u, v of each vertex on the texture of the quad, both eyes of [eyeWidth] x [eyeHeight] side by side in their gutters
   * (StereoComposer.compose): the left eye, the photo itself. [MAX_VERTICES] pairs, those past [vertexCount] at 0.
   */
  fun textureCoordinates(eyeWidth: Int, eyeHeight: Int, out: FloatArray = FloatArray(2 * MAX_VERTICES)): FloatArray {
    require(out.size == 2 * MAX_VERTICES) { "room for $MAX_VERTICES vertices" }
    val (textureWidth, textureHeight) = StereoComposer.textureSize(eyeWidth, eyeHeight)
    val gutter = StereoComposer.GUTTER.toDouble()
    out.fill(0f)
    for (j in 0 until rows) {
      val v = ((gutter + j.toDouble() / (rows - 1) * eyeHeight) / textureHeight).toFloat()
      for (i in 0 until columns) {
        val k = j * columns + i
        out[2 * k] = ((gutter + i.toDouble() / (columns - 1) * eyeWidth) / textureWidth).toFloat()
        out[2 * k + 1] = v
      }
    }
    return out
  }

  /**
   * The two triangles of each cell drawn, then triangles of no area up to [MAX_INDICES]: the mesh keeps its size from
   * one photo to the next
   */
  fun indices(): IntArray {
    val out = IntArray(MAX_INDICES)
    var n = 0
    for (j in 0 until rows - 1) {
      for (i in 0 until columns - 1) {
        if (!kept[j * (columns - 1) + i]) continue
        val topLeft = j * columns + i
        val bottomLeft = topLeft + columns
        out[n++] = topLeft
        out[n++] = bottomLeft
        out[n++] = topLeft + 1
        out[n++] = topLeft + 1
        out[n++] = bottomLeft
        out[n++] = bottomLeft + 1
      }
    }
    return out
  }

  /**
   * x, y, z of each vertex for [view] with the relief scaled by [attenuation] (0 flat, 1 whole), in the frame of the
   * start pose, in [out]: [MAX_VERTICES] triples, those past [vertexCount] at the origin
   */
  fun positions(view: ReliefView, attenuation: Double, out: FloatArray = FloatArray(3 * MAX_VERTICES)): FloatArray {
    require(out.size == 3 * MAX_VERTICES) { "room for $MAX_VERTICES vertices" }
    val scale = attenuation * slope(view)
    for (j in 0 until rows) {
      // The point of the photo on the plane of the quad, then along its ray to the depth of the vertex
      val y = (0.5 - j.toDouble() / (rows - 1)) * view.height / view.distance
      for (i in 0 until columns) {
        val k = j * columns + i
        val z = depthAlongGaze(view, scale, depths[k])
        out[3 * k] = ((i.toDouble() / (columns - 1) - 0.5) * view.width / view.distance * z).toFloat()
        out[3 * k + 1] = (y * z).toFloat()
        out[3 * k + 2] = z.toFloat()
      }
    }
    out.fill(0f, 3 * vertexCount, out.size)
    return out
  }

  /** The depth along the gaze of the farthest vertex for [view] and [attenuation], where the backdrop goes */
  fun farthest(view: ReliefView, attenuation: Double): Double {
    val scale = attenuation * slope(view)
    return max(depthAlongGaze(view, scale, farValue), depthAlongGaze(view, scale, nearValue))
  }

  /** How much the inverse of the depth changes per unit of map value, for the whole relief */
  private fun slope(view: ReliefView): Double = view.parallax * view.width / (IPD_M * view.distance)

  private fun depthAlongGaze(view: ReliefView, scale: Double, d: Double): Double {
    val inverse = 1.0 / view.distance + scale * (d - view.convergence)
    return 1.0 / inverse.coerceIn(1.0 / MAX_DEPTH_M, 1.0 / MIN_DEPTH_M)
  }

  private fun value(x: Int, y: Int): Double = map.level(y * map.width + x) / ReliefMap.MAX_LEVEL.toDouble()

  private fun bilinear(x: Double, y: Double): Double {
    val cx = x.coerceIn(0.0, map.width - 1.0)
    val cy = y.coerceIn(0.0, map.height - 1.0)
    val x0 = floor(cx).toInt()
    val y0 = floor(cy).toInt()
    val x1 = min(x0 + 1, map.width - 1)
    val y1 = min(y0 + 1, map.height - 1)
    val fx = cx - x0
    val fy = cy - y0
    val upper = value(x0, y0) + (value(x1, y0) - value(x0, y0)) * fx
    val lower = value(x0, y1) + (value(x1, y1) - value(x0, y1)) * fx
    return upper + (lower - upper) * fy
  }

  /** For each value but the last of its row, whether the next one along the row is a break away */
  private fun breaksAcross(): BooleanArray {
    val width = map.width
    val out = BooleanArray(max(0, width - 1) * map.height)
    for (y in 0 until map.height) {
      for (x in 0 until width - 1) out[y * (width - 1) + x] = isBreak(value(x, y), value(x + 1, y))
    }
    return out
  }

  /** For each value but those of the last row, whether the one below is a break away */
  private fun breaksDown(): BooleanArray {
    val width = map.width
    val out = BooleanArray(width * max(0, map.height - 1))
    for (y in 0 until map.height - 1) {
      for (x in 0 until width) out[y * width + x] = isBreak(value(x, y), value(x, y + 1))
    }
    return out
  }

  private fun isBreak(a: Double, b: Double): Boolean = abs(a - b) > ReliefV1.LINK_THRESHOLD

  /**
   * Whether two neighbouring values within the columns [left] to [right] and the rows [top] to [bottom] of the map are
   * a break away. The values a vertex of the cell reads in bilinear are in that window, so a cell drawn never joins a
   * vertex that mixes both sides of a break.
   */
  private fun hasBreak(
    across: BooleanArray,
    down: BooleanArray,
    left: Int,
    right: Int,
    top: Int,
    bottom: Int,
  ): Boolean {
    val width = map.width
    for (y in top..bottom) {
      for (x in left until right) if (across[y * (width - 1) + x]) return true
    }
    for (y in top until bottom) {
      for (x in left..right) if (down[y * width + x]) return true
    }
    return false
  }

  private fun clampIndex(i: Int, size: Int): Int = min(size - 1, max(0, i))
}
