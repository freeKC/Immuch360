package app.alextran.immich.spherical

import android.content.Context
import android.content.Intent
import android.graphics.SurfaceTexture
import android.media.MediaFormat
import android.opengl.GLES20
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.Pair
import android.view.Surface
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.annotation.OptIn
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.updateLayoutParams
import androidx.core.view.updatePadding
import androidx.lifecycle.Lifecycle
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ErrorMessageProvider
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.video.VideoFrameMetadataListener
import androidx.media3.exoplayer.video.spherical.SphericalGLSurfaceView
import androidx.media3.ui.PlayerView
import app.alextran.immich.R
import app.alextran.immich.core.AudioTrackChooser
import app.alextran.immich.core.BufferingIndicator
import app.alextran.immich.core.DualFisheyeEffect
import app.alextran.immich.core.HttpClientManager
import app.alextran.immich.core.StreamingLoadControl
import app.alextran.immich.core.VideoDecoders
import app.alextran.immich.core.raw.RawMessage
import app.alextran.immich.core.raw.RawMode
import app.alextran.immich.core.raw.RawPlan
import app.alextran.immich.core.raw.RawPlaybackPlanner
import app.alextran.immich.core.raw.RawProjection
import app.alextran.immich.core.raw.RawStitchException
import app.alextran.immich.core.raw.RawTrack
import app.alextran.immich.core.raw.TwoLensPlayback
import java.lang.reflect.Field
import kotlin.math.min
import kotlin.math.roundToInt

private const val TAG = "SphericalVideoActivity"

/** Log tag of the rawProjection parse result and of its refusals, shared with the Quest viewer. */
private const val RAW_PROJECTION_TAG = "RawProjection"

/** Opacity of the 3D control while the video shows as a regular 360° video */
private const val MONO_ALPHA = 0.6f

/**
 * Plays an equirectangular video full screen. The spherical surface of [PlayerView] turns the view with touch
 * drags and with the orientation sensors; a tap shows the playback controls, the close button and the 3D control.
 * System back closes the player too.
 *
 * A stereoscopic (3D) video holds one equirectangular image per eye, either stacked (left eye on top) or side by
 * side (left eye on the left). The phone screen shows the left eye only. The 3D control cycles the layout used for
 * videos that do not declare one in their spherical metadata.
 *
 * The image of each eye covers the full sphere (360°) or its front half only (180°, VR180 videos), the back half then
 * staying black. The field of view control switches between the two. A video that declares its coverage in its
 * spherical metadata starts with it, any other with the guess of Flutter.
 *
 * A video with several audio tracks (languages, commentary) shows an audio track button, see [AudioTrackChooser].
 * While the video loads or stalls, a label tells how far the buffer is filled, see [BufferingIndicator].
 *
 * With a fallback URL (the server's transcoded stream), the original gives way to it once: when its codec and size are
 * above what the device decodes (see [VideoDecoders]), checked as soon as its tracks are known, or when it fails. The
 * transcoded stream starts where the original stopped; the error shows only if it fails too.
 *
 * On close (button, system back, or the system destroying the activity), Flutter gets [SphericalVideoEvents.closed]
 * with the layout and the coverage shown last, so that the corrections of the user can be remembered for the asset.
 *
 * A raw 360° video comes with its rawProjection JSON (see [RawProjection]) and is drawn as a mono full sphere
 * whatever the file or the controls say, so the 3D and field of view controls hide. Both lenses side by side in one
 * track: [DualFisheyeEffect] stitches each frame. Lenses in two tracks of one file or in two files (an Insta360 split
 * pair, a GoPro .360, a DJI .osv): [TwoLensPlayback] decodes both streams and its compositor draws the stitched frame
 * into the surface of the spherical view. [RawPlaybackPlanner] decides how it plays and falls back (one lens, the
 * transcoded streams, the frame unstitched), see [plan].
 */
