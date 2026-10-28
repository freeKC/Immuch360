package app.alextran.immich.immersive.scene

import app.alextran.immich.immersive.VolumetricSceneSpec.SafeZone
import app.alextran.immich.relief.ReliefFixtures
import java.util.Random
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The edge of the zone and the glide in a scene (design-final 2026-10-27, section 3.4): rho, the flattening and the
 * darkening, the photo plane and the flattened vertices read again in scene_golden_v1.json (make_scene_golden.py, step
 * 10), the glide of the left thumbstick in the frame of the gaze, eased and stopped at the edge of the zone, the
 * meshes made again only when the flattening moved by 0.02, the passing text at the edge, and Reset; the root pose
 * against the eye for any yaw and glide, and the passage to the left handed world of the Spatial SDK (SdkFrame): the
 * photo not mirrored, the stick gliding the way it is pushed, the triangles facing the camera.
 */
class SceneNavigatorTest {
  private val golden = ReliefFixtures.json("scene_golden_v1.json")
  private val tolerance = golden.getValue("tolerance").jsonPrimitive.double
  // Frames of 10 ms: the glide is checked against whole numbers of frames
  private val frame = 0.01

  private fun assertClose(message: String, expected: Double, actual: Double, within: Double = tolerance) =
    assertEquals(message, expected, actual, within * max(1.0, abs(expected)))

  private fun doubles(array: JsonArray): DoubleArray = array.map { it.jsonPrimitive.double }.toDoubleArray()

  private fun safeOf(case: JsonObject): SafeZone =
    case.getValue("safe").jsonObject.let {
      SafeZone(
        it.getValue("lateral").jsonPrimitive.double,
        it.getValue("vertical").jsonPrimitive.double,
        it.getValue("forward").jsonPrimitive.double,
        it.getValue("backward").jsonPrimitive.double,
      )
    }

  private val cases = golden.getValue("cases").jsonArray.map { it.jsonObject }

  @Test
  fun `the constants of the edge are those of the golden`() {
    val flatten = doubles(golden.getValue("flatten").jsonArray)
    assertEquals(
      listOf(flatten[0], flatten[1], flatten[2], flatten[3], flatten[4], flatten[5]),
      listOf(
        SceneNavigator.FLATTEN_FROM,
        SceneNavigator.FLATTEN_TO,
        SceneNavigator.DARKEN_FROM,
        SceneNavigator.DARKEN_MAX,
        SceneNavigator.FLAT_BACKGROUND,
        SceneNavigator.FLATTEN_STEP,
      ),
    )
  }

  @Test
  fun `the flattening and the darkening follow the curve of the golden`() {
    for (row in golden.getValue("edgeCurve").jsonArray) {
      val (rho, flatten, darken) = doubles(row.jsonArray).toList()
      assertClose("flatten at $rho", flatten, SceneNavigator.flattenOf(rho))
      assertClose("darken at $rho", darken, SceneNavigator.darkenOf(rho))
    }
    // No step anywhere: the curves rise without a jump, flat at both ends
    var previous = 0.0
    for (k in 0..300) {
      val value = SceneNavigator.flattenOf(1.0 + k / 600.0)
      assertTrue(value >= previous && value - previous < 0.01)
      previous = value
    }
    assertEquals(1.0, SceneNavigator.flattenOf(7.0), 0.0)
    assertEquals(0.95, SceneNavigator.darkenOf(Double.POSITIVE_INFINITY), 0.0)
  }

  @Test
  fun `rho of each eye of each case is the one of the golden, forward and backward told apart`() {
    var checked = 0
    for (case in cases) {
      val safe = safeOf(case)
      for (edge in case.getValue("edge").jsonArray.map { it.jsonObject }) {
        val (x, y, z) = doubles(edge.getValue("eye").jsonArray).toList()
        val name = "${case.getValue("name").jsonPrimitive.content} $x $y $z"
        val rho = SceneNavigator.rhoOf(x, y, z, safe)
        assertClose("rho of $name", edge.getValue("rho").jsonPrimitive.double, rho)
        assertClose("flatten of $name", edge.getValue("flatten").jsonPrimitive.double, SceneNavigator.flattenOf(rho))
        assertClose("darken of $name", edge.getValue("darken").jsonPrimitive.double, SceneNavigator.darkenOf(rho))
        checked++
      }
    }
    assertEquals(6 * cases.size, checked)
  }

