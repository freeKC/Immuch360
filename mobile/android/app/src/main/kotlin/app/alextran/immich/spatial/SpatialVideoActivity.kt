package app.alextran.immich.spatial

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.opengl.GLSurfaceView
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Choreographer
import android.view.Display
import android.view.GestureDetector
import android.view.Menu
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.Surface
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.CheckBox
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.PopupMenu
import android.widget.ProgressBar
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.OptIn
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.updateLayoutParams
import androidx.lifecycle.Lifecycle
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import app.alextran.immich.R
import app.alextran.immich.core.AudioTrackChooser
import app.alextran.immich.core.BufferingIndicator
import app.alextran.immich.core.HttpClientManager
import app.alextran.immich.core.StreamingLoadControl
import app.alextran.immich.core.VideoDecoders
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

private const val TAG = "SpatialVideoActivity"

/** The controls hide after this long while the video plays */
private const val CONTROLS_TIMEOUT_MS = 3000L

/** How long a message (camera refused) stays on screen */
private const val MESSAGE_DURATION_MS = 3000L

/** How long the message of a switch to the transcoded stream stays on screen: a longer text, read while it plays */
private const val LONG_MESSAGE_DURATION_MS = 6000L

private const val PROGRESS_INTERVAL_MS = 250L
private const val STATS_INTERVAL_MS = 500L

/** The renderer gives its video surface within this delay, or the GPU cannot run it and the player closes */
private const val SURFACE_TIMEOUT_MS = 5000L

/** 360° videos: degrees of view rotation per pixel of drag */
private const val DEGREES_PER_PIXEL = 0.2f
private const val MIN_FIELD_OF_VIEW = 50f
private const val MAX_FIELD_OF_VIEW = 100f
private const val MAX_PITCH = 90f

/**
 * After the last new video frame (paused video), a few more draws let the renderer settle the disparity of that frame
 * (it estimates again when the eyes have not changed for 100 ms)
 */
private const val SETTLE_INTERVAL_MS = 120L
private const val SETTLE_DRAWS = 5

/** While the camera works, the manual viewpoint slider shows once the face has been lost for this long */
private const val MANUAL_AFTER_LOST_MS = 3000L

/**
 * Turning the phone to look around a 360° video also moves the face in the front camera, which would throw the
 * viewpoint to one side. A change of the sensor direction above this many degrees, between two sensor readings,
 * counts as a turn: the viewpoint holds still, and once the direction has been steady for [TURN_SETTLE_MS] the
 * face is taken as the new centre.
 */
private const val TURN_MOVE_DEGREES = 0.15f
private const val TURN_SETTLE_MS = 400L

/** The sensitivity slider goes from 0.5 to 4.0 by steps of 0.1 */
private const val SENSITIVITY_MIN = 0.5f
private const val SENSITIVITY_STEP = 0.1f

/**
 * Experimental Spatial 2.5D player for stereoscopic videos, full screen and landscape. The renderer turns the two eyes
 * of each frame into a view from an in between viewpoint; the front camera follows the head of the user and moves that
 * viewpoint, so the screen behaves like a window on the scene. Nothing from the camera leaves the device.
 *
 * A 360° video covers the full sphere, or only its front half for a VR180 video
 * ([SpatialProjection.EQUIRECTANGULAR180]); the field of view button switches between the two.
 *
 * A video with several audio tracks (languages, commentary) shows an audio track button, see [AudioTrackChooser].
 * While the video loads or stalls, a label tells how far the buffer is filled, see [BufferingIndicator].
 *
 * With a fallback URL (the server's transcoded stream), the original gives way to it once: when its codec and size are
 * above what the device decodes (see [VideoDecoders]), checked as soon as its tracks are known, or when it fails. The
 * transcoded stream starts where the original stopped.
 *
 * Opened from Flutter through [SpatialVideoApi]. On close (button, system back, or the system destroying the
 * activity) Flutter gets [SpatialVideoEvents.closed] once, with the position, so that the normal player takes over,
 * and with the layout and the projection shown last, so that the choices of the user can be remembered for the asset.
 * A playback error (of the transcoded stream too, when there is one) or a GPU that cannot render closes the player the
 * same way, after a short message.
 */
@OptIn(UnstableApi::class)
class SpatialVideoActivity : ComponentActivity(), HeadTracker.Listener {
  companion object {
    private const val EXTRA_URL = "url"
    private const val EXTRA_HEADERS = "headers"
    private const val EXTRA_TITLE = "title"
    private const val EXTRA_LAYOUT = "layout"
    private const val EXTRA_PROJECTION = "projection"
    private const val EXTRA_START_POSITION_MS = "start_position_ms"
    private const val EXTRA_AUTOPLAY = "autoplay"
    private const val EXTRA_DEBUG_OVERLAY = "debug_overlay"
    private const val EXTRA_LABELS = "labels"
    private const val EXTRA_FALLBACK_URL = "fallback_url"
    private const val STATE_POSITION = "position"
    private const val STATE_PLAY_WHEN_READY = "play_when_ready"
    private const val STATE_LAYOUT = "layout"
    private const val STATE_SENSITIVITY = "sensitivity"
    private const val STATE_PERMISSION_ASKED = "permission_asked"
    private const val STATE_FIELD_OF_VIEW = "field_of_view"
    private const val STATE_VIEWPOINT = "viewpoint"
    private const val STATE_MANUAL_HOLD = "manual_hold"
    private const val STATE_HALF_SPHERE = "half_sphere"
    private const val STATE_AUDIO_TRACK = "audio_track"
    private const val STATE_PLAYING_FALLBACK = "playing_fallback"
    private const val STATE_DECODER_CHECKED = "decoder_checked"
    private const val STATE_DECLARED_STEREO_MODE = "declared_stereo_mode"

    private const val LABEL_LAYOUT = "layout"
    private const val LABEL_LAYOUT_AUTO = "layoutAuto"
    private const val LABEL_LAYOUT_SIDE_BY_SIDE = "layoutSideBySide"
    private const val LABEL_LAYOUT_TOP_BOTTOM = "layoutTopBottom"
    private const val LABEL_LAYOUT_SIDE_BY_SIDE_SWAPPED = "layoutSideBySideSwapped"
    private const val LABEL_LAYOUT_TOP_BOTTOM_SWAPPED = "layoutTopBottomSwapped"
    private const val LABEL_LAYOUT_NONE = "layoutNone"
    private const val LABEL_RECENTER = "recenter"
    private const val LABEL_TRACKING_LOST = "trackingLost"
    private const val LABEL_CAMERA_DENIED = "cameraDenied"
    private const val LABEL_UNAVAILABLE = "unavailable"
    private const val LABEL_SENSITIVITY = "sensitivity"
    private const val LABEL_CLOSE = "close"
    private const val LABEL_ERROR = "error"
    private const val LABEL_COVERAGE = "coverage"
    private const val LABEL_COVERAGE_FULL = "coverage_full"
    private const val LABEL_COVERAGE_HALF = "coverage_half"

    /** English labels, used for the keys Flutter does not send */
    private val DEFAULT_LABELS = mapOf(
      "spatial" to "Spatial 2.5D",
      "normal" to "Normal",
      LABEL_LAYOUT to "Stereo layout",
      LABEL_LAYOUT_AUTO to "Auto",
      LABEL_LAYOUT_SIDE_BY_SIDE to "Side by side",
      LABEL_LAYOUT_TOP_BOTTOM to "Top and bottom",
      LABEL_LAYOUT_SIDE_BY_SIDE_SWAPPED to "Side by side, eyes swapped",
      LABEL_LAYOUT_TOP_BOTTOM_SWAPPED to "Top and bottom, eyes swapped",
      LABEL_LAYOUT_NONE to "Not stereoscopic",
      LABEL_RECENTER to "Recenter",
      LABEL_TRACKING_LOST to "Face not found, looking for it",
      LABEL_CAMERA_DENIED to "Camera access refused: use the slider to move the viewpoint",
      LABEL_UNAVAILABLE to "Spatial 2.5D is not available on this device",
      LABEL_SENSITIVITY to "Head sensitivity",
      LABEL_CLOSE to "Close",
      LABEL_ERROR to "Unable to play this video",
      LABEL_COVERAGE to "Field of view",
      LABEL_COVERAGE_FULL to "360°, full sphere",
      LABEL_COVERAGE_HALF to "180°, half sphere (VR180)",
    )

    private val SpatialStereoLayout.labelKey: String
      get() = when (this) {
        SpatialStereoLayout.AUTO -> LABEL_LAYOUT_AUTO
        SpatialStereoLayout.SIDE_BY_SIDE -> LABEL_LAYOUT_SIDE_BY_SIDE
        SpatialStereoLayout.TOP_BOTTOM -> LABEL_LAYOUT_TOP_BOTTOM
        SpatialStereoLayout.SIDE_BY_SIDE_SWAPPED -> LABEL_LAYOUT_SIDE_BY_SIDE_SWAPPED
        SpatialStereoLayout.TOP_BOTTOM_SWAPPED -> LABEL_LAYOUT_TOP_BOTTOM_SWAPPED
        SpatialStereoLayout.NONE -> LABEL_LAYOUT_NONE
      }

    private val EyeLayout.labelKey: String
      get() = when (this) {
        EyeLayout.SIDE_BY_SIDE -> LABEL_LAYOUT_SIDE_BY_SIDE
        EyeLayout.TOP_BOTTOM -> LABEL_LAYOUT_TOP_BOTTOM
        EyeLayout.SIDE_BY_SIDE_SWAPPED -> LABEL_LAYOUT_SIDE_BY_SIDE_SWAPPED
        EyeLayout.TOP_BOTTOM_SWAPPED -> LABEL_LAYOUT_TOP_BOTTOM_SWAPPED
        EyeLayout.NONE -> LABEL_LAYOUT_NONE
      }

    /** The request from Flutter as intent extras: enums by name, headers and labels as bundles of strings */
    fun intent(context: Context, request: SpatialOpenRequest): Intent {
      return Intent(context, SpatialVideoActivity::class.java)
        .putExtra(EXTRA_URL, request.url)
        .putExtra(EXTRA_HEADERS, request.headers.toBundle())
        .putExtra(EXTRA_TITLE, request.title)
        .putExtra(EXTRA_LAYOUT, request.layout.name)
        .putExtra(EXTRA_PROJECTION, request.projection.name)
        .putExtra(EXTRA_START_POSITION_MS, request.startPositionMs)
        .putExtra(EXTRA_AUTOPLAY, request.autoplay)
        .putExtra(EXTRA_DEBUG_OVERLAY, request.debugOverlay)
        .putExtra(EXTRA_LABELS, request.labels.toBundle())
        .putExtra(EXTRA_FALLBACK_URL, request.fallbackUrl)
    }

    private fun stereoLayoutNamed(name: String?): SpatialStereoLayout? =
      SpatialStereoLayout.entries.firstOrNull { it.name == name }

    private fun projectionNamed(name: String?): SpatialProjection? =
      SpatialProjection.entries.firstOrNull { it.name == name }
  }