@OptIn(UnstableApi::class)
class SphericalVideoActivity : ComponentActivity() {
  companion object {
    private const val EXTRA_URL = "url"
    private const val EXTRA_HEADERS = "headers"
    private const val EXTRA_TITLE = "title"
    private const val EXTRA_CLOSE_LABEL = "close_label"
    private const val EXTRA_ERROR_MESSAGE = "error_message"
    private const val EXTRA_STEREO_LAYOUT = "stereo_layout"
    private const val EXTRA_STEREO_LABELS = "stereo_labels"
    private const val EXTRA_COVERAGE = "coverage"
    private const val EXTRA_FALLBACK_URL = "fallback_url"
    private const val EXTRA_RAW_PROJECTION = "raw_projection"
    private const val STATE_POSITION = "position"
    private const val STATE_PLAY_WHEN_READY = "play_when_ready"
    private const val STATE_STEREO_LAYOUT = "stereo_layout"
    private const val STATE_COVERAGE = "coverage"
    private const val STATE_DECLARED_COVERAGE = "declared_coverage"
    private const val STATE_AUDIO_TRACK = "audio_track"
    private const val STATE_PLAYING_FALLBACK = "playing_fallback"
    private const val STATE_DECODER_CHECKED = "decoder_checked"
    private const val STATE_RAW_PLAN_MODE = "raw_plan_mode"
    private const val STATE_RAW_PLAN_STREAMS = "raw_plan_streams"
    private const val STATE_RAW_PLAN_URLS = "raw_plan_urls"
    private const val STATE_RAW_PLAN_FALLBACK = "raw_plan_fallback"

    /**
     * Keys of the messages of the raw fallbacks, in the labels from Flutter: one lens because the device cannot decode
     * both ("{codec}", "{width}" and "{height}" filled in), one lens because the other file cannot be read, unstitched.
     */
    const val LABEL_RAW_ONE_LENS_DECODER = "rawOneLensDecoder"
    const val LABEL_RAW_ONE_LENS_FILE = "rawOneLensFile"
    const val LABEL_RAW_UNSTITCHED = "rawUnstitched"

    /**
     * Largest stitched frame drawn on the sphere: the surface of the spherical view gets this size at most (keeping the
     * 2:1 shape of the frame), below the texture limit of every GPU the app runs on. A phone shows about a quarter of
     * the sphere's width, so 4096 pixels around still give about one pixel per screen pixel.
     */
    private const val MAX_RAW_OUTPUT_WIDTH = 4096
    private const val MAX_RAW_OUTPUT_HEIGHT = 2048

    /**
     * The SurfaceTexture behind the video surface of the spherical view, private in Media3, found by its type so that
     * R8 renaming the field does not matter. Null when this Media3 has none, the raw video then plays unstitched.
     * See [sizeRawSurface] for why it is needed.
     */
    private val surfaceTextureField: Field? by lazy {
      runCatching {
        SphericalGLSurfaceView::class.java.declaredFields
          .firstOrNull { it.type == SurfaceTexture::class.java }
          ?.apply { isAccessible = true }
      }.getOrNull()
    }

    /** Key of the label of the 3D control itself, in the labels from Flutter */
    private const val LABEL_STEREO = "stereo"

    /** Keys of the label of the field of view control itself and of its two values, in the labels from Flutter */
    private const val LABEL_COVERAGE = "coverage"
    private const val LABEL_COVERAGE_FULL = "coverage_full"
    private const val LABEL_COVERAGE_HALF = "coverage_half"

    /** English labels of the controls, used for the keys Flutter does not send */
    private val DEFAULT_LABELS = mapOf(
      LABEL_STEREO to "3D layout",
      "mono" to "Mono (not 3D)",
      "topBottom" to "3D, top and bottom",
      "leftRight" to "3D, side by side",
      LABEL_COVERAGE to "Field of view",
      LABEL_COVERAGE_FULL to "360°, full sphere",
      LABEL_COVERAGE_HALF to "180°, half sphere (VR180)",
      LABEL_RAW_ONE_LENS_DECODER to
        "This device cannot decode the two lenses of this video at once ({codec} {width}x{height}, twice). It shows " +
        "one lens: half of the sphere stays black.",
      LABEL_RAW_ONE_LENS_FILE to
        "The file of the other lens cannot be read. One lens shows: half of the sphere stays black.",
      LABEL_RAW_UNSTITCHED to
        "The 360° stitching failed on this device. The video shows as the camera recorded it.",
    )

    /** Key of the name of the layout, in the labels from Flutter */
    private val StereoLayout.labelKey: String
      get() = when (this) {
        StereoLayout.MONO -> "mono"
        StereoLayout.TOP_BOTTOM -> "topBottom"
        StereoLayout.LEFT_RIGHT -> "leftRight"
      }

    /** Stereo mode of the spherical renderer, which draws the top half or the left half (left eye) on the phone */
    private val StereoLayout.stereoMode: Int
      get() = when (this) {
        StereoLayout.MONO -> C.STEREO_MODE_MONO
        StereoLayout.TOP_BOTTOM -> C.STEREO_MODE_TOP_BOTTOM
        StereoLayout.LEFT_RIGHT -> C.STEREO_MODE_LEFT_RIGHT
      }

    /**
     * [closeLabel] and [errorMessage] come translated from Flutter; null falls back to the English resources.
     * [stereoLayout] is the layout Flutter guessed from the video dimensions and [stereoLabels] are the translated
     * labels of the 3D control, keyed "stereo", "mono", "topBottom" and "leftRight", and of the field of view
     * control, keyed "coverage", "coverage_full" and "coverage_half", of the audio track control (see
     * [AudioTrackChooser]), of the buffering label (see [BufferingIndicator]) and of the switch to the transcoded
     * stream (see [VideoDecoders.LABEL_SWITCHED]). [coverage] is the part of the sphere Flutter expects the video to
     * cover. [fallbackUrl] is the server's transcoded stream, null when there is none. [rawProjection] is the JSON
     * calibration of a raw dual fisheye video (docs 16-dual-fisheye-spec.md section 5), null for an equirectangular
     * one.
     */
    fun intent(
      context: Context,
      url: String,
      headers: Map<String, String>,
      title: String,
      closeLabel: String?,
      errorMessage: String?,
      stereoLayout: StereoLayout,
      stereoLabels: Map<String, String>,
      coverage: SphereCoverage,
      fallbackUrl: String?,
      rawProjection: String?,
    ): Intent {
      return Intent(context, SphericalVideoActivity::class.java)
        .putExtra(EXTRA_URL, url)
        .putExtra(EXTRA_HEADERS, headers.toBundle())
        .putExtra(EXTRA_TITLE, title)
        .putExtra(EXTRA_CLOSE_LABEL, closeLabel)
        .putExtra(EXTRA_ERROR_MESSAGE, errorMessage)
        .putExtra(EXTRA_STEREO_LAYOUT, stereoLayout.name)
        .putExtra(EXTRA_STEREO_LABELS, stereoLabels.toBundle())
        .putExtra(EXTRA_COVERAGE, coverage.name)
        .putExtra(EXTRA_FALLBACK_URL, fallbackUrl)
        .putExtra(EXTRA_RAW_PROJECTION, rawProjection)
    }

    private fun stereoLayoutNamed(name: String?): StereoLayout? = StereoLayout.entries.firstOrNull { it.name == name }

    private fun stereoLayoutOf(stereoMode: Int): StereoLayout? =
      StereoLayout.entries.firstOrNull { it.stereoMode == stereoMode }

    private fun coverageNamed(name: String?): SphereCoverage? = SphereCoverage.entries.firstOrNull { it.name == name }

    /**
     * [format] as the spherical renderer should draw it for [coverage]. A video with its own mesh keeps it for the
     * half sphere (the mesh of a VR180 camera follows its lenses) and loses it for the full sphere, which the renderer
     * then draws as a plain equirectangular sphere. Any other video gets the half sphere mesh for the half sphere, and
     * keeps its projection data for the full sphere (the renderer does not read the bounds of an equi box and draws
     * the full sphere). The stereo mode stays: the renderer applies it, or the layout of the 3D control when the
     * video declares none, to whatever mesh it draws.
     */
    private fun projectedFormat(format: Format, coverage: SphereCoverage): Format {
      val mesh = DeclaredProjection.of(format.projectionData)?.mesh == true
      return when {
        coverage == SphereCoverage.HALF && !mesh ->
          format.buildUpon().setProjectionData(HalfSphereMesh.projectionData).build()
        coverage == SphereCoverage.FULL && mesh -> format.buildUpon().setProjectionData(null).build()
        else -> format
      }
    }

    /** A stitched frame is a plain mono equirectangular frame: no mesh, no eye split, the full sphere. */
    private fun stitchedFormat(format: Format): Format =
      format.buildUpon().setProjectionData(null).setStereoMode(C.STEREO_MODE_MONO).build()

    /**
     * The surface size for the stitched frame of [projection]: the natural equirectangular size of its lenses, within
     * the output limit and within [gpuLimit] (the viewport and texture limits of the compositor's GPU), keeping its
     * shape.
     */
    private fun rawOutputSize(projection: RawProjection, gpuLimit: Size? = null): Size {
      val width = projection.frameWidth.toDouble()
      val height = projection.frameHeight.toDouble()
      var scale = min(1.0, min(MAX_RAW_OUTPUT_WIDTH / width, MAX_RAW_OUTPUT_HEIGHT / height))
      if (gpuLimit != null && gpuLimit.width > 0 && gpuLimit.height > 0) {
        scale = min(scale, min(gpuLimit.width / width, gpuLimit.height / height))
      }
      return Size((width * scale).roundToInt().coerceAtLeast(1), (height * scale).roundToInt().coerceAtLeast(1))
    }

    /** Media3 errors of a decoder that cannot run (or no longer runs) the lens streams: the ladder's decoder step. */
    private fun isDecoderError(error: PlaybackException): Boolean =
      error.errorCode == PlaybackException.ERROR_CODE_DECODER_INIT_FAILED ||
        error.errorCode == PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES ||
        error.errorCode == PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED ||
        error.errorCode == PlaybackException.ERROR_CODE_DECODING_RESOURCES_RECLAIMED

    /** Media3 errors of reading the media (2000 to 2999): the ladder's step for one file of a split pair. */
    private fun isSourceError(error: PlaybackException): Boolean = error.errorCode in 2000..2999
  }