  @Test
  fun `the photo plane of each case is the median depth of the vertices its triangles use`() {
    for (case in cases) {
      val vertices = doubles(case.getValue("vertices").jsonArray)
      val used = case.getValue("indices").jsonArray.map { it.jsonPrimitive.int }.toSortedSet()
      val depths = used.map { -vertices[3 * it + 2] }.toDoubleArray()
      val name = case.getValue("name").jsonPrimitive.content
      assertClose(name, case.getValue("photoPlane").jsonPrimitive.double, SceneNavigator.planeOf(depths)!!)
    }
    assertEquals(null, SceneNavigator.planeOf(DoubleArray(0)))
    // The lower middle of an even count
    assertEquals(2.0, SceneNavigator.planeOf(doubleArrayOf(3.0, 1.0, 2.0, 4.0))!!, 0.0)
  }

  @Test
  fun `each vertex slides on its ray towards the plane, the background 1 cm behind`() {
    for (case in cases) {
      val probe = case.getValue("flattenedVertex").jsonObject
      val vertex = doubles(probe.getValue("vertex").jsonArray)
      val plane = case.getValue("photoPlane").jsonPrimitive.double
      val name = case.getValue("name").jsonPrimitive.content
      val probes =
        listOf(Triple("half", 0.5, plane), Triple("full", 1.0, plane), Triple("background", 1.0, plane + 0.01))
      for ((key, a, target) in probes) {
        val expected = doubles(probe.getValue(key).jsonArray)
        val actual = SceneNavigator.flattened(vertex[0], vertex[1], vertex[2], a, target)
        for (i in 0 until 3) assertClose("$name $key $i", expected[i], actual[i])
      }
    }
  }

  @Test
  fun `the meshes of the fixture flatten by layer, unchanged at 0 and flat at 1`() {
    val scene = GlbReader.read(SceneTestFiles.tinyGlb())
    // The photo layer: three rows at 2, 2.25 and 2.5 m, three vertices each
    val plane = SceneNavigator.photoPlane(scene.meshes)!!
    assertEquals(2.25, plane, 0.0)
    val (front, back) = scene.meshes
    val whole = SceneNavigator.flatten(front, 0.0, plane, FloatArray(front.positions.size))
    assertTrue(front.positions.contentEquals(whole))
    val flat = SceneNavigator.flatten(front, 1.0, plane, FloatArray(front.positions.size))
    val background = SceneNavigator.flatten(back, 1.0, plane, FloatArray(back.positions.size))
    for (k in 0 until front.vertexCount) {
      assertEquals(-2.25f, flat[3 * k + 2], 1e-6f)
      // On its ray: x / z and y / z kept
      assertEquals(front.positions[3 * k] / front.positions[3 * k + 2], flat[3 * k] / flat[3 * k + 2], 1e-6f)
      assertEquals(front.positions[3 * k + 1] / front.positions[3 * k + 2], flat[3 * k + 1] / flat[3 * k + 2], 1e-6f)
    }
    for (k in 0 until back.vertexCount) assertEquals(-2.26f, background[3 * k + 2], 1e-6f)
    // A float mesh gives the golden vertex within the precision of a float
    val probe = cases[0].getValue("flattenedVertex").jsonObject
    val vertex = doubles(probe.getValue("vertex").jsonArray)
    val position = floatArrayOf(vertex[0].toFloat(), vertex[1].toFloat(), vertex[2].toFloat())
    val mesh = GlbMesh(position, FloatArray(2), intArrayOf(0, 0, 0), 0, SceneLayer.PHOTO)
    val half = SceneNavigator.flatten(mesh, 0.5, cases[0].getValue("photoPlane").jsonPrimitive.double, FloatArray(3))
    val expected = doubles(probe.getValue("half").jsonArray)
    for (i in 0 until 3) assertEquals(expected[i], half[i].toDouble(), 1e-6)
  }

