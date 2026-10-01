package app.alextran.immich.spatial

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.graphics.PointF
import android.graphics.Rect
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.FaceDetector
import android.media.Image
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.Surface
import androidx.core.content.ContextCompat
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

private const val TAG = "SpatialHeadTracker"

/** Size of the camera stream asked for: small, face detection needs no more */
private const val STREAM_WIDTH = 640
private const val STREAM_HEIGHT = 480

/** Highest camera frame rate asked for */
private const val MAX_FPS = 30

/** Long side of the image given to the software face detector */
private const val SOFTWARE_LONG_SIDE = 160

/** The face counts as lost after this long without a detection */
private const val LOST_AFTER_NANOS = 300_000_000L

/** With the hardware detector, the software detector also runs when the hardware has seen no face for this long */
private const val HARDWARE_SILENT_NANOS = 1_000_000_000L

/**
 * The One Euro filter runs on the head position expressed in pixels of a 640 pixel wide camera image, the unit its
 * usual parameters (beta about 0.02) are tuned for. On the normalised position (-0.5 to 0.5) the same beta would
 * barely raise the cutoff and a moving head would lag behind.
 */
private const val FILTER_SCALE = 640.0

/**
 * One head tracking sample, delivered on the main thread.
 *
 * [rawX] and [filteredX] are the horizontal position of the face centre in the mirrored front camera image, from -0.5
 * (left edge) to 0.5 (right edge), oriented so that a head moving to the user's right gives a larger value. They keep
 * the last measured values when no face is found in this frame, and are NaN before the first face. Both detectors
 * measure against the whole active pixel array of the sensor, the frame of the hardware face rectangles; the software
 * detector maps its camera stream, which may be a crop of that array, back into it.
 */
data class HeadSample(
  val rawX: Float,
  val filteredX: Float,
  /** From 0 to 1, 0 when no face was found in this frame */
  val confidence: Float,
  /** A face was found in this frame */
  val faceFound: Boolean,
  /** No face for more than 300 ms */
  val lost: Boolean,
  /** Face detections per second */
  val trackingFps: Float,
  /** The face came from the face detector of the camera hardware rather than from the software detector */
  val hardware: Boolean,
  /** [System.nanoTime] of the sample */
  val timeNanos: Long,
)

/**
 * Tracks the horizontal position of the user's head with the front camera, through Camera2 and without any extra
 * library. Nothing leaves the device: the frames stay in memory on a background thread and are dropped once read.
 *
 * The camera stream is about 640x480 YUV at up to 30 fps. When the camera hardware has a face detector (statistics
 * face detect mode SIMPLE or FULL) its face rectangles are used. Otherwise, or while the hardware has seen no face for
 * a second, [FaceDetector] runs on every other frame, on a 160x120 grey image made from the Y plane.
 *
 * Call [start] and [stop] on the main thread; [Listener] is called on the main thread. [displayRotation] gives the
 * current [Surface] rotation constant of the display; it is read on the camera thread.
 */