  private lateinit var playerView: PlayerView
  private lateinit var stereoButton: View
  private lateinit var coverageButton: TextView
  private lateinit var audioButton: View
  private lateinit var audioTracks: AudioTrackChooser
  private lateinit var bufferingLabel: TextView
  private lateinit var bufferingIndicator: BufferingIndicator

  /** The spherical surface of [playerView] */
  private var sphericalView: SphericalGLSurfaceView? = null
  private var player: ExoPlayer? = null
  private var startPosition = 0L
  private var playWhenReady = true
  private var labels = emptyMap<String, String>()
  private var toast: Toast? = null

  /** Layout for videos that declare none: first the guess of Flutter, then the choice made with the 3D control */
  private var stereoLayout = StereoLayout.MONO

  /** Stereo mode the video declares in its spherical metadata (st3d box), [Format.NO_VALUE] when it declares none */
  private var declaredStereoMode = Format.NO_VALUE

  /**
   * Part of the sphere the image covers: first the guess of Flutter, then what the video declares, then the choice
   * made with the field of view control. Read on the playback thread too.
   */
  @Volatile
  private var coverage = SphereCoverage.FULL

  /** Coverage the video declares in its spherical metadata, null when it declares none or until its tracks are known */
  private var declaredCoverage: SphereCoverage? = null

  /** The server's transcoded stream, null when Flutter sent none */
  private var fallbackUrl: String? = null

  /**
   * The transcoded stream plays in place of the original: the device cannot decode the original, or it failed. Once
   * per opening, kept across a stop and a recreation.
   */
  private var playingFallback = false

  /** The video track of the URL that plays was checked against the decoders of the device */
  private var decoderChecked = false

  /** Flutter sent a rawProjection: a raw 360° video, drawn as a mono full sphere whatever happens */
  private var rawJsonPresent = false

  /**
   * The rawProjection of a raw 360° video, parsed; null for an equirectangular video, for a JSON the parser refused
   * and when the surface of the spherical view cannot be sized (the frame then plays as it is).
   */
  private var rawProjection: RawProjection? = null

  /**
   * How the video plays, see [RawPlaybackPlanner]: PLAIN for an equirectangular video. Kept across a stop and a
   * recreation, so that a mode that failed is not tried again. Read on the playback and compositor threads too.
   */
  @Volatile
  private var plan = RawPlan(RawMode.PLAIN, emptyList(), emptyList(), false, null, "")

  /** The lens player of a LENSES plan, null otherwise */
  private var twoLens: TwoLensPlayback? = null

  /** The decoders of the current lens player were checked against the selected lens tracks */
  private var lensDecodersChecked = false

  /** A new plan is posted: errors that follow from the same failure do not post another one */
  private var replanPending = false

  /** A new plan was applied while the activity was stopped: its message shows once onStart has built its player */
  private var rawMessageOnStart = false

  /** Sets the clear colour of the renderer, on its GL thread: black, the back of a half sphere */
  private val clearToBlack = Runnable { GLES20.glClearColor(0f, 0f, 0f, 1f) }

  /**
   * The spherical view creates a new surface with each GL context (after a pause for instance), once its renderer
   * has started; the player follows it.
   */
  private val videoSurfaceListener = object : SphericalGLSurfaceView.VideoSurfaceListener {
    override fun onVideoSurfaceCreated(surface: Surface) {
      if (twoLens != null) attachLensOutput(surface) else player?.let { setPlayerSurface(it, surface) }
      // The renderer has just started and set its clear colour, gray; queued, this runs after it
      sphericalView?.queueEvent(clearToBlack)
    }

    override fun onVideoSurfaceDestroyed(surface: Surface) {
      // Synchronous for the compositor: the view releases its SurfaceTexture right after
      val lens = twoLens
      if (lens != null) lens.clearOutput() else player?.clearVideoSurface(surface)
    }
  }

