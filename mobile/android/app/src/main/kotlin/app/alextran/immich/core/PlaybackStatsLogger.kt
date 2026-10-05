package app.alextran.immich.core

import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.Format
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DecoderCounters
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.analytics.AnalyticsListener.EventTime
import java.util.Locale

/**
 * Logs what the video decoders of a player do, for the codec checks on a device: the decoder Media3 picked, the
 * input format with its colour, the frames dropped as Media3 reports them (50 at a time), and the frames rendered and
 * dropped at each loop of the video and when a video renderer stops. The counters only tell whether a decoder keeps
 * up once read on a device, which a decoder list cannot say: an 8K HEVC video the list accepts may still drop frames.
 *
 * A lens player (TwoLensPlayback) has one video renderer per decoded stream, [streams], each with its own counters:
 * each gets its own summary line, prefixed with its stream, see [DecoderStats]. One logger per player.
 */
@OptIn(UnstableApi::class)
class PlaybackStatsLogger(private val tag: String, streams: List<Int> = emptyList()) : AnalyticsListener {
  private val stats = DecoderStats(streams)
  private var frameRate = Format.NO_VALUE.toFloat()

  override fun onVideoEnabled(eventTime: EventTime, decoderCounters: DecoderCounters) {
    stats.enabled(decoderCounters, eventTime.realtimeMs)
  }

  override fun onVideoDecoderInitialized(
    eventTime: EventTime,
    decoderName: String,
    initializedTimestampMs: Long,
    initializationDurationMs: Long,
  ) {
    Log.i(tag, "video decoder $decoderName initialized in $initializationDurationMs ms")
  }

  override fun onVideoInputFormatChanged(
    eventTime: EventTime,
    format: Format,
    decoderReuseEvaluation: DecoderReuseEvaluation?,
  ) {
    // The lenses of a raw video share their frame rate: the last format tells it for every summary
    frameRate = format.frameRate
    Log.i(
      tag,
      "video input ${format.sampleMimeType} ${format.codecs} ${format.width}x${format.height} " +
        "${format.frameRate} fps, ${format.colorInfo?.toLogString() ?: "no color info"}",
    )
  }

  override fun onDroppedVideoFrames(eventTime: EventTime, droppedFrames: Int, elapsedMs: Long) {
    Log.w(tag, "dropped $droppedFrames video frames in $elapsedMs ms")
  }

  override fun onPositionDiscontinuity(
    eventTime: EventTime,
    oldPosition: Player.PositionInfo,
    newPosition: Player.PositionInfo,
    reason: Int,
  ) {
    // A looping video starts over with an automatic transition: one summary per pass and per renderer
    if (reason == Player.DISCONTINUITY_REASON_AUTO_TRANSITION) {
      stats.summaries("loop", eventTime.realtimeMs, frameRate).forEach { Log.i(tag, it) }
    }
  }

  override fun onVideoDisabled(eventTime: EventTime, decoderCounters: DecoderCounters) {
    stats.disabled(decoderCounters, "stop", eventTime.realtimeMs, frameRate)?.let { Log.i(tag, it) }
  }

  companion object {
    /**
     * "video stats (loop): 998 rendered, 2 dropped (0.2%), at most 1 in a row, in 20.0 s, 49.9 fps of 50.0": the
     * frames [rendered] and [dropped] in [elapsedMs], the longest run of drops ([maxConsecutive]), and the rate
     * reached against the [frameRate] of the video ("of ?" when unknown), prefixed with the [stream] of a lens
     * renderer ("stream 1: video stats ..."). Written the same in every locale, for the logs.
     */
    fun statsLine(
      reason: String,
      rendered: Int,
      dropped: Int,
      maxConsecutive: Int,
      elapsedMs: Long,
      frameRate: Float,
      stream: Int? = null,
    ): String {
      val frames = rendered + dropped
      val droppedPercent = if (frames > 0) dropped * 100.0 / frames else 0.0
      val renderedRate = if (elapsedMs > 0) rendered * 1000.0 / elapsedMs else 0.0
      val expected = if (frameRate > 0) oneDecimal(frameRate.toDouble()) else "?"
      val prefix = if (stream != null) "stream $stream: " else ""
      return "${prefix}video stats ($reason): $rendered rendered, $dropped dropped (${oneDecimal(droppedPercent)}%), " +
        "at most $maxConsecutive in a row, in ${oneDecimal(elapsedMs / 1000.0)} s, " +
        "${oneDecimal(renderedRate)} fps of $expected"
    }

    private fun oneDecimal(value: Double): String = String.format(Locale.ROOT, "%.1f", value)
  }
}

/**
 * The frames each enabled video renderer of a player rendered and dropped since its last summary, its counters
 * ([DecoderCounters], one set per renderer and per enabling) kept apart so that two lens renderers never mix their
 * counts. Media3 hands the counters over without the renderer they belong to: the lens renderers come in the order of
 * [streams] and are enabled in that order, and a renderer enabled again alone takes back the place it left, which is
 * how a set of counters gets its stream. Without [streams] (any other player) the lines have no prefix.
 */
@OptIn(UnstableApi::class)
internal class DecoderStats(private val streams: List<Int>) {
  private class Renderer(val counters: DecoderCounters, var sinceMs: Long) {
    var renderedBefore = 0
    var droppedBefore = 0
  }

  /** The enabled renderers by place, null for the place of a renderer disabled while a later one stays enabled. */
  private val places = ArrayList<Renderer?>()

  /** A renderer was enabled at [nowMs] with [counters]: it counts from here, in the first free place. */
  fun enabled(counters: DecoderCounters, nowMs: Long) {
    if (places.any { it?.counters === counters }) return
    val renderer = Renderer(counters, nowMs)
    val free = places.indexOf(null)
    if (free >= 0) places[free] = renderer else places += renderer
  }

  /** One line per enabled renderer, then each counts from [nowMs]. */
  fun summaries(reason: String, nowMs: Long, frameRate: Float): List<String> =
    places.indices.mapNotNull { place -> places[place]?.let { summary(place, it, reason, nowMs, frameRate) } }

  /** The line of the renderer of [counters], which then leaves its place; null for counters never enabled here. */
  fun disabled(counters: DecoderCounters, reason: String, nowMs: Long, frameRate: Float): String? {
    val place = places.indexOfFirst { it?.counters === counters }
    if (place < 0) return null
    val line = summary(place, places[place]!!, reason, nowMs, frameRate)
    places[place] = null
    while (places.isNotEmpty() && places.last() == null) places.removeAt(places.lastIndex)
    return line
  }

  private fun summary(place: Int, renderer: Renderer, reason: String, nowMs: Long, frameRate: Float): String {
    val counters = renderer.counters
    // The renderer updates the counters on the playback thread: this makes them visible here
    counters.ensureUpdated()
    val line =
      PlaybackStatsLogger.statsLine(
        reason,
        counters.renderedOutputBufferCount - renderer.renderedBefore,
        counters.droppedBufferCount - renderer.droppedBefore,
        counters.maxConsecutiveDroppedBufferCount,
        nowMs - renderer.sinceMs,
        frameRate,
        if (streams.isEmpty()) null else streams.getOrElse(place) { place },
      )
    renderer.renderedBefore = counters.renderedOutputBufferCount
    renderer.droppedBefore = counters.droppedBufferCount
    renderer.sinceMs = nowMs
    return line
  }
}
