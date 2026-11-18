package app.alextran.immich.spherical

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Bundle
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.Surface
import android.view.View
import android.view.ViewConfiguration
import android.view.animation.DecelerateInterpolator
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.video.spherical.SphereViewDriver
import androidx.media3.exoplayer.video.spherical.SphericalGLSurfaceView
import kotlin.math.hypot

/**
 * The controls of the 360° photo viewer on the spherical view of the 360° video player of the phones and tablets
 * (issue 20), in place of Media3's own touch and orientation sensor:
 * - a drag turns the view, the picture following the finger as before, now up to straight up and straight down (see
 *   [SphereLookMath.maxLatitude]); two fingers turn it too, from their middle;
 * - a pinch zooms between [SphereLookMath.MIN_FOV] and [SphereLookMath.MAX_FOV], a double tap zooms in to 45 degrees
 *   or back to 90, while the video plays or is paused; the player opens at 90;
 * - a tap shows or hides the controls, as before (PlayerView listens to the clicks of the view), once it cannot be a
 *   double tap;
 * - with the gyroscope on ([motionEnabled]), the turns of the phone add to the view as in the photo viewer; off, the
 *   sensor is not even listened to, so nothing of the motion of the phone reaches the view.
 *
 * The view goes to Media3's renderer through [driver], see [SphereViewDriver]: the stabilisation of a raw video (the
 * rotation of each frame, see [StabilizedFrames]) stays Media3's, applied to the frame before this view.
 *
 * Main thread only. The activity starts and stops it with itself ([start], [stop]).
 */
