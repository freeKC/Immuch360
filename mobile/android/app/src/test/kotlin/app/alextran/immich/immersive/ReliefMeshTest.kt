package app.alextran.immich.immersive

import app.alextran.immich.relief.ReliefMap
import app.alextran.immich.relief.ReliefV1
import kotlin.math.abs
import kotlin.math.max
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The mesh of the 2.5D view of a relief, in plain JVM code as spherical/HalfSphereMeshTest.kt tests its mesh: from the
 * start pose each vertex lies on the ray of the pixel it shows, the two eyes see there the relief of the stereo view,
 * the triangles over a break of the depth map are left out, the relief fades with the distance of the head without
 * steps, and the grid has the size the map gives.
 */
class ReliefMeshTest {
  private val view = ReliefView(distance = 2.0, width = 2.0, height = 1.5)

  /** A map of [width] x [height] whose value at the column x and the row y is [depth] */
  private fun map(width: Int, height: Int, depth: (Int, Int) -> Double): ReliefMap =
    ReliefMap.quantize(width, height, DoubleArray(width * height) { i -> depth(i % width, i / width) })

  /** The triangles of [mesh] that are drawn, three vertices each: the padding is left out */
  private fun drawn(mesh: ReliefMesh): List<IntArray> =
    mesh.indices().toList().chunked(3).map { it.toIntArray() }.filter { it[0] != it[1] || it[1] != it[2] }

  private fun z(positions: FloatArray, vertex: Int): Double = positions[3 * vertex + 2].toDouble()

  @Test
  fun `the map of the model gives a grid of 173 x 131 vertices, one every 4 values`() {
    val mesh = ReliefMesh(map(686, 518) { _, _ -> 0.5 })

    assertEquals(173, mesh.columns)
    assertEquals(131, mesh.rows)
    assertEquals(22_663, mesh.vertexCount)
    assertEquals(ReliefMesh.MAX_VERTICES, mesh.vertexCount)
    assertEquals(6 * 172 * 130, ReliefMesh.MAX_INDICES)
    // Every cell drawn, two triangles each
    assertEquals(2 * 172 * 130, drawn(mesh).size)
    assertEquals(ReliefMesh.MAX_INDICES, mesh.indices().size)
  }

  @Test
  fun `a portrait, a tiny map and a larger one keep their grid within the mesh`() {
    // The frame of a 3000 x 4000 portrait in the input of the model: 389 x 518
    val portrait = ReliefMesh(map(389, 518) { _, _ -> 0.5 })
    assertEquals(98 to 131, portrait.columns to portrait.rows)
    assertEquals(2 * 97 * 130, drawn(portrait).size)

    val tiny = ReliefMesh(map(1, 1) { _, _ -> 0.5 })
    assertEquals(2 to 2, tiny.columns to tiny.rows)
    assertEquals(2, drawn(tiny).size)

    val larger = ReliefMesh(map(2000, 1000) { _, _ -> 0.5 })
    assertEquals(ReliefMesh.MAX_COLUMNS to ReliefMesh.MAX_ROWS, larger.columns to larger.rows)
    // One array serves every photo: what a larger photo left past the vertices of this one goes back to the origin
    val reused = portrait.positions(view, 1.0, larger.positions(view, 1.0))
    assertTrue((3 * portrait.vertexCount until reused.size).all { reused[it] == 0f })
    for (mesh in listOf(portrait, tiny, larger)) {
      assertTrue(mesh.vertexCount <= ReliefMesh.MAX_VERTICES)
      assertEquals(3 * ReliefMesh.MAX_VERTICES, mesh.positions(view, 1.0).size)
      assertEquals(2 * ReliefMesh.MAX_VERTICES, mesh.textureCoordinates(400, 300).size)
      assertTrue(mesh.indices().all { it in 0 until mesh.vertexCount })
    }
  }

