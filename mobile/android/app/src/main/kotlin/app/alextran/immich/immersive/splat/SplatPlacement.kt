package app.alextran.immich.immersive.splat

import java.util.BitSet
import java.util.Locale

/**
 * The robust bounds of the positions of a splat, in the numbers of its file: the percentiles 5 and 95 of each axis
 * ([low] and [high]), so that a few gaussians far away (the floaters of a capture) do not move it.
 */
internal class SplatBounds(val low: DoubleArray, val high: DoubleArray) {
  val center: DoubleArray
    get() = DoubleArray(3) { (low[it] + high[it]) / 2 }

  val extent: DoubleArray
    get() = DoubleArray(3) { high[it] - low[it] }

  /** The largest of the three extents: the same whichever axis is up, since the orientations swap axes only */
  val size: Double
    get() = extent.max()

  override fun toString(): String =
    "SplatBounds(${low.joinToString { String.format(Locale.ROOT, "%.3f", it) }} to " +
      "${high.joinToString { String.format(Locale.ROOT, "%.3f", it) }})"
}

/**
 * Which axis of the file is up in the world, the rotation of the splat about the x axis of the Spatial SDK by
 * [pitchDegrees]: Quaternion(pitchDegrees, 0f, 0f). Turn upright goes to the [next] one, and the choice is remembered
 * for the file ([SplatUprightMemory]).
 *
 * [Z_UP] is the rotation of Meta's SplatSample (MIT, Meta-Spatial-SDK-Samples, SplatSampleActivity: "-90 degrees on X
 * axis converts from original Splat coordinate space to Spatial SDK space"), so the first one a file shows in. How
 * the module maps the axes of an SPZ (right, up, back, by its specification) and of a PLY (often right, down,
 * forward, as the captures of COLMAP) is not documented: the axes of make_splat_fixtures.py tell it in the headset.
 */
internal enum class SplatUpright(val key: String, val pitchDegrees: Float) {
  Y_UP("yUp", 0f),
  Z_UP("zUp", -90f),
  Y_DOWN("yDown", 180f);

  /** The orientation after this one: Y up, Z up, Y down, then Y up again */
  fun next(): SplatUpright = entries[(ordinal + 1) % entries.size]

  companion object {
    val DEFAULT = Z_UP

    fun of(key: String?): SplatUpright? = entries.firstOrNull { it.key == key }
  }
}

/**
 * Where a splat goes when it opens, at Reset and at Turn upright (lot S5): from its bounds, an object (under
 * [OBJECT_LIMIT] on its largest side) has its centre in front of the user, [OBJECT_GAP] plus half its size away and
 * [OBJECT_DROP] under the eyes; a scene (a room, a street) has its centre right where the user stands, [SCENE_DROP]
 * under the eyes, so that the user is inside it. A splat without positions read (a version 4 SPZ) has the origin of
 * its file [UNKNOWN_DISTANCE] ahead, [SCENE_DROP] under the eyes.
 *
 * The frame is that of the anchor of the splat (SceneNavigator.anchorInSdk at the head, its yaw only): the numbers of
 * the Spatial SDK, x to the right, y up, z ahead. The viewer rotates the centre of the bounds by the orientation with
 * the quaternion of the SDK itself (Quaternion(pitchDegrees, 0f, 0f) times the centre), then [localPosition] gives the
 * position of the entity in that frame, and the root of the navigator, which carries the glide, puts it in the world.
 * Pure JVM, tested by SplatPlacementTest.
 */
internal object SplatPlacement {
  const val OBJECT_LIMIT = 2.5
  const val OBJECT_GAP = 0.6
  const val OBJECT_DROP = 0.2
  const val SCENE_DROP = 0.3
  const val UNKNOWN_DISTANCE = 2.0
  const val LOW_PERCENTILE = 5
  const val HIGH_PERCENTILE = 95

  /** The bounds of the positions [scan] sampled, of the kept gaussians only when [kept] is given; null without any */
  fun boundsOf(scan: SplatScan, kept: BitSet?): SplatBounds? {
    val chosen = (0 until scan.sampleCount).filter { kept == null || kept[scan.sampleIndices[it]] }
    if (chosen.isEmpty()) return null
    val low = DoubleArray(3)
    val high = DoubleArray(3)
    for (axis in 0 until 3) {
      val values = DoubleArray(chosen.size) { scan.samplePositions[3 * chosen[it] + axis].toDouble() }
      if (values.any { !it.isFinite() }) return null
      values.sort()
      low[axis] = percentile(values, LOW_PERCENTILE)
      high[axis] = percentile(values, HIGH_PERCENTILE)
    }
    return SplatBounds(low, high)
  }

  /** The value of rank max(1, (P * N + 99) / 100) of the [sorted] values, as relief-v1 takes its percentiles */
  fun percentile(sorted: DoubleArray, p: Int): Double {
    val rank = maxOf(1, (p * sorted.size + 99) / 100)
    return sorted[rank - 1]
  }

  /** Whether the splat of [bounds] is an object to look at, rather than a place to stand in */
  fun isObject(bounds: SplatBounds?): Boolean = bounds != null && bounds.size < OBJECT_LIMIT

  /** Where the centre of the splat goes, in the frame of the anchor: x right, y up, z ahead */
  fun target(bounds: SplatBounds?): DoubleArray =
    when {
      bounds == null -> doubleArrayOf(0.0, -SCENE_DROP, UNKNOWN_DISTANCE)
      isObject(bounds) -> doubleArrayOf(0.0, -OBJECT_DROP, OBJECT_GAP + bounds.size / 2)
      else -> doubleArrayOf(0.0, -SCENE_DROP, 0.0)
    }

  /**
   * The position of the entity in the frame of the anchor, for the centre of its bounds rotated by its orientation
   * ([rotatedCenter], 0 without bounds): the target less that centre
   */
  fun localPosition(bounds: SplatBounds?, rotatedCenter: DoubleArray): DoubleArray {
    val target = target(bounds)
    if (bounds == null) return target
    return DoubleArray(3) { target[it] - rotatedCenter[it] }
  }
}

/** Where the orientation of each file is kept: SharedPreferences in the viewer, a map in the tests */
internal interface SplatUprightStore {
  fun read(key: String): String?

  fun write(key: String, value: String)
}

/**
 * The orientation the user chose for a file with Turn upright, by its name and its size (lot S5): the same file found
 * again, on a share or picked from the headset, opens upright at once
 */
internal class SplatUprightMemory(private val store: SplatUprightStore) {
  fun keyOf(name: String, fileBytes: Long): String = "upright:$fileBytes:$name"

  fun read(name: String, fileBytes: Long): SplatUpright = SplatUpright.of(store.read(keyOf(name, fileBytes))) ?: SplatUpright.DEFAULT

  fun write(name: String, fileBytes: Long, upright: SplatUpright) = store.write(keyOf(name, fileBytes), upright.key)
}