class HeadTracker(
  context: Context,
  private val displayRotation: () -> Int,
  private val listener: Listener,
) {
  interface Listener {
    fun onHeadSample(sample: HeadSample)

    /** The camera could not open or went away (another app took it, an error): tracking is off until [start] */
    fun onTrackingError()
  }

  /** What the tracker knows about the front camera, read once */
  private class CameraSetup(
    val id: String,
    val sensorOrientation: Int,
    val activeArray: Rect,
    /** CaptureRequest.STATISTICS_FACE_DETECT_MODE to ask for, OFF when the hardware has no face detector */
    val faceMode: Int,
    val size: Size,
    val fpsRange: Range<Int>?,
  )

  private val appContext = context.applicationContext
  private val cameraManager = appContext.getSystemService(CameraManager::class.java)
  private val mainHandler = Handler(Looper.getMainLooper())

  /** Every [start] and [stop] moves to a new generation; callbacks of an older generation close what they get */
  private val generation = AtomicInteger()

  private var thread: HandlerThread? = null
  private var handler: Handler? = null

  @Volatile
  private var released = false

  // Camera thread state
  private var setup: CameraSetup? = null
  private var camera: CameraDevice? = null
  private var session: CameraCaptureSession? = null
  private var reader: ImageReader? = null
  private val filter = OneEuroFilter(minCutoff = 1.0, beta = 0.02, derivativeCutoff = 1.0)
  private var rawX = Float.NaN
  private var filteredX = Float.NaN
  private var lastFaceNanos = 0L
  private var lastHardwareFaceNanos = 0L
  private var wasLost = true
  private var frameCounter = 0
  private var fpsWindowStartNanos = 0L
  private var fpsWindowCount = 0
  private var trackingFps = 0f
  private var softwareDetector: FaceDetector? = null
  private var softwareBitmap: Bitmap? = null
  private var softwarePixels = IntArray(0)
  private val softwareFaces = arrayOfNulls<FaceDetector.Face>(1)
  private val midPoint = PointF()

  /** Whether the device has a front camera and the app may use it */
  fun canTrack(): Boolean =
    appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_FRONT) &&
      ContextCompat.checkSelfPermission(appContext, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

  /** Opens the front camera and starts tracking. False when tracking cannot start (no camera, no permission). */
  fun start(): Boolean {
    if (released || !canTrack()) {
      return false
    }
    val cameraHandler = handler ?: HandlerThread("SpatialHeadTracker").let {
      it.start()
      thread = it
      Handler(it.looper).also { created -> handler = created }
    }
    val current = generation.incrementAndGet()
    cameraHandler.post { openCamera(current) }
    return true
  }

  /** Closes the camera. The background thread stays, [start] opens the camera again. */
  fun stop() {
    generation.incrementAndGet()
    handler?.post { closeCamera() }
  }

  /** Closes the camera and ends the background thread for good. */
  fun release() {
    if (released) {
      return
    }
    stop()
    released = true
    // The thread lives a little longer so that a camera still opening gets its callback and is closed at once
    val cameraThread = thread
    handler?.postDelayed({ cameraThread?.quitSafely() }, 1000)
    thread = null
    handler = null
  }

  // Everything below runs on the camera thread

  @SuppressLint("MissingPermission")
  private fun openCamera(current: Int) {
    if (current != generation.get()) {
      return
    }
    val cameraHandler = handler ?: return
    // A start without a stop in between: the camera of the previous start goes first
    closeCamera()
    try {
      val found = setup ?: findFrontCamera()?.also { setup = it }
      if (found == null) {
        Log.w(TAG, "No usable front camera")
        fail(current)
        return
      }
      resetTracking()
      reader = ImageReader.newInstance(found.size.width, found.size.height, ImageFormat.YUV_420_888, 2).apply {
        setOnImageAvailableListener({ onImage(it, current) }, cameraHandler)
      }
      cameraManager.openCamera(found.id, cameraCallback(current), cameraHandler)
    } catch (e: CameraAccessException) {
      Log.w(TAG, "Cannot open the front camera", e)
      fail(current)
    } catch (e: SecurityException) {
      Log.w(TAG, "No camera permission", e)
      fail(current)
    } catch (e: IllegalArgumentException) {
      Log.w(TAG, "Cannot open the front camera", e)
      fail(current)
    }
  }

  private fun findFrontCamera(): CameraSetup? {
    val id = cameraManager.cameraIdList.firstOrNull {
      cameraManager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) ==
        CameraCharacteristics.LENS_FACING_FRONT
    } ?: return null
    val characteristics = cameraManager.getCameraCharacteristics(id)
    val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return null
    val sizes = map.getOutputSizes(ImageFormat.YUV_420_888)
    if (sizes.isNullOrEmpty()) {
      return null
    }
    val size = sizes.minBy { abs(it.width - STREAM_WIDTH) + abs(it.height - STREAM_HEIGHT) }
    val activeArray = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
      ?: Rect(0, 0, size.width, size.height)

    // Prefer the SIMPLE hardware face detector (rectangles only), FULL also gives rectangles
    val faceModes = characteristics.get(CameraCharacteristics.STATISTICS_INFO_AVAILABLE_FACE_DETECT_MODES)
    val maxFaces = characteristics.get(CameraCharacteristics.STATISTICS_INFO_MAX_FACE_COUNT) ?: 0
    val faceMode = when {
      maxFaces <= 0 || faceModes == null -> CaptureRequest.STATISTICS_FACE_DETECT_MODE_OFF
      faceModes.contains(CaptureRequest.STATISTICS_FACE_DETECT_MODE_SIMPLE) ->
        CaptureRequest.STATISTICS_FACE_DETECT_MODE_SIMPLE
      faceModes.contains(CaptureRequest.STATISTICS_FACE_DETECT_MODE_FULL) ->
        CaptureRequest.STATISTICS_FACE_DETECT_MODE_FULL
      else -> CaptureRequest.STATISTICS_FACE_DETECT_MODE_OFF
    }

    // Highest frame rate up to 30 fps, with a lower bound of 15 fps or more when the camera offers one
    val fpsRange = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
      ?.filter { it.upper <= MAX_FPS }
      ?.maxByOrNull { it.upper * 100 + min(it.lower, 15) }

    val sensorOrientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 270
    Log.i(
      TAG,
      "Front camera $id, ${size.width}x${size.height}, fps $fpsRange, face mode $faceMode, sensor $sensorOrientation",
    )
    return CameraSetup(id, sensorOrientation, activeArray, faceMode, size, fpsRange)
  }

  private fun cameraCallback(current: Int) = object : CameraDevice.StateCallback() {
    override fun onOpened(device: CameraDevice) {
      if (current != generation.get()) {
        device.close()
        return
      }
      camera = device
      createSession(device, current)
    }

    override fun onDisconnected(device: CameraDevice) {
      // Another app took the camera, or it went away
      Log.w(TAG, "Front camera disconnected")
      device.close()
      if (camera === device || camera == null) {
        camera = null
        fail(current)
      }
    }

    override fun onError(device: CameraDevice, error: Int) {
      Log.w(TAG, "Front camera error $error")
      device.close()
      if (camera === device || camera == null) {
        camera = null
        fail(current)
      }
    }
  }

  private fun createSession(device: CameraDevice, current: Int) {
    val cameraHandler = handler ?: return
    val target = reader?.surface ?: return
    val callback = object : CameraCaptureSession.StateCallback() {
      override fun onConfigured(configured: CameraCaptureSession) {
        if (current != generation.get() || camera !== device) {
          configured.close()
          return
        }
        session = configured
        startRepeating(device, configured, target, current)
      }

      override fun onConfigureFailed(failed: CameraCaptureSession) {
        Log.w(TAG, "Cannot configure the front camera")
        fail(current)
      }
    }
    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        val executor = Executor { cameraHandler.post(it) }
        val configuration = SessionConfiguration(
          SessionConfiguration.SESSION_REGULAR,
          listOf(OutputConfiguration(target)),
          executor,
          callback,
        )
        device.createCaptureSession(configuration)
      } else {
        @Suppress("DEPRECATION")
        device.createCaptureSession(listOf(target), callback, cameraHandler)
      }
    } catch (e: CameraAccessException) {
      Log.w(TAG, "Cannot configure the front camera", e)
      fail(current)
    } catch (e: IllegalStateException) {
      Log.w(TAG, "Cannot configure the front camera", e)
      fail(current)
    }
  }

  private fun startRepeating(device: CameraDevice, configured: CameraCaptureSession, target: Surface, current: Int) {
    val found = setup ?: return
    try {
      val request = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
        addTarget(target)
        set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
        found.fpsRange?.let { set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
        set(CaptureRequest.STATISTICS_FACE_DETECT_MODE, found.faceMode)
      }.build()
      configured.setRepeatingRequest(request, captureCallback(current), handler)
    } catch (e: CameraAccessException) {
      Log.w(TAG, "Cannot start the front camera", e)
      fail(current)
    } catch (e: IllegalStateException) {
      Log.w(TAG, "Cannot start the front camera", e)
      fail(current)
    }
  }

  private fun captureCallback(current: Int) = object : CameraCaptureSession.CaptureCallback() {
    override fun onCaptureCompleted(
      session: CameraCaptureSession,
      request: CaptureRequest,
      result: TotalCaptureResult,
    ) {
      val found = setup ?: return
      if (current != generation.get() || found.faceMode == CaptureRequest.STATISTICS_FACE_DETECT_MODE_OFF) {
        return
      }
      val now = System.nanoTime()
      val face = result.get(CaptureResult.STATISTICS_FACES)
        ?.filter { it.bounds.width() > 0 && it.bounds.height() > 0 }
        ?.maxByOrNull { it.bounds.width() * it.bounds.height() }
      if (face != null) {
        lastHardwareFaceNanos = now
        // Face rectangles are in the coordinates of the active pixel array, the orientation of the raw sensor image
        val bounds = face.bounds
        val area = found.activeArray
        val x = (bounds.exactCenterX() - area.left) / area.width()
        val y = (bounds.exactCenterY() - area.top) / area.height()
        report(current, headXFromSensor(x, y), face.score / 100f, hardware = true, now)
      } else if (!softwareActive(now)) {
        // While the software detector runs, it reports the frames without a face
        report(current, null, 0f, hardware = true, now)
      }
    }
  }

  /** The software detector runs without a hardware detector, and while the hardware one sees no face */
  private fun softwareActive(now: Long): Boolean {
    val found = setup ?: return false
    return found.faceMode == CaptureRequest.STATISTICS_FACE_DETECT_MODE_OFF ||
      now - lastHardwareFaceNanos > HARDWARE_SILENT_NANOS
  }

  private fun onImage(imageReader: ImageReader, current: Int) {
    // Every image must go back to the reader, or the camera stalls once the two buffers are taken
    val image = try {
      imageReader.acquireLatestImage()
    } catch (e: IllegalStateException) {
      null
    } ?: return
    try {
      val now = System.nanoTime()
      if (current == generation.get() && softwareActive(now) && frameCounter++ % 2 == 0) {
        detectInSoftware(image, current, now)
      }
    } catch (e: IllegalStateException) {
      // The image was closed under us (camera closing)
    } finally {
      image.close()
    }
  }

  /**
   * Builds a small upright grey image from the Y plane and runs [FaceDetector] on it. [FaceDetector] only finds
   * upright faces, so the raw sensor image is turned the way the user sees the world before detection.
   */
  private fun detectInSoftware(image: Image, current: Int, now: Long) {
    val found = setup ?: return
    val rotation = uprightRotation(found)
    val rawWidth = image.width
    val rawHeight = image.height
    val scale = SOFTWARE_LONG_SIDE.toFloat() / max(rawWidth, rawHeight)
    // FaceDetector needs an even width
    val smallRawWidth = (rawWidth * scale).roundToInt() and 1.inv()
    val smallRawHeight = (rawHeight * scale).roundToInt() and 1.inv()
    val quarterTurn = rotation == 90 || rotation == 270
    val width = if (quarterTurn) smallRawHeight else smallRawWidth
    val height = if (quarterTurn) smallRawWidth else smallRawHeight
    if (width <= 0 || height <= 0) {
      return
    }

    var bitmap = softwareBitmap
    var detector = softwareDetector
    if (bitmap == null || detector == null || bitmap.width != width || bitmap.height != height) {
      bitmap?.recycle()
      bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.RGB_565)
      detector = FaceDetector(width, height, softwareFaces.size)
      softwareBitmap = bitmap
      softwareDetector = detector
      softwarePixels = IntArray(width * height)
    }

    // Nearest neighbour sampling of the Y plane, rotated upright
    val plane = image.planes[0]
    val buffer = plane.buffer
    val rowStride = plane.rowStride
    val pixelStride = plane.pixelStride
    val pixels = softwarePixels
    for (v in 0 until height) {
      val vn = (v + 0.5f) / height
      for (u in 0 until width) {
        val un = (u + 0.5f) / width
        // Inverse of the clockwise rotation: upright (un, vn) back to the raw sensor image (xr, yr)
        val xr: Float
        val yr: Float
        when (rotation) {
          90 -> { xr = vn; yr = 1f - un }
          180 -> { xr = 1f - un; yr = 1f - vn }
          270 -> { xr = 1f - vn; yr = un }
          else -> { xr = un; yr = vn }
        }
        val sx = (xr * rawWidth).toInt().coerceIn(0, rawWidth - 1)
        val sy = (yr * rawHeight).toInt().coerceIn(0, rawHeight - 1)
        val grey = buffer.get(sy * rowStride + sx * pixelStride).toInt() and 0xFF
        pixels[v * width + u] = (0xFF shl 24) or (grey shl 16) or (grey shl 8) or grey
      }
    }
    bitmap.setPixels(pixels, 0, width, 0, 0, width, height)

    softwareFaces.fill(null)
    val count = detector.findFaces(bitmap, softwareFaces)
    val face = if (count > 0) softwareFaces[0] else null
    if (face == null) {
      report(current, null, 0f, hardware = false, now)
      return
    }
    face.getMidPoint(midPoint)
    // Upright position in the small image, back to the raw stream image with the same inverse rotation as the sampling
    val un = midPoint.x / width
    val vn = midPoint.y / height
    val xr: Float
    val yr: Float
    when (rotation) {
      90 -> { xr = vn; yr = 1f - un }
      180 -> { xr = 1f - un; yr = 1f - vn }
      270 -> { xr = 1f - vn; yr = un }
      else -> { xr = un; yr = vn }
    }
    val (ax, ay) = streamToActiveArray(found, xr, yr, rawWidth, rawHeight)
    report(current, headXFromSensor(ax, ay), face.confidence().coerceIn(0f, 1f), hardware = false, now)
  }

  /**
   * Maps a point of the raw stream image, normalised to 0..1, to the active pixel array, normalised to 0..1: the frame
   * of the hardware face rectangles. Both detectors then give the same head position for the same head, and the
   * tracker can switch between them without a jump of the viewpoint.
   *
   * Without zoom the crop region is the whole active array, and a stream of another aspect ratio is the largest centred
   * crop of it with the stream's aspect ratio (for example a 4:3 stream from a 16:9 sensor keeps 75% of its width).
   * For a stream with the aspect ratio of the array the point does not change.
   */
  private fun streamToActiveArray(
    found: CameraSetup,
    x: Float,
    y: Float,
    streamWidth: Int,
    streamHeight: Int,
  ): Pair<Float, Float> {
    val area = found.activeArray
    if (area.width() <= 0 || area.height() <= 0 || streamWidth <= 0 || streamHeight <= 0) {
      return x to y
    }
    val scale = min(area.width().toFloat() / streamWidth, area.height().toFloat() / streamHeight)
    val cropWidth = streamWidth * scale / area.width()
    val cropHeight = streamHeight * scale / area.height()
    return (0.5f + (x - 0.5f) * cropWidth) to (0.5f + (y - 0.5f) * cropHeight)
  }

  /**
   * Clockwise rotation, in degrees, that turns the raw sensor image upright as the user sees it on the display.
   *
   * The camera documentation (CaptureRequest.JPEG_ORIENTATION) gives (sensorOrientation + deviceOrientation) % 360
   * with deviceOrientation negated for a front camera, deviceOrientation being the clockwise physical rotation of the
   * device. The display rotation turns the other way (Surface.ROTATION_90 is the device turned a quarter turn counter
   * clockwise), so for the front camera the two negations cancel out: (sensorOrientation + displayRotation) % 360.
   * With the usual front sensor at 270 degrees, landscape ROTATION_90 gives 0 and ROTATION_270 gives 180.
   */
  private fun uprightRotation(found: CameraSetup): Int {
    val display = when (displayRotation()) {
      Surface.ROTATION_90 -> 90
      Surface.ROTATION_180 -> 180
      Surface.ROTATION_270 -> 270
      else -> 0
    }
    return (found.sensorOrientation + display) % 360
  }

  /**
   * headX from a point of the raw sensor image, (x, y) normalised to 0..1.
   *
   * Turning the image clockwise by a quarter turn sends (x, y) to (1 - y, x), so the horizontal position u in the
   * upright image is x, 1 - y, 1 - x or y for a rotation of 0, 90, 180 or 270 degrees. The upright image is what the
   * camera sees, facing the user: a head moving to the user's right moves to the left of that image. Mirroring it
   * like a selfie preview gives headX = 0.5 - u, larger when the head moves to the user's right.
   */
  private fun headXFromSensor(x: Float, y: Float): Float {
    val found = setup ?: return 0f
    val upright = when (uprightRotation(found)) {
      90 -> 1f - y
      180 -> 1f - x
      270 -> y
      else -> x
    }
    return (0.5f - upright).coerceIn(-0.5f, 0.5f)
  }

  /** Updates the filter and the lost state with one detection ([headX] null when no face) and sends a sample */
  private fun report(current: Int, headX: Float?, confidence: Float, hardware: Boolean, now: Long) {
    if (current != generation.get()) {
      return
    }
    fpsWindowCount++
    val elapsed = now - fpsWindowStartNanos
    if (elapsed >= 1_000_000_000L) {
      trackingFps = fpsWindowCount * 1e9f / elapsed
      fpsWindowCount = 0
      fpsWindowStartNanos = now
    }

    if (headX != null) {
      if (wasLost) {
        // A face found again starts a new trajectory: no glide from where the head was seconds ago
        filter.reset()
      }
      rawX = headX
      filteredX = (filter.filter(headX * FILTER_SCALE, now) / FILTER_SCALE).toFloat()
      lastFaceNanos = now
    }
    val lost = now - lastFaceNanos > LOST_AFTER_NANOS
    wasLost = lost
    val sample = HeadSample(rawX, filteredX, confidence, headX != null, lost, trackingFps, hardware, now)
    mainHandler.post {
      if (current == generation.get() && !released) {
        listener.onHeadSample(sample)
      }
    }
  }

  private fun resetTracking() {
    val now = System.nanoTime()
    filter.reset()
    rawX = Float.NaN
    filteredX = Float.NaN
    // Counts as lost 300 ms after the start when no face shows up
    lastFaceNanos = now
    lastHardwareFaceNanos = now
    wasLost = true
    frameCounter = 0
    fpsWindowStartNanos = now
    fpsWindowCount = 0
    trackingFps = 0f
  }

  private fun fail(current: Int) {
    closeCamera()
    mainHandler.post {
      if (current == generation.get() && !released) {
        listener.onTrackingError()
      }
    }
  }

  private fun closeCamera() {
    try {
      session?.close()
    } catch (e: IllegalStateException) {
      // Already closed with its camera
    }
    session = null
    camera?.close()
    camera = null
    reader?.close()
    reader = null
    if (released) {
      softwareBitmap?.recycle()
      softwareBitmap = null
      softwareDetector = null
    }
  }
}

