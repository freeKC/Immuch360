package app.alextran.immich.spherical

import android.opengl.Matrix
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.sin
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The controls of the 360° photo viewer in the 360° video player of the phones (issue 20): the pitch range, the zoom
 * limits, the gyroscope (the same cases as the Dart tests of applyGyroRotation, panorama_gyro_test.dart), and the view
 * matrix handed to Media3, checked against the matrices Media3's own touch built before (with the test copy of
 * android.opengl.Matrix).
 */
class SphereLookMathTest {
  private val step = (0.1 * 180 / PI).toFloat()

  /** Where the camera of [matrix] looks in the world, and its up direction, without the zoom */
  private fun forward(matrix: FloatArray): Triple<Float, Float, Float> {
    // The view matrix maps the world to the camera: its third row, negated, is the forward direction
    return Triple(-matrix[2], -matrix[6], -matrix[10])
  }

  private fun up(matrix: FloatArray): Triple<Float, Float, Float> {
    val k = SphereLookMath.zoomScale(SphereLookMath.DEFAULT_FOV)
    return Triple(matrix[1] / k, matrix[5] / k, matrix[9] / k)
  }

  /** The view Media3's renderer drew from its touch offsets, without the orientation sensor (a TV, or the sensor off) */
  private fun media3View(yawOffset: Float, pitchOffset: Float): FloatArray {
    val yaw = FloatArray(16)
    val pitch = FloatArray(16)
    val view = FloatArray(16)
    // Renderer.onScrollChange and updatePitchMatrix, with the upright roll of pi
    Matrix.setRotateM(yaw, 0, -yawOffset, 0f, 1f, 0f)
    Matrix.setRotateM(pitch, 0, -pitchOffset, cos(PI).toFloat(), sin(PI).toFloat(), 0f)
    // pitch · device (identity) · yaw
    Matrix.multiplyMM(view, 0, pitch, 0, yaw, 0)
    return view
  }

  private fun assertMatrix(expected: FloatArray, actual: FloatArray, tolerance: Float, message: String) {
    for (i in 0 until 16) assertEquals("$message, element $i", expected[i], actual[i], tolerance)
  }

  @Test
  fun aDragReachesStraightUpAndStraightDown() {
    val portrait = SphereLookMath.verticalFov(90f, 1080, 2340)
    val max = SphereLookMath.maxLatitude(halfSphere = false, verticalFov = portrait)
    assertEquals(90f, max, 0f)
    // A long drag down looks up, to the zenith and no further
    var look = SphereLook()
    repeat(40) { look = SphereLookMath.drag(look, 0f, 200f, max) }
    assertEquals(90f, look.latitude, 0f)
    var matrix = SphereLookMath.viewMatrix(look)
    assertEquals(1f, forward(matrix).second, 1e-6f)
    // And up, to the nadir
    repeat(80) { look = SphereLookMath.drag(look, 0f, -200f, max) }
    assertEquals(-90f, look.latitude, 0f)
    matrix = SphereLookMath.viewMatrix(look)
    assertEquals(-1f, forward(matrix).second, 1e-6f)
  }

  @Test
  fun theViewNeverFlipsOver() {
    // Whatever the drags, the camera stays upright: its up direction never points down, the latitude is its pitch
    val random = Random(20)
    var look = SphereLook()
    repeat(2000) {
      look = SphereLookMath.drag(look, random.nextFloat() * 800 - 400, random.nextFloat() * 800 - 400, 90f)
      val matrix = SphereLookMath.viewMatrix(look)
      assertTrue("upright at ${look.latitude}", up(matrix).second >= -1e-6f)
      assertEquals(sin(look.latitude * PI / 180).toFloat(), forward(matrix).second, 1e-5f)
      assertTrue(look.latitude in -90f..90f)
    }
  }

