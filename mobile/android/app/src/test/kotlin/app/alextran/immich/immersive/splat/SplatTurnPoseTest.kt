package app.alextran.immich.immersive.splat

import app.alextran.immich.immersive.VolumetricSceneSpec.SafeZone
import app.alextran.immich.immersive.scene.SceneNavigation
import app.alextran.immich.immersive.scene.SceneNavigator
import com.meta.spatial.core.Pose
import com.meta.spatial.core.Quaternion
import com.meta.spatial.core.Vector3
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pose the splat module gets after a glide and a turn of the right thumbstick (FreeKC's report of 1 November 2026:
 * a turn after a glide put him back in the middle of the scene). The pose of the splat is the root of its navigator
 * then its place in that frame (SplatPose, as SplatStage.poseOf takes it), converted once for the module
 * (SplatModuleFrame.toModule); the module shows a point p of the file at M (t + q p), M = diag(1, 1, -1), as
 * measured on a Quest 3 on 31 October 2026. After a turn the point of the file under the user is the one the glide took him to,
 * and the splat turned about him by the step; Reset alone puts him back where the splat opened.
 */
class SplatTurnPoseTest {
  /** v rotated by the unit quaternion (w, x, y, z): v' = q v q* */
  private fun rotate(w: Double, x: Double, y: Double, z: Double, v: DoubleArray): DoubleArray {
    val tx = 2 * (y * v[2] - z * v[1])
    val ty = 2 * (z * v[0] - x * v[2])
    val tz = 2 * (x * v[1] - y * v[0])
    return doubleArrayOf(
      v[0] + w * tx + (y * tz - z * ty),
      v[1] + w * ty + (z * tx - x * tz),
      v[2] + w * tz + (x * ty - y * tx),
    )
  }

  /** The pose as the module gets it: computed in the frame of the SDK, converted once */
  private fun given(frame: SceneNavigation, position: Vector3, rotation: Quaternion): DoubleArray {
    val pose: Pose = SplatPose.of(frame, position, rotation)
    val values = floatArrayOf(pose.t.x, pose.t.y, pose.t.z, pose.q.w, pose.q.x, pose.q.y, pose.q.z)
    return SplatModuleFrame.toModule(values).map { it.toDouble() }.toDoubleArray()
  }

  /** Where the module shows the point [p] of the file for [given]: M (t + q p) */
  private fun shown(given: DoubleArray, p: DoubleArray): DoubleArray {
    val turned = rotate(given[3], given[4], given[5], given[6], p)
    return doubleArrayOf(given[0] + turned[0], given[1] + turned[1], -(given[2] + turned[2]))
  }

  /** The point of the file the module shows at [world]: p = q* (M world - t) */
  private fun fileAt(given: DoubleArray, world: DoubleArray): DoubleArray {
    val local = doubleArrayOf(world[0] - given[0], world[1] - given[1], -world[2] - given[2])
    return rotate(given[3], -given[4], -given[5], -given[6], local)
  }

  /** The yaw of the x axis of the file as the module shows it, in degrees from +z of the SDK towards +x */
  private fun fileYaw(given: DoubleArray): Double {
    val origin = shown(given, doubleArrayOf(0.0, 0.0, 0.0))
    val x = shown(given, doubleArrayOf(1.0, 0.0, 0.0))
    return Math.toDegrees(atan2(x[0] - origin[0], x[2] - origin[2]))
  }

  private fun assertPoint(message: String, expected: DoubleArray, actual: DoubleArray, within: Double = 1e-4) {
    for (axis in 0 until 3) assertEquals("$message, axis $axis", expected[axis], actual[axis], within)
  }

  private fun angle(degrees: Double): Double = Math.IEEEremainder(degrees, 360.0)

  private fun distance(a: DoubleArray, b: DoubleArray): Double =
    Math.sqrt((0 until 3).sumOf { (a[it] - b[it]) * (a[it] - b[it]) })

  @Test
  fun `a turn after a glide keeps the point of the file under the user, the splat turned about him by the step`() {
    // A place, its centre 0.3 m under the eyes, as it opens upright, and the same turned to Z up
    for (rotation in listOf(Quaternion(0f, 0f, 0f), Quaternion(90f, 0f, 0f))) {
      val position = Vector3(0f, -0.3f, 0f)
      val navigator = SceneNavigator(SafeZone(5.0, 5.0, 5.0, 5.0), glideSpeed = 0.5)
      val gazeYaw = Math.toRadians(20.0)
      val gazeX = sin(gazeYaw)
      val gazeZ = cos(gazeYaw)
      val head = doubleArrayOf(0.3, 1.6, -0.2)
      navigator.anchorInSdk(head[0], head[1], head[2], gazeX, gazeZ)
      fun frame(forward: Double, x: Double = head[0], z: Double = head[2]) =
        navigator.updateInSdk(x, head[1], z, gazeX, gazeZ, 0.0, forward, 0.011)
      val opened = given(frame(0.0), position, rotation)
      val start = fileAt(opened, head)
      // Two seconds forward, then stopped
      repeat(182) { frame(1.0) }
      repeat(40) { frame(0.0) }
      val glided = given(frame(0.0), position, rotation)
      val reached = fileAt(glided, head)
      val travelled = distance(reached, start)
      assertTrue("glided $travelled m", travelled > 0.9)
      // A snap turn to the right: the yaw of the SDK of snapTurnDegrees(TURN_RIGHT, 30, false)
      navigator.turnInSdk(head[0], head[2], -30.0)
      val turned = given(frame(0.0), position, rotation)
      // Under the user, the same point of the file: no jump back to the middle of the scene
      assertPoint("the point under the user", reached, fileAt(turned, head))
      // The splat turned by the step about the user, the way a snap turn of the spheres turns
      assertEquals(-30.0, angle(fileYaw(turned) - fileYaw(glided)), 1e-3)
      // The head, a step aside, still over the file where the glide and the step took it
      val aside = doubleArrayOf(head[0] + 0.4, head[1], head[2])
      val stepped = given(frame(0.0, x = aside[0]), position, rotation)
      val underStep = fileAt(stepped, aside)
      assertEquals(0.4, distance(underStep, reached), 1e-4)
      // Reset: placed again from the head of now, as the splat opened
      navigator.anchorInSdk(aside[0], aside[1], aside[2], gazeX, gazeZ)
      val reset = given(frame(0.0, x = aside[0]), position, rotation)
      assertPoint("Reset", start, fileAt(reset, aside))
    }
  }
}
