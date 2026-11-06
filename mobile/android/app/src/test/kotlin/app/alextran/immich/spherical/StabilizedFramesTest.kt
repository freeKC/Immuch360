package app.alextran.immich.spherical

import androidx.media3.exoplayer.video.spherical.CameraMotionListener
import androidx.media3.exoplayer.video.spherical.RotationQueueForTests
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The rotation of each frame of the 360° player (issue 14): what the frame listener of the spherical view hands to the
 * camera motion listener of the renderer before each frame, at which time, the reset once the table goes, the time
 * base of the side by side effect, and what Media3's own FrameRotationQueue (1.10.0, run here with the test copy of
 * android.opengl.Matrix) makes of it: the rotation of each frame when the renderer draws it, and the matrix of a
 * correction K in the frame of its sphere.
 */
class StabilizedFramesTest {
  private val degree = PI / 180

  /** What a camera motion listener and the scene get, in order */
  private class Recorder : CameraMotionListener {
    val events = mutableListOf<String>()
    val rotations = mutableListOf<Pair<Long, FloatArray>>()

    override fun onCameraMotion(timeUs: Long, rotation: FloatArray) {
      events += "motion $timeUs"
      rotations += timeUs to rotation
    }

    override fun onCameraMotionReset() {
      events += "reset"
    }

    fun frame(timeUs: Long): () -> Unit = { events += "frame $timeUs" }
  }