/**
 * Turns head samples into the viewpoint of the synthesised view: 0 is the left camera, 0.5 the centre, 1 the right
 * camera. Used on the main thread.
 *
 * The first face after [recenter] (and after creation) sets the centre. Then p = 0.5 + (headX - centre) * sensitivity,
 * kept between 0.15 and 0.85. When the tracker reports the face lost (no face for 300 ms, during which the viewpoint
 * holds still) the viewpoint eases back to 0.5 over one second; a face found again, or a new centre, eases in over
 * 0.3 s.
 */
class HeadViewpoint {
  companion object {
    const val DEFAULT_SENSITIVITY = 2.0f
    const val MIN_VIEWPOINT = 0.15f
    const val MAX_VIEWPOINT = 0.85f
    private const val CENTRE = 0.5f
    private const val LOST_EASE_NANOS = 1_000_000_000L
    private const val FOUND_EASE_NANOS = 300_000_000L
  }

  var sensitivity = DEFAULT_SENSITIVITY

  private var centre = Float.NaN
  private var recenterPending = true
  private var target = CENTRE

  /** When the face was reported lost, -1 while a face is tracked */
  private var lostSinceNanos = -1L
  private var lostFrom = CENTRE

  /** When the face was found again after a loss, -1 when no ease in runs */
  private var foundSinceNanos = -1L
  private var foundFrom = CENTRE

