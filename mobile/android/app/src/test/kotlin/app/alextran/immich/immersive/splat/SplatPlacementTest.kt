package app.alextran.immich.immersive.splat

import kotlin.math.cos
import kotlin.math.sin
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Where a splat goes (lot S5): an object in front of the user, a scene around the user, a splat without positions
 * ahead; the orientations of Turn upright and their memory.
 */
class SplatPlacementTest {
  /** Quaternion(pitch, 0, 0) applied to a vector by the usual formula (v' = q v q*): what the SDK is taken to do */
  private fun rotate(upright: SplatUpright, v: DoubleArray): DoubleArray {
    val a = Math.toRadians(upright.pitchDegrees.toDouble())
    return doubleArrayOf(v[0], v[1] * cos(a) - v[2] * sin(a), v[1] * sin(a) + v[2] * cos(a))
  }

  private fun bounds(low: DoubleArray, high: DoubleArray) = SplatBounds(low, high)

  @Test
  fun `an object has its centre in front, at 0_6 m plus half its size, under the eyes`() {
    // The axes: 1 m, 1.5 m and 2 m long
    val axes = bounds(doubleArrayOf(-0.01, -0.01, -0.01), doubleArrayOf(0.66, 1.16, 1.66))
    assertTrue(SplatPlacement.isObject(axes))
    assertArrayEquals(doubleArrayOf(0.0, -0.2, 0.6 + 1.67 / 2), SplatPlacement.target(axes), 1e-9)
    // Upright with Z up, its centre comes where the target is
    for (upright in SplatUpright.entries) {
      val local = SplatPlacement.localPosition(axes, rotate(upright, axes.center))
      val centre = rotate(upright, axes.center)
      assertArrayEquals(
        upright.name,
        SplatPlacement.target(axes),
        doubleArrayOf(local[0] + centre[0], local[1] + centre[1], local[2] + centre[2]),
        1e-9,
      )
    }
  }

  @Test
  fun `a scene has its centre where the user stands, 0_3 m under the eyes`() {
    val room = bounds(doubleArrayOf(-2.0, 0.0, -2.0), doubleArrayOf(2.0, 2.4, 2.0))
    assertFalse(SplatPlacement.isObject(room))
    assertArrayEquals(doubleArrayOf(0.0, -0.3, 0.0), SplatPlacement.target(room), 1e-9)
    // The floor of the room 1.5 m under the eyes, upright with Y up
    val local = SplatPlacement.localPosition(room, rotate(SplatUpright.Y_UP, room.center))
    assertEquals(-1.5, local[1], 1e-9)
    // At 2.5 m on its largest side a splat is a scene
    assertFalse(SplatPlacement.isObject(bounds(doubleArrayOf(0.0, 0.0, 0.0), doubleArrayOf(2.5, 0.1, 0.1))))
  }

  @Test
  fun `a splat without positions has the origin of its file ahead`() {
    assertFalse(SplatPlacement.isObject(null))
    assertArrayEquals(doubleArrayOf(0.0, -0.3, 2.0), SplatPlacement.localPosition(null, doubleArrayOf(5.0, 5.0, 5.0)), 1e-9)
    assertNull(SplatPlacement.boundsOf(SplatScan(FloatArray(0), IntArray(0), FloatArray(0)), null))
  }

  @Test
  fun `the bounds leave the far few out`() {
    // 100 points on a line of 1 m, and 4 floaters 50 m away
    val count = 104
    val positions = FloatArray(3 * count) { i ->
      val point = i / 3
      when {
        point >= 100 -> 50f
        i % 3 == 0 -> point / 100f
        else -> 0f
      }
    }
    val scan = SplatScan(FloatArray(count), IntArray(count) { it }, positions)
    val bounds = SplatPlacement.boundsOf(scan, null)!!
    assertEquals(0.05, bounds.low[0], 1e-6)
    assertEquals(0.98, bounds.high[0], 1e-6)
    assertTrue(SplatPlacement.isObject(bounds))
  }

  @Test
  fun `turn upright goes Y up, Z up, Y down and back, from Z up as Meta's sample`() {
    assertEquals(SplatUpright.Z_UP, SplatUpright.DEFAULT)
    assertEquals(-90f, SplatUpright.Z_UP.pitchDegrees)
    assertEquals(SplatUpright.Y_DOWN, SplatUpright.Z_UP.next())
    assertEquals(SplatUpright.Y_UP, SplatUpright.Y_DOWN.next())
    assertEquals(SplatUpright.Z_UP, SplatUpright.Y_UP.next())
    // With the usual formula, Z up takes +z of the file up, Y down takes +y down
    assertArrayEquals(doubleArrayOf(0.0, 1.0, 0.0), rotate(SplatUpright.Z_UP, doubleArrayOf(0.0, 0.0, 1.0)), 1e-9)
    assertArrayEquals(doubleArrayOf(0.0, -1.0, 0.0), rotate(SplatUpright.Y_DOWN, doubleArrayOf(0.0, 1.0, 0.0)), 1e-9)
  }

  @Test
  fun `the orientation chosen is remembered by the name and the size of the file`() {
    val values = mutableMapOf<String, String>()
    val memory =
      SplatUprightMemory(
        object : SplatUprightStore {
          override fun read(key: String): String? = values[key]

          override fun write(key: String, value: String) {
            values[key] = value
          }
        }
      )
    assertEquals(SplatUpright.DEFAULT, memory.read("room.ply", 1000))
    memory.write("room.ply", 1000, SplatUpright.Y_DOWN)
    assertEquals(SplatUpright.Y_DOWN, memory.read("room.ply", 1000))
    // Another file of the same name is another file
    assertEquals(SplatUpright.DEFAULT, memory.read("room.ply", 1001))
    values[memory.keyOf("room.ply", 1001)] = "sideways"
    assertEquals(SplatUpright.DEFAULT, memory.read("room.ply", 1001))
  }
}
