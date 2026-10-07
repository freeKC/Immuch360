package app.alextran.immich.camera

import android.content.Context
import android.content.ContextWrapper
import android.net.Uri
import android.view.Gravity
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.rtsp.RtspMediaSource
import androidx.media3.ui.AspectRatioFrameLayout
import io.flutter.plugin.platform.PlatformView

/**
 * The address Media3 plays for a live view: [url] (`rtsp://host:port/path`, without credentials, as Flutter sends it)
 * with the camera account in its user info. Media3 reads the account from there (decoded, split at the first `:`) and
 * takes it out of every request it sends. Each byte of the account outside the unreserved characters of RFC 3986 is
 * percent-encoded, so that any character of a password survives (a space as `%20`: `+` would stay a `+`). Null for an
 * address that is not a plain `rtsp://` one, or that already holds a user info.
 */
fun cameraRtspUri(url: String, user: String?, password: String?): String? {
  val prefix = "rtsp://"
  if (!url.startsWith(prefix, ignoreCase = true)) {
    return null
  }
  val rest = url.substring(prefix.length)
  val authority = rest.substringBefore('/')
  if (authority.isEmpty() || authority.contains('@')) {
    return null
  }
  if (user.isNullOrEmpty()) {
    return prefix + rest
  }
  val userInfo = encodeUserInfo(user) + if (password.isNullOrEmpty()) "" else ":" + encodeUserInfo(password)
  return "$prefix$userInfo@$rest"
}

private fun encodeUserInfo(text: String): String {
  val out = StringBuilder()
  for (byte in text.toByteArray(Charsets.UTF_8)) {
    val value = byte.toInt() and 0xff
    val char = value.toChar()
    if (char in 'A'..'Z' || char in 'a'..'z' || char in '0'..'9' || char == '-' || char == '.' || char == '_' || char == '~') {
      out.append(char)
    } else {
      out.append('%').append("0123456789ABCDEF"[value shr 4]).append("0123456789ABCDEF"[value and 0x0f])
    }
  }
  return out.toString()
}

/**
 * One live view of a Tapo camera (Tapo design 3.8): an ExoPlayer on the RTSP stream of the camera, RTP over TCP, a short
 * buffer for a small delay, muted at first, drawn on a SurfaceView kept at the aspect ratio of the video. The address
 * with the camera account stays in memory: never logged, Media3 debug logging off, and the errors sent to Flutter carry
 * the name of the Media3 error code only. The player is released when Flutter stops the view, disposes of it, and when
 * the activity stops (the camera serves two viewers at most).
 */
@OptIn(UnstableApi::class)
class CameraLiveView(
  private val context: Context,
  private val viewId: Int,
  private val events: CameraLiveEvents,
  private val onDispose: () -> Unit,
) : PlatformView {
  private val surface = SurfaceView(context)
  private val frame =
    AspectRatioFrameLayout(context).apply {
      resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
      addView(surface, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
    }
  private val root =
    FrameLayout(context).apply {
      setBackgroundColor(android.graphics.Color.BLACK)
      addView(frame, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER))
    }

  private var player: ExoPlayer? = null
  private var muted = true
  private var hasAudio = true
  private var lastState: CameraLiveState? = null
  private var disposed = false

  private val lifecycle: Lifecycle? = findLifecycle(context)
  private val lifecycleObserver =
    object : DefaultLifecycleObserver {
      override fun onStop(owner: LifecycleOwner) {
        stop()
      }
    }

  private val listener =
    object : Player.Listener {
      override fun onPlaybackStateChanged(playbackState: Int) {
        report()
      }

      override fun onIsPlayingChanged(isPlaying: Boolean) {
        report()
      }

      override fun onVideoSizeChanged(videoSize: VideoSize) {
        if (videoSize.width > 0 && videoSize.height > 0) {
          frame.setAspectRatio(videoSize.width * videoSize.pixelWidthHeightRatio / videoSize.height)
        }
      }

      override fun onTracksChanged(tracks: Tracks) {
        // A camera sends G.711: a device without its decoder plays the video alone, which the sound button tells
        hasAudio = tracks.groups.any { it.type == C.TRACK_TYPE_AUDIO && it.isSupported }
        report(force = true)
      }

      override fun onPlayerError(error: PlaybackException) {
        send(CameraLiveState.FAILED, error.errorCodeName)
      }
    }

  init {
    lifecycle?.addObserver(lifecycleObserver)
  }

  override fun getView(): View = root

  /** Plays [source] in place of what played before (also the switch between the HD and SD streams) */
  fun play(source: CameraLiveSource) {
    if (disposed) {
      return
    }
    releasePlayer()
    val address = if (source.isHls) null else cameraRtspUri(source.url, source.username, source.password)
    if (address == null) {
      send(CameraLiveState.FAILED, "unsupported address")
      return
    }
    val loadControl = DefaultLoadControl.Builder().setBufferDurationsMs(500, 2_000, 250, 500).build()
    val exoPlayer = ExoPlayer.Builder(context).setLoadControl(loadControl).build()
    exoPlayer.setVideoSurfaceView(surface)
    exoPlayer.addListener(listener)
    exoPlayer.volume = if (muted) 0f else 1f
    val mediaSource =
      RtspMediaSource.Factory()
        .setForceUseRtpTcp(true)
        .setTimeoutMs(8_000)
        .setDebugLoggingEnabled(false)
        .createMediaSource(MediaItem.fromUri(Uri.parse(address)))
    exoPlayer.setMediaSource(mediaSource)
    exoPlayer.playWhenReady = true
    exoPlayer.prepare()
    player = exoPlayer
    hasAudio = true
    send(CameraLiveState.CONNECTING, null)
  }

  fun setMuted(muted: Boolean) {
    this.muted = muted
    player?.volume = if (muted) 0f else 1f
  }

  fun stop() {
    if (player != null) {
      releasePlayer()
      send(CameraLiveState.IDLE, null)
    }
  }

  private fun releasePlayer() {
    val current = player ?: return
    player = null
    current.removeListener(listener)
    current.clearVideoSurfaceView(surface)
    current.release()
  }

  private fun report(force: Boolean = false) {
    val current = player ?: return
    val state =
      when (current.playbackState) {
        Player.STATE_READY -> if (current.isPlaying) CameraLiveState.PLAYING else CameraLiveState.BUFFERING
        Player.STATE_BUFFERING -> if (lastState == CameraLiveState.PLAYING) CameraLiveState.BUFFERING else CameraLiveState.CONNECTING
        Player.STATE_ENDED -> CameraLiveState.IDLE
        else -> return
      }
    if (force || state != lastState) {
      send(state, null)
    }
  }

  private fun send(state: CameraLiveState, error: String?) {
    lastState = state
    if (disposed) {
      return
    }
    events.stateChanged(viewId.toLong(), state, error, hasAudio) {}
  }

  override fun dispose() {
    releasePlayer()
    disposed = true
    lifecycle?.removeObserver(lifecycleObserver)
    onDispose()
  }

  private companion object {
    /** The activity of the view, through the wrappers Flutter puts around its context */
    fun findLifecycle(context: Context): Lifecycle? {
      var current: Context? = context
      while (current != null) {
        if (current is LifecycleOwner) {
          return current.lifecycle
        }
        current = (current as? ContextWrapper)?.baseContext
      }
      return null
    }
  }
}