  @Test
  fun `the photo plane counts a vertex shared by two bands once, and leaves the background and unused vertices out`() {
    // A photo layer of three rows at 1, 2 and 3 m cut in two bands that share the row at 2 m, the second band with a
    // vertex at 100 m that no triangle uses, and a background at 9 m
    val cells = intArrayOf(0, 3, 1, 1, 3, 4, 1, 4, 2, 2, 4, 5)
    fun row(depth: Float, x: Float) = floatArrayOf(x, 0f, -depth, x + 0.1f, 0f, -depth, x + 0.2f, 0f, -depth)
    val top = GlbMesh(row(1f, 0f) + row(2f, 0.5f), FloatArray(12), cells, 0, SceneLayer.PHOTO)
    val unused = floatArrayOf(9f, 9f, -100f)
    val bottom = GlbMesh(row(2f, 0.5f) + row(3f, 1f) + unused, FloatArray(14), cells, 0, SceneLayer.PHOTO)
    val wall = floatArrayOf(0f, 0f, -9f, 1f, 0f, -9f, 0f, 1f, -9f)
    val background = GlbMesh(wall, FloatArray(6), intArrayOf(0, 1, 2), 1, SceneLayer.BACKGROUND)
    val meshes = listOf(top, bottom, background)

    val depths = SceneNavigator.photoDepths(meshes).sorted().toList()
    assertEquals(listOf(1.0, 1.0, 1.0, 2.0, 2.0, 2.0, 3.0, 3.0, 3.0), depths)
    assertEquals(2.0, SceneNavigator.photoPlane(meshes)!!, 0.0)
    assertEquals(null, SceneNavigator.photoPlane(listOf(background)))
  }

  private fun navigator(safe: SafeZone = SafeZone(0.2, 0.12, 0.4, 0.1)) = SceneNavigator(safe)

  /** [seconds] of frames with the head still at [x], [y], [z] and [yaw], the stick held at [right], [forward] */
  private fun SceneNavigator.hold(
    seconds: Double,
    right: Double,
    forward: Double,
    x: Double = 0.0,
    y: Double = 1.6,
    z: Double = 0.0,
    yaw: Double = 0.0,
  ): SceneNavigation {
    var last = update(x, y, z, yaw, right, forward, frame)
    repeat(Math.round(seconds / frame).toInt() - 1) { last = update(x, y, z, yaw, right, forward, frame) }
    return last
  }

  @Test
  fun `at the anchor the eye is at the centre of the zone, the scene where the head was`() {
    val navigator = navigator()
    navigator.anchor(1.0, 1.6, 2.0, 0.3)
    val still = navigator.update(1.0, 1.6, 2.0, 0.3, 0.0, 0.0, frame)
    assertEquals(0.0, still.rho, 0.0)
    assertEquals(0.0, still.flatten, 0.0)
    assertEquals(0.0, still.darken, 0.0)
    assertFalse(still.rebuild)
    assertFalse(still.edgeNotice)
    assertEquals(listOf(1.0, 1.6, 2.0, 0.3), listOf(still.rootX, still.rootY, still.rootZ, still.rootYaw))
    // A head that leans 10 cm to its right, turned by 0.3 rad: in the frame of the scene, 10 cm along x
    val leaning = navigator.update(1.0 + 0.1 * Math.cos(0.3), 1.6, 2.0 - 0.1 * Math.sin(0.3), 0.3, 0.0, 0.0, frame)
    assertEquals(0.1, leaning.eyeX, 1e-12)
    assertEquals(0.0, leaning.eyeZ, 1e-12)
    assertEquals(0.5, leaning.rho, 1e-12)
    // The first update anchors a navigator that was never anchored
    val fresh = navigator()
    assertEquals(0.0, fresh.update(5.0, 1.0, -3.0, 1.0, 0.0, 0.0, frame).rho, 0.0)
  }

