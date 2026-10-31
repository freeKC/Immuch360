package app.alextran.immich.core

import android.os.SystemClock
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Timeline
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.TrackGroupArray
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.exoplayer.upstream.Allocator
import kotlin.math.abs

/**
 * The buffering of the native video players for a video read over the network (the media bridge of the app on
 * 127.0.0.1, which streams from a network share, or a server), so that a share that answers in bursts (SMB on a
 * Freebox Server) no longer pauses the video every few seconds. Media3 1.10 keeps loading until 50 s are buffered and
 * starts again as soon as the buffer falls under 50 s; here the loading goes on to 60 s and starts again under 50 s,
 * so that the buffer never runs low while the share stalls. When the video starts, and starts again after a stall, is
 * the measured link's (see [AdaptiveLoadControl] and [LinkStartRule]): at once when the link keeps up, longer when it
 * does not. Local files keep the defaults of Media3.
 *
 * Media3 also stops loading once the buffer holds a number of bytes, about 137 MiB for a video with sound, whatever
 * the durations above: that is less than 9 s of a 360 video at 132 Mbit/s, so a stall of the share longer than that
 * stalled the video. The buffer here may hold half of the Java heap of the app (largeHeap, 512 MiB on recent phones),
 * up to [MAX_TARGET_BUFFER_BYTES], see [targetBufferBytes]. On a TV whose heap is 128 to 256 MiB, that is less than
 * the Media3 default: the default would take the whole heap.
 *
 * A wait is never an error here: Media3's check of a buffering without progress keeps its default of 10 minutes (it
 * watches the media buffered only, which stays at 0 while the index of a long film arrives: the 30 s it had until 31
 * October 2026 ended films over slow links). A server or a link that sends nothing is told by the link instead, see
 * [LinkStartRule.isDead].
 */
object StreamingLoadControl {
  private const val TAG = "StreamingLoadControl"

  const val MIN_BUFFER_MS = 50_000
  const val MAX_BUFFER_MS = 60_000

  /** The least media before playing, at the start and after a stall: the link decides above it, see [LinkStartRule] */
  const val BUFFER_FOR_PLAYBACK_MS = LinkStartRule.START_MS.toInt()
  const val BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS = LinkStartRule.REBUFFER_MS.toInt()

  /**
   * Media buffered ahead past which a decoder that gives nothing had media enough to give a picture (the kind of a stuck
   * player, see PlaybackErrors), whatever the link waits for
   */
  const val DECODER_FED_MS = 5_000

  /** The most bytes the buffer holds, whatever the heap: 24 s of a video at 132 Mbit/s */
  const val MAX_TARGET_BUFFER_BYTES = 384 * 1024 * 1024

  /** Whether [url] is read over HTTP: the loopback media bridge, or any http(s) URL */
  fun isStreamed(url: String): Boolean {
    val scheme = url.substringBefore(':', missingDelimiterValue = "").lowercase()
    return scheme == "http" || scheme == "https"
  }

  /** The buffers of a streamed video, which [AdaptiveLoadControl] starts */
  @OptIn(UnstableApi::class)
  fun createDefault(): DefaultLoadControl {
    val maxHeap = Runtime.getRuntime().maxMemory()
    val target = targetBufferBytes(maxHeap)
    Log.i(TAG, "Java heap of ${maxHeap shr 20} MiB: the buffer holds up to ${target shr 20} MiB")
    return DefaultLoadControl.Builder()
      .setBufferDurationsMs(
        MIN_BUFFER_MS,
        MAX_BUFFER_MS,
        BUFFER_FOR_PLAYBACK_MS,
        BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS,
      )
      .setTargetBufferBytes(target)
      .build()
  }

  /**
   * The bytes the buffer of a streamed video may hold for a Java heap of [maxHeapBytes]: half of it, up to
   * [MAX_TARGET_BUFFER_BYTES]. The loading stops there even if the buffer holds less than [MIN_BUFFER_MS] of media,
   * so that a video with a high bitrate does not run the app out of memory; the playback starts then too, whatever
   * the link waits for.
   */
  fun targetBufferBytes(maxHeapBytes: Long): Int =
    (maxHeapBytes / 2).coerceIn(1L, MAX_TARGET_BUFFER_BYTES.toLong()).toInt()

  /**
   * The media a decoder had before it counts as fed (see [DECODER_FED_MS]), or more when its link waits for more
   * ([linkTargetMs], see [PlayerLink.targetMs]): a player that waits for the media its link asks has no decoder that
   * cannot keep up
   */
  fun decoderFedMs(linkTargetMs: Long): Long = maxOf(DECODER_FED_MS.toLong(), linkTargetMs)

  /**
   * Gives [builder] the streaming buffers, started by the link of [link] (see [PlayerLink]), when [url] is read over
   * HTTP, and leaves it as it is otherwise
   */
  @OptIn(UnstableApi::class)
  fun applyTo(builder: ExoPlayer.Builder, url: String, link: PlayerLink): ExoPlayer.Builder =
    if (isStreamed(url)) link.applyTo(builder, createDefault()) else builder
}

/**
 * A load control that decides when the video plays from its measured link ([meter], see [LinkStartRule]) and leaves
 * the loading to [delegate]: Media3 calls [shouldStartPlayback] every few milliseconds while the player waits, on its
 * playback thread. What it waits for is in [targetMs], for the texts of the players.
 *
 * Also plays at once:
 * - a video whose link is not measured (a file of the device): [delegate] decides, as before;
 * - a wait that begins with what [delegate] asks already buffered: the link did not run out, a decoder fell behind,
 *   the picture got a new surface, or a seek landed inside the buffer (measured on an emulator, 31 October 2026: a
 *   decoder that fell behind with 6.6 s buffered waited 30 s for the link each time, for 3 s of play);
 * - a buffer that holds all [delegate] lets it load (its bytes cap): nothing more would come;
 * - a play asked during a wait at the start, more than a second after it began: the user decides.
 */
