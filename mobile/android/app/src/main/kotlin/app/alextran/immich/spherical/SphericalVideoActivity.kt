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
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView
import app.alextran.immich.R
import app.alextran.immich.core.HttpClientManager

private const val TAG = "SphericalVideoActivity"

/**
 * Plays an equirectangular video full screen. The spherical surface of [PlayerView] turns the view with touch
 * drags and with the orientation sensors; a tap shows the playback controls and the close button. System back
 * closes the player too.
 */
@OptIn(UnstableApi::class)
class SphericalVideoActivity : ComponentActivity() {
  companion object {
    private const val EXTRA_URL = "url"
    private const val EXTRA_HEADERS = "headers"
    private const val EXTRA_TITLE = "title"
    private const val EXTRA_CLOSE_LABEL = "close_label"
    private const val EXTRA_ERROR_MESSAGE = "error_message"
    private const val STATE_POSITION = "position"
    private const val STATE_PLAY_WHEN_READY = "play_when_ready"

    /** [closeLabel] and [errorMessage] come translated from Flutter; null falls back to the English resources */
    fun intent(
      context: Context,
      url: String,
      headers: Map<String, String>,
      title: String,
      closeLabel: String?,
      errorMessage: String?,
    ): Intent {
      val headerBundle = Bundle().apply { headers.forEach { (key, value) -> putString(key, value) } }
      return Intent(context, SphericalVideoActivity::class.java)
        .putExtra(EXTRA_URL, url)
        .putExtra(EXTRA_HEADERS, headerBundle)
        .putExtra(EXTRA_TITLE, title)
        .putExtra(EXTRA_CLOSE_LABEL, closeLabel)
        .putExtra(EXTRA_ERROR_MESSAGE, errorMessage)
    }
  }

  private lateinit var playerView: PlayerView
  private var player: ExoPlayer? = null
  private var startPosition = 0L
  private var playWhenReady = true

  private val playerListener = object : Player.Listener {
    override fun onIsPlayingChanged(isPlaying: Boolean) {
      playerView.keepScreenOn = isPlaying
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

    // The close button and the title come and go with the playback controls
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
    val headers = intent.getBundleExtra(EXTRA_HEADERS)?.let { bundle ->
      bundle.keySet().associateWith { bundle.getString(it).orEmpty() }
    } ?: emptyMap()

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