  @Test
  fun `the stick glides at 0_25 m per second after easing in over 0_2 s, and eases out the same`() {
    val navigator = navigator(SafeZone(5.0, 5.0, 5.0, 5.0))
    navigator.anchor(0.0, 1.6, 0.0, 0.0)
    val ramp = navigator.hold(SceneNavigator.GLIDE_EASE, 0.0, 1.0)
    // Half the speed on average over the ease: 0.025 m
    assertEquals(-0.025, ramp.eyeZ, 0.004)
    val cruising = navigator.hold(0.8, 0.0, 1.0)
    assertEquals(-0.225, cruising.eyeZ, 0.004)
    assertEquals(0.0, cruising.eyeX, 1e-12)
    // Released: it stops within 0.2 s, 0.025 m further
    val stopped = navigator.hold(0.5, 0.0, 0.0)
    assertEquals(-0.25, stopped.eyeZ, 0.004)
    assertEquals(stopped.eyeZ, navigator.update(0.0, 1.6, 0.0, 0.0, 0.0, 0.0, frame).eyeZ, 0.0)
    // A diagonal is no faster than a straight push
    val diagonal = navigator(SafeZone(5.0, 5.0, 5.0, 5.0)).apply { anchor(0.0, 1.6, 0.0, 0.0) }.hold(1.0, 1.0, 1.0)
    assertEquals(0.225, Math.hypot(diagonal.eyeX, diagonal.eyeZ), 0.004)
    // A long frame (the headset busy) moves no further than 0.1 s would
    val stalled = navigator(SafeZone(5.0, 5.0, 5.0, 5.0)).apply { anchor(0.0, 1.6, 0.0, 0.0) }
    stalled.hold(1.0, 0.0, 1.0)
    val before = stalled.update(0.0, 1.6, 0.0, 0.0, 0.0, 1.0, frame).eyeZ
    assertEquals(before - 0.025, stalled.update(0.0, 1.6, 0.0, 0.0, 0.0, 1.0, 5.0).eyeZ, 1e-9)
  }

  @Test
  fun `the glide goes where the gaze looks, the scene moving the other way in the world`() {
    val navigator = navigator(SafeZone(5.0, 5.0, 5.0, 5.0))
    navigator.anchor(0.0, 1.6, 0.0, PI / 2)
    // The head turned back to the start direction of the world (yaw 0), a quarter turn right of the scene
    val glided = navigator.hold(1.0, 0.0, 1.0, yaw = 0.0)
    assertEquals(0.225, glided.eyeX, 0.004)
    assertEquals(0.0, glided.eyeZ, 1e-12)
    // In the world the head looked towards -z and glid that way: the scene moved towards +z
    assertEquals(0.225, glided.rootZ, 0.004)
    assertEquals(0.0, glided.rootX, 1e-12)
    assertEquals(PI / 2, glided.rootYaw, 0.0)
    // Right of the gaze, gaze along the scene: along x of the scene
    val right = navigator(SafeZone(5.0, 5.0, 5.0, 5.0)).apply { anchor(0.0, 1.6, 0.0, 0.0) }.hold(1.0, 1.0, 0.0)
    assertEquals(0.225, right.eyeX, 0.004)
    assertEquals(SceneNavigator.yawOf(0.0, -1.0), 0.0, 0.0)
    assertEquals(SceneNavigator.yawOf(-1.0, 0.0), PI / 2, 1e-12)
  }