  @Test
  fun theDragsTurnAsMedia3sTouchDidBelowItsLimit() {
    // 25 pixels per degree at the default field of view, the same picture as Media3's touch drew, so the horizontal drag
    // and the start of a vertical one are unchanged
    val random = Random(14)
    var look = SphereLook()
    var yawOffset = 0f
    var pitchOffset = 0f
    repeat(300) {
      val dx = random.nextFloat() * 200 - 100
      val dy = random.nextFloat() * 60 - 30
      // TouchTracker.onScroll with the upright roll: x grows with dx, y falls with dy, clamped at 45 degrees
      val nextPitch = pitchOffset - dy / 25f
      if (abs(nextPitch) > 44f) return@repeat
      yawOffset += dx / 25f
      pitchOffset = nextPitch
      look = SphereLookMath.drag(look, dx, dy, 90f)
      // The longitude is kept within one turn: the same rotation as Media3's unbounded yaw
      assertMatrix(media3View(yawOffset, pitchOffset), SphereLookMath.viewMatrix(look), 2e-4f, "drag ${it}")
    }
    assertEquals(-yawOffset, unwrap(look.longitude, -yawOffset), 1e-2f)
  }

  private fun unwrap(longitude: Float, near: Float): Float {
    var value = longitude
    while (value - near > 180f) value -= 360f
    while (near - value > 180f) value += 360f
    return value
  }

  @Test
  fun aDragToTheLeftLooksRightAndADragDownLooksUp() {
    val look = SphereLookMath.drag(SphereLook(), -250f, 0f, 90f)
    assertEquals(10f, look.longitude, 1e-4f)
    assertTrue(forward(SphereLookMath.viewMatrix(look)).first > 0f)
    assertEquals(10f, SphereLookMath.drag(SphereLook(), 0f, 250f, 90f).latitude, 1e-4f)
    // Zoomed in to 45 degrees, half as fast: the picture still follows the finger
    assertEquals(5f, SphereLookMath.drag(SphereLook(fov = 45f), -250f, 0f, 90f).longitude, 1e-4f)
  }

  @Test
  fun theOpeningViewIsTheMiddleOfTheFrameAsBefore() {
    assertMatrix(media3View(0f, 0f), SphereLookMath.viewMatrix(SphereLook()), 1e-6f, "opening view")
  }

  @Test
  fun aHalfSphereStopsWhereTheEdgeOfTheScreenReachesThePole() {
    // Portrait at the default field of view: 45 degrees, where Media3's touch stopped
    val portrait = SphereLookMath.verticalFov(90f, 1080, 2340)
    assertEquals(90f, portrait, 1e-3f)
    assertEquals(45f, SphereLookMath.maxLatitude(halfSphere = true, verticalFov = portrait), 1e-3f)
    // Zoomed in, further
    assertEquals(75f, SphereLookMath.maxLatitude(true, SphereLookMath.verticalFov(30f, 1080, 2340)), 1e-3f)
    // Zoomed out to the limit, less far
    assertEquals(32.5f, SphereLookMath.maxLatitude(true, SphereLookMath.verticalFov(115f, 1080, 2340)), 1e-3f)
    // A drag stops there
    var look = SphereLook()
    repeat(10) { look = SphereLookMath.drag(look, 0f, 500f, SphereLookMath.maxLatitude(true, portrait)) }
    assertEquals(45f, look.latitude, 0f)
  }

  @Test
  fun theVerticalFieldOfViewFollowsMedia3sProjection() {
    // Media3 draws 90 degrees across the longer side: vertical in portrait, horizontal in landscape
    assertEquals(90f, SphereLookMath.verticalFov(90f, 1080, 2340), 1e-3f)
    val landscape = (2 * atan(1080.0 / 2340.0) * 180 / PI).toFloat()
    assertEquals(landscape, SphereLookMath.verticalFov(90f, 2340, 1080), 1e-3f)
    // A square screen counts as portrait, as in Media3
    assertEquals(60f, SphereLookMath.verticalFov(60f, 1000, 1000), 1e-3f)
    assertEquals(60f, SphereLookMath.verticalFov(60f, 0, 0), 0f)
  }

  @Test
  fun thePinchKeepsThePhotoViewersLimits() {
    assertEquals(45f, SphereLookMath.pinchFov(90f, 2f), 1e-4f)
    assertEquals(15f, SphereLookMath.pinchFov(90f, 10f), 0f)
    assertEquals(115f, SphereLookMath.pinchFov(90f, 0.5f), 0f)
    assertEquals(90f, SphereLookMath.pinchFov(90f, 0f), 0f)
    assertEquals(90f, SphereLookMath.pinchFov(90f, Float.NaN), 0f)
    assertEquals(115f, SphereLookMath.clamp(SphereLook(fov = 200f), 90f).fov, 0f)
    assertEquals(15f, SphereLookMath.clamp(SphereLook(fov = 1f), 90f).fov, 0f)
  }

