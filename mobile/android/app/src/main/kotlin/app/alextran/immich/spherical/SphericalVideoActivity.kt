package app.alextran.immich.spherical

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.Pair
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
import androidx.media3.exoplayer.video.spherical.SphericalGLSurfaceView
import androidx.media3.ui.PlayerView
import app.alextran.immich.R
import app.alextran.immich.core.HttpClientManager

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
    private const val STATE_POSITION = "position"
    private const val STATE_PLAY_WHEN_READY = "play_when_ready"
    private const val STATE_STEREO_LAYOUT = "stereo_layout"

    /** Key of the label of the 3D control itself, in the labels from Flutter */
    private const val LABEL_STEREO = "stereo"

    /** English labels of the 3D control, used for the keys Flutter does not send */
    private val DEFAULT_STEREO_LABELS = mapOf(
      LABEL_STEREO to "3D layout",
      "mono" to "Mono (not 3D)",
      "topBottom" to "3D, top and bottom",
      "leftRight" to "3D, side by side",
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
     * labels of the 3D control, keyed "stereo", "mono", "topBottom" and "leftRight".
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
    ): Intent {
      return Intent(context, SphericalVideoActivity::class.java)
        .putExtra(EXTRA_URL, url)
        .putExtra(EXTRA_HEADERS, headers.toBundle())
        .putExtra(EXTRA_TITLE, title)
        .putExtra(EXTRA_CLOSE_LABEL, closeLabel)
        .putExtra(EXTRA_ERROR_MESSAGE, errorMessage)
        .putExtra(EXTRA_STEREO_LAYOUT, stereoLayout.name)
        .putExtra(EXTRA_STEREO_LABELS, stereoLabels.toBundle())
    }

    private fun stereoLayoutNamed(name: String?): StereoLayout? = StereoLayout.entries.firstOrNull { it.name == name }

    private fun stereoLayoutOf(stereoMode: Int): StereoLayout? =
      StereoLayout.entries.firstOrNull { it.stereoMode == stereoMode }
  }

  private lateinit var playerView: PlayerView
  private lateinit var stereoButton: View
  private var player: ExoPlayer? = null
  private var startPosition = 0L
  private var playWhenReady = true
  private var stereoLabels = emptyMap<String, String>()
  private var stereoToast: Toast? = null

  /** Layout for videos that declare none: first the guess of Flutter, then the choice made with the 3D control */
  private var stereoLayout = StereoLayout.MONO

  /** Stereo mode the video declares in its spherical metadata (st3d box), [Format.NO_VALUE] when it declares none */
  private var declaredStereoMode = Format.NO_VALUE

  private val playerListener = object : Player.Listener {
    override fun onIsPlayingChanged(isPlaying: Boolean) {
      playerView.keepScreenOn = isPlaying
    }

    override fun onTracksChanged(tracks: Tracks) {
      // The spherical renderer only falls back to the default stereo mode set by the 3D control when the video
      // declares no stereo mode. For a video that declares one, the declared mode wins over the control, so the
      // control shows the declared layout and does not cycle.
      val stereoMode = selectedVideoFormat(tracks)?.stereoMode ?: Format.NO_VALUE
      if (stereoMode != declaredStereoMode) {
        declaredStereoMode = stereoMode
        updateStereoButton()
      }
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

    // The close button, the title and the 3D control come and go with the playback controls
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

    stereoLabels = intent.getBundleExtra(EXTRA_STEREO_LABELS)?.toStringMap() ?: emptyMap()
    stereoLayout = stereoLayoutNamed(savedInstanceState?.getString(STATE_STEREO_LAYOUT))
      ?: stereoLayoutNamed(intent.getStringExtra(EXTRA_STEREO_LAYOUT))
      ?: StereoLayout.MONO
    stereoButton = findViewById<View>(R.id.spherical_video_stereo).apply {
      contentDescription = stereoLabel(LABEL_STEREO)
      setOnClickListener { cycleStereoLayout() }
    }
    applyStereoLayout()

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

    player = ExoPlayer.Builder(this)
      .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
      .setAudioAttributes(audioAttributes, /* handleAudioFocus= */ true)
      .setHandleAudioBecomingNoisy(true)
      .build()
      .also {
        it.addListener(playerListener)
        it.setMediaItem(MediaItem.fromUri(url), startPosition)
        it.playWhenReady = playWhenReady
        it.prepare()
        playerView.player = it
      }
  }

  private fun releasePlayer() {
    val current = player ?: return
    startPosition = current.currentPosition
    playWhenReady = current.playWhenReady
    current.removeListener(playerListener)
    playerView.player = null
    current.release()
    player = null
    playerView.keepScreenOn = false
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
    stereoToast?.cancel()
    stereoToast = Toast.makeText(this, currentStereoLabel(), Toast.LENGTH_SHORT).also { it.show() }
  }

  /**
   * Hands the layout to the spherical renderer as its default stereo mode, used for videos that declare none. The
   * renderer reads the default again for every video frame it draws, so a new layout shows from the next frame on.
   */
  private fun applyStereoLayout() {
    (playerView.videoSurfaceView as? SphericalGLSurfaceView)?.setDefaultStereoMode(stereoLayout.stereoMode)
    updateStereoButton()
  }

  /**
   * A paused or ended video draws no new frame, and the renderer only applies a new layout to the next frame it draws,
   * so a seek draws the frame on screen again with the new layout. ExoPlayer ignores a seek to the current
   * millisecond, hence the step of 1 ms back (or forward to 1 ms at the very start). After the video has ended, the
   * seek moves it back into its last millisecond: that millisecond plays again and the video ends again, now showing
   * the new layout.
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
  private fun currentStereoLabel(): String = stereoLabel(currentStereoLayout()?.labelKey ?: LABEL_STEREO)

  private fun stereoLabel(key: String): String =
    stereoLabels[key]?.takeIf { it.isNotBlank() } ?: DEFAULT_STEREO_LABELS.getValue(key)

  private fun selectedVideoFormat(tracks: Tracks): Format? {
    val group = tracks.groups.firstOrNull { it.type == C.TRACK_TYPE_VIDEO && it.isSelected } ?: return null
    return (0 until group.length).firstOrNull { group.isTrackSelected(it) }?.let { group.getTrackFormat(it) }
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