  @Test
  fun `the glide stops at the edge of the zone, and comes back from beyond it`() {
    val navigator = navigator(SafeZone(0.2, 0.12, 0.4, 0.1))
    navigator.anchor(0.0, 1.6, 0.0, 0.0)
    val edge = navigator.hold(3.0, 1.0, 0.0)
    assertTrue(edge.rho <= 1.0 + 1e-9)
    assertEquals(0.2, edge.eyeX, 0.002)
    assertEquals(0.0, edge.flatten, 1e-6)
    // Backward is shorter than forward
    val back = navigator(SafeZone(0.2, 0.12, 0.4, 0.1)).apply { anchor(0.0, 1.6, 0.0, 0.0) }.hold(3.0, 0.0, -1.0)
    assertEquals(0.1, back.eyeZ, 0.002)
    val ahead = navigator(SafeZone(0.2, 0.12, 0.4, 0.1)).apply { anchor(0.0, 1.6, 0.0, 0.0) }.hold(3.0, 0.0, 1.0)
    assertEquals(-0.4, ahead.eyeZ, 0.002)
    // Walking is never stopped: the head 0.3 m to the right, beyond the zone; pushing further does nothing, pushing
    // back brings the eye in
    val walked = navigator(SafeZone(0.2, 0.12, 0.4, 0.1)).apply { anchor(0.0, 1.6, 0.0, 0.0) }
    val out = walked.hold(1.0, 1.0, 0.0, x = 0.3)
    assertEquals(0.3, out.eyeX, 1e-12)
    assertEquals(1.5, out.rho, 1e-12)
    val inward = walked.hold(1.0, -1.0, 0.0, x = 0.3)
    assertEquals(0.3 - 0.225, inward.eyeX, 0.004)
  }

  @Test
  fun `the meshes are made again when the flattening moved by 0_02, and at its ends`() {
    val navigator = navigator(SafeZone(0.2, 0.12, 0.4, 0.1))
    navigator.anchor(0.0, 1.6, 0.0, 0.0)
    var applied = 0.0
    var rebuilds = 0
    // The head walks to the right from the centre to rho 2, 1 mm a frame
    for (k in 0..400) {
      val step = navigator.update(k * 0.001, 1.6, 0.0, 0.0, 0.0, 0.0, frame)
      if (step.rebuild) {
        assertTrue(abs(step.flatten - applied) >= SceneNavigator.FLATTEN_STEP || step.flatten == 1.0)
        applied = step.flatten
        rebuilds++
      } else {
        assertTrue(abs(step.flatten - applied) < SceneNavigator.FLATTEN_STEP)
      }
    }
    assertEquals(1.0, applied, 0.0)
    // From 0 to 1 by steps of 0.02 at least (51 at most), each frame adding at most 0.015 here (34 at least)
    assertTrue("$rebuilds", rebuilds in 34..51)
    // Back inside in one step: flat to whole, made again at once
    val inside = navigator.update(0.1, 1.6, 0.0, 0.0, 0.0, 0.0, frame)
    assertTrue(inside.rebuild)
    assertEquals(0.0, inside.flatten, 0.0)
    assertFalse(navigator.update(0.1, 1.6, 0.0, 0.0, 0.0, 0.0, frame).rebuild)
  }

  @Test
  fun `the text of the edge shows once when the darkening starts, again only after coming back inside`() {
    val navigator = navigator(SafeZone(0.2, 0.12, 0.4, 0.1))
    navigator.anchor(0.0, 1.6, 0.0, 0.0)
    fun at(x: Double) = navigator.update(x, 1.6, 0.0, 0.0, 0.0, 0.0, frame)
    assertFalse(at(0.249).edgeNotice)
    assertTrue(at(0.251).edgeNotice)
    assertFalse(at(0.27).edgeNotice)
    // Back between 1 and 1.25, then out again: still said
    assertFalse(at(0.22).edgeNotice)
    assertFalse(at(0.26).edgeNotice)
    // Inside the zone, then out: said again
    assertFalse(at(0.19).edgeNotice)
    assertTrue(at(0.3).edgeNotice)
  }

