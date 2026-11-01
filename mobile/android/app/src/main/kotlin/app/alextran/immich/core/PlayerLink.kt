package app.alextran.immich.core

import android.content.Context
import android.os.Handler
import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.upstream.BandwidthMeter
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter

/**
 * The link of one player: what it measures ([meter]), the load control that starts the video from it (see
 * [AdaptiveLoadControl]), the policy that keeps trying a link that sends nothing ([errorPolicy]), and what Flutter and
 * the texts of the players read of it ([snapshot]). One per player, made with it.
 */
@OptIn(UnstableApi::class)
class PlayerLink(context: Context, private val clock: () -> Long = { SystemClock.elapsedRealtime() }) {
  companion object {
    /**
     * A player that waits with media enough for its decoder ([StreamingLoadControl.decoderFedMs]) and asked to play
     * for this long has a decoder that gives no picture, not a slow link (the copy a Meta Quest 3 cannot decode)
     */
    const val FED_WITHOUT_PICTURE_MS = 10_000L

    /** Keys of [snapshot], read by the plugin's Dart side (link_state.dart) */
    const val KEY_WAITING = "waiting"
    const val KEY_REBUFFERING = "rebuffering"
    const val KEY_AHEAD_MS = "aheadMs"
    const val KEY_RATE = "rate"
    const val KEY_NEED = "need"
    const val KEY_SINCE_PROGRESS_MS = "sinceProgressMs"
    const val KEY_TARGET_MS = "targetMs"
    const val KEY_MINIMUM_HELD_MS = "minimumHeldMs"
    const val KEY_LOADING = "loading"
    const val KEY_RECEIVED = "receivedBytes"
    const val KEY_NETWORK = "network"
  }

  val meter = LinkMeter(clock)
  val errorPolicy = StreamLoadErrorPolicy(meter)
  private val bandwidthMeter = LinkBandwidthMeter(DefaultBandwidthMeter.getSingletonInstance(context), meter)
  private var loadControl: AdaptiveLoadControl? = null
  private var fedSince = -1L

  /** What the player waits for now, ms of media ahead; 0 while it does not wait or is not measured */
  val targetMs: Long get() = loadControl?.targetMs ?: 0L

  /** Gives [builder] the load control of this link over [buffers], and the meter of its network reads */
  fun applyTo(builder: ExoPlayer.Builder, buffers: LoadControl): ExoPlayer.Builder {
    val control = AdaptiveLoadControl(buffers, meter, clock)
    loadControl = control
    return builder.setLoadControl(control).setBandwidthMeter(bandwidthMeter)
  }

  /** A new video loads */
  fun reset() {
    meter.reset()
    fedSince = -1L
  }

  /** The time [minimumMs] is buffered in the wait under way, null while it is not */
  private fun minimumHeldMs(): Long? = loadControl?.minimumAt?.takeIf { it >= 0 }?.let { clock() - it }

  /** What Flutter gets of the link of [player], on the main thread (see the KEY_ constants) */
  fun snapshot(player: Player): Map<String, Any?> {
    val waiting = player.playbackState == Player.STATE_BUFFERING
    return mapOf(
      KEY_WAITING to waiting,
      KEY_REBUFFERING to (waiting && loadControl?.rebuffering == true),
      KEY_AHEAD_MS to player.totalBufferedDuration,
      KEY_RATE to (meter.rate() ?: -1L),
      KEY_NEED to (meter.need() ?: -1L),
      KEY_SINCE_PROGRESS_MS to (meter.sinceProgressMs() ?: -1L),
      KEY_TARGET_MS to if (waiting) targetMs else 0L,
      KEY_MINIMUM_HELD_MS to ((if (waiting) minimumHeldMs() else null) ?: -1L),
      KEY_LOADING to player.isLoading,
      KEY_RECEIVED to meter.receivedBytes,
      KEY_NETWORK to meter.isNetwork,
    )
  }

  /**
   * Whether [player] waits, asked to play, with media enough for its decoder for [FED_WITHOUT_PICTURE_MS]: its
   * decoder gives no picture. Read twice a second.
   */
  fun fedWithoutPicture(player: Player): Boolean {
    val fed =
      player.playWhenReady &&
        player.playbackState == Player.STATE_BUFFERING &&
        player.totalBufferedDuration >= StreamingLoadControl.decoderFedMs(targetMs) &&
        targetMs == 0L
    if (!fed) {
      fedSince = -1L
      return false
    }
    val now = clock()
    if (fedSince < 0) fedSince = now
    return now - fedSince >= FED_WITHOUT_PICTURE_MS
  }
}

/**
 * The bandwidth meter of a player with a [LinkMeter]: Media3 hands its transfer listener to every data source of the
 * player's media (ProgressiveMediaSource adds it to each read), so the meter hears the bytes of this player only; the
 * estimate of the app's shared meter is kept for the rest.
 */
@OptIn(UnstableApi::class)
class LinkBandwidthMeter(private val shared: DefaultBandwidthMeter, private val meter: LinkMeter) : BandwidthMeter {
  private val listener =
    object : TransferListener {
      override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
        shared.onTransferInitializing(source, dataSpec, isNetwork)
        meter.onTransferInitializing(source, dataSpec, isNetwork)
      }

      override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
        shared.onTransferStart(source, dataSpec, isNetwork)
        meter.onTransferStart(source, dataSpec, isNetwork)
      }

      override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytes: Int) {
        shared.onBytesTransferred(source, dataSpec, isNetwork, bytes)
        meter.onBytesTransferred(source, dataSpec, isNetwork, bytes)
      }

      override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
        shared.onTransferEnd(source, dataSpec, isNetwork)
        meter.onTransferEnd(source, dataSpec, isNetwork)
      }
    }

  override fun getBitrateEstimate(): Long = shared.bitrateEstimate

  override fun getTimeToFirstByteEstimateUs(): Long = shared.timeToFirstByteEstimateUs

  override fun getTransferListener(): TransferListener = listener

  override fun addEventListener(eventHandler: Handler, eventListener: BandwidthMeter.EventListener) =
    shared.addEventListener(eventHandler, eventListener)

  override fun removeEventListener(eventListener: BandwidthMeter.EventListener) =
    shared.removeEventListener(eventListener)
}
