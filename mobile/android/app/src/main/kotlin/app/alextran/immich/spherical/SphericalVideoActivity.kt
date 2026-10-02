package app.alextran.immich.spherical

import android.content.Context
import android.content.Intent
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
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ErrorMessageProvider
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
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
import app.alextran.immich.core.HttpClientManager
import app.alextran.immich.core.StreamingLoadControl

private const val TAG = "SphericalVideoActivity"

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
 *
 * On close (button, system back, or the system destroying the activity), Flutter gets [SphericalVideoEvents.closed]
 * with the layout and the coverage shown last, so that the corrections of the user can be remembered for the asset.
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
    private const val STATE_POSITION = "position"
    private const val STATE_PLAY_WHEN_READY = "play_when_ready"
    private const val STATE_STEREO_LAYOUT = "stereo_layout"
    private const val STATE_COVERAGE = "coverage"
    private const val STATE_DECLARED_COVERAGE = "declared_coverage"
    private const val STATE_AUDIO_TRACK = "audio_track"

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
     * control, keyed "coverage", "coverage_full" and "coverage_half", and of the audio track control (see
     * [AudioTrackChooser]). [coverage] is the part of the sphere Flutter expects the video to cover.
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
  }

  private lateinit var playerView: PlayerView
  private lateinit var stereoButton: View
  private lateinit var coverageButton: TextView
  private lateinit var audioButton: View
  private lateinit var audioTracks: AudioTrackChooser

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

  /** Sets the clear colour of the renderer, on its GL thread: black, the back of a half sphere */
  private val clearToBlack = Runnable { GLES20.glClearColor(0f, 0f, 0f, 1f) }

  /**
   * The spherical view creates a new surface with each GL context (after a pause for instance), once its renderer
   * has started; the player follows it.
   */
  private val videoSurfaceListener = object : SphericalGLSurfaceView.VideoSurfaceListener {
    override fun onVideoSurfaceCreated(surface: Surface) {
      player?.setVideoSurface(surface)
      // The renderer has just started and set its clear colour, gray; queued, this runs after it
      sphericalView?.queueEvent(clearToBlack)
    }

    override fun onVideoSurfaceDestroyed(surface: Surface) {
      player?.clearVideoSurface(surface)
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
      // Tracks without a selected video say nothing about the coverage
      if (format != null) {
        applyDeclaredCoverage(DeclaredProjection.of(format.projectionData)?.coverage)
      }
      // The audio track button shows when there is a choice
      val options = player?.let { audioTracks.onTracksChanged(it, tracks) }.orEmpty()
      audioButton.visibility = if (options.size >= 2) View.VISIBLE else View.GONE
    }

    override fun onPlayerError(error: PlaybackException) {
      Log.e(TAG, "Cannot play the 360° video", error)
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

    labels = intent.getBundleExtra(EXTRA_STEREO_LABELS)?.toStringMap() ?: emptyMap()
    sphericalView = (playerView.videoSurfaceView as? SphericalGLSurfaceView)?.also {
      it.addVideoSurfaceListener(videoSurfaceListener)
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

    audioTracks = AudioTrackChooser(this, labels)
    audioTracks.chosenIndex = savedInstanceState?.getInt(STATE_AUDIO_TRACK, -1) ?: -1
    audioButton = findViewById<View>(R.id.spherical_video_audio).apply {
      contentDescription = audioTracks.buttonLabel
      tooltipText = audioTracks.buttonLabel
      setOnClickListener { showAudioTracks() }
    }

    enterFullScreen(topBar)
  }

  override fun onStart() {
    super.onStart()
    initializePlayer()
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
    val url = intent.getStringExtra(EXTRA_URL)
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
        // The language picked last, and the track picked for this video before a stop
        audioTracks.attach(it)
        it.setMediaItem(MediaItem.fromUri(url), startPosition)
        it.playWhenReady = playWhenReady
        playerView.player = it
        attachSphericalView(it)
        it.prepare()
      }
  }

  /**
   * PlayerView hands the spherical view to the player, which then gives the renderer of the view the projection of
   * the file with every frame, whatever else listens to the frames. Instead, the player renders into the surface of
   * the view alone (setting the surface drops the link of the player to the view), and the frames reach the renderer
   * through [CoverageFrameListener], which gives it the projection of the coverage. The camera motion track of a
   * video, if any, still turns the view.
   */
  private fun attachSphericalView(player: ExoPlayer) {
    val view = sphericalView ?: return
    player.setVideoSurface(view.videoSurface)
    player.setVideoFrameMetadataListener(CoverageFrameListener(view.videoFrameMetadataListener))
    player.setCameraMotionListener(view.cameraMotionListener)
  }

  private fun releasePlayer() {
    val current = player ?: return
    audioTracks.dismissDialog()
    startPosition = current.currentPosition
    playWhenReady = current.playWhenReady
    current.removeListener(playerListener)
    playerView.player = null
    current.release()
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
  private fun showToast(text: String) {
    toast?.cancel()
    toast = Toast.makeText(this, text, Toast.LENGTH_SHORT).also { it.show() }
  }

  private fun selectedVideoFormat(tracks: Tracks): Format? {
    val group = tracks.groups.firstOrNull { it.type == C.TRACK_TYPE_VIDEO && it.isSelected } ?: return null
    return (0 until group.length).firstOrNull { group.isTrackSelected(it) }?.let { group.getTrackFormat(it) }
  }

  /**
   * Passes each video frame on to [scene], the renderer of the spherical view, with the format of [projectedFormat].
   * Called on the playback thread. Frames of the same format and coverage reuse the format built for the first one.
   */
  private inner class CoverageFrameListener(private val scene: VideoFrameMetadataListener) :
    VideoFrameMetadataListener {
    private var lastFormat: Format? = null
    private var lastCoverage: SphereCoverage? = null
    private var lastProjected: Format? = null

    override fun onVideoFrameAboutToBeRendered(
      presentationTimeUs: Long,
      releaseTimeNs: Long,
      format: Format,
      mediaFormat: MediaFormat?,
    ) {
      val coverage = this@SphericalVideoActivity.coverage
      var projected = lastProjected
      if (projected == null || format !== lastFormat || coverage != lastCoverage) {
        projected = projectedFormat(format, coverage)
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
    ViewCompat.setOnApplyWindowInsetsListener(findViewById(R.id.spherical_video_root)) { _, insets ->
      val safe = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
      topBar.updateLayoutParams<FrameLayout.LayoutParams> {
        leftMargin = safe.left
        topMargin = safe.top
        rightMargin = safe.right
      }
      controller?.updatePadding(left = safe.left, right = safe.right, bottom = safe.bottom)
      insets
    }
  }
}

private fun Map<String, String>.toBundle() =
  Bundle().also { bundle -> forEach { (key, value) -> bundle.putString(key, value) } }

private fun Bundle.toStringMap(): Map<String, String> = keySet().associateWith { getString(it).orEmpty() }
