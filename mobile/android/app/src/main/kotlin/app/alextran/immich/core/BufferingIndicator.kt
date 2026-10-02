package app.alextran.immich.core

import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.TextView
import androidx.annotation.OptIn
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi

/**
 * "Buffering 42%" in [view] while the Media3 player buffers: before the first frame of the video, and whenever the
 * playback stalls until enough media is loaded again. The percentage is how much of the media the player waits for
 * before it plays is loaded ahead of the position, see [StreamingLoadControl.playbackBufferMs]; it updates four times
 * a second, and the label hides as soon as the player is ready.
 *
 * [labels] are the translated labels from Flutter: [LABEL_BUFFERING], with "{percent}" for the percentage; English is
 * the fallback. [streamed] tells whether the video is read over HTTP, which waits for more media (see
 * [StreamingLoadControl.isStreamed]).
 */
@OptIn(UnstableApi::class)
class BufferingIndicator(private val view: TextView, labels: Map<String, String>, private val streamed: Boolean) {
  companion object {
    const val LABEL_BUFFERING = "buffering"
    private const val PERCENT = "{percent}"
    private const val DEFAULT_LABEL = "Buffering $PERCENT%"
    private const val UPDATE_INTERVAL_MS = 250L

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

  /** Follows [player] from now on, in place of the player followed so far */
  fun attach(player: Player) {
    detach()
    this.player = player
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
    val bufferedAheadMs = current.bufferedPosition - current.currentPosition
    val targetMs = StreamingLoadControl.playbackBufferMs(streamed, rebuffering).toLong()
    view.text = template.replace(PERCENT, percent(bufferedAheadMs, targetMs).toString())
    view.visibility = View.VISIBLE
    return true
  }
}