  /** The quaternion (w, x, y, z) of the rotation by [angle] radians about [axis] */
  private fun quaternion(axis: DoubleArray, angle: Double): DoubleArray {
    val n = sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2])
    val s = sin(angle / 2) / n
    return doubleArrayOf(cos(angle / 2), axis[0] * s, axis[1] * s, axis[2] * s)
  }

  /** A table of turns about the view x axis: frame i at [timesUs] i turned by [degrees] i */
  private fun table(timesUs: LongArray, degrees: DoubleArray): StabilizationTable {
    val values = DoubleArray(4 * timesUs.size)
    for (i in timesUs.indices) quaternion(doubleArrayOf(1.0, 0.0, 0.0), degrees[i] * degree).copyInto(values, 4 * i)
    return StabilizationTable.of(timesUs, values)!!
  }

  /** The rotation matrix (row major, 3 x 3) of the unit quaternion [q] */
  private fun matrixOf(q: DoubleArray): Array<DoubleArray> {
    val (w, x, y, z) = q.toList()
    return arrayOf(
      doubleArrayOf(1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)),
      doubleArrayOf(2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)),
      doubleArrayOf(2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)),
    )
  }

  /** The 3 x 3 rotation part (row major) of a column major 4 x 4 OpenGL matrix */
  private fun rotationPart(m: FloatArray) = Array(3) { r -> DoubleArray(3) { k -> m[4 * k + r].toDouble() } }

  private fun assertMatrix(expected: Array<DoubleArray>, actual: Array<DoubleArray>, tolerance: Double, what: String) {
    for (r in 0 until 3) for (k in 0 until 3) {
      assertEquals("$what, element ($r, $k)", expected[r][k], actual[r][k], tolerance)
    }
  }

  /** The angle in degrees of the turn about x that the column major matrix [m] makes */
  private fun angleAboutX(m: FloatArray): Double {
    assertEquals("no turn but about x", 1.0, m[0].toDouble(), 1e-6)
    return Math.toDegrees(kotlin.math.atan2(m[6].toDouble(), m[5].toDouble()))
  }

  @Test
  fun theRotationOfAFrameGoesToTheRendererBeforeTheFrameAtItsPresentationTime() {
    val recorder = Recorder()
    val table = table(longArrayOf(0, 40_000, 80_000), doubleArrayOf(0.0, 2.0, 4.0))
    var firstFrames = 0
    val frames = StabilizedFrames { firstFrames++ }
    frames.table = table

    frames.onFrame(40_000, recorder, recorder.frame(40_000))
    frames.onFrame(80_000, recorder, recorder.frame(80_000))

    assertEquals(listOf("motion 40000", "frame 40000", "motion 80000", "frame 80000"), recorder.events)
    assertArrayEquals(table.angleAxisAt(40_000), recorder.rotations[0].second, 0f)
    assertArrayEquals(table.angleAxisAt(80_000), recorder.rotations[1].second, 0f)
    assertEquals("the notice of the first stabilised frame, once", 1, firstFrames)
  }

  @Test
  fun aPlayerStartedAtAPositionLooksTheTableUpOnTheTimelineOfTheVideo() {
    val recorder = Recorder()
    val table = table(longArrayOf(0, 5_000_000, 5_040_000), doubleArrayOf(0.0, 3.0, 6.0))
    val frames = StabilizedFrames()
    frames.table = table
    // The side by side effect of a player started at 5 s: its frame listener gets 0 for the frame at 5 s
    frames.timeBaseUs = StabilizedFrames.timeBaseUs(sideBySideEffect = true, startPositionMs = 5_000)
    assertEquals(5_000_000L, frames.timeBaseUs)

    frames.onFrame(40_000, recorder, recorder.frame(40_000))

    // Keyed on the time the listener got, the renderer polls with it; the rotation is the one of the frame at 5.04 s
    assertEquals(40_000L, recorder.rotations.single().first)
    assertArrayEquals(table.angleAxisAt(5_040_000), recorder.rotations.single().second, 0f)
  }

  @Test
  fun onlyTheSideBySideEffectShiftsTheTimes() {
    assertEquals(0L, StabilizedFrames.timeBaseUs(sideBySideEffect = false, startPositionMs = 5_000))
    assertEquals(0L, StabilizedFrames.timeBaseUs(sideBySideEffect = true, startPositionMs = 0))
    assertEquals(0L, StabilizedFrames.timeBaseUs(sideBySideEffect = true, startPositionMs = -1))
    assertEquals(12_345_000L, StabilizedFrames.timeBaseUs(sideBySideEffect = true, startPositionMs = 12_345))
  }

  @Test
  fun oneResetBringsTheFramesBackOnceTheTableGoes() {
    val recorder = Recorder()
    val frames = StabilizedFrames()

    // No table ever: nothing but the frames
    frames.onFrame(0, recorder, recorder.frame(0))
    assertEquals(listOf("frame 0"), recorder.events)

    frames.table = table(longArrayOf(0, 40_000), doubleArrayOf(0.0, 1.0))
    frames.onFrame(40_000, recorder, recorder.frame(40_000))
    // The switch off: one reset before the next frame, then the frames alone
    frames.table = null
    frames.onFrame(80_000, recorder, recorder.frame(80_000))
    frames.onFrame(120_000, recorder, recorder.frame(120_000))

    assertEquals(
      listOf("frame 0", "motion 40000", "frame 40000", "reset", "frame 80000", "frame 120000"),
      recorder.events,
    )
  }

  @Test
  fun aReplacedPlayerWithoutATableResetsWhatThePlayerBeforeLeft() {
    // One per activity: the frame listener of the next player (another motion listener of the same view) resets it
    val before = Recorder()
    val next = Recorder()
    val frames = StabilizedFrames()
    frames.table = table(longArrayOf(0, 40_000), doubleArrayOf(0.0, 1.0))
    frames.onFrame(0, before, before.frame(0))
    // Replanned to the unstitched frame: no table any more
    frames.table = null
    frames.onFrame(0, next, next.frame(0))
    frames.onFrame(40_000, next, next.frame(40_000))
    assertEquals(listOf("reset", "frame 0", "frame 40000"), next.events)
  }

  @Test
  fun media3DrawsEachFrameWithItsOwnRotationAcrossASeekAndAReset() {
    val table = table(longArrayOf(0, 40_000, 80_000, 120_000), doubleArrayOf(0.0, 2.0, 4.0, 6.0))
    val queue = RotationQueueForTests()
    val listener =
      object : CameraMotionListener {
        override fun onCameraMotion(timeUs: Long, rotation: FloatArray) = queue.setRotation(timeUs, rotation)

        override fun onCameraMotionReset() = queue.reset()
      }
    val frames = StabilizedFrames()
    frames.table = table
    val matrix = FloatArray(16)
    // The renderer draws the frame of the time it was handed with, polling the queue with that time
    val drawn = mutableListOf<Double>()
    fun play(timeUs: Long) =
      frames.onFrame(timeUs, listener) {
        assertTrue("a rotation for the frame at $timeUs", queue.pollRotationMatrix(matrix, timeUs))
        drawn += angleAboutX(matrix)
      }

    // Frame 0 has no turn: Media3 recentres on it with the identity
    play(0)
    play(40_000)
    play(80_000)
    // A seek back: the time goes back, the queue starts again, the frame gets its own rotation
    play(40_000)
    play(120_000)
    // Media3 negates y and z, not x: the turn about the view x keeps its sign in the frame of its sphere
    assertEquals(listOf(0.0, 2.0, 4.0, 2.0, 6.0), drawn.map { Math.round(it * 1e4) / 1e4 })

    // The switch off: the reset empties the queue, the renderer draws the frames as they are
    frames.table = null
    var polled = true
    frames.onFrame(160_000, listener) { polled = queue.pollRotationMatrix(matrix, 160_000) }
    assertFalse("nothing in the queue after the reset", polled)
  }

  @Test
  fun media3TurnsItsSphereByTheCorrectionSeenFromItsOwnFrame() {
    // The equirectangular mesh of Media3 puts the view direction (x, y, z) of the picture at F (x, y, z), F = (x, -y,
    // -z) (StabilizationTableTest), and its renderer draws each vertex turned by the matrix of the queue. The point at
    // view direction d is meant to show at K d: the matrix must be F K F.
    val random = java.util.Random(14)
    val f = arrayOf(doubleArrayOf(1.0, 0.0, 0.0), doubleArrayOf(0.0, -1.0, 0.0), doubleArrayOf(0.0, 0.0, -1.0))
    fun times(a: Array<DoubleArray>, b: Array<DoubleArray>) =
      Array(3) { r -> DoubleArray(3) { k -> a[r][0] * b[0][k] + a[r][1] * b[1][k] + a[r][2] * b[2][k] } }
    for (n in 0 until 50) {
      val q = DoubleArray(4) { random.nextGaussian() }
      val norm = sqrt(q.sumOf { it * it })
      for (i in 0 until 4) q[i] /= norm
      val table = StabilizationTable.of(longArrayOf(0, 40_000), doubleArrayOf(1.0, 0.0, 0.0, 0.0, *q))!!
      val queue = RotationQueueForTests()
      val matrix = FloatArray(16)
      // Recentred on an identity first, so that the recentre of Media3 (a yaw from its first rotation) is out of it
      queue.setRotation(0, table.angleAxisAt(0))
      assertTrue(queue.pollRotationMatrix(matrix, 0))
      queue.setRotation(40_000, table.angleAxisAt(40_000))
      assertTrue(queue.pollRotationMatrix(matrix, 40_000))
      assertMatrix(times(times(f, matrixOf(q)), f), rotationPart(matrix), 2e-5, "rotation $n")
    }
  }

  @Test
  fun theRecentreOfMedia3IsAYawAboutTheVerticalOfTheDisplay() {
    // The first rotation of a queue sets Media3's recentre: a turn about the y axis of its sphere (the vertical of
    // the display) whatever that rotation, so the level of the frames stays; only the heading moves
    val random = java.util.Random(5)
    for (n in 0 until 20) {
      val rotation = FloatArray(16)
      android.opengl.Matrix.setRotateM(
        rotation,
        0,
        (random.nextDouble() * 360 - 180).toFloat(),
        random.nextGaussian().toFloat(),
        random.nextGaussian().toFloat(),
        random.nextGaussian().toFloat(),
      )
      val recentre = FloatArray(16)
      RotationQueueForTests.computeRecenterMatrix(recentre, rotation)
      val m = rotationPart(recentre)
      assertEquals("rotation $n keeps the vertical", 1.0, m[1][1], 1e-6)
      for (k in listOf(0, 2)) {
        assertEquals(0.0, m[1][k], 1e-6)
        assertEquals(0.0, m[k][1], 1e-6)
      }
      assertEquals(1.0, m[0][0] * m[0][0] + m[2][0] * m[2][0], 1e-5)
      assertEquals(m[0][0], m[2][2], 1e-6)
    }
  }
}
