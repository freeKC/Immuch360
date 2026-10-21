package app.alextran.immich.spherical

import androidx.annotation.OptIn
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.analytics.AnalyticsListener

/**
 * What the 360° player saw of the video it plays, for the report of a video that does not play (see
 * [PlaybackReport.describe]): the decoder Media3 picked and how long it took to start, the times the playback waited
 * for data once it had played, the frames the decoder dropped, and the network rate Media3 measured. A TV user cannot
 * read logcat: the report goes to the Logs page.
 */
@OptIn(UnstableApi::class)
class PlaybackStats : AnalyticsListener {
  var decoderName: String? = null
    private set
  var decoderInitMs = 0L
    private set
  var rebuffers = 0
    private set
  var droppedFrames = 0
    private set
  var bitrateEstimate = 0L
    private set
  private var played = false

  override fun onVideoDecoderInitialized(
    eventTime: AnalyticsListener.EventTime,
    decoderName: String,
    initializedTimestampMs: Long,
    initializationDurationMs: Long,
  ) {
    this.decoderName = decoderName
    decoderInitMs = initializationDurationMs
  }

  override fun onPlaybackStateChanged(eventTime: AnalyticsListener.EventTime, state: Int) {
    when (state) {
      Player.STATE_READY -> played = true
      Player.STATE_BUFFERING -> if (played) rebuffers++
    }
  }

  override fun onDroppedVideoFrames(eventTime: AnalyticsListener.EventTime, droppedFrames: Int, elapsedMs: Long) {
    this.droppedFrames += droppedFrames
  }

  override fun onBandwidthEstimate(
    eventTime: AnalyticsListener.EventTime,
    totalLoadTimeMs: Int,
    totalBytesLoaded: Long,
    bitrateEstimate: Long,
  ) {
    this.bitrateEstimate = bitrateEstimate
  }
}

/** The text of the report of a 360° video that does not play, written to the Logs page (see AppHealth.report) */
object PlaybackReport {
  /**
   * One paragraph: the video [title] and where it played from ([source]), the [error] of the player, the [video]
   * track (codec, size, bit rate), what [stats] saw, the media [bufferedMs] ahead of the position when it failed, the
   * Java heap and the buffer target ([heapBytes], [bufferTargetBytes], null for a file on the device) and the [device].
   */
  fun describe(
    title: String?,
    source: String,
    error: String,
    video: String?,
    stats: PlaybackStats?,
    bufferedMs: Long,
    heapBytes: Long,
    bufferTargetBytes: Int?,
    device: String,
  ): String {
    val decoder =
      stats?.let { seen -> seen.decoderName?.let { "$it, started in ${seen.decoderInitMs} ms" } } ?: "none started"
    val network = stats?.bitrateEstimate?.takeIf { it > 0 }?.let { "${megabits(it)} Mbit/s" } ?: "not measured"
    val buffer = bufferTargetBytes?.let { "${it shr 20} MiB" } ?: "the default of a file"
    return "The 360° player cannot play ${title ?: "a video"} from $source: $error. " +
      "Video: ${video ?: "no video track"}. Decoder: $decoder. " +
      "Waits for data after playing: ${stats?.rebuffers ?: 0}, dropped frames: ${stats?.droppedFrames ?: 0}, " +
      "network rate: $network, buffered ahead: $bufferedMs ms. " +
      "Java heap: ${heapBytes shr 20} MiB, buffer target: $buffer. Device: $device."
  }

  /** [text] with each URL in it replaced: the URLs of the media bridge hold its token */
  fun withoutUrls(text: String): String = URL.replace(text, "(a URL)")

  private val URL = Regex("""[a-zA-Z][a-zA-Z0-9+.-]*://\S+""")

  /** [bitsPerSecond] in Mbit/s with one decimal */
  fun megabits(bitsPerSecond: Long): String = String.format(java.util.Locale.ROOT, "%.1f", bitsPerSecond / 1_000_000.0)
}