  private val playerListener = object : Player.Listener {
    override fun onIsPlayingChanged(isPlaying: Boolean) {
      playerView.keepScreenOn = isPlaying
    }

    override fun onTracksChanged(tracks: Tracks) {
      val format = selectedVideoFormat(tracks)
      // The spherical renderer only falls back to the default stereo mode set by the 3D control when the video
      // declares no stereo mode. For a video that declares one, the declared mode wins over the control, so the
      // control shows the declared layout and does not cycle.
      val stereoMode = format?.stereoMode ?: Format.NO_VALUE
      if (stereoMode != declaredStereoMode) {
        declaredStereoMode = stereoMode
        updateStereoButton()
      }
      // Tracks without a selected video say nothing about the coverage; a raw frame always covers the full sphere
      if (format != null && !rawJsonPresent) {
        applyDeclaredCoverage(DeclaredProjection.of(format.projectionData)?.coverage)
      }
      // The audio track button shows when there is a choice
      val options = player?.let { audioTracks.onTracksChanged(it, tracks) }.orEmpty()
      audioButton.visibility = if (options.size >= 2) View.VISIBLE else View.GONE
      // Last: a switch to the transcoded stream, or to one lens, replaces these tracks
      if (plan.mode == RawMode.LENSES) checkLensDecoders(tracks) else format?.let(::checkDecoder)
    }

    override fun onPlayerError(error: PlaybackException) {
      Log.e(TAG, "Cannot play the 360° video", error)
      if (plan.mode == RawMode.EFFECT_SIDE_BY_SIDE && DualFisheyeEffect.isStitchingError(error)) {
        if (replan(RawPlaybackPlanner.afterStitchFailure(plan))) return
      }
      if (plan.mode == RawMode.LENSES) {
        // The ladder replaces the fallback of other videos: a lens player shows the error once it has nothing left
        val projection = rawProjection ?: return
        val url = intent.getStringExtra(EXTRA_URL) ?: return
        if (isDecoderError(error)) {
          replan(RawPlaybackPlanner.afterDecoderFailure(plan, projection, url, fallbackUrl))
        } else {
          // A read error of a split pair keeps the lens of the opened file first; any other failure (a container the
          // extractor refuses, a timeout) plays the transcoded streams, once, like the switch of other videos
          val oneFile = if (isSourceError(error)) RawPlaybackPlanner.afterSourceError(plan, projection, url) else null
          replan(oneFile ?: RawPlaybackPlanner.afterSourceFailure(plan, projection, url, fallbackUrl))
        }
        return
      }
      // PlayerView shows the error while the player stays in error: the transcoded stream gets its chance first
      switchToFallback("the original failed (${error.errorCodeName})")
    }
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    // The system may restore this activity alone after the process died
    HttpClientManager.initialize(this)

    setContentView(R.layout.activity_spherical_video)
    playerView = findViewById(R.id.spherical_video_player)
    val topBar = findViewById<View>(R.id.spherical_video_top_bar)
    findViewById<TextView>(R.id.spherical_video_title).text = intent.getStringExtra(EXTRA_TITLE)
    findViewById<View>(R.id.spherical_video_close).apply {
      intent.getStringExtra(EXTRA_CLOSE_LABEL)?.let { contentDescription = it }
      setOnClickListener { finish() }
    }
    val errorMessage = intent.getStringExtra(EXTRA_ERROR_MESSAGE) ?: getString(R.string.spherical_video_error)

    // The close button, the title and the audio track, field of view and 3D controls come and go with the playback
    // controls
    playerView.setControllerVisibilityListener(PlayerView.ControllerVisibilityListener { visibility ->
      topBar.visibility = visibility
    })
    playerView.setErrorMessageProvider(ErrorMessageProvider<PlaybackException> { error ->
      Pair.create(error.errorCode, errorMessage)
    })

    if (savedInstanceState != null) {
      startPosition = savedInstanceState.getLong(STATE_POSITION)
      playWhenReady = savedInstanceState.getBoolean(STATE_PLAY_WHEN_READY, true)
    }
    fallbackUrl = intent.getStringExtra(EXTRA_FALLBACK_URL)?.takeIf { it.isNotBlank() }
    playingFallback = savedInstanceState?.getBoolean(STATE_PLAYING_FALLBACK) == true && fallbackUrl != null
    decoderChecked = savedInstanceState?.getBoolean(STATE_DECODER_CHECKED) == true

    labels = intent.getBundleExtra(EXTRA_STEREO_LABELS)?.toStringMap() ?: emptyMap()
    sphericalView = (playerView.videoSurfaceView as? SphericalGLSurfaceView)?.also {
      it.addVideoSurfaceListener(videoSurfaceListener)
    }
    val rawJson = intent.getStringExtra(EXTRA_RAW_PROJECTION)?.takeIf { it.isNotBlank() }
    rawJsonPresent = rawJson != null
    rawProjection = rawProjectionOf(rawJson)
    val restored = savedInstanceState?.let(::restoredPlan)
    if (restored != null) {
      plan = restored
    } else {
      val url = intent.getStringExtra(EXTRA_URL).orEmpty()
      plan = RawPlaybackPlanner.initial(rawJsonPresent, rawProjection, url, fallbackUrl, false, ::canDecodeRaw)
      if (plan.mode != RawMode.PLAIN) Log.i(TAG, "raw plan ${plan.mode} streams ${plan.streams}: ${plan.reason}")
      // A raw plan may start on the transcoded stream (a two track file the device cannot decode at all)
      if (plan.mode != RawMode.LENSES && fallbackUrl != null && plan.urls.firstOrNull() == fallbackUrl) {
        playingFallback = true
      }
    }
    stereoLayout = stereoLayoutNamed(savedInstanceState?.getString(STATE_STEREO_LAYOUT))
      ?: stereoLayoutNamed(intent.getStringExtra(EXTRA_STEREO_LAYOUT))
      ?: StereoLayout.MONO
    stereoButton = findViewById<View>(R.id.spherical_video_stereo).apply {
      contentDescription = label(LABEL_STEREO)
      setOnClickListener { cycleStereoLayout() }
    }
    applyStereoLayout()

    coverage = coverageNamed(savedInstanceState?.getString(STATE_COVERAGE))
      ?: coverageNamed(intent.getStringExtra(EXTRA_COVERAGE))
      ?: SphereCoverage.FULL
    declaredCoverage = coverageNamed(savedInstanceState?.getString(STATE_DECLARED_COVERAGE))
    coverageButton = findViewById<TextView>(R.id.spherical_video_coverage).apply {
      contentDescription = label(LABEL_COVERAGE)
      tooltipText = label(LABEL_COVERAGE)
      setOnClickListener { cycleCoverage() }
    }
    updateCoverageButton()
    // A raw frame (stitched, one lens or unstitched) is mono and covers the full sphere: neither control would change
    // what shows
    if (rawJsonPresent) {
      stereoButton.visibility = View.GONE
      coverageButton.visibility = View.GONE
    }

    audioTracks = AudioTrackChooser(this, labels)
    audioTracks.chosenIndex = savedInstanceState?.getInt(STATE_AUDIO_TRACK, -1) ?: -1
    audioButton = findViewById<View>(R.id.spherical_video_audio).apply {
      contentDescription = audioTracks.buttonLabel
      tooltipText = audioTracks.buttonLabel
      setOnClickListener { showAudioTracks() }
    }

    bufferingLabel = findViewById(R.id.spherical_video_buffering_label)
    val streamed = StreamingLoadControl.isStreamed(playbackUrl().orEmpty())
    bufferingIndicator = BufferingIndicator(bufferingLabel, labels, streamed)

    enterFullScreen(topBar)
    // The first plan of this opening may already be a fallback: the user reads why (a recreation said it already)
    if (restored == null) showRawMessage(plan)
  }