  @Test
  fun `from the start pose each vertex lies on the ray of the pixel it shows`() {
    val mesh = ReliefMesh(map(686, 518) { x, y -> ((x * 7 + y * 3) % 100) / 99.0 })
    val eyeWidth = 2560
    val eyeHeight = 1932
    val gutter = StereoComposer.GUTTER
    val (textureWidth, textureHeight) = StereoComposer.textureSize(eyeWidth, eyeHeight)
    val uvs = mesh.textureCoordinates(eyeWidth, eyeHeight)
    for (attenuation in doubleArrayOf(1.0, 0.4, 0.0)) {
      val positions = mesh.positions(view, attenuation)
      for (k in 0 until mesh.vertexCount) {
        // The pixel of the photo the vertex shows, from 0 to its width and height
        val px = uvs[2 * k] * textureWidth.toDouble() - gutter
        val py = uvs[2 * k + 1] * textureHeight.toDouble() - gutter
        val x = positions[3 * k].toDouble()
        val y = positions[3 * k + 1].toDouble()
        val z = z(positions, k)
        assertTrue(z > 0)
        // Where its ray from the eyes meets the plane of the photo: that very pixel of the photo on the quad
        assertEquals("vertex $k at $attenuation", (px / eyeWidth - 0.5) * view.width, x * view.distance / z, 1e-4)
        assertEquals("vertex $k at $attenuation", (0.5 - py / eyeHeight) * view.height, y * view.distance / z, 1e-4)
      }
    }
    // The first vertex shows the top left corner of the photo, the last one the bottom right one
    assertEquals(gutter.toDouble(), uvs[0] * textureWidth.toDouble(), 1e-3)
    assertEquals(gutter.toDouble(), uvs[1] * textureHeight.toDouble(), 1e-3)
    val last = mesh.vertexCount - 1
    assertEquals((gutter + eyeWidth).toDouble(), uvs[2 * last] * textureWidth.toDouble(), 1e-3)
    assertEquals((gutter + eyeHeight).toDouble(), uvs[2 * last + 1] * textureHeight.toDouble(), 1e-3)
  }

  @Test
  fun `the texture coordinates read the left eye, the photo itself, never the gutter nor the right eye`() {
    val mesh = ReliefMesh(map(686, 518) { _, _ -> 0.5 })
    val uvs = mesh.textureCoordinates(1000, 750)
    val (textureWidth, textureHeight) = StereoComposer.textureSize(1000, 750)
    for (k in 0 until mesh.vertexCount) {
      assertTrue(uvs[2 * k] * textureWidth >= StereoComposer.GUTTER - 1e-3)
      assertTrue(uvs[2 * k] * textureWidth <= StereoComposer.GUTTER + 1000 + 1e-3)
      assertTrue(uvs[2 * k] < 0.5f)
      assertTrue(uvs[2 * k + 1] * textureHeight >= StereoComposer.GUTTER - 1e-3)
      assertTrue(uvs[2 * k + 1] * textureHeight <= StereoComposer.GUTTER + 750 + 1e-3)
    }
  }

  @Test
  fun `the depth of a vertex is the map read in bilinear at its place, as relief-v1 reads it`() {
    val width = 686
    val mesh = ReliefMesh(map(width, 518) { x, _ -> x / (width - 1.0) })
    for (i in 0 until mesh.columns) {
      // The centre of the map value x is at x + 0.5: the edges repeat the first and the last value
      val at = (i.toDouble() / (mesh.columns - 1) * width - 0.5).coerceIn(0.0, width - 1.0)
      assertEquals("column $i", at / (width - 1.0), mesh.depth(i), 2.0 / ReliefMap.MAX_LEVEL)
    }
  }

  @Test
  fun `at the start pose the two eyes see the relief the stereo view gives`() {
    // relief-v1 moves a pixel of depth d by parallax * width * (convergence - d) in the right eye: the mesh puts it
    // where two eyes IPD_M apart see that very disparity on the plane of the quad
    val mesh = ReliefMesh(map(64, 48) { x, y -> (x + y) / 110.0 })
    val reliefs = listOf(view, view.copy(parallax = 0.03, convergence = 0.4), view.copy(width = 1.2, distance = 1.5))
    for (relief in reliefs) {
      val positions = mesh.positions(relief, 1.0)
      for (k in 0 until mesh.vertexCount) {
        val disparity = ReliefMesh.IPD_M * (1 - relief.distance / z(positions, k))
        val stereo = relief.parallax * relief.width * (relief.convergence - mesh.depth(k))
        assertEquals("vertex $k", stereo, disparity, 1e-5)
      }
    }
    // The middle of the relief on the plane of the quad, the near values in front of it, the far ones behind
    val ramp = ReliefMesh(map(686, 518) { x, _ -> x / 685.0 })
    val positions = ramp.positions(view, 1.0)
    assertTrue(z(positions, 0) > view.distance)
    assertTrue(z(positions, ramp.columns - 1) < view.distance)
    assertEquals(view.distance, z(positions, ramp.columns / 2), 0.01)
  }

