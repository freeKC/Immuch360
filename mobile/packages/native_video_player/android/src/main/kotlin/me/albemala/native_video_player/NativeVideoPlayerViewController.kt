package me.albemala.native_video_player

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.SurfaceView
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.SubtitleView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.platform.PlatformView
import me.albemala.native_video_player.platform_interface.*

// Immuch360: the position goes to Flutter at most this often while the video plays (each one rebuilds the controls,
// and on a phone the frames, the Dart isolate and the media bridge share the main thread)
private const val POSITION_INTERVAL_MS = 100L

// Immuch360: a move of the position by more than this while the video plays is a seek, sent at once
private const val POSITION_JUMP_MS = 1000L

// Immuch360, temporary (the measure of release 48 on a Samsung S24, see lib/infrastructure/network/rate_switches.dart
// of the app): `adb shell setprop debug.immuch.position_ms 8` sends the position at every 8 ms tick again, as upstream
// did, to a player opened after it; unset, or out of 1 to 1000, keeps POSITION_INTERVAL_MS
private fun positionIntervalMs(): Long {
    val value = try {
        Class.forName("android.os.SystemProperties")
            .getMethod("get", String::class.java)
            .invoke(null, "debug.immuch.position_ms") as? String
    } catch (e: Throwable) {
        null
    }
    val ms = value?.trim()?.toLongOrNull() ?: return POSITION_INTERVAL_MS
    if (ms !in 1L..1000L) {
        return POSITION_INTERVAL_MS
    }
    Log.i("NativeVideoPlayer", "Immuch360 rate switch: the position goes every $ms ms")
    return ms
}