  override fun onStart() {
    super.onStart()
    initializePlayer()
    if (rawMessageOnStart) {
      rawMessageOnStart = false
      showRawMessage(plan)
    }
    // Starts the rendering thread and the orientation sensors of the spherical surface
    playerView.onResume()
  }

  override fun onWindowFocusChanged(hasFocus: Boolean) {
    super.onWindowFocusChanged(hasFocus)
    // A dialog, the notification shade or another app may have brought the system bars back
    if (hasFocus) {
      hideSystemBars()
    }
  }

  override fun onStop() {
    super.onStop()
    playerView.onPause()
    releasePlayer()
  }

  override fun onSaveInstanceState(outState: Bundle) {
    super.onSaveInstanceState(outState)
    player?.let {
      startPosition = it.currentPosition
      playWhenReady = it.playWhenReady
    }
    outState.putLong(STATE_POSITION, startPosition)
    outState.putBoolean(STATE_PLAY_WHEN_READY, playWhenReady)
    outState.putString(STATE_STEREO_LAYOUT, stereoLayout.name)
    outState.putString(STATE_COVERAGE, coverage.name)
    declaredCoverage?.let { outState.putString(STATE_DECLARED_COVERAGE, it.name) }
    outState.putInt(STATE_AUDIO_TRACK, audioTracks.chosenIndex)
    outState.putBoolean(STATE_PLAYING_FALLBACK, playingFallback)
    outState.putBoolean(STATE_DECODER_CHECKED, decoderChecked)
    outState.putString(STATE_RAW_PLAN_MODE, plan.mode.name)
    outState.putIntArray(STATE_RAW_PLAN_STREAMS, plan.streams.toIntArray())
    outState.putStringArrayList(STATE_RAW_PLAN_URLS, ArrayList(plan.urls))
    outState.putBoolean(STATE_RAW_PLAN_FALLBACK, plan.fromFallback)
  }

  override fun onDestroy() {
    // Closed by the user or destroyed by the system rather than recreated: Flutter hears what the player showed last
    if (!isChangingConfigurations) {
      SphericalVideoApiImpl.notifyClosed(currentStereoLayout() ?: stereoLayout, coverage)
    }
    sphericalView?.removeVideoSurfaceListener(videoSurfaceListener)
    super.onDestroy()
  }