  /** The next face sets the centre */
  fun recenter() {
    recenterPending = true
  }

  fun onFace(headX: Float, now: Long) {
    if (headX.isNaN()) {
      return
    }
    if (recenterPending || centre.isNaN()) {
      centre = headX
      recenterPending = false
      // The viewpoint goes back to the middle smoothly rather than jumping there
      foundFrom = valueAt(now)
      foundSinceNanos = now
    }
    if (lostSinceNanos >= 0) {
      foundFrom = valueAt(now)
      foundSinceNanos = now
      lostSinceNanos = -1L
    }
    target = (CENTRE + (headX - centre) * sensitivity).coerceIn(MIN_VIEWPOINT, MAX_VIEWPOINT)
  }

  fun onLost(now: Long) {
    if (lostSinceNanos < 0) {
      lostFrom = valueAt(now)
      lostSinceNanos = now
      foundSinceNanos = -1L
    }
  }

  /** The viewpoint at [now] ([System.nanoTime]) */
  fun valueAt(now: Long): Float {
    if (lostSinceNanos >= 0) {
      return mix(lostFrom, CENTRE, smoothStep((now - lostSinceNanos).toFloat() / LOST_EASE_NANOS))
    }
    if (foundSinceNanos >= 0) {
      val t = (now - foundSinceNanos).toFloat() / FOUND_EASE_NANOS
      if (t < 1f) {
        return mix(foundFrom, target, smoothStep(t))
      }
      foundSinceNanos = -1L
    }
    return target
  }

  /** Whether the viewpoint still moves on its own (an ease runs), so it needs updates at the display rate */
  fun isAnimating(now: Long): Boolean =
    (lostSinceNanos >= 0 && now - lostSinceNanos < LOST_EASE_NANOS) ||
      (foundSinceNanos >= 0 && now - foundSinceNanos < FOUND_EASE_NANOS)

  private fun smoothStep(t: Float): Float {
    val x = t.coerceIn(0f, 1f)
    return x * x * (3f - 2f * x)
  }

  private fun mix(from: Float, to: Float, t: Float) = from + (to - from) * t
}