@OptIn(UnstableApi::class)
internal class SphereLookController(
  private val view: SphericalGLSurfaceView,
  private val driver: SphereViewDriver,
) : View.OnTouchListener, SensorEventListener {
  /** Where the view looks */
  var look = SphereLook()
    private set

  /** The sphere is the front half only (VR180): the latitudes stop where the edge of the screen reaches a pole */
  var halfSphere = false
    set(value) {
      if (field == value) return
      field = value
      show(look)
    }

  /** The motion of the phone turns the view (the gyroscope button); off by default, the photo viewer's default */
  var motionEnabled = false
    set(value) {
      if (field == value) return
      field = value
      updateSensor()
    }

  private val sensors = view.context.getSystemService(Context.SENSOR_SERVICE) as SensorManager?
  private val gyroscope: Sensor? = sensors?.getDefaultSensor(Sensor.TYPE_GYROSCOPE)

  /** The device has the gyroscope the button needs */
  val hasGyroscope: Boolean
    get() = gyroscope != null

  private var started = false
  private var sensorRegistered = false
  private var lastGyroNs = 0L

  private val matrix = FloatArray(16)
  private val touchSlop = ViewConfiguration.get(view.context).scaledTouchSlop

  // The drag: where the fingers went down, their middle at the last event, and whether they moved beyond the slop
  private var downX = 0f
  private var downY = 0f
  private var lastX = 0f
  private var lastY = 0f
  private var dragging = false

  // The pinch: the field of view when it began and how far the fingers spread since
  private var pinchStartFov = SphereLookMath.DEFAULT_FOV
  private var pinchScale = 1f
  private var zoomAnimator: ValueAnimator? = null

  private val scaleDetector =
    ScaleGestureDetector(
      view.context,
      object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
          zoomAnimator?.cancel()
          pinchStartFov = look.fov
          pinchScale = 1f
          return true
        }

        override fun onScale(detector: ScaleGestureDetector): Boolean {
          pinchScale *= detector.scaleFactor
          show(look.copy(fov = SphereLookMath.pinchFov(pinchStartFov, pinchScale)))
          return true
        }
      },
    ).apply {
      // A double tap zooms by steps: no zoom by double tap and drag that would fight it
      isQuickScaleEnabled = false
    }

  private val tapDetector =
    GestureDetector(
      view.context,
      object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent): Boolean = true

        // The controls toggle once the tap cannot be the first of a double tap
        override fun onSingleTapConfirmed(e: MotionEvent): Boolean = view.performClick()

        override fun onDoubleTap(e: MotionEvent): Boolean {
          zoomTo(SphereLookMath.doubleTapFov(zoomAnimator?.takeIf { it.isRunning }?.let { targetFov } ?: look.fov))
          return true
        }
      },
    )

  private var targetFov = SphereLookMath.DEFAULT_FOV

  /** Takes the touches of the view and draws the opening view */
  private fun install() {
    view.setOnTouchListener(this)
    // Media3's orientation sensor would replace the view with the attitude of the phone: the gyroscope is ours
    view.setUseSensorRotation(false)
    // A rotation changes the vertical field of view, and so how far the latitudes of a half sphere go
    view.addOnLayoutChangeListener { _, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom ->
      if (right - left != oldRight - oldLeft || bottom - top != oldBottom - oldTop) show(look)
    }
    show(look)
  }

  /** The activity started: the gyroscope runs again if it is on */
  fun start() {
    started = true
    updateSensor()
    show(look)
  }

  /** The activity stopped: no sensor in the background, no zoom going on */
  fun stop() {
    started = false
    updateSensor()
    zoomAnimator?.cancel()
  }

  fun save(state: Bundle) {
    state.putFloat(STATE_LONGITUDE, look.longitude)
    state.putFloat(STATE_LATITUDE, look.latitude)
    state.putFloat(STATE_FOV, zoomAnimator?.takeIf { it.isRunning }?.let { targetFov } ?: look.fov)
  }

  fun restore(state: Bundle?) {
    if (state == null || !state.containsKey(STATE_FOV)) return
    look =
      SphereLook(
        state.getFloat(STATE_LONGITUDE),
        state.getFloat(STATE_LATITUDE),
        state.getFloat(STATE_FOV, SphereLookMath.DEFAULT_FOV),
      )
    show(look)
  }

  @SuppressLint("ClickableViewAccessibility") // performClick on a confirmed tap, as Media3's touch did on a tap
  override fun onTouch(v: View, event: MotionEvent): Boolean {
    // Any touch stops a zoom going on, as in the photo viewer; before the detectors, so that the second tap of a double
    // tap starts its own zoom
    if (event.actionMasked == MotionEvent.ACTION_DOWN) zoomAnimator?.cancel()
    tapDetector.onTouchEvent(event)
    scaleDetector.onTouchEvent(event)
    val (x, y) = focalPoint(event)
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        downX = x
        downY = y
        lastX = x
        lastY = y
        dragging = false
      }
      // A finger more or less moves the middle of the fingers: the drag goes on from there, without a jump
      MotionEvent.ACTION_POINTER_DOWN,
      MotionEvent.ACTION_POINTER_UP -> {
        lastX = x
        lastY = y
        dragging = true
      }
      MotionEvent.ACTION_MOVE -> {
        if (!dragging && hypot(x - downX, y - downY) > touchSlop) {
          // From where the finger went down, as Media3's touch did: the turn does not lose the slop
          dragging = true
        }
        if (dragging) {
          show(SphereLookMath.drag(look, x - lastX, y - lastY, maxLatitude()))
          lastX = x
          lastY = y
        }
      }
      MotionEvent.ACTION_UP,
      MotionEvent.ACTION_CANCEL -> dragging = false
    }
    return true
  }

  override fun onSensorChanged(event: SensorEvent) {
    if (!motionEnabled || event.sensor.type != Sensor.TYPE_GYROSCOPE) return
    val dt = SphereLookMath.gyroStep(lastGyroNs, event.timestamp)
    lastGyroNs = event.timestamp
    val rotation = view.display?.rotation ?: Surface.ROTATION_0
    show(SphereLookMath.gyro(look, event.values[0], event.values[1], event.values[2], dt, rotation, maxLatitude()))
  }

  override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

  private fun updateSensor() {
    val wanted = started && motionEnabled && gyroscope != null
    if (wanted == sensorRegistered) return
    val manager = sensors ?: return
    if (wanted) {
      lastGyroNs = 0L
      sensorRegistered = manager.registerListener(this, gyroscope, SensorManager.SENSOR_DELAY_GAME)
    } else {
      manager.unregisterListener(this)
      sensorRegistered = false
    }
  }

  private fun zoomTo(fov: Float) {
    zoomAnimator?.cancel()
    targetFov = fov
    zoomAnimator =
      ValueAnimator.ofFloat(look.fov, fov).apply {
        duration = SphereLookMath.ZOOM_ANIMATION_MS
        // The ease out of the photo viewer (Curves.easeOutCubic)
        interpolator = DecelerateInterpolator(1.5f)
        addUpdateListener { show(look.copy(fov = it.animatedValue as Float)) }
        start()
      }
  }

  private fun maxLatitude(fov: Float = look.fov): Float =
    SphereLookMath.maxLatitude(halfSphere, SphereLookMath.verticalFov(fov, view.width, view.height))

  /** [next] becomes the view, within its limits, and goes to the renderer */
  private fun show(next: SphereLook) {
    look = SphereLookMath.clamp(next, maxLatitude(next.fov))
    driver.setView(SphereLookMath.viewMatrix(look, matrix))
  }

  /** The middle of the fingers on the screen, without the one going up */
  private fun focalPoint(event: MotionEvent): Pair<Float, Float> {
    val skip = if (event.actionMasked == MotionEvent.ACTION_POINTER_UP) event.actionIndex else -1
    var sumX = 0f
    var sumY = 0f
    var count = 0
    for (i in 0 until event.pointerCount) {
      if (i == skip) continue
      sumX += event.getX(i)
      sumY += event.getY(i)
      count++
    }
    return if (count == 0) Pair(event.x, event.y) else Pair(sumX / count, sumY / count)
  }

  companion object {
    private const val STATE_LONGITUDE = "look_longitude"
    private const val STATE_LATITUDE = "look_latitude"
    private const val STATE_FOV = "look_fov"

    /**
     * The controller of [view], attached, or null when this Media3 cannot be driven (see [SphereViewDriver.of]): the
     * player then keeps Media3's own touch and sensor, the gyroscope button turning that sensor on and off.
     */
    fun attach(view: SphericalGLSurfaceView): SphereLookController? {
      val driver = SphereViewDriver.of(view) ?: return null
      return SphereLookController(view, driver).also { it.install() }
    }
  }
}