  private fun initializePlayer() {
    if (player != null) {
      return
    }
    val url = playbackUrl()
    if (url == null) {
      finish()
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
    val mediaSourceFactory = DefaultMediaSourceFactory(dataSourceFactory)
    val audioAttributes = AudioAttributes.Builder()
      .setUsage(C.USAGE_MEDIA)
      .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
      .build()

    // Larger buffers for a video read over HTTP (the media bridge of a network share, a server); local files as before
    val builder = StreamingLoadControl.applyTo(ExoPlayer.Builder(this), url)
      .setMediaSourceFactory(mediaSourceFactory)
      .setAudioAttributes(audioAttributes, /* handleAudioFocus= */ true)
      .setHandleAudioBecomingNoisy(true)
    val projection = rawProjection
    val lens =
      if (plan.mode == RawMode.LENSES && projection != null) {
        createLensPlayback(projection, builder, mediaSourceFactory)
      } else {
        null
      }
    twoLens = lens
    lensDecodersChecked = false
    player = (lens?.player ?: builder.build())
      .also {
        it.addListener(playerListener)
        // The language picked last, and the track picked for this video before a stop
        audioTracks.attach(it)
        bufferingIndicator.attach(it)
        // Before the surface and before prepare, which sets up the effect pipeline. Once the stitching failed, the
        // player is built without any effect: an empty list would still route the frames through the GL pipeline
        if (plan.mode == RawMode.EFFECT_SIDE_BY_SIDE && projection != null) {
          val size = rawOutputSize(projection)
          it.setVideoEffects(listOf(DualFisheyeEffect(projection, size.width, size.height)))
        }
        if (lens != null) {
          lens.setMedia(plan.urls, startPosition)
        } else {
          it.setMediaItem(MediaItem.fromUri(url), startPosition)
        }
        it.playWhenReady = playWhenReady
        playerView.player = it
        attachSphericalView(it)
        it.prepare()
      }
  }

  /**
   * The lens player of the LENSES plan, or null when its compositor cannot start (no OpenGL ES 3, a shader the
   * driver refuses): the plan then becomes the unstitched one, built by the caller as a plain player.
   */
  private fun createLensPlayback(
    projection: RawProjection,
    builder: ExoPlayer.Builder,
    mediaSourceFactory: DefaultMediaSourceFactory,
  ): TwoLensPlayback? {
    val listener = LensListener()
    return try {
      TwoLensPlayback.create(
        this,
        projection,
        plan.streams,
        RawPlaybackPlanner.assignmentOf(plan, projection),
        builder,
        mediaSourceFactory,
        listener,
      ).also { listener.playback = it }
    } catch (e: RawStitchException) {
      Log.e(TAG, "The lens compositor cannot start, the raw video plays unstitched", e)
      RawPlaybackPlanner.afterStitchFailure(plan)?.let { applyPlan(it) }
      if (!replanPending) showRawMessage(plan)
      null
    }
  }

  /** What the lens player tells, on the main thread; ignored once that player is replaced. */
  private inner class LensListener : TwoLensPlayback.Listener {
    var playback: TwoLensPlayback? = null

    override fun onFirstFrameDrawn() {
      if (playback == null || playback !== twoLens) return
      Log.i(TAG, "First stitched frame on the sphere (${plan.mode} ${plan.streams})")
      // PlayerView.setPlayer closes the black shutter over the video, and only the player's first rendered frame opens
      // it again: a lens player never reports one, its renderers draw into the compositor rather than into the
      // player's surface. The stitched frame opens it; the next player closes it again, as for any player
      playerView.findViewById<View>(androidx.media3.ui.R.id.exo_shutter)?.visibility = View.INVISIBLE
    }

    override fun onStitchError(error: Exception) {
      if (playback !== twoLens || playback == null) return
      Log.e(TAG, "The lens compositor failed while playing", error)
      replan(RawPlaybackPlanner.afterStitchFailure(plan))
    }

    override fun onStreamsMissing(streams: List<Int>) {
      if (playback !== twoLens || playback == null) return
      val projection = rawProjection ?: return
      val url = intent.getStringExtra(EXTRA_URL) ?: return
      Log.w(TAG, "No decodable track for streams $streams")
      // Without a next step there is no error to show either (no track, no decoder error): the frame plays unstitched,
      // where the default renderers may still find a decoder, or fail with an error the user sees
      replan(
        RawPlaybackPlanner.afterDecoderFailure(plan, projection, url, fallbackUrl)
          ?: RawPlaybackPlanner.afterStitchFailure(plan),
      )
    }
  }

  /**
   * PlayerView hands the spherical view to the player, which then gives the renderer of the view the projection of
   * the file with every frame, whatever else listens to the frames. Instead, the player renders into the surface of
   * the view alone (setting the surface drops the link of the player to the view), and the frames reach the renderer
   * through [CoverageFrameListener], which gives it the projection of the coverage. The camera motion track of a
   * video, if any, still turns the view.
   *
   * A lens player never renders into the view itself: clearVideoSurface undoes what PlayerView.setPlayer did (the
   * view's surface given to every video renderer, the link to the view), then each lens renderer gets its own
   * Surface of the compositor, which draws into the view's surface and tells the view's renderer about each frame.
   */
  private fun attachSphericalView(player: ExoPlayer) {
    val view = sphericalView ?: return
    val lens = twoLens
    if (lens != null) {
      player.clearVideoSurface()
      lens.bindRendererOutputs()
      lens.setDownstream(CoverageFrameListener(view.videoFrameMetadataListener))
      player.setCameraMotionListener(view.cameraMotionListener)
      view.videoSurface?.let(::attachLensOutput)
      return
    }
    val surface = view.videoSurface
    if (surface != null) setPlayerSurface(player, surface) else player.setVideoSurface(null)
    player.setVideoFrameMetadataListener(CoverageFrameListener(view.videoFrameMetadataListener))
    player.setCameraMotionListener(view.cameraMotionListener)
  }

  /**
   * Hands [surface] to the lens compositor, the SurfaceTexture behind it sized first (see [sizeRawSurface]) to the
   * stitched frame within the limits of the phone and of the GPU.
   */
  private fun attachLensOutput(surface: Surface) {
    val lens = twoLens ?: return
    val projection = rawProjection ?: return
    val size = rawOutputSize(projection, lens.maxOutputSize)
    sizeRawSurface(size.width, size.height)
    lens.setOutput(surface, size.width, size.height)
  }

  /**
   * Hands [surface] to [player]. With the stitching on, Media3 draws the frames into it with OpenGL and must be told
   * its size, and the SurfaceTexture behind it must get that size first (see [sizeRawSurface]).
   */
  private fun setPlayerSurface(player: ExoPlayer, surface: Surface) {
    val raw = rawProjection
    if (raw == null || plan.mode != RawMode.EFFECT_SIDE_BY_SIDE) {
      player.setVideoSurface(surface)
      return
    }
    val size = rawOutputSize(raw)
    sizeRawSurface(size.width, size.height)
    player.setVideoSurface(surface)
    DualFisheyeEffect.setOutputResolution(player, size.width, size.height)
  }

  /**
   * The SurfaceTexture of the spherical view has buffers of 1x1 pixel unless told otherwise: the decoder sets its own
   * size when it renders there, OpenGL does not. Media3 draws the stitched frames with OpenGL, so the texture gets the
   * size of the output first, before Media3 creates its EGL surface on it.
   */
  private fun sizeRawSurface(width: Int, height: Int) {
    val texture = sphericalView?.let { view -> runCatching { surfaceTextureField?.get(view) }.getOrNull() }
    if (texture is SurfaceTexture) {
      texture.setDefaultBufferSize(width, height)
    } else {
      Log.w(TAG, "No SurfaceTexture to size for the stitched frame, it may not show")
    }
  }

  /**
   * The rawProjection of a raw 360° video from [json], or null for an equirectangular video. A JSON the parser refuses,
   * or a spherical view whose surface cannot be sized, plays the frame as it is (the lenses on the sphere): the log
   * tells why.
   */
  private fun rawProjectionOf(json: String?): RawProjection? {
    if (json == null) return null
    val projection =
      try {
        RawProjection.parse(json)
      } catch (e: IllegalArgumentException) {
        Log.e(RAW_PROJECTION_TAG, "rawProjection rejected: ${e.message}")
        return null
      }
    if (sphericalView == null || surfaceTextureField == null) {
      Log.w(TAG, "The spherical view cannot take a stitched frame here, the raw frame plays as it is")
      return null
    }
    Log.i(RAW_PROJECTION_TAG, projection.summary())
    return projection
  }

  /** Whether the device decodes [instances] streams like [track] at once, null when the JSON cannot tell. */
  private fun canDecodeRaw(track: RawTrack, instances: Int): Boolean? {
    val codec = track.codecs ?: track.codec ?: return null
    val verdict =
      VideoDecoders.canDecode(
        codec,
        track.codecs,
        track.width,
        track.height,
        track.frameRate,
        track.bitDepth,
        transferCharacteristics = 0,
        instances = instances,
      )
    return verdict.supported
  }

  /** The plan saved by [onSaveInstanceState], or null without one. */
  private fun restoredPlan(state: Bundle): RawPlan? {
    val mode = RawMode.entries.firstOrNull { it.name == state.getString(STATE_RAW_PLAN_MODE) } ?: return null
    if (mode == RawMode.LENSES && rawProjection == null) return null
    return RawPlan(
      mode,
      state.getIntArray(STATE_RAW_PLAN_STREAMS)?.toList().orEmpty(),
      state.getStringArrayList(STATE_RAW_PLAN_URLS).orEmpty(),
      state.getBoolean(STATE_RAW_PLAN_FALLBACK),
      null,
      "restored",
    )
  }

  /** Makes [newPlan] the plan: a plain player plays the transcoded stream when the plan says so. */
  private fun applyPlan(newPlan: RawPlan) {
    plan = newPlan
    if (newPlan.mode != RawMode.LENSES) {
      playingFallback = fallbackUrl != null && newPlan.urls.firstOrNull() == fallbackUrl
      decoderChecked = false
    }
  }

  /**
   * Plays the video again from where it stopped with [newPlan] (one lens, the transcoded streams, unstitched), on a
   * new player: the renderers and the effects of a player are fixed when it is built. False when there is no new plan
   * (the error then shows), or no player.
   */
  private fun replan(newPlan: RawPlan?): Boolean {
    if (newPlan == null || player == null) return false
    if (replanPending) return true
    replanPending = true
    Log.i(TAG, "Raw plan ${plan.mode} ${plan.streams} -> ${newPlan.mode} ${newPlan.streams}: ${newPlan.reason}")
    // Posted, not run from within the listener of the player being replaced
    playerView.post {
      replanPending = false
      if (isFinishing || isDestroyed) return@post
      // Stopped meanwhile: onStop released the player, and a new one built now would play in the background. onStart
      // builds the player of the plan, from where onStop left it, and tells why
      if (!lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {
        applyPlan(newPlan)
        rawMessageOnStart = true
        return@post
      }
      releasePlayer()
      applyPlan(newPlan)
      initializePlayer()
      // The plan that plays: a lens compositor that cannot start made it the unstitched one meanwhile
      showRawMessage(plan)
    }
    return true
  }

  /** The message of [plan], if it has one, translated by Flutter or in English. */
  private fun showRawMessage(plan: RawPlan) {
    val text =
      when (plan.message ?: return) {
        RawMessage.ONE_LENS_DECODER -> {
          val track = rawProjection?.tracks?.maxByOrNull { it.pixels }
          val codec = VideoDecoders.codecName(VideoDecoders.mimeFor(track?.codecs ?: track?.codec ?: ""))
          val template = label(LABEL_RAW_ONE_LENS_DECODER)
          VideoDecoders.decoderLabel(
            mapOf(LABEL_RAW_ONE_LENS_DECODER to template),
            LABEL_RAW_ONE_LENS_DECODER,
            codec,
            track?.width ?: 0,
            track?.height ?: 0,
          ) ?: template
        }
        RawMessage.ONE_LENS_FILE -> label(LABEL_RAW_ONE_LENS_FILE)
        RawMessage.UNSTITCHED -> label(LABEL_RAW_UNSTITCHED)
      }
    Log.i(TAG, "Shown to the user: $text")
    showToast(text, Toast.LENGTH_LONG)
  }

  /**
   * Once per lens player: the selected lens tracks against the decoders, the instance count included (the JSON's
   * sizes were checked before; the decoded formats tell the frame rate and the colour for sure). Two streams the
   * device refuses become one lens.
   */
  private fun checkLensDecoders(tracks: Tracks) {
    if (lensDecodersChecked || plan.streams.size < 2) return
    val formats = tracks.groups.filter { it.type == C.TRACK_TYPE_VIDEO && it.isSelected }.flatMap { group ->
      (0 until group.length).filter { group.isTrackSelected(it) }.map { group.getTrackFormat(it) }
    }
    val largest = formats.filter { it.width > 0 && it.height > 0 }.maxByOrNull { it.width * it.height } ?: return
    lensDecodersChecked = true
    val verdict = VideoDecoders.canDecode(largest, instances = plan.streams.size)
    Log.i(TAG, "Lens decoders: ${formats.size} tracks selected, ${verdict.reason}")
    if (verdict.supported) return
    val projection = rawProjection ?: return
    val url = intent.getStringExtra(EXTRA_URL) ?: return
    replan(RawPlaybackPlanner.afterDecoderFailure(plan, projection, url, fallbackUrl))
  }

  /** The URL that plays: the plan's first in lens mode, else the original or the transcoded stream once switched */
  private fun playbackUrl(): String? =
    if (plan.mode == RawMode.LENSES) plan.urls.firstOrNull()
    else if (playingFallback) fallbackUrl else intent.getStringExtra(EXTRA_URL)

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
      showToast(message, Toast.LENGTH_LONG)
    } else {
      Log.i(TAG, "No label from Flutter for the switch to the transcoded stream")
    }
  }

