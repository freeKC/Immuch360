package app.alextran.immich.spherical

import androidx.media3.exoplayer.video.spherical.CameraMotionListener
import androidx.media3.exoplayer.video.spherical.RotationQueueForTests
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.asin
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

  // The recentre of Media3 (fix-stab-android-46): the frames start without their heading, then show the table exactly

  /** The Hamilton product a b of two quaternions (w, x, y, z): b, then a */
  private fun times(a: DoubleArray, b: DoubleArray) =
    doubleArrayOf(
      a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
      a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
      a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
      a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
    )

  private val xAxis = doubleArrayOf(1.0, 0.0, 0.0)
  private val yAxis = doubleArrayOf(0.0, 1.0, 0.0)

  /** What Media3 is meant to draw for the correction [k]: F K F, F = diag(1, -1, -1) (see the test above) */
  private fun meant(k: DoubleArray): Array<DoubleArray> {
    val m = matrixOf(k)
    val f = doubleArrayOf(1.0, -1.0, -1.0)
    return Array(3) { r -> DoubleArray(3) { c -> f[r] * m[r][c] * f[c] } }
  }

  /**
   * The angle in degrees between two rotations (row major 3 x 3), from their distance: |A - B| = 2 sqrt(2)
   * sin(angle / 2), which keeps its precision for small angles (an arc cosine of the trace loses it in the float
   * matrices of Media3)
   */
  private fun angleBetween(a: Array<DoubleArray>, b: Array<DoubleArray>): Double {
    var squares = 0.0
    for (r in 0 until 3) for (c in 0 until 3) squares += (a[r][c] - b[r][c]) * (a[r][c] - b[r][c])
    return Math.toDegrees(2 * asin((sqrt(squares) / (2 * sqrt(2.0))).coerceAtMost(1.0)))
  }

  /**
   * How far the vertical of the display drawn from [drawn] is from the one of [meant], in degrees: the level. M^T y is
   * the direction of the sphere drawn straight up; the recentre of Media3 turns about that y and leaves it.
   */
  private fun levelError(drawn: Array<DoubleArray>, meant: Array<DoubleArray>): Double {
    var squares = 0.0
    for (c in 0 until 3) squares += (drawn[1][c] - meant[1][c]) * (drawn[1][c] - meant[1][c])
    return Math.toDegrees(2 * asin((sqrt(squares) / 2).coerceAtMost(1.0)))
  }

  /** A camera motion listener in front of Media3's own queue */
  private fun listenerOf(queue: RotationQueueForTests) =
    object : CameraMotionListener {
      override fun onCameraMotion(timeUs: Long, rotation: FloatArray) = queue.setRotation(timeUs, rotation)

      override fun onCameraMotionReset() = queue.reset()
    }

  /**
   * Plays the frames at [timesUs] through [frames] into [queue] and returns what Media3 draws for each of them, null
   * for a frame the renderer did not draw ([drawn] says which it draws: it may miss the first ones)
   */
  private fun play(
    frames: StabilizedFrames,
    queue: RotationQueueForTests,
    timesUs: LongArray,
    motion: CameraMotionListener = listenerOf(queue),
    drawn: (Int) -> Boolean = { true },
  ): List<Array<DoubleArray>?> {
    val matrix = FloatArray(16)
    return timesUs.indices.map { i ->
      var shown: Array<DoubleArray>? = null
      frames.onFrame(timesUs[i], motion) {
        if (drawn(i)) {
          assertTrue("a rotation for frame $i", queue.pollRotationMatrix(matrix, timesUs[i]))
          shown = rotationPart(matrix)
        }
      }
      shown
    }
  }

  /**
   * 60 frames 33,366 us apart (29.97 frames a second) of a correction that shows the front 49 degrees to the right and
   * 10 degrees down, shaking
   */
  private val turnedTimes = LongArray(60) { it * 33_366L }
  private val turnedCorrections =
    Array(60) { i ->
      val shake = 1.5 * sin(i * 0.9)
      times(quaternion(yAxis, (49 + shake) * degree), quaternion(xAxis, (10 - shake) * degree))
    }
  private val turned = StabilizationTable.of(turnedTimes, DoubleArray(240) { turnedCorrections[it / 4][it % 4] })!!

  @Test
  fun media3AloneDrawsEveryFrameTurnedByTheHeadingOfTheFirstOne() {
    // What the player did before: the correction as it is, so the whole video shows 49 degrees off the table
    val queue = RotationQueueForTests()
    val matrix = FloatArray(16)
    for (i in turnedTimes.indices) {
      queue.setRotation(turnedTimes[i], turned.angleAxisAt(turnedTimes[i]))
      assertTrue(queue.pollRotationMatrix(matrix, turnedTimes[i]))
      val drawn = rotationPart(matrix)
      val error = angleBetween(drawn, meant(turnedCorrections[i]))
      assertEquals("frame $i, off by the heading of frame 0", 49.0, error, 1.0)
      assertEquals("frame $i keeps its level", 0.0, levelError(drawn, meant(turnedCorrections[i])), 1e-3)
    }
  }

  @Test
  fun theViewStartsWithoutTheHeadingThenShowsTheTableExactly() {
    val frames = StabilizedFrames()
    frames.table = turned
    val drawn = play(frames, RotationQueueForTests(), turnedTimes)
    // 300 ms (9 frames) without the heading, then 1 s (30 frames) to bring it back
    val hold = 9
    val exactFrom = hold + 30 - 1
    for (i in turnedTimes.indices) {
      val error = angleBetween(drawn[i]!!, meant(turnedCorrections[i]))
      assertEquals("frame $i is level", 0.0, levelError(drawn[i]!!, meant(turnedCorrections[i])), 1e-3)
      when {
        // The heading of each frame taken off: the front where the camera points, about 49 degrees from the table
        i < hold -> assertEquals("frame $i without its heading", 49.0, error, 2.0)
        i >= exactFrom -> assertEquals("frame $i shows the table", 0.0, error, 0.01)
      }
      if (i > 0) {
        val before = angleBetween(drawn[i - 1]!!, meant(turnedCorrections[i - 1]))
        // The share rises by at most 1.5 / 30 a frame (2.5 of the 49 degrees), plus the shake of the heading taken off
        assertTrue("frame $i: the heading comes back smoothly (${error - before} degrees)", abs(error - before) < 4.0)
      }
    }
  }

  @Test
  fun theTableIsExactWhicheverOfTheFirstFramesMedia3DrawsFirst() {
    // The renderer misses the first frames (busy, or frames dropped by its SurfaceTexture), and one more later on
    for (firstDrawn in listOf(1, 3, 8)) {
      val frames = StabilizedFrames()
      frames.table = turned
      val drawn = play(frames, RotationQueueForTests(), turnedTimes) { it >= firstDrawn && it != 20 }
      for (i in 38 until turnedTimes.size) {
        val error = angleBetween(drawn[i]!!, meant(turnedCorrections[i]))
        assertEquals("first drawn $firstDrawn, frame $i", 0.0, error, 0.01)
      }
    }
  }

  @Test
  fun theRealTablesOfAnX5AndOfAGoProEndOnTheirOwnHeading() {
    for ((name, table) in listOf("X5" to StabilizationSliceTables.x5, "GoPro" to StabilizationSliceTables.gopro)) {
      val times = LongArray(table.size) { table.firstTimeUs + it * HeadingFade.frameStepUs(table) }
      times[times.size - 1] = table.lastTimeUs
      val expected = times.map { meant(table.quaternionAt(it)) }
      // Before: the correction as it is
      val queue = RotationQueueForTests()
      val matrix = FloatArray(16)
      val before =
        times.indices.map { i ->
          queue.setRotation(times[i], table.angleAxisAt(times[i]))
          queue.pollRotationMatrix(matrix, times[i])
          angleBetween(rotationPart(matrix), expected[i])
        }
      // Now, with a hold of two frames and a fade of two, the slices being short
      val frames = StabilizedFrames(holdUs = 0, minHoldFrames = 2, fadeUs = 2 * HeadingFade.frameStepUs(table))
      frames.table = table
      val after = play(frames, RotationQueueForTests(), times).mapIndexed { i, m -> angleBetween(m!!, expected[i]) }
      assertTrue("$name: off by ${before.last()} degrees before", before.last() > 5.0)
      for (i in 3 until times.size) assertEquals("$name frame $i", 0.0, after[i], 0.01)
    }
  }

  @Test
  fun theSwitchOffAndOnAgainStartsWithoutTheHeadingAgain() {
    val queue = RotationQueueForTests()
    val frames = StabilizedFrames()
    frames.table = turned
    play(frames, queue, turnedTimes)
    // Off: one reset, the frames as they are
    frames.table = null
    play(frames, queue, longArrayOf(2_000_000)) { false }
    frames.table = turned
    val drawn = play(frames, queue, turnedTimes)
    assertEquals("without its heading again", 49.0, angleBetween(drawn[0]!!, meant(turnedCorrections[0])), 2.0)
    assertEquals(0.0, angleBetween(drawn.last()!!, meant(turnedCorrections.last())), 0.01)
  }

  @Test
  fun aResetOfTheQueueByMedia3ItselfStartsWithoutTheHeadingAgain() {
    // The camera motion renderer of a file with a CAMM track resets the queue at a seek and when its track goes
    val queue = RotationQueueForTests()
    val frames = StabilizedFrames()
    frames.table = turned
    val forwarding = frames.forwardingResets(listenerOf(queue))
    play(frames, queue, turnedTimes)
    forwarding.onCameraMotionReset()
    var drawn = play(frames, queue, turnedTimes)
    assertEquals(0.0, angleBetween(drawn.last()!!, meant(turnedCorrections.last())), 0.01)

    // The same reset not passed on: Media3 recentres on a frame that has its heading, the table is off for good
    play(frames, queue, turnedTimes)
    queue.reset()
    drawn = play(frames, queue, turnedTimes)
    assertTrue(angleBetween(drawn.last()!!, meant(turnedCorrections.last())) > 40.0)
  }

  @Test
  fun changingTheTableSaysWhetherAPausedFrameMustBeDrawnAgain() {
    val frames = StabilizedFrames()
    assertFalse("no table, still none", frames.changeTable(null))
    assertTrue("the table arrives", frames.changeTable(turned))
    assertFalse("the same table", frames.changeTable(turned))
    assertTrue("the switch off", frames.changeTable(null))
  }

  @Test
  fun theHeadingIsTheTurnAboutTheVerticalOfTheFrontShown() {
    for (yaw in listOf(-170.0, -49.0, 0.0, 19.0, 120.0)) {
      for (tilt in listOf(-30.0, 0.0, 10.0)) {
        val q = times(quaternion(yAxis, yaw * degree), quaternion(xAxis, tilt * degree))
        assertEquals("yaw $yaw tilt $tilt", yaw, Math.toDegrees(HeadingFade.heading(q)), 1e-9)
        // Taken off, the heading is gone and the level stays
        val off = HeadingFade.shown(q, HeadingFade.heading(q), 0.0)
        assertEquals(0.0, HeadingFade.heading(off), 1e-12)
        assertEquals(0.0, levelError(meant(off), meant(q)), 1e-6)
        assertTrue("all of it is q itself", HeadingFade.shown(q, HeadingFade.heading(q), 1.0) === q)
        val half = HeadingFade.shown(q, HeadingFade.heading(q), 0.5)
        assertEquals(yaw / 2, Math.toDegrees(HeadingFade.heading(half)), 1e-9)
      }
    }
    // Unwrapped next to the heading before, a turn through the back moves by a little, not by a whole turn
    assertEquals(181.0, Math.toDegrees(HeadingFade.unwrap(-179 * degree, 179 * degree)), 1e-9)
    assertEquals(-179.0, Math.toDegrees(HeadingFade.unwrap(-179 * degree, null)), 1e-9)
  }

  @Test
  fun theShareOfTheHeadingHoldsThenRisesSmoothly() {
    assertEquals(listOf(0.0, 0.0, 0.0), (0 until 3).map { HeadingFade.share(it, holdFrames = 3, fadeFrames = 4) })
    val fade = (3 until 8).map { HeadingFade.share(it, holdFrames = 3, fadeFrames = 4) }
    assertTrue("rising: $fade", fade.zipWithNext().all { (a, b) -> b >= a })
    assertEquals(1.0, fade[3], 0.0)
    assertEquals(1.0, fade[4], 0.0)
    assertEquals(1.0, HeadingFade.share(0, holdFrames = 0, fadeFrames = 0), 0.0)
    assertEquals(9, HeadingFade.frames(StabilizedFrames.HOLD_US, 33_366))
    assertEquals(30, HeadingFade.frames(StabilizedFrames.FADE_US, 33_366))
    assertEquals(10, HeadingFade.frames(StabilizedFrames.HOLD_US, 33_333))
    assertEquals(33_366L, HeadingFade.frameStepUs(turned))
    val identities = DoubleArray(12) { if (it % 4 == 0) 1.0 else 0.0 }
    assertEquals(33_000L, HeadingFade.frameStepUs(StabilizationTable.of(longArrayOf(0, 33_000, 66_000), identities)!!))
  }
}