  private val handler = Handler(Looper.getMainLooper())

  private lateinit var glView: GLSurfaceView
  private lateinit var renderer: SpatialRenderer
  private lateinit var controls: View
  private lateinit var topBar: View
  private lateinit var bottomBar: View
  private lateinit var playPauseButton: ImageButton
  private lateinit var positionText: TextView
  private lateinit var durationText: TextView
  private lateinit var seekBar: SeekBar
  private lateinit var layoutButton: Button
  private lateinit var audioButton: ImageButton
  private lateinit var audioTracks: AudioTrackChooser
  private lateinit var coverageButton: Button
  private lateinit var recenterButton: Button
  private lateinit var sensitivityLabel: TextView
  private lateinit var sensitivityBar: SeekBar
  private lateinit var viewpointViews: List<View>
  private lateinit var viewpointBar: SeekBar
  private lateinit var disparityBox: CheckBox
  private lateinit var statsText: TextView
  private lateinit var messageText: TextView
  private lateinit var bufferingView: ProgressBar
  private lateinit var bufferingLabel: TextView
  private lateinit var bufferingIndicator: BufferingIndicator
  private lateinit var windowDisplay: Display
  private lateinit var headTracker: HeadTracker

  private var labels = emptyMap<String, String>()
  private var projection = Projection.FLAT

  /**
   * 360° videos: the image covers the front half of the sphere only (VR180), as Flutter asked or as the field of view
   * button set it
   */
  private var halfSphere = false
  private var debugOverlay = false
  private var hasFrontCamera = false

  private var player: ExoPlayer? = null
  private var videoSurface: Surface? = null
  private var startPosition = 0L
  private var playWhenReady = true

  /** Whether the video played when the activity stopped, to play it again on start */
  private var resumeOnStart = false
  private var stopped = true
  private var closedSent = false

  /** Read on the thread of the video texture too */
  @Volatile
  private var released = false

  /** The layout chosen by Flutter or in the layout menu; AUTO resolves to [eyeLayout] */
  private var selectedLayout = SpatialStereoLayout.AUTO

  /** Stereo mode the video declares (st3d box or Matroska StereoMode), [Format.NO_VALUE] when it declares none */
  private var declaredStereoMode = Format.NO_VALUE

  /** The server's transcoded stream, null when Flutter sent none */
  private var fallbackUrl: String? = null

  /**
   * The transcoded stream plays in place of the original: the device cannot decode the original, or it failed. Once
   * per opening, kept across a recreation.
   */
  private var playingFallback = false

  /** The video track of the URL that plays was checked against the decoders of the device */
  private var decoderChecked = false

  /** Display aspect ratio of the whole frame, 0 until the video size is known */
  private var videoAspect = 0f

  // Head tracking and viewpoint
  private val headViewpoint = HeadViewpoint()
  private var trackingRunning = false
  private var permissionAsked = false
  private var lastSample: HeadSample? = null
  private var faceLost = false

  /** The manual slider moved: the viewpoint stays where the slider put it until a face is found */
  private var manualHold = false

  /** The face has been lost for [MANUAL_AFTER_LOST_MS] while the camera works: the manual slider shows */
  private var lostTooLong = false

  /** onCreate failed: the activity finishes at once and its views and renderer may not exist */
  private var startFailed = false
  private var draggingViewpoint = false
  private var draggingSensitivity = false
  private var userSeeking = false
  private var layoutMenuOpen = false
  private var audioDialogOpen = false
  private var frameLoopPosted = false

  // 360° view direction: touch offsets plus the device orientation, in degrees
  private var touchYaw = 0f
  private var touchPitch = 0f
  private var sensorYaw = 0f
  private var sensorPitch = 0f
  private var sensorYawBase = Float.NaN
  private var fieldOfView = Float.NaN
  /** The phone is turning (see [TURN_MOVE_DEGREES]): the head viewpoint holds until the turn ends */
  private var viewTurning = false
  private var lastTurnMoveNanos = 0L
  private var lastSensorYaw = Float.NaN
  private var lastSensorPitch = Float.NaN
  private var sensorManager: SensorManager? = null
  private var rotationSensor: Sensor? = null
  private var sensorRegistered = false
  private val rotationMatrix = FloatArray(9)
  private val displayMatrix = FloatArray(9)
  private val viewMatrix = FloatArray(9)
  private val orientationAngles = FloatArray(3)