  @Test
  fun `Reset puts the eye back at the centre where the head is now, and the scene whole`() {
    val navigator = navigator(SafeZone(0.2, 0.12, 0.4, 0.1))
    navigator.anchor(0.0, 1.6, 0.0, 0.0)
    navigator.hold(2.0, 1.0, 0.0)
    val beyond = navigator.update(0.5, 1.6, 0.0, 0.0, 0.0, 0.0, frame)
    assertEquals(1.0, beyond.flatten, 0.0)
    navigator.anchor(0.5, 1.5, -0.2, 1.0)
    val reset = navigator.update(0.5, 1.5, -0.2, 1.0, 0.0, 0.0, frame)
    assertEquals(0.0, reset.rho, 0.0)
    assertEquals(listOf(0.0, 0.0, 0.0), listOf(reset.eyeX, reset.eyeY, reset.eyeZ))
    assertEquals(listOf(0.5, 1.5, -0.2, 1.0), listOf(reset.rootX, reset.rootY, reset.rootZ, reset.rootYaw))
    assertTrue(reset.rebuild)
    assertEquals(0.0, reset.flatten, 0.0)
    // The glide starts from nothing again
    assertEquals(0.0, navigator.update(0.5, 1.5, -0.2, 1.0, 0.0, 1.0, frame).eyeZ, 1e-3)
  }

  @Test
  fun `a zone of no depth on an axis allows no movement along it`() {
    val safe = SafeZone(0.2, 0.0, 0.4, 0.1)
    assertEquals(0.0, SceneNavigator.rhoOf(0.0, 0.0, 0.0, safe), 0.0)
    assertEquals(Double.POSITIVE_INFINITY, SceneNavigator.rhoOf(0.0, 0.001, 0.0, safe), 0.0)
    val navigator = navigator(safe)
    navigator.anchor(0.0, 1.6, 0.0, 0.0)
    val up = navigator.update(0.0, 1.61, 0.0, 0.0, 0.0, 0.0, frame)
    assertEquals(1.0, up.flatten, 0.0)
    assertEquals(0.95, up.darken, 0.0)
  }

  /** Quaternion(0f, [degrees], 0f) of the Spatial SDK applied to [x], [z]: a positive yaw takes +z towards +x */
  private fun sdkTurn(degrees: Double, x: Double, z: Double): Pair<Double, Double> {
    val a = Math.toRadians(degrees)
    return Pair(x * cos(a) + z * sin(a), -x * sin(a) + z * cos(a))
  }

  /** Where the point [x], [y], [z] of the glb lands in the world of the SDK, the root posed as [step] says */
  private fun sdkWorldOf(step: SceneNavigation, x: Double, y: Double, z: Double): DoubleArray {
    // The mesh holds the point as SdkFrame writes it
    val local = SdkFrame.positions(floatArrayOf(x.toFloat(), y.toFloat(), z.toFloat()), FloatArray(3))
    val (turnedX, turnedZ) = sdkTurn(step.sdkRootYawDegrees, local[0].toDouble(), local[2].toDouble())
    return doubleArrayOf(step.sdkRootX + turnedX, step.sdkRootY + local[1], step.sdkRootZ + turnedZ)
  }

  @Test
  fun `the root pose puts the eye where the navigator says, for any yaw and any glide`() {
    val random = Random(42)
    fun between(low: Double, high: Double) = low + (high - low) * random.nextDouble()
    repeat(200) {
      val navigator = navigator(SafeZone(3.0, 3.0, 3.0, 3.0))
      val originX = between(-2.0, 2.0)
      val originY = between(1.2, 1.8)
      val originZ = between(-2.0, 2.0)
      navigator.anchor(originX, originY, originZ, between(-PI, PI))
      repeat(1 + random.nextInt(80)) {
        val x = originX + between(-0.5, 0.5)
        val y = originY + between(-0.2, 0.2)
        val z = originZ + between(-0.5, 0.5)
        val step = navigator.update(x, y, z, between(-PI, PI), between(-1.0, 1.0), between(-1.0, 1.0), frame)
        // R(-rootYaw) applied to the head minus the root is the eye in the frame of the scene
        val c = cos(step.rootYaw)
        val s = sin(step.rootYaw)
        val dx = x - step.rootX
        val dz = z - step.rootZ
        assertEquals(step.eyeX, dx * c - dz * s, 1e-9)
        assertEquals(step.eyeY, y - step.rootY, 1e-9)
        assertEquals(step.eyeZ, dx * s + dz * c, 1e-9)
      }
    }
  }