  @Test
  fun aDoubleTapZoomsInThenBackLikeThePhotoViewer() {
    assertEquals(45f, SphereLookMath.doubleTapFov(90f), 0f)
    assertEquals(90f, SphereLookMath.doubleTapFov(45f), 0f)
    assertEquals(90f, SphereLookMath.doubleTapFov(46f), 0f)
    assertEquals(45f, SphereLookMath.doubleTapFov(47f), 0f)
    assertEquals(45f, SphereLookMath.doubleTapFov(115f), 0f)
    assertEquals(90f, SphereLookMath.doubleTapFov(15f), 0f)
  }

  @Test
  fun theZoomScalesThePictureAgainstMedia3s90Degrees() {
    assertEquals(1f, SphereLookMath.zoomScale(90f), 1e-6f)
    assertEquals((1 / Math.tan(Math.toRadians(22.5))).toFloat(), SphereLookMath.zoomScale(45f), 1e-5f)
    assertTrue(SphereLookMath.zoomScale(115f) < 1f)
    // The zoom changes how much shows, never where the view looks
    val look = SphereLook(longitude = 30f, latitude = 20f)
    val wide = SphereLookMath.viewMatrix(look)
    val close = SphereLookMath.viewMatrix(look.copy(fov = 30f))
    for (i in listOf(2, 6, 10)) assertEquals(wide[i], close[i], 1e-6f)
  }

  @Test
  fun portraitGyroscopeTurnsLikeThePhotoViewer() {
    // Positive y is counterclockwise seen from above: the phone turns left
    val left = SphereLookMath.gyro(SphereLook(), 0f, 0.1f, 0f, 1f, SphereLookMath.ROTATION_0, 90f)
    assertEquals(-5.73f, left.longitude, 0.01f)
    assertEquals(0f, left.latitude, 0f)
    // Top of the phone towards the user: its back points higher
    val up = SphereLookMath.gyro(SphereLook(), 0.1f, 0f, 0f, 1f, SphereLookMath.ROTATION_0, 90f)
    assertEquals(5.73f, up.latitude, 0.01f)
    assertEquals(0f, up.longitude, 0f)
    // Over dt
    assertEquals(step / 50, SphereLookMath.gyro(SphereLook(), 0f, -0.1f, 0f, 1f / 50, 0, 90f).longitude, 1e-4f)
    // The roll around z is ignored
    assertEquals(SphereLook(), SphereLookMath.gyro(SphereLook(), 0f, 0f, 1f, 1f, 0, 90f))
  }

  @Test
  fun theGyroscopeStopsAtThePoles() {
    assertEquals(90f, SphereLookMath.gyro(SphereLook(latitude = 89f), 1f, 0f, 0f, 1f, 0, 90f).latitude, 0f)
    assertEquals(-90f, SphereLookMath.gyro(SphereLook(latitude = -89f), -1f, 0f, 0f, 1f, 0, 90f).latitude, 0f)
  }

  @Test
  fun landscapeSwapsTheAxesWithTheSideOfTheTop() {
    // ROTATION_90, the top on the left: device x points up, device y points left
    var look = SphereLookMath.gyro(SphereLook(), 0.1f, 0f, 0f, 1f, SphereLookMath.ROTATION_90, 90f)
    assertEquals(-step, look.longitude, 1e-4f)
    assertEquals(0f, look.latitude, 1e-6f)
    look = SphereLookMath.gyro(SphereLook(), 0f, 0.1f, 0f, 1f, SphereLookMath.ROTATION_90, 90f)
    assertEquals(0f, look.longitude, 1e-6f)
    assertEquals(-step, look.latitude, 1e-4f)
    // ROTATION_270, the top on the right
    look = SphereLookMath.gyro(SphereLook(), 0.1f, 0f, 0f, 1f, SphereLookMath.ROTATION_270, 90f)
    assertEquals(step, look.longitude, 1e-4f)
    look = SphereLookMath.gyro(SphereLook(), 0f, 0.1f, 0f, 1f, SphereLookMath.ROTATION_270, 90f)
    assertEquals(step, look.latitude, 1e-4f)
    // Upside down, both axes reversed
    look = SphereLookMath.gyro(SphereLook(), 0.1f, 0.1f, 0f, 1f, SphereLookMath.ROTATION_180, 90f)
    assertEquals(step, look.longitude, 1e-4f)
    assertEquals(-step, look.latitude, 1e-4f)
  }