  /**
   * Plays the transcoded stream in place of the original, from where it stopped, once. False when there is none, when
   * it already plays, or without a player.
   */
  private fun switchToFallback(reason: String): Boolean {
    val fallback = fallbackUrl ?: return false
    val current = player ?: return false
    if (playingFallback) {
      return false
    }
    playingFallback = true
    decoderChecked = false
    Log.i(TAG, "Switching to the transcoded stream: $reason")
    // The transcoded stream may lose the stereo metadata of the original: the layout the original declared becomes the
    // layout of the 3D control, which the renderer applies to a video that declares none
    currentStereoLayout()?.let { stereoLayout = it }
    declaredStereoMode = Format.NO_VALUE
    applyStereoLayout()
    current.setMediaItem(MediaItem.fromUri(fallback), current.currentPosition.coerceAtLeast(0L))
    current.prepare()
    return true
  }

  private fun releasePlayer() {
    val current = player ?: return
    audioTracks.dismissDialog()
    bufferingIndicator.detach()
    startPosition = current.currentPosition
    playWhenReady = current.playWhenReady
    current.removeListener(playerListener)
    playerView.player = null
    // The lens player first, then its compositor (the decoders leave the compositor's Surfaces before they go)
    val lens = twoLens
    twoLens = null
    if (lens != null) lens.release() else current.release()
    player = null
    playerView.keepScreenOn = false
  }

  /** Lists the audio tracks of the video to pick one */
  private fun showAudioTracks() {
    val current = player ?: return
    playerView.showController()
    audioTracks.showDialog(this, current)
  }

  /** Cycles mono, top and bottom, side by side, unless the video declares its own layout */
  private fun cycleStereoLayout() {
    // Keeps the controls, and so this button, on screen while the user cycles
    playerView.showController()
    if (declaredStereoMode == Format.NO_VALUE) {
      stereoLayout = when (stereoLayout) {
        StereoLayout.MONO -> StereoLayout.TOP_BOTTOM
        StereoLayout.TOP_BOTTOM -> StereoLayout.LEFT_RIGHT
        StereoLayout.LEFT_RIGHT -> StereoLayout.MONO
      }
      applyStereoLayout()
      redrawPausedFrame()
    }
    showToast(currentStereoLabel())
  }

  /**
   * Hands the layout to the spherical renderer as its default stereo mode, used for videos that declare none. The
   * renderer reads the default again for every video frame it draws, so a new layout shows from the next frame on.
   */
  private fun applyStereoLayout() {
    sphericalView?.setDefaultStereoMode(stereoLayout.stereoMode)
    updateStereoButton()
  }

  /**
   * Switches between the full sphere and the half sphere, from the coverage the video declares when it does. The
   * renderer gets the projection with each frame, so the new coverage shows from the next frame on.
   */
  private fun cycleCoverage() {
    // Keeps the controls, and so this button, on screen while the user switches
    playerView.showController()
    coverage = if (coverage == SphereCoverage.FULL) SphereCoverage.HALF else SphereCoverage.FULL
    updateCoverageButton()
    redrawPausedFrame()
    showToast(coverageLabel())
  }