  @Test
  fun `in the left handed world of the SDK the photo is not mirrored and the stick glides the way it is pushed`() {
    val random = Random(7)
    fun between(low: Double, high: Double) = low + (high - low) * random.nextDouble()
    repeat(100) { round ->
      // The head somewhere, its gaze turned by [turn] from +z of the SDK towards +x (the first round looks along +z)
      val turn = if (round == 0) 0.0 else between(-PI, PI)
      val gazeX = sin(turn)
      val gazeZ = cos(turn)
      // The right of the user, Up x gaze in the SDK (StereoComposer.quadRotation)
      val rightX = gazeZ
      val rightZ = -gazeX
      val x = between(-2.0, 2.0)
      val y = between(1.2, 1.8)
      val z = between(-2.0, 2.0)
      val navigator = navigator(SafeZone(5.0, 5.0, 5.0, 5.0))
      navigator.anchorInSdk(x, y, z, gazeX, gazeZ)
      val start = navigator.updateInSdk(x, y, z, gazeX, gazeZ, 0.0, 0.0, frame)
      // The point 1 m right of the centre of the photo, 0.5 m above it, 2 m ahead of its camera: right of the user,
      // above, ahead
      val edge = sdkWorldOf(start, 1.0, 0.5, -2.0)
      assertEquals("ahead", 2.0, (edge[0] - x) * gazeX + (edge[2] - z) * gazeZ, 1e-5)
      assertEquals("right", 1.0, (edge[0] - x) * rightX + (edge[2] - z) * rightZ, 1e-5)
      assertEquals("above", 0.5, edge[1] - y, 1e-5)
      // The head 10 cm to the right of the user: 10 cm along x of the scene
      val leaning = navigator.updateInSdk(x + 0.1 * rightX, y, z + 0.1 * rightZ, gazeX, gazeZ, 0.0, 0.0, frame)
      assertEquals(0.1, leaning.eyeX, 1e-9)
      assertEquals(0.0, leaning.eyeZ, 1e-9)
      // The stick pushed to the right for 1 s: the user glides 0.225 m to the right, so the scene goes to the left
      var glided = start
      repeat(100) { glided = navigator.updateInSdk(x, y, z, gazeX, gazeZ, 1.0, 0.0, frame) }
      val movedX = glided.sdkRootX - start.sdkRootX
      val movedZ = glided.sdkRootZ - start.sdkRootZ
      assertEquals("glide to the right", -0.225, movedX * rightX + movedZ * rightZ, 0.004)
      assertEquals(0.0, movedX * gazeX + movedZ * gazeZ, 1e-9)
      assertEquals(0.225, glided.eyeX, 0.004)
      // Pushed forward for 1 s, the speed turning from the right to ahead: the scene comes 0.2 m or more towards the
      // user
      var ahead = glided
      repeat(100) { ahead = navigator.updateInSdk(x, y, z, gazeX, gazeZ, 0.0, 1.0, frame) }
      val came = (ahead.sdkRootX - glided.sdkRootX) * gazeX + (ahead.sdkRootZ - glided.sdkRootZ) * gazeZ
      assertTrue("glide forward $came", came < -0.2 && came > -0.25)
      // In the SDK too, the root pose turned back puts the head at the eye of the navigator, z the other way
      for (step in listOf(start, glided, ahead)) {
        val (eyeX, eyeZ) = sdkTurn(-step.sdkRootYawDegrees, x - step.sdkRootX, z - step.sdkRootZ)
        assertEquals(step.eyeX, eyeX, 1e-9)
        assertEquals(step.eyeY, y - step.sdkRootY, 1e-9)
        assertEquals(-step.eyeZ, eyeZ, 1e-9)
      }
    }
    // The gaze along +z of the SDK is yaw 0 for the navigator, along +x a quarter turn clockwise seen from above
    assertEquals(0.0, SdkFrame.yawOfGaze(0.0, 1.0), 0.0)
    assertEquals(-PI / 2, SdkFrame.yawOfGaze(1.0, 0.0), 1e-12)
  }