  @Test
  fun `without relief the mesh is the flat photo on the plane of the quad`() {
    val varied = ReliefMesh(map(686, 518) { x, y -> ((x * 13 + y * 5) % 97) / 96.0 })
    val flat = varied.positions(view, 0.0)
    val even = ReliefMesh(map(686, 518) { _, _ -> view.convergence }).positions(view, 1.0)
    for (k in 0 until varied.vertexCount) {
      assertEquals(view.distance, z(flat, k), 1e-6)
      assertEquals(view.distance, z(even, k), 1e-4)
    }
    assertEquals(view.distance, varied.farthest(view, 0.0), 1e-6)
  }

  @Test
  fun `the triangles over a break of the map are left out, those on each side kept whole`() {
    // A person before a wall: far on the left, near from the column 300 on, one step between them
    val mesh = ReliefMesh(map(686, 518) { x, _ -> if (x < 300) 0.2 else 0.8 })
    val triangles = drawn(mesh)

    // One column of cells goes, the one whose values cross the step, in every row
    assertEquals(2 * 172 * 130 - 2 * 130, triangles.size)
    // No skin stretched between the wall and the person: each triangle kept lies on one side
    for (t in triangles) {
      val depths = t.map { mesh.depth(it) }
      assertEquals("triangle ${t.toList()}", depths.min(), depths.max(), 1e-9)
    }
    // The padding up to the size of the mesh draws nothing
    val padding = mesh.indices().toList().drop(3 * triangles.size)
    assertTrue(padding.chunked(3).all { it[0] == it[1] && it[1] == it[2] })
  }

  @Test
  fun `a slope is kept, a break is the jump of relief-v1 between two neighbours`() {
    val gentle = ReliefMesh(map(686, 518) { x, _ -> x / 685.0 })
    assertEquals(2 * 172 * 130, drawn(gentle).size)
    // 0.03 from one value to the next is a slope (relief-v1 joins them), 0.05 a break (it does not)
    val steep = ReliefMesh(map(40, 30) { x, _ -> 0.1 + 0.03 * (x / 4) })
    assertEquals(2 * (steep.columns - 1) * (steep.rows - 1), drawn(steep).size)
    val broken = ReliefMesh(map(40, 30) { x, _ -> if (x == 20) 0.5 else if (x > 20) 0.55 else 0.45 })
    assertTrue(drawn(broken).size < 2 * (broken.columns - 1) * (broken.rows - 1))
    val joined = ReliefMesh(map(40, 30) { x, _ -> if (x == 20) 0.5 else if (x > 20) 0.53 else 0.47 })
    assertEquals(2 * (joined.columns - 1) * (joined.rows - 1), drawn(joined).size)
    // A vertex that reads both sides of a break is never drawn: the vertex column 5 lies between the values 19 and 20
    val between = ReliefMesh(map(40, 30) { x, _ -> if (x < 20) 0.2 else 0.8 })
    assertEquals(2 * 8 * 8, drawn(between).size)
    for (t in drawn(between)) assertEquals(t.minOf { between.depth(it) }, t.maxOf { between.depth(it) }, 1e-9)
    // A break across the rows counts as one across the columns: the vertex row 4 lies on it (between the values 14
    // and 15), so both rows of cells it joins go
    val rows = ReliefMesh(map(40, 30) { _, y -> if (y < 15) 0.3 else 0.9 })
    assertEquals(11 to 9, rows.columns to rows.rows)
    assertEquals(2 * 10 * 6, drawn(rows).size)
    assertEquals(0.04, ReliefV1.LINK_THRESHOLD, 0.0)
  }