@OptIn(UnstableApi::class)
class AdaptiveLoadControl(
  private val delegate: LoadControl,
  private val meter: LinkMeter,
  private val clock: () -> Long = { SystemClock.elapsedRealtime() },
) : LoadControl {
  companion object {
    /** A call after this long without one starts another wait */
    private const val NEW_WAIT_GAP_MS = 1_000L
  }

  private val period = Timeline.Period()

  /** What the player waits for now, ms of media ahead of the position; 0 while it does not wait */
  @Volatile
  var targetMs: Long = 0L
    private set

  /** Whether the wait under way follows a stall */
  @Volatile
  var rebuffering: Boolean = false
    private set

  /** Since when [LinkStartRule.minimumMs] is buffered in the wait under way, in [clock] time; -1 while it is not */
  @Volatile
  var minimumAt: Long = -1L
    private set

  private var lastCallAt = -1L
  private var waitStartedAt = -1L
  private var waitPositionUs = C.TIME_UNSET
  private var playAtWaitStart = false
  private var started = false
  @Volatile private var lastContinue = true

  override fun onPrepared(playerId: PlayerId) = delegate.onPrepared(playerId)

  override fun onTracksSelected(
    parameters: LoadControl.Parameters,
    trackGroups: TrackGroupArray,
    trackSelections: Array<out ExoTrackSelection?>,
  ) = delegate.onTracksSelected(parameters, trackGroups, trackSelections)

  override fun onStopped(playerId: PlayerId) {
    targetMs = 0L
    delegate.onStopped(playerId)
  }

  override fun onReleased(playerId: PlayerId) = delegate.onReleased(playerId)

  override fun getAllocator(playerId: PlayerId): Allocator = delegate.getAllocator(playerId)

  override fun getBackBufferDurationUs(playerId: PlayerId): Long = delegate.getBackBufferDurationUs(playerId)

  override fun retainBackBufferFromKeyframe(playerId: PlayerId): Boolean =
    delegate.retainBackBufferFromKeyframe(playerId)

  override fun shouldContinuePreloading(
    playerId: PlayerId,
    timeline: Timeline,
    mediaPeriodId: MediaSource.MediaPeriodId,
    bufferedDurationUs: Long,
  ): Boolean = delegate.shouldContinuePreloading(playerId, timeline, mediaPeriodId, bufferedDurationUs)

  override fun shouldContinueLoading(parameters: LoadControl.Parameters): Boolean {
    noteTimeline(parameters)
    val wanted = delegate.shouldContinueLoading(parameters)
    lastContinue = wanted
    meter.setLoadingWanted(wanted)
    return wanted
  }

  override fun shouldStartPlayback(parameters: LoadControl.Parameters): Boolean {
    noteTimeline(parameters)
    val now = clock()
    val samePosition =
      waitPositionUs != C.TIME_UNSET && abs(parameters.playbackPositionUs - waitPositionUs) < 1_000_000L
    val delegateStarts = delegate.shouldStartPlayback(parameters)
    if (lastCallAt < 0 || now - lastCallAt > NEW_WAIT_GAP_MS || parameters.rebuffering != rebuffering || !samePosition) {
      waitStartedAt = now
      waitPositionUs = parameters.playbackPositionUs
      playAtWaitStart = parameters.playWhenReady
      rebuffering = parameters.rebuffering
      minimumAt = -1L
      // Media3 asks only once its renderers are ready: a wait whose first ask finds what the delegate wants is not
      // the link's, it plays as soon as the player can
      started = delegateStarts
    }
    lastCallAt = now
    val bufferedMs = parameters.bufferedDurationUs / 1000L
    if (minimumAt < 0 && bufferedMs >= LinkStartRule.minimumMs(parameters.rebuffering)) {
      minimumAt = now
    }
    if (!meter.isNetwork) {
      targetMs = 0L
      return delegateStarts
    }
    val ratio = meter.ratio(parameters.playbackSpeed)
    if (!started) {
      targetMs = LinkStartRule.targetMs(ratio, parameters.rebuffering)
    }
    if (!delegateStarts) {
      return false
    }
    // Once a wait said play, it stays so until the player plays (a decoder that is not ready yet keeps it waiting)
    started =
      started ||
      !lastContinue ||
      (!parameters.rebuffering && parameters.playWhenReady && !playAtWaitStart && now - waitStartedAt >= NEW_WAIT_GAP_MS) ||
      LinkStartRule.shouldStart(bufferedMs, ratio, parameters.rebuffering, minimumAt.takeIf { it >= 0 }?.let { now - it })
    if (started) {
      targetMs = 0L
    }
    return started
  }

  private fun noteTimeline(parameters: LoadControl.Parameters) {
    val timeline = parameters.timeline
    var durationMs = -1L
    if (!timeline.isEmpty) {
      try {
        val durationUs = timeline.getPeriodByUid(parameters.mediaPeriodId.periodUid, period).durationUs
        if (durationUs != C.TIME_UNSET && durationUs > 0) durationMs = durationUs / 1000L
      } catch (e: RuntimeException) {
        // A period the timeline no longer holds: the next call tells
      }
    }
    val bufferedPositionMs = (parameters.playbackPositionUs + parameters.bufferedDurationUs) / 1000L
    meter.onTimeline(durationMs, bufferedPositionMs)
  }
}