  private fun cross(p: FloatArray, a: Int, b: Int, c: Int): DoubleArray {
    fun at(k: Int, i: Int) = p[3 * k + i].toDouble()
    val u = DoubleArray(3) { at(b, it) - at(a, it) }
    val v = DoubleArray(3) { at(c, it) - at(a, it) }
    return doubleArrayOf(u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
  }

  /** Whether the triangle [a], [b], [c] of [p] turns counter clockwise about its normal towards the origin */
  private fun facesOrigin(p: FloatArray, a: Int, b: Int, c: Int): Boolean {
    val n = cross(p, a, b, c)
    return (0 until 3).sumOf { -n[it] * (p[3 * a + it] + p[3 * b + it] + p[3 * c + it]) } > 0
  }

  @Test
  fun `the meshes written for the SDK keep their places and face the camera with the winding of singleSidedQuad`() {
    // SceneMesh.singleSidedQuad of the SDK (javap, 0.14.0): normal +z, triangles 0 1 2 and 0 2 3 counter clockwise
    // about it, written in the numbers of the SDK; its uv put 0, 0 at the top left, as glTF does
    val quad = floatArrayOf(-0.5f, -0.5f, 0f, 0.5f, -0.5f, 0f, 0.5f, 0.5f, 0f, -0.5f, 0.5f, 0f)
    assertTrue(cross(quad, 0, 1, 2)[2] > 0 && cross(quad, 0, 2, 3)[2] > 0)

    val scene = GlbReader.read(SceneTestFiles.tinyGlb())
    for (mesh in scene.meshes) {
      val positions = SdkFrame.positions(mesh.positions, FloatArray(mesh.positions.size))
      for (k in 0 until mesh.vertexCount) {
        assertEquals(mesh.positions[3 * k], positions[3 * k], 0f)
        assertEquals(mesh.positions[3 * k + 1], positions[3 * k + 1], 0f)
        assertEquals(-mesh.positions[3 * k + 2], positions[3 * k + 2], 0f)
      }
      val indices = SdkFrame.indices(mesh.indices)
      assertEquals(mesh.indices.size, indices.size)
      for (t in 0 until mesh.indices.size / 3) {
        val (a, b, c) = mesh.indices.copyOfRange(3 * t, 3 * t + 3).toList()
        // In the glb the triangle faces the camera, counter clockwise seen from it
        assertTrue(facesOrigin(mesh.positions, a, b, c))
        // Written for the SDK: the same corners, the winding the SDK's single sided quad gives its front
        assertEquals(listOf(a, c, b), indices.copyOfRange(3 * t, 3 * t + 3).toList())
        assertTrue(facesOrigin(positions, indices[3 * t], indices[3 * t + 1], indices[3 * t + 2]))
        assertFalse(facesOrigin(positions, a, b, c))
      }
    }
    // Written in place, as the viewer does after flatten
    val flat = SceneNavigator.flatten(scene.meshes[0], 1.0, 2.25, FloatArray(scene.meshes[0].positions.size))
    assertTrue(SdkFrame.positions(flat, flat).all { it.isFinite() })
    assertEquals(2.25f, flat[2], 1e-6f)
  }
}