  @Test
  fun `the relief fades with the distance of the head from the start pose, without steps`() {
    assertEquals(1.0, ReliefMesh.attenuation(0.0), 0.0)
    assertEquals(1.0, ReliefMesh.attenuation(ReliefMesh.FULL_RELIEF_M), 0.0)
    assertEquals(0.0, ReliefMesh.attenuation(ReliefMesh.FLAT_M), 0.0)
    assertEquals(0.0, ReliefMesh.attenuation(3.0), 0.0)
    assertEquals(0.5, ReliefMesh.attenuation((ReliefMesh.FULL_RELIEF_M + ReliefMesh.FLAT_M) / 2), 1e-12)
    // A millimetre of head never moves it by 1 percent, and it only goes down
    var previous = 1.0
    for (mm in 0..1000) {
      val a = ReliefMesh.attenuation(mm / 1000.0)
      assertTrue("$mm mm", a <= previous)
      assertTrue("$mm mm", previous - a < 0.01)
      previous = a
    }
  }

  @Test
  fun `the mesh follows the attenuation smoothly, and the viewer moves it before a step could show`() {
    val mesh = ReliefMesh(map(686, 518) { x, y -> ((x * 7 + y * 3) % 100) / 99.0 })
    var last = mesh.positions(view, 1.0)
    for (step in 1..100) {
      val next = mesh.positions(view, 1.0 - step / 100.0)
      var moved = 0.0
      for (i in 0 until 3 * mesh.vertexCount) moved = max(moved, abs(next[i] - last[i]).toDouble())
      // A hundredth of the relief moves no vertex by more than 2 cm (the nearest are about 1.5 m away)
      assertTrue("step $step: $moved m", moved < 0.02)
      last = next
    }
    assertFalse(ReliefMesh.needsUpdate(1.0, 1.0))
    assertFalse(ReliefMesh.needsUpdate(0.5, 0.503))
    assertTrue(ReliefMesh.needsUpdate(0.5, 0.494))
    // The ends are always reached: whole relief near the start pose, flat far from it
    assertTrue(ReliefMesh.needsUpdate(0.002, 0.0))
    assertTrue(ReliefMesh.needsUpdate(0.997, 1.0))
    assertTrue(ReliefMesh.ATTENUATION_STEP <= 0.005)
  }

  @Test
  fun `the backdrop distance is behind every vertex, on the plane of the quad without relief`() {
    val mesh = ReliefMesh(map(686, 518) { x, y -> ((x * 7 + y * 3) % 100) / 99.0 })
    for (attenuation in doubleArrayOf(1.0, 0.7, 0.2, 0.0)) {
      val positions = mesh.positions(view, attenuation)
      val farthest = mesh.farthest(view, attenuation)
      var deepest = 0.0
      for (k in 0 until mesh.vertexCount) deepest = max(deepest, z(positions, k))
      assertEquals(deepest, farthest, 1e-4)
    }
  }

  @Test
  fun `a relief too strong for the plane stays between half a metre and 50 m`() {
    val mesh = ReliefMesh(map(64, 48) { x, _ -> x / 63.0 })
    val positions = mesh.positions(view.copy(parallax = 0.5), 1.0)
    for (k in 0 until mesh.vertexCount) {
      assertTrue(z(positions, k) >= ReliefMesh.MIN_DEPTH_M - 1e-6)
      assertTrue(z(positions, k) <= ReliefMesh.MAX_DEPTH_M + 1e-3)
    }
  }

  @Test
  fun `the photo of the mesh is the photo of the quad, its gutters left out`() {
    val eyeWidth = 2560
    val eyeHeight = 1920
    val angle = 48f
    val relief = ReliefView.forQuad(angle, eyeWidth, eyeHeight, parallax = 0.02, convergence = 0.5)
    val (quadWidth, quadHeight) = StereoComposer.quadSize(angle, eyeWidth, eyeHeight)
    val gutter = StereoComposer.GUTTER

    assertEquals(StereoComposer.DISTANCE_M.toDouble(), relief.distance, 0.0)
    assertEquals(quadWidth * eyeWidth / (eyeWidth + 2.0 * gutter), relief.width, 1e-6)
    assertEquals(quadHeight * eyeHeight / (eyeHeight + 2.0 * gutter), relief.height, 1e-6)
    assertEquals(0.02, relief.parallax, 0.0)
    assertEquals(0.5, relief.convergence, 0.0)
  }
}