@OptIn(UnstableApi::class)
class NativeVideoPlayerViewController(
    messenger: BinaryMessenger,
    viewId: Int,
    context: Context,
    private val api: NativeVideoPlayerApi = NativeVideoPlayerApi(messenger, viewId),
    private val dataSourceFactory: ((Map<String, String>) -> DataSource.Factory)? = null,
) : PlatformView,
    NativeVideoPlayerApiDelegate,
    Player.Listener {

    private val player: ExoPlayer
    private val view: SurfaceView
    private val container: FrameLayout
    private val aspectRatioLayout: AspectRatioFrameLayout

    // Immuch360: the subtitles of the video, over the picture
    private val subtitleView: SubtitleView

    private val positionUpdateHandler = Handler(Looper.getMainLooper())
    private var positionUpdateRunnable: Runnable? = null
    private var lastPosition = -1L
    private var lastPositionSentAt = 0L
    private val positionInterval = positionIntervalMs()

    // Immuch360: the player as the app makes it, and what Flutter is told of its link twice a second while it loads
    private val setup: PlayerSetup? = NativeVideoPlayerPlugin.playerSetup?.invoke(context)
    private val linkHandler = Handler(Looper.getMainLooper())
    private var linkRunnable: Runnable? = null
    private var lastLink: Map<String, Any?>? = null
    private var stuckSent = false

    init {
        api.delegate = this
        player = setup?.player ?: ExoPlayer.Builder(context).build()
        player.addListener(this)
        // Immuch360: the audio language the user picked last, for every video, and no subtitles until asked for
        player.trackSelectionParameters = VideoTracks.initialParameters(
            player.trackSelectionParameters,
            NativeVideoPlayerPlugin.preferredAudioLanguage?.invoke(),
        )

        view = SurfaceView(context)
        view.setBackgroundColor(0)
        view.layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        )
        player.setVideoSurfaceView(view)

        aspectRatioLayout = AspectRatioFrameLayout(context)
        aspectRatioLayout.visibility = View.INVISIBLE
        aspectRatioLayout.layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
            Gravity.CENTER
        )
        aspectRatioLayout.addView(view)

        subtitleView = SubtitleView(context)
        subtitleView.layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        )
        // The size and style the user chose in the accessibility settings of the device
        subtitleView.setUserDefaultStyle()
        subtitleView.setUserDefaultTextSize()
        aspectRatioLayout.addView(subtitleView)

        container = FrameLayout(context)
        container.layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        )
        container.addView(aspectRatioLayout)
    }

    override fun getView(): View {
        return container
    }

    override fun dispose() {
        player.removeListener(this)
        stopPositionUpdates()
        stopLinkUpdates()
        api.dispose()
        player.release()
        setup?.release()
    }

    override fun loadVideoSource(videoSource: VideoSource) {
        val mediaItem = mediaItemOf(videoSource)
        // Immuch360: a film that resumes loads at its place, rather than at its start and then seeks there
        val start = videoSource.startPositionMs?.takeIf { it > 0 }
        setup?.onLoad()
        stuckSent = false
        lastLink = null
        when (videoSource.type) {
            VideoSourceType.Asset, VideoSourceType.File ->
                if (start != null) player.setMediaItem(mediaItem, start) else player.setMediaItem(mediaItem)
            VideoSourceType.Network -> {
                val dataSource = dataSourceFactory?.invoke(videoSource.headers)
                    ?: DefaultHttpDataSource.Factory().setDefaultRequestProperties(videoSource.headers)
                // Immuch360: a video with side files of subtitles goes through the default factory, which merges a
                // source for each file with the video's; one without keeps the progressive source it always had
                // Immuch360: an HLS playlist (a film the Plex server converts, served by the app's bridge as
                // film.m3u8) goes through the HLS source (patch 4)
                val factory: MediaSource.Factory = if (isHlsPlaylist(videoSource.path)) {
                    HlsMediaSource.Factory(dataSource)
                } else if (videoSource.subtitles.isEmpty()) {
                    ProgressiveMediaSource.Factory(dataSource)
                } else {
                    DefaultMediaSourceFactory(dataSource)
                }
                setup?.loadErrorPolicy?.let { factory.setLoadErrorHandlingPolicy(it) }
                val mediaSource = factory.createMediaSource(mediaItem)
                if (start != null) player.setMediaSource(mediaSource, start) else player.setMediaSource(mediaSource)
            }
        }
        player.prepare()
        startLinkUpdates()
    }

    /** Immuch360: whether [path] names an HLS playlist (its path, the query left out, ends with .m3u8) */
    private fun isHlsPlaylist(path: String): Boolean =
        Uri.parse(path).path?.lowercase()?.endsWith(".m3u8") == true

    /**
     * Immuch360: the media item of [videoSource], with its side files of subtitles when it has some (patch 3). They
     * carry no selection flag, so they start off like the subtitles of the file (VideoTracks.initialParameters), and
     * the id the app gave each, which Media3 keeps in the Format.id of its track behind the prefix of its period.
     */
    private fun mediaItemOf(videoSource: VideoSource): MediaItem {
        if (videoSource.subtitles.isEmpty()) {
            return MediaItem.fromUri(videoSource.path)
        }
        val subtitles = videoSource.subtitles.map { subtitle ->
            MediaItem.SubtitleConfiguration.Builder(Uri.parse(subtitle.uri))
                .setMimeType(subtitle.mimeType)
                .setLanguage(subtitle.language)
                .setLabel(subtitle.label)
                .setId(subtitle.id)
                .setSelectionFlags(0)
                .build()
        }
        return MediaItem.Builder()
            .setUri(videoSource.path)
            .setSubtitleConfigurations(subtitles)
            .build()
    }

    override fun getVideoInfo(): VideoInfo {
        val videoSize = player.videoSize
        return VideoInfo(videoSize.height.toLong(), videoSize.width.toLong(), player.duration)
    }

    override fun getPlaybackPosition(): Long {
        return player.currentPosition
    }

    override fun play() {
        player.play()
    }

    override fun pause() {
        player.pause()
    }

    override fun stop() {
        player.stop()
        stopLinkUpdates()
    }

    override fun isPlaying(): Boolean {
        return player.isPlaying
    }

    override fun seekTo(position: Int) {
        player.seekTo(position.toLong())
    }

    override fun setPlaybackSpeed(speed: Double) {
        player.setPlaybackSpeed(speed.toFloat())
    }

    override fun setVolume(volume: Double) {
        player.volume = volume.toFloat()
    }

    override fun setLoop(loop: Boolean) {
        player.repeatMode = if (loop) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF
    }

    // Immuch360: the audio and subtitle tracks, see VideoTracks
    override fun getTracks(localeTag: String?): List<Map<String, Any?>> =
        VideoTracks.describe(player.currentTracks, VideoTracks.displayLocale(localeTag))

    override fun selectTrack(type: String, group: Int, track: Int): Boolean {
        val chosen = VideoTracks.select(player, type, group, track) ?: return false
        if (type == VideoTracks.AUDIO) {
            NativeVideoPlayerPlugin.onAudioLanguageChosen?.invoke(VideoTracks.languageOf(chosen.language))
        }
        return true
    }

    override fun disableTracks(type: String) {
        VideoTracks.disable(player, type)
    }

    override fun onTracksChanged(tracks: Tracks) {
        api.onTracksChanged()
    }

    override fun onCues(cueGroup: CueGroup) {
        subtitleView.setCues(cueGroup.cues)
    }

    override fun onPlaybackStateChanged(@Player.State state: Int) {
        if (state == Player.STATE_READY) {
            api.onPlaybackReady()
            startPositionUpdates()
        }

        if (state == Player.STATE_ENDED) {
            return api.onPlaybackEnded()
        }
    }

    override fun onVideoSizeChanged(videoSize: VideoSize) {
        if (videoSize.height <= 0) return
        aspectRatioLayout.setAspectRatio(
            (videoSize.width * videoSize.pixelWidthHeightRatio) / videoSize.height
        )
        if (aspectRatioLayout.visibility != View.VISIBLE) {
            aspectRatioLayout.post { aspectRatioLayout.visibility = View.VISIBLE }
        }
    }

    override fun onPlayerError(error: PlaybackException) {
        // Immuch360: an error the app puts in its own words goes to Flutter as its token
        val token = NativeVideoPlayerPlugin.errorToken?.invoke(error, player)
        if (token != null) {
            api.onError(Error(token))
            return
        }
        if (error.cause == null) {
            api.onError(Error("Unknown playback error occurred"))
        } else {
            api.onError(error.cause as Throwable)
        }
    }

    private fun startPositionUpdates() {
        stopPositionUpdates()
        positionUpdateRunnable = object : Runnable {
            override fun run() {
                val position = player.currentPosition
                if (lastPosition != position) {
                    // Immuch360: while the video plays, the position goes to Flutter every 100 ms rather than at each
                    // 8 ms tick; a seek, a pause or a stop still goes at once
                    val now = SystemClock.uptimeMillis()
                    val jumped = lastPosition < 0 || position < lastPosition ||
                        position - lastPosition > POSITION_JUMP_MS
                    if (!player.isPlaying || jumped || now - lastPositionSentAt >= positionInterval) {
                        lastPosition = position
                        lastPositionSentAt = now
                        api.onPlaybackPositionChanged(position)
                    }
                }
                positionUpdateHandler.postDelayed(this, 8L)
            }
        }
        positionUpdateHandler.post(positionUpdateRunnable!!)
    }

    // Immuch360: the link of the player, twice a second while a video is loaded (see PlayerSetup); the same value is not
    // sent again
    private fun startLinkUpdates() {
        val current = setup ?: return
        stopLinkUpdates()
        linkRunnable = object : Runnable {
            override fun run() {
                val link = current.link()
                if (link != null && link != lastLink) {
                    lastLink = link
                    api.onLinkChanged(link)
                }
                if (!stuckSent) {
                    current.stuckError()?.let {
                        stuckSent = true
                        api.onError(Error(it))
                    }
                }
                linkHandler.postDelayed(this, 500L)
            }
        }
        linkHandler.post(linkRunnable!!)
    }

    private fun stopLinkUpdates() {
        linkRunnable?.let {
            linkHandler.removeCallbacks(it)
            linkRunnable = null
        }
    }

    private fun stopPositionUpdates() {
        positionUpdateRunnable?.let {
            positionUpdateHandler.removeCallbacks(it)
            positionUpdateRunnable = null
        }
    }
}