  @Test
  fun theSameMovementOfThePhoneMovesTheViewTheSameWayInEveryRotation() {
    // The up and right axes of the screen, in device coordinates, for each rotation of the display
    val axes =
      mapOf(
        SphereLookMath.ROTATION_0 to (Pair(0f, 1f) to Pair(1f, 0f)),
        SphereLookMath.ROTATION_90 to (Pair(1f, 0f) to Pair(0f, -1f)),
        SphereLookMath.ROTATION_180 to (Pair(0f, -1f) to Pair(-1f, 0f)),
        SphereLookMath.ROTATION_270 to (Pair(-1f, 0f) to Pair(0f, 1f)),
      )
    for ((rotation, axis) in axes) {
      val (up, right) = axis
      // Turning around the screen's up axis, then tilting around its right axis
      val turn = SphereLookMath.gyro(SphereLook(), 0.1f * up.first, 0.1f * up.second, 0f, 1f, rotation, 90f)
      assertEquals("turn at $rotation", -step, turn.longitude, 1e-4f)
      assertEquals("turn at $rotation", 0f, turn.latitude, 1e-4f)
      val tilt = SphereLookMath.gyro(SphereLook(), 0.1f * right.first, 0.1f * right.second, 0f, 1f, rotation, 90f)
      assertEquals("tilt at $rotation", step, tilt.latitude, 1e-4f)
      assertEquals("tilt at $rotation", 0f, tilt.longitude, 1e-4f)
    }
  }

  @Test
  fun noiseDoesNotMoveTheView() {
    // A phone at rest on a table: rates under 0.005 rad/s are noise, the view does not drift
    var look = SphereLook(longitude = 12f, latitude = -7f)
    repeat(50 * 60) { look = SphereLookMath.gyro(look, 0.004f, -0.0049f, 0.003f, 1f / 50, 0, 90f) }
    assertEquals(SphereLook(longitude = 12f, latitude = -7f), look)
  }

  @Test
  fun theStepBetweenSamples() {
    assertEquals(0.02f, SphereLookMath.gyroStep(0L, 123L), 0f)
    assertEquals(0.01f, SphereLookMath.gyroStep(1_000_000_000L, 1_010_000_000L), 1e-6f)
    // A pause of the sensor, or a clock that went back
    assertEquals(0.02f, SphereLookMath.gyroStep(1_000_000_000L, 2_000_000_000L), 0f)
    assertEquals(0.02f, SphereLookMath.gyroStep(2_000_000_000L, 1_000_000_000L), 0f)
  }

  @Test
  fun theLongitudeStaysWithinOneTurn() {
    assertEquals(-170f, SphereLookMath.wrapLongitude(190f), 1e-4f)
    assertEquals(170f, SphereLookMath.wrapLongitude(-190f), 1e-4f)
    assertEquals(-180f, SphereLookMath.wrapLongitude(180f), 1e-4f)
    assertEquals(10f, SphereLookMath.wrapLongitude(3610f), 1e-3f)
    assertEquals(45f, SphereLookMath.wrapLongitude(45f), 0f)
    var look = SphereLook()
    repeat(1000) { look = SphereLookMath.drag(look, 2500f, 0f, 90f) }
    assertTrue(look.longitude >= -180f && look.longitude < 180f)
  }

  @Test
  fun theTopBarFitsAPhoneInPortrait() {
    // 360 dp: the close button and five buttons of 48 dp, the coverage button a little wider, the padding of 8 dp on
    // each side and the margin of the title, leave the title room once the buttons sit side by side
    assertEquals(0, TopBarFit.buttonMarginDp(360, 400))
    val used = 8 + 48 + 8 + 4 * 48 + 56 + 8
    assertTrue(360 - used >= 40)
    // Wider, the usual margins
    assertEquals(8, TopBarFit.buttonMarginDp(400, 400))
    assertEquals(8, TopBarFit.buttonMarginDp(800, 400))
    // An unknown width keeps the layout's
    assertEquals(8, TopBarFit.buttonMarginDp(0, 400))
  }
}
