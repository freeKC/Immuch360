package app.alextran.immich.core

import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.TextView
import androidx.annotation.OptIn
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import java.util.Locale

/**
 * What [view] says while the Media3 player buffers: before the first frame of the video, and whenever the playback
 * stalls until enough media is loaded again. With the measured link of the player (see [PlayerLink]): "Loading: 1.2
 * Mbit/s of the 3 Mbit/s this video needs" once both are known, "The server stopped sending this video" after
 * [LinkStartRule.DEAD_AFTER_MS] without progress (it plays on by itself when the bytes come back); else "Buffering
 * 42%", how much of the media the player waits for is loaded ahead of the position. It updates four times a second,
 * and the label hides as soon as the player is ready.
 *
 * [labels] are the translated labels from Flutter (see [describe]); English is the fallback. [streamed] tells whether
 * the video is read over HTTP (see [StreamingLoadControl.isStreamed]).
 */
@OptIn(UnstableApi::class)
class BufferingIndicator(
  private val view: TextView,
  private val labels: Map<String, String>,
  private val streamed: Boolean,
  private val share: Boolean = false,
) {
  companion object {
    const val LABEL_BUFFERING = "buffering"
    const val LABEL_LOADING_RATE = "loadingRate"
    const val LABEL_DEAD_SERVER = "deadServer"
    const val LABEL_DEAD_SHARE = "deadShare"
    const val LABEL_MBPS = "playbackMbps"
    const val LABEL_KBPS = "playbackKbps"
    private const val PERCENT = "{percent}"
    private const val DEFAULT_LABEL = "Buffering $PERCENT%"
    private const val DEFAULT_LOADING_RATE = "Loading: {got} of the {need} this video needs"
    private const val DEFAULT_DEAD_SERVER = "The server stopped sending this video. It plays on as soon as the server answers"
    private const val DEFAULT_DEAD_SHARE = "The share stopped sending this video. It plays on as soon as the share answers"
    private const val UPDATE_INTERVAL_MS = 250L

    /**
     * A bit rate of [bytesPerSecond] as the details of a video write it, in the units of [labels] ("{value} Mbit/s",
     * "{value} kbit/s"): one decimal below 10 Mbit/s
     */
    fun formatRate(bytesPerSecond: Long, labels: Map<String, String>, locale: Locale = Locale.getDefault()): String {
      val bits = bytesPerSecond * 8L
      if (bits < 1_000_000L) {
        val template = labels[LABEL_KBPS]?.takeIf { it.contains("{value}") } ?: "{value} kbit/s"
        return template.replace("{value}", (bits / 1000L).toString())
      }
      val mbps = bits / 1_000_000.0
      val template = labels[LABEL_MBPS]?.takeIf { it.contains("{value}") } ?: "{value} Mbit/s"
      val value =
        if (mbps < 10) {
          // "1.2", "3" rather than "3.0"
          String.format(locale, "%.1f", mbps).let { if (it.endsWith("0")) it.dropLast(2) else it }
        } else {
          String.format(locale, "%.0f", mbps)
        }
      return template.replace("{value}", value)
    }

    /**
     * What a player that waits says, from its link: dead after [LinkStartRule.DEAD_AFTER_MS] without progress (the
     * share's words for [share], the media bridge of a network share), the rate against the need once both are known
     * ([rate] and [need] in bytes per second), else null (the percentage then)
     */
    fun describe(
      labels: Map<String, String>,
      rate: Long?,
      need: Long?,
      sinceProgressMs: Long?,
      share: Boolean,
      locale: Locale = Locale.getDefault(),
    ): String? {
      if (LinkStartRule.isDead(waiting = true, sinceProgressMs = sinceProgressMs)) {
        return if (share) {
          labels[LABEL_DEAD_SHARE] ?: DEFAULT_DEAD_SHARE
        } else {
          labels[LABEL_DEAD_SERVER] ?: DEFAULT_DEAD_SERVER
        }
      }
      if (rate == null || need == null || need <= 0) return null
      val template = labels[LABEL_LOADING_RATE]?.takeIf { it.contains("{got}") && it.contains("{need}") } ?: DEFAULT_LOADING_RATE
      return template.replace("{got}", formatRate(rate, labels, locale)).replace("{need}", formatRate(need, labels, locale))
    }

    /** Whether [url] is read through the media bridge of the app, a network share */
    fun isShare(url: String?): Boolean {
      val host = url?.let { runCatching { java.net.URI(it).host }.getOrNull() } ?: return false
      return host == "127.0.0.1" || host == "localhost"
    }

    /** The part of [targetMs] that [bufferedAheadMs] of media loaded ahead of the position fill, from 0 to 100 */
    fun percent(bufferedAheadMs: Long, targetMs: Long): Int {
      if (targetMs <= 0) {
        return 100
      }
      return (bufferedAheadMs.coerceAtLeast(0) * 100 / targetMs).coerceAtMost(100).toInt()
    }
  }

  private val template = labels[LABEL_BUFFERING]?.takeIf { it.contains(PERCENT) } ?: DEFAULT_LABEL
  private val handler = Handler(Looper.getMainLooper())
  private var player: Player? = null
  private var link: PlayerLink? = null
  private var lastState = Player.STATE_IDLE

  /**
   * Whether the player stalled while it played, rather than buffers for the first time or after a seek: it then
   * waits for more media before it plays again, like Media3 does.
   */
  private var rebuffering = false

  /** Set by a seek until the end of the batch of player events it belongs to, whatever their order */
  private var seeking = false

  private val updateRunnable = object : Runnable {
    override fun run() {
      if (update()) {
        handler.postDelayed(this, UPDATE_INTERVAL_MS)
      }
    }
  }

  private val listener = object : Player.Listener {
    override fun onPlaybackStateChanged(playbackState: Int) {
      val current = player ?: return
      when (playbackState) {
        Player.STATE_BUFFERING ->
          if (!seeking && lastState == Player.STATE_READY && current.playWhenReady) rebuffering = true
        else -> rebuffering = false
      }
      lastState = playbackState
      refresh()
    }

    override fun onPositionDiscontinuity(
      oldPosition: Player.PositionInfo,
      newPosition: Player.PositionInfo,
      reason: Int,
    ) {
      // A seek buffers like the first load
      if (reason == Player.DISCONTINUITY_REASON_SEEK) {
        rebuffering = false
        seeking = true
      }
    }

    override fun onEvents(player: Player, events: Player.Events) {
      seeking = false
    }
  }

  /** Follows [player] and its [link] from now on, in place of the player followed so far */
  fun attach(player: Player, link: PlayerLink? = null) {
    detach()
    this.player = player
    this.link = link
    lastState = player.playbackState
    rebuffering = false
    seeking = false
    player.addListener(listener)
    refresh()
  }

  /** Stops following the player and hides the label */
  fun detach() {
    player?.removeListener(listener)
    player = null
    link = null
    handler.removeCallbacks(updateRunnable)
    view.visibility = View.GONE
  }

  /** Shows the label and starts its updates while the player buffers, hides it otherwise */
  private fun refresh() {
    handler.removeCallbacks(updateRunnable)
    if (update()) {
      handler.postDelayed(updateRunnable, UPDATE_INTERVAL_MS)
    }
  }

  /** Shows the percentage while the player buffers and returns true, hides the label and returns false otherwise */
  private fun update(): Boolean {
    val current = player
    if (current == null || current.playbackState != Player.STATE_BUFFERING) {
      view.visibility = View.GONE
      return false
    }
    val link = link
    val said =
      if (streamed) link?.let { describe(labels, it.meter.rate(), it.meter.need(), it.meter.sinceProgressMs(), share) } else null
    if (said != null) {
      view.text = said
    } else {
      val bufferedAheadMs = current.bufferedPosition - current.currentPosition
      val targetMs = link?.targetMs?.takeIf { it > 0 } ?: LinkStartRule.minimumMs(rebuffering)
      view.text = template.replace(PERCENT, percent(bufferedAheadMs, targetMs).toString())
    }
    view.visibility = View.VISIBLE
    return true
  }
}
