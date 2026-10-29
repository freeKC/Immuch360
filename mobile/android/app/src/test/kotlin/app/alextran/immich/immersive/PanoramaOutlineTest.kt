package app.alextran.immich.immersive

import kotlin.math.abs
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.sqrt
import kotlin.math.tan
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The outline of the photo itself on a panorama we generated (design-final 2026-10-27, section 5, point 3): its four
 * arcs follow the edges of the photo as pano-v1 projects it (make_pano_golden.py, step 1: a pinhole camera of the
 * horizontal field of view of the photo, whose plane is met at x / z and y / z in a frame x right, y up, z ahead).
 */
class PanoramaOutlineTest {
  // The photo of the panorama sample of the fixtures (xmp_v1_panorama_sample.xmp)
  private val sample = PhotoRegion(yaw = 0.0, pitch = 0.0, hfov = 65.4, vfov = 50.6)

  private fun radians(degrees: Double) = Math.toRadians(degrees)

  private fun length(v: DoubleArray) = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])

  @Test
  fun `the corners of a photo looking ahead are where the golden projection puts the corners of the photo`() {
    val t = tan(radians(65.4) / 2)
    val s = tan(radians(50.6) / 2)
    val corners = PanoramaOutline.corners(sample)

    // Top left, top right, bottom right, bottom left: the plane of the photo met at (-t, s), (t, s), (t, -s), (-t, -s)
    val expected = listOf(-t to s, t to s, t to -s, -t to -s)
    assertEquals(4, corners.size)
    for ((corner, plane) in corners.zip(expected)) {
      assertEquals(1.0, length(corner), 1e-12)
      assertTrue(corner[2] > 0)
      assertEquals(plane.first, corner[0] / corner[2], 1e-12)
      assertEquals(plane.second, corner[1] / corner[2], 1e-12)
    }
  }

  @Test
  fun `each arc stays on its edge of the photo, from one corner to the next`() {
    val t = tan(radians(65.4) / 2)
    val s = tan(radians(50.6) / 2)
    val arcs = PanoramaOutline.arcs(sample, segments = 16)
    val corners = PanoramaOutline.corners(sample)

    assertEquals(4, arcs.size)
    for ((k, arc) in arcs.withIndex()) {
      assertEquals(17, arc.size)
      assertArrayEquals(corners[k], arc.first())
      assertArrayEquals(corners[(k + 1) % 4], arc.last())
      for (point in arc) {
        assertEquals(1.0, length(point), 1e-12)
        val a = point[0] / point[2]
        val b = point[1] / point[2]
        when (k) {
          0 -> assertEquals(s, b, 1e-12) // top
          1 -> assertEquals(t, a, 1e-12) // right
          2 -> assertEquals(-s, b, 1e-12) // bottom
          else -> assertEquals(-t, a, 1e-12) // left
        }
      }
    }
  }

  @Test
  fun `the top edge of a wide photo bends up towards the middle, as a straight line of the photo does on the sphere`() {
    val top = PanoramaOutline.arcs(sample, segments = 16)[0]
    val (_, cornerLatitude) = PanoramaOutline.longitudeLatitude(top.first())
    val (middleLongitude, middleLatitude) = PanoramaOutline.longitudeLatitude(top[8])

    assertEquals(0.0, middleLongitude, 1e-9)
    assertEquals(50.6 / 2, middleLatitude, 1e-9)
    // At the corner: atan(s * cos(longitude)), lower than the middle
    val cornerLongitude = 65.4 / 2
    assertEquals(Math.toDegrees(atan(tan(radians(25.3)) * cos(radians(cornerLongitude)))), cornerLatitude, 1e-9)
    assertTrue(cornerLatitude < middleLatitude)
  }

  @Test
  fun `a photo turned to the right and looking up has its centre and its outline turned with it`() {
    val region = PhotoRegion(yaw = 40.0, pitch = 20.0, hfov = 60.0, vfov = 45.0)
    val center = PanoramaOutline.direction(region, 0.0, 0.0)
    val (longitude, latitude) = PanoramaOutline.longitudeLatitude(center)

    assertEquals(40.0, longitude, 1e-9)
    assertEquals(20.0, latitude, 1e-9)
    // The middle of the top edge is straight above the centre, vfov / 2 higher; the middle of the right edge is right
    // of the centre at the angle hfov / 2
    val arcs = PanoramaOutline.arcs(region, segments = 2)
    val topMiddle = PanoramaOutline.longitudeLatitude(arcs[0][1])
    assertEquals(40.0, topMiddle.first, 1e-9)
    assertEquals(20.0 + 22.5, topMiddle.second, 1e-9)
    assertEquals(30.0, angleBetween(center, arcs[1][1]), 1e-9)
    assertTrue(PanoramaOutline.longitudeLatitude(arcs[1][1]).first > 40.0)
  }

  @Test
  fun `a photo behind the user wraps its longitude across the back of the sphere`() {
    val region = PhotoRegion(yaw = 180.0, pitch = 0.0, hfov = 60.0, vfov = 40.0)
    val longitudes =
      PanoramaOutline.arcs(region, segments = 8).flatten().map { PanoramaOutline.longitudeLatitude(it).first }

    assertTrue(longitudes.all { abs(it) >= 150.0 - 1e-9 })
    assertTrue(longitudes.any { it > 0 } && longitudes.any { it < 0 })
  }

  @Test
  fun `the ribbon is two rows of vertices along each arc at the radius, a thin band either side of the edge`() {
    val ribbon = PanoramaOutline.ribbon(sample, radius = 250f, widthDegrees = 0.4, segments = 8)
    val arcs = PanoramaOutline.arcs(sample, segments = 8)

    assertEquals(3 * 4 * 9 * 2, ribbon.positions.size)
    assertEquals(4 * 8 * 6, ribbon.indices.size)
    assertTrue(ribbon.indices.all { it in 0 until 4 * 9 * 2 })
    for ((k, arc) in arcs.withIndex()) {
      for ((i, point) in arc.withIndex()) {
        val v = 2 * (k * 9 + i)
        val inner = DoubleArray(3) { ribbon.positions[3 * v + it].toDouble() }
        val outer = DoubleArray(3) { ribbon.positions[3 * (v + 1) + it].toDouble() }
        assertEquals(250.0, length(inner), 1e-3)
        assertEquals(250.0, length(outer), 1e-3)
        // Both sides of the edge, 0.2° each way
        assertEquals(0.2, angleBetween(inner, point), 1e-4)
        assertEquals(0.2, angleBetween(outer, point), 1e-4)
        assertEquals(0.4, angleBetween(inner, outer), 1e-4)
      }
    }
  }

  @Test
  fun `the mesh of the viewer is the dark ribbon then the light one in front of it, at the sizes it is made for`() {
    val mesh = PanoramaOutline.mesh(sample)
    val half = PanoramaOutline.RIBBON_VERTICES

    assertEquals(3 * PanoramaOutline.VERTICES, mesh.positions.size)
    assertEquals(PanoramaOutline.VERTICES, mesh.colors.size)
    assertEquals(PanoramaOutline.INDICES, mesh.indices.size)
    assertTrue(mesh.indices.all { it in 0 until PanoramaOutline.VERTICES })
    // The triangles of the light ribbon use its vertices only
    assertTrue(mesh.indices.drop(PanoramaOutline.RIBBON_INDICES).all { it >= half })
    assertTrue(mesh.indices.take(PanoramaOutline.RIBBON_INDICES).all { it < half })
    assertTrue(mesh.colors.take(half).all { it == PanoramaOutline.DARK })
    assertTrue(mesh.colors.drop(half).all { it == PanoramaOutline.LIGHT })
    // The light one nearer, both in front of the half sphere of 180° photos (300 m) and of the skybox (950 m,
    // ToolkitFeature of SDK 0.14.0)
    val darkFirst = DoubleArray(3) { mesh.positions[it].toDouble() }
    val lightFirst = DoubleArray(3) { mesh.positions[3 * half + it].toDouble() }
    assertEquals(PanoramaOutline.DARK_RADIUS_M.toDouble(), length(darkFirst), 1e-3)
    assertEquals(PanoramaOutline.RADIUS_M.toDouble(), length(lightFirst), 1e-3)
    assertTrue(PanoramaOutline.RADIUS_M < PanoramaOutline.DARK_RADIUS_M && PanoramaOutline.DARK_RADIUS_M < 300f)
    assertTrue(PanoramaOutline.WIDTH_DEGREES < PanoramaOutline.DARK_WIDTH_DEGREES)
  }

  @Test
  fun `each segment of a ribbon is two triangles of four distinct vertices, a band and not a saw tooth`() {
    for (ribbon in listOf(PanoramaOutline.ribbon(sample), PanoramaOutline.ribbon(sample, 260f, 0.7))) {
      for (k in 0 until ribbon.indices.size / 6) {
        val quad = ribbon.indices.copyOfRange(6 * k, 6 * k + 6)
        assertEquals("segment $k", 4, quad.toSet().size)
        for (triangle in 0 until 2) {
          val (a, b, c) = (0 until 3).map { vertex(ribbon.positions, quad[3 * triangle + it]) }
          val ab = DoubleArray(3) { b[it] - a[it] }
          val ac = DoubleArray(3) { c[it] - a[it] }
          val cross =
            doubleArrayOf(ab[1] * ac[2] - ab[2] * ac[1], ab[2] * ac[0] - ab[0] * ac[2], ab[0] * ac[1] - ab[1] * ac[0])
          assertTrue("segment $k, triangle $triangle has an area", length(cross) / 2 > 1e-3)
        }
      }
    }
  }

  @Test
  fun `the dark ribbon is opaque black and the light one opaque white, whatever the order of the channels`() {
    assertEquals(0xFF000000.toInt(), PanoramaOutline.DARK)
    assertEquals(0xFFFFFFFF.toInt(), PanoramaOutline.LIGHT)
    val mesh = PanoramaOutline.mesh(sample)
    assertTrue(mesh.colors.all { it ushr 24 == 0xFF })
  }

  private fun vertex(positions: FloatArray, index: Int) = DoubleArray(3) { positions[3 * index + it].toDouble() }

  private fun angleBetween(a: DoubleArray, b: DoubleArray): Double {
    val dot = (a[0] * b[0] + a[1] * b[1] + a[2] * b[2]) / (length(a) * length(b))
    return Math.toDegrees(Math.acos(dot.coerceIn(-1.0, 1.0)))
  }

  private fun assertArrayEquals(expected: DoubleArray, actual: DoubleArray) {
    for (i in expected.indices) assertEquals(expected[i], actual[i], 1e-12)
  }
}