  /**
   * Takes the coverage the video declares in place of the current one, but only when it differs from the declared
   * coverage known so far: a new player for the same video (after a stop) or a recreated activity keeps the choice
   * made with the control since.
   */
  private fun applyDeclaredCoverage(declared: SphereCoverage?) {
    if (declared == declaredCoverage) {
      return
    }
    declaredCoverage = declared
    if (declared != null && declared != coverage) {
      coverage = declared
      updateCoverageButton()
      redrawPausedFrame()
    }
  }

  /**
   * A paused or ended video draws no new frame, and the renderer only applies a new layout or coverage to the next
   * frame it draws, so a seek draws the frame on screen again with the new layout or coverage. ExoPlayer ignores a
   * seek to the current millisecond, hence the step of 1 ms back (or forward to 1 ms at the very start). After the
   * video has ended, the seek moves it back into its last millisecond: that millisecond plays again and the video ends
   * again, now showing the change.
   */
  private fun redrawPausedFrame() {
    val current = player ?: return
    if (current.isPlaying || !current.isCurrentMediaItemSeekable) {
      return
    }
    val state = current.playbackState
    if (state != Player.STATE_READY && state != Player.STATE_ENDED) {
      return
    }
    val position = current.currentPosition
    current.seekTo(if (position > 0) position - 1 else 1)
  }

  /** Dims the 3D control for a regular 360° video and gives the name of the current layout as tooltip and state */
  private fun updateStereoButton() {
    val label = currentStereoLabel()
    stereoButton.alpha = if (currentStereoLayout() == StereoLayout.MONO) MONO_ALPHA else 1f
    stereoButton.tooltipText = label
    ViewCompat.setStateDescription(stereoButton, label)
  }

  /** The layout the video declares, or the layout of the 3D control when it declares none */
  private fun currentStereoLayout(): StereoLayout? =
    if (declaredStereoMode == Format.NO_VALUE) stereoLayout else stereoLayoutOf(declaredStereoMode)

  /** A declared stereo mode the control has no name for (a stereo mesh for instance) shows the control's label */
  private fun currentStereoLabel(): String = label(currentStereoLayout()?.labelKey ?: LABEL_STEREO)

  /** "360°" or "180°", which read the same in every language, with the name of the coverage as state */
  private fun updateCoverageButton() {
    coverageButton.text = if (coverage == SphereCoverage.HALF) "180°" else "360°"
    ViewCompat.setStateDescription(coverageButton, coverageLabel())
  }

  private fun coverageLabel(): String =
    label(if (coverage == SphereCoverage.HALF) LABEL_COVERAGE_HALF else LABEL_COVERAGE_FULL)

  private fun label(key: String): String = labels[key]?.takeIf { it.isNotBlank() } ?: DEFAULT_LABELS.getValue(key)

  /** One message at a time: a new one replaces the one on screen */
  private fun showToast(text: String, duration: Int = Toast.LENGTH_SHORT) {
    toast?.cancel()
    toast = Toast.makeText(this, text, duration).also { it.show() }
  }

  private fun selectedVideoFormat(tracks: Tracks): Format? {
    val group = tracks.groups.firstOrNull { it.type == C.TRACK_TYPE_VIDEO && it.isSelected } ?: return null
    return (0 until group.length).firstOrNull { group.isTrackSelected(it) }?.let { group.getTrackFormat(it) }
  }

  /**
   * Passes each video frame on to [scene], the renderer of the spherical view, with the format of [projectedFormat],
   * or of [stitchedFormat] for a raw 360° video (stitched, one lens or unstitched: whatever the file declares no
   * longer applies). Called on the playback thread, or on the compositor's thread for a lens player. Frames of the
   * same format and coverage reuse the format built for the first one.
   */
  private inner class CoverageFrameListener(private val scene: VideoFrameMetadataListener) :
    VideoFrameMetadataListener {
    private var lastFormat: Format? = null
    private var lastCoverage: SphereCoverage? = null
    private var lastProjected: Format? = null
    private var lastRaw = false

    override fun onVideoFrameAboutToBeRendered(
      presentationTimeUs: Long,
      releaseTimeNs: Long,
      format: Format,
      mediaFormat: MediaFormat?,
    ) {
      val coverage = this@SphericalVideoActivity.coverage
      val raw = plan.mode != RawMode.PLAIN
      var projected = lastProjected
      if (projected == null || format !== lastFormat || coverage != lastCoverage || raw != lastRaw) {
        projected = if (raw) stitchedFormat(format) else projectedFormat(format, coverage)
        lastRaw = raw
        lastFormat = format
        lastCoverage = coverage
        lastProjected = projected
      }
      scene.onVideoFrameAboutToBeRendered(presentationTimeUs, releaseTimeNs, projected, mediaFormat)
    }
  }

  private fun hideSystemBars() {
    WindowInsetsControllerCompat(window, window.decorView).apply {
      systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
      hide(WindowInsetsCompat.Type.systemBars())
    }
  }

  private fun enterFullScreen(topBar: View) {
    WindowCompat.setDecorFitsSystemWindows(window, false)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      window.attributes = window.attributes.apply {
        layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
      }
    }
    hideSystemBars()

    // The video fills the whole screen, the controls stay clear of the camera cutout and of the system bars
    val controller = playerView.findViewById<View>(androidx.media3.ui.R.id.exo_controller)
    val bufferingMargin = (bufferingLabel.layoutParams as FrameLayout.LayoutParams).bottomMargin
    ViewCompat.setOnApplyWindowInsetsListener(findViewById(R.id.spherical_video_root)) { _, insets ->
      val safe = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
      topBar.updateLayoutParams<FrameLayout.LayoutParams> {
        leftMargin = safe.left
        topMargin = safe.top
        rightMargin = safe.right
      }
      controller?.updatePadding(left = safe.left, right = safe.right, bottom = safe.bottom)
      bufferingLabel.updateLayoutParams<FrameLayout.LayoutParams> { bottomMargin = bufferingMargin + safe.bottom }
      insets
    }
  }
}

private fun Map<String, String>.toBundle() =
  Bundle().also { bundle -> forEach { (key, value) -> bundle.putString(key, value) } }

private fun Bundle.toStringMap(): Map<String, String> = keySet().associateWith { getString(it).orEmpty() }