  private var transientMessage: String? = null

  @Volatile
  private var settleDrawsLeft = 0

  private val permissionLauncher =
    registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
      if (granted) {
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {
          startTracking()
        }
      } else {
        showMessage(label(LABEL_CAMERA_DENIED))
        updateTrackingUi()
        // The message points at the manual viewpoint slider
        showControls()
      }
    }

  private val hideControlsRunnable = Runnable { controls.visibility = View.GONE }

  private val lostTooLongRunnable = Runnable {
    if (trackingRunning && faceLost) {
      lostTooLong = true
      updateTrackingUi()
    }
  }

  private val clearMessageRunnable = Runnable {
    transientMessage = null
    updateMessage()
  }

  private val surfaceTimeoutRunnable = Runnable {
    Log.e(TAG, "The renderer gave no video surface")
    Toast.makeText(this, label(LABEL_UNAVAILABLE), Toast.LENGTH_LONG).show()
    close()
  }

  private val progressRunnable = object : Runnable {
    override fun run() {
      updateProgress()
      handler.postDelayed(this, PROGRESS_INTERVAL_MS)
    }
  }

  private val settleRunnable = object : Runnable {
    override fun run() {
      glView.requestRender()
      if (--settleDrawsLeft > 0) {
        handler.postDelayed(this, SETTLE_INTERVAL_MS)
      }
    }
  }

  private val statsRunnable = object : Runnable {
    override fun run() {
      updateStats()
      handler.postDelayed(this, STATS_INTERVAL_MS)
    }
  }

  /** Moves the viewpoint at the display rate while it eases on its own (face lost, face found again) */
  private val frameCallback = Choreographer.FrameCallback { frameTimeNanos ->
    frameLoopPosted = false
    if (trackingRunning && !manualHold && !released) {
      setViewpoint(headViewpoint.valueAt(frameTimeNanos))
      ensureFrameLoop(frameTimeNanos)
    }
  }

  private val playerListener = object : Player.Listener {
    override fun onIsPlayingChanged(isPlaying: Boolean) {
      glView.keepScreenOn = isPlaying
      updatePlayPause()
      if (isPlaying) {
        scheduleHideControls()
      } else {
        handler.removeCallbacks(hideControlsRunnable)
      }
    }

    override fun onPlaybackStateChanged(playbackState: Int) {
      bufferingView.visibility = if (playbackState == Player.STATE_BUFFERING) View.VISIBLE else View.GONE
      updatePlayPause()
      updateProgress()
      if (playbackState == Player.STATE_ENDED) {
        showControls()
      }
    }

    override fun onVideoSizeChanged(videoSize: VideoSize) {
      if (videoSize.width <= 0 || videoSize.height <= 0) {
        return
      }
      // The renderer takes the width with the pixel aspect ratio applied
      val displayWidth = (videoSize.width * videoSize.pixelWidthHeightRatio).roundToInt()
      renderer.setVideoSize(displayWidth, videoSize.height)
      videoAspect = displayWidth.toFloat() / videoSize.height
      applyLayout()
    }

    override fun onTracksChanged(tracks: Tracks) {
      val format = selectedVideoFormat(tracks)
      val declared = format?.stereoMode ?: Format.NO_VALUE
      // The transcoded stream may lose the stereo metadata of the original: the layout the original declared stays
      val stereoMode = if (playingFallback && declared == Format.NO_VALUE) declaredStereoMode else declared
      if (stereoMode != declaredStereoMode) {
        declaredStereoMode = stereoMode
        applyLayout()
      }
      // The audio track button shows when there is a choice
      val options = player?.let { audioTracks.onTracksChanged(it, tracks) }.orEmpty()
      audioButton.visibility = if (options.size >= 2) View.VISIBLE else View.GONE
      // Last: a switch to the transcoded stream replaces these tracks
      format?.let(::checkDecoder)
    }

    override fun onPlayerError(error: PlaybackException) {
      Log.e(TAG, "Cannot play the video in Spatial 2.5D", error)
      // The transcoded stream gets its chance before the player gives up
      if (switchToFallback("the original failed (${error.errorCodeName})")) {
        return
      }
      Toast.makeText(this@SpatialVideoActivity, label(LABEL_ERROR), Toast.LENGTH_LONG).show()
      // The normal player takes over. Posted, so the player is not released inside its own callback.
      handler.post { close() }
    }
  }

  private val rotationListener = object : SensorEventListener {
    override fun onSensorChanged(event: SensorEvent) {
      onRotationVector(event.values)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    // The player shares the process with Flutter: an uncaught exception here would close the whole app. Any failure
    // closes this player alone and the normal player takes over.
    try {
      // First, so that even a failed start tells Flutter the projection it asked for
      val requestedProjection = projectionNamed(intent.getStringExtra(EXTRA_PROJECTION)) ?: SpatialProjection.FLAT
      projection = if (requestedProjection == SpatialProjection.FLAT) Projection.FLAT else Projection.EQUIRECTANGULAR
      halfSphere = savedInstanceState?.getBoolean(STATE_HALF_SPHERE)
        ?: (requestedProjection == SpatialProjection.EQUIRECTANGULAR180)

      // The system may restore this activity alone after the process died
      HttpClientManager.initialize(this)

      labels = intent.getBundleExtra(EXTRA_LABELS)?.toStringMap() ?: emptyMap()
      fallbackUrl = intent.getStringExtra(EXTRA_FALLBACK_URL)?.takeIf { it.isNotBlank() }
      playingFallback = savedInstanceState?.getBoolean(STATE_PLAYING_FALLBACK) == true && fallbackUrl != null
      decoderChecked = savedInstanceState?.getBoolean(STATE_DECODER_CHECKED) == true
      if (playingFallback) {
        // What the original declared, which the transcoded stream may have lost
        declaredStereoMode = savedInstanceState?.getInt(STATE_DECLARED_STEREO_MODE, Format.NO_VALUE) ?: Format.NO_VALUE
      }
      audioTracks = AudioTrackChooser(this, labels)
      audioTracks.chosenIndex = savedInstanceState?.getInt(STATE_AUDIO_TRACK, -1) ?: -1
      debugOverlay = intent.getBooleanExtra(EXTRA_DEBUG_OVERLAY, false)
      hasFrontCamera = packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_FRONT)
      selectedLayout = stereoLayoutNamed(savedInstanceState?.getString(STATE_LAYOUT))
        ?: stereoLayoutNamed(intent.getStringExtra(EXTRA_LAYOUT))
        ?: SpatialStereoLayout.AUTO
      if (savedInstanceState != null) {
        startPosition = savedInstanceState.getLong(STATE_POSITION)
        playWhenReady = savedInstanceState.getBoolean(STATE_PLAY_WHEN_READY, true)
        headViewpoint.sensitivity = savedInstanceState.getFloat(STATE_SENSITIVITY, HeadViewpoint.DEFAULT_SENSITIVITY)
        permissionAsked = savedInstanceState.getBoolean(STATE_PERMISSION_ASKED)
        fieldOfView = savedInstanceState.getFloat(STATE_FIELD_OF_VIEW, Float.NaN)
        manualHold = savedInstanceState.getBoolean(STATE_MANUAL_HOLD)
      } else {
        startPosition = max(0L, intent.getLongExtra(EXTRA_START_POSITION_MS, 0L))
        playWhenReady = intent.getBooleanExtra(EXTRA_AUTOPLAY, true)
      }

      setContentView(R.layout.activity_spatial_video)
      bindViews()
      // Read on the camera thread too, for the display rotation
      @Suppress("DEPRECATION")
      windowDisplay =
        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else null) ?: windowManager.defaultDisplay

      renderer = SpatialRenderer { surface -> onVideoSurface(surface) }
      renderer.projection = projection
      renderer.halfSphere = halfSphere
      renderer.quality = Quality.MEDIUM
      renderer.adaptiveQuality = true
      // The viewpoint of before a recreation; updateTrackingUi below sets the manual slider from it
      renderer.viewpoint = savedInstanceState?.getFloat(STATE_VIEWPOINT, 0.5f)?.coerceIn(0f, 1f) ?: 0.5f
      if (fieldOfView.isNaN()) {
        fieldOfView = renderer.fieldOfViewDegrees
      } else {
        renderer.fieldOfViewDegrees = fieldOfView
      }
      // Draws on demand: on each new video frame, and when the viewpoint or the view direction changes
      renderer.onFrameAvailable = {
        glView.requestRender()
        settle()
      }
      glView.setEGLContextClientVersion(3)
      // Keeps the video texture across a stop and start where the device allows it
      glView.preserveEGLContextOnPause = true
      glView.setRenderer(renderer)
      glView.renderMode = GLSurfaceView.RENDERMODE_WHEN_DIRTY

      headTracker = HeadTracker(this, { windowDisplay.rotation }, this)
      setUpControls()
      setUpTouch()
      if (projection == Projection.EQUIRECTANGULAR) {
        sensorManager = getSystemService(SensorManager::class.java)
        rotationSensor = sensorManager?.let {
          it.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR) ?: it.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        }
      }
      applyCoverage()
      updateTrackingUi()

      onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
        override fun handleOnBackPressed() {
          close()
        }
      })

      enterFullScreen()
      initializePlayer()
      showControls()
    } catch (e: Throwable) {
      abortStart(e)
    }
  }

  /** Closes the player after a failure in onCreate: Flutter gets the closed event once, nothing is shown */
  private fun abortStart(error: Throwable) {
    Log.e(SpatialGl.TAG, "Cannot start the Spatial 2.5D player", error)
    startFailed = true
    if (!closedSent) {
      closedSent = true
      SpatialVideoApiImpl.notifyClosed(startPosition, playWhenReady, selectedLayout, spatialProjection())
    }
    // Releases what was created before the failure; onDestroy then finds everything released
    released = true
    handler.removeCallbacksAndMessages(null)
    try {
      player?.let {
        it.removeListener(playerListener)
        it.release()
      }
      player = null
      if (::headTracker.isInitialized) {
        headTracker.release()
      }
      if (::renderer.isInitialized) {
        renderer.onFrameAvailable = null
        renderer.release()
      }
    } catch (e: Throwable) {
      Log.e(SpatialGl.TAG, "Cannot release the Spatial 2.5D player after a failed start", e)
    }
    finish()
  }

  override fun onStart() {
    super.onStart()
    if (startFailed) {
      return
    }
    stopped = false
    glView.onResume()
    if (videoSurface == null) {
      handler.postDelayed(surfaceTimeoutRunnable, SURFACE_TIMEOUT_MS)
    }
    if (resumeOnStart) {
      player?.play()
    }
    resumeOnStart = false
    registerRotationSensor()
    maybeStartTracking()
    handler.post(progressRunnable)
    if (debugOverlay) {
      handler.post(statsRunnable)
    }
  }

  override fun onWindowFocusChanged(hasFocus: Boolean) {
    super.onWindowFocusChanged(hasFocus)
    // A dialog, the notification shade or another app may have brought the system bars back
    if (hasFocus) {
      hideSystemBars()
    }
  }

  override fun onStop() {
    if (startFailed) {
      super.onStop()
      return
    }
    player?.let {
      resumeOnStart = it.playWhenReady && it.playbackState != Player.STATE_ENDED
      it.pause()
    }
    stopTracking()
    unregisterRotationSensor()
    handler.removeCallbacks(surfaceTimeoutRunnable)
    handler.removeCallbacks(progressRunnable)
    handler.removeCallbacks(statsRunnable)
    glView.onPause()
    stopped = true
    super.onStop()
  }

  override fun onSaveInstanceState(outState: Bundle) {
    super.onSaveInstanceState(outState)
    player?.let {
      startPosition = it.currentPosition
      playWhenReady = if (stopped) resumeOnStart else it.playWhenReady
    }
    outState.putLong(STATE_POSITION, startPosition)
    outState.putBoolean(STATE_PLAY_WHEN_READY, playWhenReady)
    outState.putString(STATE_LAYOUT, selectedLayout.name)
    outState.putFloat(STATE_SENSITIVITY, headViewpoint.sensitivity)
    outState.putBoolean(STATE_PERMISSION_ASKED, permissionAsked)
    outState.putFloat(STATE_FIELD_OF_VIEW, fieldOfView)
    if (::renderer.isInitialized) {
      outState.putFloat(STATE_VIEWPOINT, renderer.viewpoint)
    }
    outState.putBoolean(STATE_MANUAL_HOLD, manualHold)
    outState.putBoolean(STATE_HALF_SPHERE, halfSphere)
    if (::audioTracks.isInitialized) {
      outState.putInt(STATE_AUDIO_TRACK, audioTracks.chosenIndex)
    }
    outState.putBoolean(STATE_PLAYING_FALLBACK, playingFallback)
    outState.putBoolean(STATE_DECODER_CHECKED, decoderChecked)
    outState.putInt(STATE_DECLARED_STEREO_MODE, declaredStereoMode)
  }

  override fun onDestroy() {
    // Destroyed by the system rather than closed by the user: Flutter still hears about it, once
    if (!isChangingConfigurations) {
      sendClosed()
    }
    releaseAll()
    super.onDestroy()
  }

  private fun bindViews() {
    glView = findViewById(R.id.spatial_video_surface)
    controls = findViewById(R.id.spatial_video_controls)
    topBar = findViewById(R.id.spatial_video_top_bar)
    bottomBar = findViewById(R.id.spatial_video_bottom_bar)
    playPauseButton = findViewById(R.id.spatial_video_play_pause)
    positionText = findViewById(R.id.spatial_video_position)
    durationText = findViewById(R.id.spatial_video_duration)
    seekBar = findViewById(R.id.spatial_video_seek)
    layoutButton = findViewById(R.id.spatial_video_layout)
    audioButton = findViewById(R.id.spatial_video_audio)
    coverageButton = findViewById(R.id.spatial_video_coverage)
    recenterButton = findViewById(R.id.spatial_video_recenter)
    sensitivityLabel = findViewById(R.id.spatial_video_sensitivity_label)
    sensitivityBar = findViewById(R.id.spatial_video_sensitivity)
    viewpointBar = findViewById(R.id.spatial_video_viewpoint)
    // Typed explicitly: with the SeekBar in the middle, Kotlin would infer List<SeekBar> and the two labels would
    // fail at runtime with an ArrayStoreException
    viewpointViews = listOf<View>(
      findViewById<View>(R.id.spatial_video_viewpoint_label),
      viewpointBar,
      findViewById<View>(R.id.spatial_video_viewpoint_label_end),
    )
    disparityBox = findViewById(R.id.spatial_video_disparity)
    statsText = findViewById(R.id.spatial_video_stats)
    messageText = findViewById(R.id.spatial_video_message)
    bufferingView = findViewById(R.id.spatial_video_buffering)
    bufferingLabel = findViewById(R.id.spatial_video_buffering_label)
    val streamed = StreamingLoadControl.isStreamed(playbackUrl().orEmpty())
    bufferingIndicator = BufferingIndicator(bufferingLabel, labels, streamed)
  }

  private fun setUpControls() {
    findViewById<TextView>(R.id.spatial_video_title).text = intent.getStringExtra(EXTRA_TITLE)
    findViewById<View>(R.id.spatial_video_close).apply {
      contentDescription = label(LABEL_CLOSE)
      setOnClickListener { close() }
    }

    playPauseButton.setOnClickListener {
      togglePlayPause()
      scheduleHideControls()
    }

    seekBar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
      override fun onProgressChanged(bar: SeekBar, progress: Int, fromUser: Boolean) {
        if (fromUser) {
          positionText.text = formatTime(progress.toLong())
        }
      }

      override fun onStartTrackingTouch(bar: SeekBar) {
        userSeeking = true
        handler.removeCallbacks(hideControlsRunnable)
      }

      override fun onStopTrackingTouch(bar: SeekBar) {
        userSeeking = false
        player?.seekTo(bar.progress.toLong())
        scheduleHideControls()
      }
    })

    layoutButton.setOnClickListener { showLayoutMenu() }

    audioButton.contentDescription = audioTracks.buttonLabel
    audioButton.tooltipText = audioTracks.buttonLabel
    audioButton.setOnClickListener { showAudioTracks() }

    coverageButton.setOnClickListener {
      halfSphere = !halfSphere
      applyCoverage()
      showMessage(coverageLabel())
      scheduleHideControls()
    }

    recenterButton.text = label(LABEL_RECENTER)
    recenterButton.setOnClickListener {
      recenter()
      scheduleHideControls()
    }

    sensitivityBar.progress = ((headViewpoint.sensitivity - SENSITIVITY_MIN) / SENSITIVITY_STEP).roundToInt()
    updateSensitivityLabel()
    sensitivityBar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
      override fun onProgressChanged(bar: SeekBar, progress: Int, fromUser: Boolean) {
        if (fromUser) {
          headViewpoint.sensitivity = SENSITIVITY_MIN + progress * SENSITIVITY_STEP
          updateSensitivityLabel()
        }
      }

      override fun onStartTrackingTouch(bar: SeekBar) {
        draggingSensitivity = true
        handler.removeCallbacks(hideControlsRunnable)
      }

      override fun onStopTrackingTouch(bar: SeekBar) {
        draggingSensitivity = false
        scheduleHideControls()
      }
    })

    viewpointBar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
      override fun onProgressChanged(bar: SeekBar, progress: Int, fromUser: Boolean) {
        if (fromUser) {
          manualHold = true
          setViewpoint(progress / bar.max.toFloat())
        }
      }

      override fun onStartTrackingTouch(bar: SeekBar) {
        draggingViewpoint = true
        manualHold = true
        handler.removeCallbacks(hideControlsRunnable)
      }

      override fun onStopTrackingTouch(bar: SeekBar) {
        draggingViewpoint = false
        // The face may have come back during the drag: the slider hides now
        updateTrackingUi()
        scheduleHideControls()
      }
    })

    if (debugOverlay) {
      statsText.visibility = View.VISIBLE
      disparityBox.visibility = View.VISIBLE
      disparityBox.setOnCheckedChangeListener { _, checked ->
        renderer.showDisparity = checked
        glView.requestRender()
        scheduleHideControls()
      }
    }
  }

  /**
   * Taps show or hide the controls. On a 360° video, drags turn the view (0.2 degrees per pixel, the scene follows
   * the finger) and pinches change the field of view between 50 and 100 degrees.
   */
  private fun setUpTouch() {
    val scaleDetector = ScaleGestureDetector(this, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
      override fun onScale(detector: ScaleGestureDetector): Boolean {
        if (projection != Projection.EQUIRECTANGULAR) {
          return false
        }
        fieldOfView = (fieldOfView / detector.scaleFactor).coerceIn(MIN_FIELD_OF_VIEW, MAX_FIELD_OF_VIEW)
        renderer.fieldOfViewDegrees = fieldOfView
        glView.requestRender()
        settle()
        return true
      }
    })
    val gestureDetector = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
      override fun onDown(e: MotionEvent): Boolean = true

      override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
        toggleControls()
        return true
      }

      override fun onScroll(e1: MotionEvent?, e2: MotionEvent, distanceX: Float, distanceY: Float): Boolean {
        if (projection != Projection.EQUIRECTANGULAR || scaleDetector.isInProgress) {
          return false
        }
        // distanceX is positive when the finger moves left: the view turns right, the scene follows the finger
        touchYaw += distanceX * DEGREES_PER_PIXEL
        touchPitch -= distanceY * DEGREES_PER_PIXEL
        applyViewDirection()
        return true
      }
    })
    glView.setOnTouchListener { view, event ->
      scaleDetector.onTouchEvent(event)
      gestureDetector.onTouchEvent(event)
      if (event.actionMasked == MotionEvent.ACTION_UP) {
        view.performClick()
      }
      true
    }
  }

  private fun initializePlayer() {
    val url = playbackUrl()
    if (url == null) {
      close()
      return
    }
    val headers = intent.getBundleExtra(EXTRA_HEADERS)?.toStringMap() ?: emptyMap()

    // Same HTTP stack as the Flutter video player (cookies, mTLS, custom headers), with the headers from Flutter on
    // every request. DefaultDataSource keeps file and content URIs working as well.
    val httpDataSourceFactory =
      ResolvingDataSource.Factory(HttpClientManager.createDataSourceFactory(headers)) { dataSpec ->
        dataSpec.withAdditionalHeaders(headers)
      }
    val dataSourceFactory = DefaultDataSource.Factory(this, httpDataSourceFactory)
    val audioAttributes = AudioAttributes.Builder()
      .setUsage(C.USAGE_MEDIA)
      .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
      .build()

    // Larger buffers for a video read over HTTP (the media bridge of a network share, a server); local files as before
    player = StreamingLoadControl.applyTo(ExoPlayer.Builder(this), url)
      .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
      .setAudioAttributes(audioAttributes, /* handleAudioFocus= */ true)
      .setHandleAudioBecomingNoisy(true)
      .build()
      .also {
        it.addListener(playerListener)
        // The language picked last, and the track picked for this video before a recreation
        audioTracks.attach(it)
        bufferingIndicator.attach(it)
        videoSurface?.let { surface -> it.setVideoSurface(surface) }
        it.setMediaItem(MediaItem.fromUri(url), startPosition)
        it.playWhenReady = playWhenReady
        it.prepare()
      }
    updatePlayPause()
  }

  /** The URL that plays: the original, or the transcoded stream once the player switched to it */
  private fun playbackUrl(): String? =
    if (playingFallback) fallbackUrl else intent.getStringExtra(EXTRA_URL)

  /**
   * A video above what the device decodes stutters or shows blocks: the transcoded stream plays instead, once, from
   * the same position, and the user reads why when Flutter sent the label. Without a transcoded stream the original
   * plays anyway, and the log tells why it may stutter.
   */
  private fun checkDecoder(format: Format) {
    if (decoderChecked || format.width <= 0 || format.height <= 0) {
      return
    }
    decoderChecked = true
    val verdict = VideoDecoders.canDecode(format)
    if (verdict.supported) {
      return
    }
    val codec = VideoDecoders.codecName(format.sampleMimeType)
    Log.w(TAG, "$codec ${format.width}x${format.height} is above what this device decodes: ${verdict.reason}")
    if (!switchToFallback("the device cannot decode the original")) {
      return
    }
    val message = VideoDecoders.decoderLabel(labels, VideoDecoders.LABEL_SWITCHED, codec, format.width, format.height)
    if (message != null) {
      showMessage(message, LONG_MESSAGE_DURATION_MS)
    } else {
      Log.i(TAG, "No label from Flutter for the switch to the transcoded stream")
    }
  }

  /**
   * Plays the transcoded stream in place of the original, from where it stopped and as it was (playing or paused),
   * once. False when there is none, when it already plays, or without a player.
   */
  private fun switchToFallback(reason: String): Boolean {
    val fallback = fallbackUrl ?: return false
    val current = player ?: return false
    if (playingFallback || released) {
      return false
    }
    playingFallback = true
    decoderChecked = false
    Log.i(TAG, "Switching to the transcoded stream: $reason")
    current.setMediaItem(MediaItem.fromUri(fallback), current.currentPosition.coerceAtLeast(0L))
    current.prepare()
    return true
  }

  /** Called by the renderer on the main thread once its video texture exists, and again after a new GL context */
  private fun onVideoSurface(surface: Surface) {
    if (released) {
      return
    }
    handler.removeCallbacks(surfaceTimeoutRunnable)
    videoSurface = surface
    player?.setVideoSurface(surface)
  }

  /** Back button and close button: Flutter gets the position, the normal player takes over */
  private fun close() {
    if (isFinishing) {
      return
    }
    sendClosed()
    releaseAll()
    finish()
  }

  private fun sendClosed() {
    if (closedSent) {
      return
    }
    closedSent = true
    val current = player
    val positionMs = max(0L, current?.currentPosition ?: startPosition)
    val wasPlaying = when {
      current == null -> false
      stopped -> resumeOnStart
      else -> current.playWhenReady && current.playbackState != Player.STATE_ENDED
    }
    SpatialVideoApiImpl.notifyClosed(positionMs, wasPlaying, selectedLayout, spatialProjection())
  }

  /** The projection shown, as Flutter names it */
  private fun spatialProjection(): SpatialProjection = when {
    projection == Projection.FLAT -> SpatialProjection.FLAT
    halfSphere -> SpatialProjection.EQUIRECTANGULAR180
    else -> SpatialProjection.EQUIRECTANGULAR
  }

  /** Releases the player, the camera and the renderer, once. The renderer releases on the GL thread. */
  private fun releaseAll() {
    if (released) {
      return
    }
    released = true
    audioTracks.dismissDialog()
    if (::bufferingIndicator.isInitialized) {
      bufferingIndicator.detach()
    }
    renderer.onFrameAvailable = null
    handler.removeCallbacksAndMessages(null)
    Choreographer.getInstance().removeFrameCallback(frameCallback)
    headTracker.release()
    trackingRunning = false
    unregisterRotationSensor()
    player?.let {
      it.removeListener(playerListener)
      it.clearVideoSurface()
      it.release()
    }
    player = null
    videoSurface = null
    glView.keepScreenOn = false
    glView.queueEvent { renderer.release() }
  }

  // Stereo layout

  /** What the video declares: side by side or top and bottom, or a mono video */
  private fun declaredLayout(): EyeLayout? = when (declaredStereoMode) {
    C.STEREO_MODE_LEFT_RIGHT -> EyeLayout.SIDE_BY_SIDE
    C.STEREO_MODE_TOP_BOTTOM -> EyeLayout.TOP_BOTTOM
    C.STEREO_MODE_MONO -> EyeLayout.NONE
    else -> null
  }

  /**
   * A guess from the frame shape for a video that declares nothing. A 360° video has two 2:1 eyes: stacked they make
   * a square, side by side a 4:1 frame. A 180° video has two square eyes: stacked they make a 1:2 frame, side by side
   * a 2:1 frame. A flat 16:9 video stacked makes 16:18. Anything else is taken as side by side, the most common stereo
   * layout; the layout button tells the user what was picked.
   */
  private fun guessedLayout(): EyeLayout {
    val ratio = videoAspect
    if (ratio <= 0f) {
      return EyeLayout.SIDE_BY_SIDE
    }
    val fullSphere = projection == Projection.EQUIRECTANGULAR && !halfSphere
    return when {
      fullSphere && ratio in 0.9f..1.1f -> EyeLayout.TOP_BOTTOM
      fullSphere && ratio in 3.2f..3.9f -> EyeLayout.SIDE_BY_SIDE
      projection == Projection.EQUIRECTANGULAR && halfSphere && ratio in 0.45f..0.55f -> EyeLayout.TOP_BOTTOM
      projection == Projection.FLAT && ratio in 0.8f..0.95f -> EyeLayout.TOP_BOTTOM
      else -> EyeLayout.SIDE_BY_SIDE
    }
  }

  private fun eyeLayout(): EyeLayout = when (selectedLayout) {
    SpatialStereoLayout.AUTO -> declaredLayout() ?: guessedLayout()
    SpatialStereoLayout.SIDE_BY_SIDE -> EyeLayout.SIDE_BY_SIDE
    SpatialStereoLayout.TOP_BOTTOM -> EyeLayout.TOP_BOTTOM
    SpatialStereoLayout.SIDE_BY_SIDE_SWAPPED -> EyeLayout.SIDE_BY_SIDE_SWAPPED
    SpatialStereoLayout.TOP_BOTTOM_SWAPPED -> EyeLayout.TOP_BOTTOM_SWAPPED
    SpatialStereoLayout.NONE -> EyeLayout.NONE
  }

  private fun applyLayout() {
    renderer.layout = eyeLayout()
    glView.requestRender()
    settle()
    // "Auto: Side by side" tells what Auto picked
    val text = if (selectedLayout == SpatialStereoLayout.AUTO) {
      "${label(LABEL_LAYOUT_AUTO)}: ${label(eyeLayout().labelKey)}"
    } else {
      label(selectedLayout.labelKey)
    }
    layoutButton.text = text
    layoutButton.contentDescription = "${label(LABEL_LAYOUT)}: $text"
    layoutButton.tooltipText = label(LABEL_LAYOUT)
  }

  /**
   * Hands the coverage to the renderer and shows it on the field of view button, which only 360° videos have:
   * "360°" or "180°", which read the same in every language. The guessed layout depends on the coverage too.
   */
  private fun applyCoverage() {
    renderer.halfSphere = halfSphere
    coverageButton.visibility = if (projection == Projection.EQUIRECTANGULAR) View.VISIBLE else View.GONE
    coverageButton.text = if (halfSphere) "180°" else "360°"
    coverageButton.contentDescription = "${label(LABEL_COVERAGE)}: ${coverageLabel()}"
    coverageButton.tooltipText = label(LABEL_COVERAGE)
    // Redraws, and estimates the disparity again for the new eyes
    applyLayout()
  }

  private fun coverageLabel(): String = label(if (halfSphere) LABEL_COVERAGE_HALF else LABEL_COVERAGE_FULL)

  private fun showLayoutMenu() {
    handler.removeCallbacks(hideControlsRunnable)
    layoutMenuOpen = true
    PopupMenu(this, layoutButton).apply {
      SpatialStereoLayout.entries.forEachIndexed { index, layout ->
        menu.add(Menu.NONE, index, index, label(layout.labelKey)).isChecked = layout == selectedLayout
      }
      menu.setGroupCheckable(Menu.NONE, true, true)
      setOnMenuItemClickListener { item ->
        SpatialStereoLayout.entries.getOrNull(item.itemId)?.let {
          selectedLayout = it
          applyLayout()
        }
        true
      }
      setOnDismissListener {
        layoutMenuOpen = false
        scheduleHideControls()
      }
      show()
    }
  }

  /** Lists the audio tracks of the video to pick one; the controls stay while the list is open */
  private fun showAudioTracks() {
    val current = player ?: return
    handler.removeCallbacks(hideControlsRunnable)
    audioDialogOpen = true
    audioTracks.showDialog(this, current) {
      audioDialogOpen = false
      scheduleHideControls()
    }
  }

  private fun selectedVideoFormat(tracks: Tracks): Format? {
    val group = tracks.groups.firstOrNull { it.type == C.TRACK_TYPE_VIDEO && it.isSelected } ?: return null
    return (0 until group.length).firstOrNull { group.isTrackSelected(it) }?.let { group.getTrackFormat(it) }
  }

  // Head tracking and viewpoint

  /** Starts tracking when the camera may be used, asks for the permission the first time otherwise */
  private fun maybeStartTracking() {
    if (!hasFrontCamera) {
      updateTrackingUi()
      return
    }
    if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
      startTracking()
    } else if (!permissionAsked) {
      permissionAsked = true
      permissionLauncher.launch(Manifest.permission.CAMERA)
    } else {
      updateTrackingUi()
    }
  }

  private fun startTracking() {
    if (trackingRunning || released || stopped) {
      return
    }
    if (headTracker.start()) {
      trackingRunning = true
      faceLost = false
      lostTooLong = false
      handler.removeCallbacks(lostTooLongRunnable)
      // The first face after the start sets the centre
      headViewpoint.recenter()
    }
    updateTrackingUi()
  }

  private fun stopTracking() {
    headTracker.stop()
    trackingRunning = false
    faceLost = false
    lostTooLong = false
    handler.removeCallbacks(lostTooLongRunnable)
    lastSample = null
    Choreographer.getInstance().removeFrameCallback(frameCallback)
    frameLoopPosted = false
    updateMessage()
  }

  override fun onHeadSample(sample: HeadSample) {
    if (!trackingRunning || released) {
      return
    }
    lastSample = sample
    val now = System.nanoTime()
    endTurnIfSteady(now)
    if (viewTurning) {
      // The face moves because the phone turns, not the head: the viewpoint keeps its value
    } else if (sample.faceFound) {
      headViewpoint.onFace(sample.filteredX, now)
      if (!draggingViewpoint) {
        manualHold = false
      }
    } else if (sample.lost) {
      headViewpoint.onLost(now)
    }
    if (!manualHold) {
      setViewpoint(headViewpoint.valueAt(now))
      ensureFrameLoop(now)
    }
    if (sample.lost != faceLost) {
      faceLost = sample.lost
      updateMessage()
      handler.removeCallbacks(lostTooLongRunnable)
      if (faceLost) {
        handler.postDelayed(lostTooLongRunnable, MANUAL_AFTER_LOST_MS)
      } else if (lostTooLong) {
        lostTooLong = false
        updateTrackingUi()
      }
    }
  }

  override fun onTrackingError() {
    // The camera went away: the manual slider takes over, no crash
    trackingRunning = false
    faceLost = false
    lostTooLong = false
    handler.removeCallbacks(lostTooLongRunnable)
    lastSample = null
    updateTrackingUi()
    updateMessage()
  }

  private fun ensureFrameLoop(now: Long) {
    if (!frameLoopPosted && headViewpoint.isAnimating(now)) {
      frameLoopPosted = true
      Choreographer.getInstance().postFrameCallback(frameCallback)
    }
  }

  private fun setViewpoint(viewpoint: Float) {
    val clamped = viewpoint.coerceIn(0f, 1f)
    renderer.viewpoint = clamped
    glView.requestRender()
    if (!draggingViewpoint && viewpointBar.visibility == View.VISIBLE) {
      viewpointBar.progress = (clamped * viewpointBar.max).roundToInt()
    }
  }

  /** Head tracking centres on the next face; a 360° video also turns back to where it started */
  private fun recenter() {
    headViewpoint.recenter()
    manualHold = false
    if (projection == Projection.EQUIRECTANGULAR) {
      touchYaw = 0f
      touchPitch = 0f
      sensorYaw = 0f
      sensorYawBase = Float.NaN
      applyViewDirection()
    }
  }

  /**
   * Sensitivity and Recenter while tracking runs. The manual viewpoint slider when tracking does not run, when the
   * face has been lost for [MANUAL_AFTER_LOST_MS], while it is being dragged, or for debugging.
   */
  private fun updateTrackingUi() {
    val trackingVisibility = if (trackingRunning) View.VISIBLE else View.GONE
    sensitivityLabel.visibility = trackingVisibility
    sensitivityBar.visibility = trackingVisibility
    recenterButton.visibility =
      if (trackingRunning || projection == Projection.EQUIRECTANGULAR) View.VISIBLE else View.GONE
    val manualVisible = debugOverlay || !trackingRunning || lostTooLong || draggingViewpoint
    val manualVisibility = if (manualVisible) View.VISIBLE else View.GONE
    viewpointViews.forEach { it.visibility = manualVisibility }
    if (manualVisibility == View.VISIBLE) {
      viewpointBar.progress = (renderer.viewpoint * viewpointBar.max).roundToInt()
    }
  }

  private fun updateSensitivityLabel() {
    sensitivityLabel.text =
      String.format(Locale.getDefault(), "%s %.1f", label(LABEL_SENSITIVITY), headViewpoint.sensitivity)
  }

  // 360° view direction

  private fun registerRotationSensor() {
    val sensor = rotationSensor ?: return
    if (sensorRegistered) {
      return
    }
    // The orientation sensor may restart from another heading: keep the current view and measure from here
    touchYaw += sensorYaw
    sensorYaw = 0f
    sensorYawBase = Float.NaN
    sensorRegistered =
      sensorManager?.registerListener(rotationListener, sensor, SensorManager.SENSOR_DELAY_GAME) == true
  }

  private fun unregisterRotationSensor() {
    if (sensorRegistered) {
      sensorManager?.unregisterListener(rotationListener)
      sensorRegistered = false
    }
  }

  /**
   * Device orientation from the rotation vector, remapped for the display rotation like SphericalGLSurfaceView does,
   * then remapped again so that Y points out of the back of the device (the viewing direction) and X to the right of
   * the screen. The azimuth of that matrix is then the heading of the view (positive to the right) and minus its pitch
   * the elevation (positive up). The heading counts from the first sample, so the video starts on its front.
   */
  private fun onRotationVector(values: FloatArray) {
    SensorManager.getRotationMatrixFromVector(rotationMatrix, values)
    val (xAxis, yAxis) = when (windowDisplay.rotation) {
      Surface.ROTATION_90 -> SensorManager.AXIS_Y to SensorManager.AXIS_MINUS_X
      Surface.ROTATION_180 -> SensorManager.AXIS_MINUS_X to SensorManager.AXIS_MINUS_Y
      Surface.ROTATION_270 -> SensorManager.AXIS_MINUS_Y to SensorManager.AXIS_X
      else -> SensorManager.AXIS_X to SensorManager.AXIS_Y
    }
    SensorManager.remapCoordinateSystem(rotationMatrix, xAxis, yAxis, displayMatrix)
    SensorManager.remapCoordinateSystem(displayMatrix, SensorManager.AXIS_X, SensorManager.AXIS_Z, viewMatrix)
    SensorManager.getOrientation(viewMatrix, orientationAngles)
    val heading = Math.toDegrees(orientationAngles[0].toDouble()).toFloat()
    val elevation = -Math.toDegrees(orientationAngles[1].toDouble()).toFloat()
    if (sensorYawBase.isNaN()) {
      sensorYawBase = heading
    }
    sensorYaw = wrapDegrees(heading - sensorYawBase)
    sensorPitch = elevation
    noteSensorTurn()
    applyViewDirection()
  }

  /** Marks the phone as turning when the sensor direction moved since the last reading */
  private fun noteSensorTurn() {
    if (!lastSensorYaw.isNaN()) {
      val moved = abs(wrapDegrees(sensorYaw - lastSensorYaw)) > TURN_MOVE_DEGREES ||
        abs(sensorPitch - lastSensorPitch) > TURN_MOVE_DEGREES
      if (moved) {
        lastTurnMoveNanos = System.nanoTime()
        viewTurning = true
      }
    }
    lastSensorYaw = sensorYaw
    lastSensorPitch = sensorPitch
  }

  /** Ends the hold once the phone has been steady long enough: the face where it is now becomes the centre */
  private fun endTurnIfSteady(now: Long) {
    if (viewTurning && now - lastTurnMoveNanos > TURN_SETTLE_MS * 1_000_000L) {
      viewTurning = false
      headViewpoint.recenter()
    }
  }

  /** Yaw positive to the right, pitch positive up, in degrees */
  private fun applyViewDirection() {
    val pitch = (touchPitch + sensorPitch).coerceIn(-MAX_PITCH, MAX_PITCH)
    // A drag past the pole does not pile up
    touchPitch = pitch - sensorPitch
    touchYaw = wrapDegrees(touchYaw)
    renderer.yawDegrees = wrapDegrees(touchYaw + sensorYaw)
    renderer.pitchDegrees = pitch
    glView.requestRender()
    settle()
  }

  /** Schedules the settle draws after the last change of the eyes; called from any thread */
  private fun settle() {
    if (released) {
      return
    }
    settleDrawsLeft = SETTLE_DRAWS
    handler.removeCallbacks(settleRunnable)
    handler.postDelayed(settleRunnable, SETTLE_INTERVAL_MS)
  }

  private fun wrapDegrees(degrees: Float): Float {
    var wrapped = degrees % 360f
    if (wrapped > 180f) wrapped -= 360f
    if (wrapped < -180f) wrapped += 360f
    return wrapped
  }

  // Controls

  private fun togglePlayPause() {
    val current = player ?: return
    when {
      current.playbackState == Player.STATE_ENDED -> {
        current.seekTo(0)
        current.play()
      }
      current.playWhenReady -> current.pause()
      else -> {
        if (current.playbackState == Player.STATE_IDLE) {
          current.prepare()
        }
        current.play()
      }
    }
  }

  private fun updatePlayPause() {
    val current = player
    val showPlay = current == null || !current.playWhenReady || current.playbackState == Player.STATE_ENDED
    playPauseButton.setImageResource(
      if (showPlay) android.R.drawable.ic_media_play else android.R.drawable.ic_media_pause,
    )
  }

  private fun updateProgress() {
    val current = player ?: return
    val duration = current.duration.takeIf { it != C.TIME_UNSET && it > 0 } ?: 0L
    seekBar.max = duration.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    seekBar.secondaryProgress = current.bufferedPosition.coerceIn(0L, duration).toInt()
    if (!userSeeking) {
      val position = current.currentPosition.coerceIn(0L, duration)
      seekBar.progress = position.toInt()
      positionText.text = formatTime(position)
    }
    durationText.text = formatTime(duration)
  }

  private fun formatTime(ms: Long): String {
    val totalSeconds = max(0L, ms) / 1000
    val hours = totalSeconds / 3600
    val minutes = (totalSeconds / 60) % 60
    val seconds = totalSeconds % 60
    return if (hours > 0) {
      String.format(Locale.ROOT, "%d:%02d:%02d", hours, minutes, seconds)
    } else {
      String.format(Locale.ROOT, "%d:%02d", minutes, seconds)
    }
  }

  private fun showControls() {
    controls.visibility = View.VISIBLE
    scheduleHideControls()
  }

  private fun toggleControls() {
    if (controls.visibility == View.VISIBLE) {
      handler.removeCallbacks(hideControlsRunnable)
      controls.visibility = View.GONE
    } else {
      showControls()
    }
  }

  /** The controls hide after 3 s while the video plays and nothing is being dragged; a paused video keeps them */
  private fun scheduleHideControls() {
    handler.removeCallbacks(hideControlsRunnable)
    val busy = userSeeking || draggingViewpoint || draggingSensitivity || layoutMenuOpen || audioDialogOpen
    if (player?.isPlaying == true && !busy) {
      handler.postDelayed(hideControlsRunnable, CONTROLS_TIMEOUT_MS)
    }
  }

  private fun showMessage(text: String, durationMs: Long = MESSAGE_DURATION_MS) {
    transientMessage = text
    handler.removeCallbacks(clearMessageRunnable)
    handler.postDelayed(clearMessageRunnable, durationMs)
    updateMessage()
  }

  /** A transient message first, then "face not found" while tracking runs without a face */
  private fun updateMessage() {
    val text = transientMessage ?: if (trackingRunning && faceLost) label(LABEL_TRACKING_LOST) else null
    messageText.text = text
    messageText.visibility = if (text == null) View.GONE else View.VISIBLE
  }

  /** Diagnostics of the debug overlay, in English: developer text, not translated */
  private fun updateStats() {
    val stats = renderer.stats()
    val sample = lastSample
    val head = when {
      sample != null -> String.format(
        Locale.ROOT,
        "head raw %+.3f filtered %+.3f\nface %s conf %.2f %s %.0f fps",
        sample.rawX,
        sample.filteredX,
        if (sample.lost) "lost" else if (sample.faceFound) "found" else "held",
        sample.confidence,
        if (sample.hardware) "hw" else "sw",
        sample.trackingFps,
      )
      trackingRunning -> "head tracking starting"
      else -> "head tracking off"
    }
    statsText.text = String.format(
      Locale.ROOT,
      "render %.0f fps %.1f ms\ndisparity %.0f fps %dx%d %s\nviewpoint %.2f%s layout %s\n%s",
      stats.renderFps,
      stats.renderMs,
      stats.disparityFps,
      stats.disparityWidth,
      stats.disparityHeight,
      stats.quality.name.lowercase(Locale.ROOT),
      stats.viewpoint,
      if (manualHold) " manual" else "",
      eyeLayout().name.lowercase(Locale.ROOT),
      head,
    )
  }

  private fun label(key: String): String = labels[key]?.takeIf { it.isNotBlank() } ?: DEFAULT_LABELS.getValue(key)

  // Full screen

  private fun hideSystemBars() {
    WindowInsetsControllerCompat(window, window.decorView).apply {
      systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
      hide(WindowInsetsCompat.Type.systemBars())
    }
  }

  private fun enterFullScreen() {
    WindowCompat.setDecorFitsSystemWindows(window, false)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      window.attributes = window.attributes.apply {
        layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
      }
    }
    hideSystemBars()

    // The video fills the whole screen, the controls stay clear of the camera cutout and of the system bars
    val baseStatsMargin = (statsText.layoutParams as FrameLayout.LayoutParams).leftMargin
    val bufferingMargin = (bufferingLabel.layoutParams as FrameLayout.LayoutParams).bottomMargin
    ViewCompat.setOnApplyWindowInsetsListener(findViewById(R.id.spatial_video_root)) { _, insets ->
      val safe = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
      topBar.updateLayoutParams<FrameLayout.LayoutParams> {
        leftMargin = safe.left
        topMargin = safe.top
        rightMargin = safe.right
      }
      bottomBar.updateLayoutParams<FrameLayout.LayoutParams> {
        leftMargin = safe.left
        rightMargin = safe.right
        bottomMargin = safe.bottom
      }
      statsText.updateLayoutParams<FrameLayout.LayoutParams> { leftMargin = baseStatsMargin + safe.left }
      bufferingLabel.updateLayoutParams<FrameLayout.LayoutParams> { bottomMargin = bufferingMargin + safe.bottom }
      insets
    }
  }
}

private fun Map<String, String>.toBundle() =
  Bundle().also { bundle -> forEach { (key, value) -> bundle.putString(key, value) } }

private fun Bundle.toStringMap(): Map<String, String> = keySet().associateWith { getString(it).orEmpty() }
