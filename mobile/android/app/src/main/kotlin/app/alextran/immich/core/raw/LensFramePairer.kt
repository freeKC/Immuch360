package app.alextran.immich.core.raw

import kotlin.math.abs
import kotlin.math.max

/**
 * Decides when the compositor draws, from the frames of the decoded streams (one per lens renderer): a stitched frame
 * needs the frame of each stream at the same presentation time, and the two decoders deliver them one after the
 * other, a few milliseconds apart, or with one stream late when a decoder is slower. Pure, so that the JVM tests run
 * it with made up timestamps; the compositor calls it on its GL thread, the renderers' metadata listeners on the
 * playback thread ([onMetadata], hence the synchronization).
 *
 * Media3 tells each renderer's listener the presentation time and release time of every frame it renders, then
 * releases the frame to its SurfaceTexture with that release time as timestamp. The compositor acquires the frame
 * (updateTexImage) and asks [onAcquired] with the texture timestamp: the release time finds the frame's metadata.
 * Frames the decoder queue replaced before the compositor got them have metadata but never arrive: they are skipped
 * (counted as replaced). A device whose texture timestamps are not the release times gets the release time pairing:
 * the texture timestamps of both streams are compared instead (logged once by the compositor, see
 * [releaseTimePairing]).
 *
 * No frame mixes two moments far apart: a stream more than [MAX_SKEW_US] ahead of the other (a seek, a loop) waits
 * for the other; a stream ahead by less draws alone after [unpairedTimeoutNs], the other texture then being at most
 * that stale.
 */
class LensFramePairer<F : Any>(
  /** The decoded streams: 0 and 1, or one of them in one lens mode. */
  private val streams: List<Int>,
  /** Frame rate to pair with until the decoded format tells its own (the JSON's, else 30). */
  fallbackFrameRate: Double = DEFAULT_FRAME_RATE,
) {
  /** What Media3 said about a frame it rendered: release time (the texture timestamp), presentation time, format. */
  data class Meta<F>(val releaseNs: Long, val ptsUs: Long, val format: F?)

  /** What the compositor should do now. */
  sealed interface Decision

  /**
   * Draw the textures as they are, at [ptsUs], presenting at [releaseNs]; [paired] is false when one stream draws
   * alone (the other texture holds an older frame).
   */
  data class Draw<F>(val ptsUs: Long, val releaseNs: Long, val format: F?, val paired: Boolean) : Decision

  /** Ask again with [onTimeout] at [deadlineNs] (System.nanoTime), or when the next frame comes when null. */
  data class Wait(val deadlineNs: Long?) : Decision

  /** Nothing to draw. */
  data object Idle : Decision

  /** Counters for the compositor's stats line. */
  data class Stats(
    val paired: Long = 0,
    val unpaired: Long = 0,
    val replaced: Long = 0,
    val maxDeltaUs: Long = 0,
  )

  private class Current<F>(val meta: Meta<F>, val acquiredAtNs: Long, var drawn: Boolean = false)

  private val queues = HashMap<Int, ArrayDeque<Meta<F>>>()
  private val lastFormat = HashMap<Int, F>()
  private val frameRate = HashMap<Int, Double>()
  private val current = HashMap<Int, Current<F>>()
  private val defaultFrameRate = if (fallbackFrameRate > 0) fallbackFrameRate else DEFAULT_FRAME_RATE

  /**
   * The texture timestamps of this device are not the release times Media3 gave: frames pair by their texture
   * timestamps. Set once, for both streams, by the first frame without its metadata.
   */
  @Volatile
  var releaseTimePairing = false
    private set

  var stats = Stats()
    private set

  init {
    require(streams.isNotEmpty() && streams.size <= 2) { "${streams.size} streams" }
    for (stream in streams) queues[stream] = ArrayDeque()
  }

  /**
   * A renderer is about to release a frame of [stream] (playback thread). [frameRate] is the stream's format rate, 0
   * or less when unknown.
   */
  @Synchronized
  fun onMetadata(stream: Int, releaseNs: Long, ptsUs: Long, format: F?, frameRate: Float = 0f) {
    val queue = queues[stream] ?: return
    if (format != null) lastFormat[stream] = format
    if (frameRate > 0) this.frameRate[stream] = frameRate.toDouble()
    queue.addLast(Meta(releaseNs, ptsUs, format))
    // A queue that never drains (texture timestamps that match nothing) keeps the newest only
    while (queue.size > MAX_QUEUE) queue.removeFirst()
  }

  /** The compositor acquired a frame of [stream] whose texture timestamp is [textureTimestampNs], at [nowNs]. */
  @Synchronized
  fun onAcquired(stream: Int, textureTimestampNs: Long, nowNs: Long): Decision {
    val queue = queues[stream] ?: return Idle
    var meta: Meta<F>? = null
    if (!releaseTimePairing) {
      // Frames released before this one never reached the texture: the queue replaced them
      while (queue.isNotEmpty() && queue.first().releaseNs < textureTimestampNs - MATCH_NS) {
        queue.removeFirst()
        stats = stats.copy(replaced = stats.replaced + 1)
      }
      val head = queue.firstOrNull()
      if (head != null && abs(head.releaseNs - textureTimestampNs) <= MATCH_NS) {
        meta = queue.removeFirst()
      } else {
        releaseTimePairing = true
      }
    }
    if (meta == null) {
      // Pairing by texture timestamps from now on: the metadata only gives the format
      queue.clear()
      meta = Meta(textureTimestampNs, textureTimestampNs / 1000, lastFormat[stream])
    }
    current[stream] = Current(meta, nowNs)
    return decide(nowNs)
  }

  /** The deadline of a [Wait] has come. */
  @Synchronized
  fun onTimeout(nowNs: Long): Decision = decide(nowNs)

  /** Half a frame of the slower stream, at least 1 ms: two frames this close are the same moment. */
  fun toleranceUs(): Long = max(MIN_TOLERANCE_US, frameDurationUs() / 2)

  /** Two frames of the slower stream, at least 50 ms: how long a frame waits for its pair before it draws alone. */
  fun unpairedTimeoutNs(): Long = max(MIN_UNPAIRED_TIMEOUT_NS, 2 * frameDurationUs() * 1000)

  private fun frameDurationUs(): Long {
    val slowest = streams.minOf { frameRate[it] ?: defaultFrameRate }
    return (1_000_000 / slowest).toLong()
  }

  private fun decide(nowNs: Long): Decision {
    if (streams.size == 1) {
      val only = current[streams[0]] ?: return Idle
      if (only.drawn) return Idle
      only.drawn = true
      stats = stats.copy(paired = stats.paired + 1)
      return Draw(only.meta.ptsUs, only.meta.releaseNs, only.meta.format, paired = true)
    }
    val a = current[streams[0]] ?: return Idle
    val b = current[streams[1]] ?: return Idle
    if (a.drawn && b.drawn) return Idle
    val delta = abs(a.meta.ptsUs - b.meta.ptsUs)
    if (delta <= toleranceUs()) {
      a.drawn = true
      b.drawn = true
      stats = stats.copy(paired = stats.paired + 1, maxDeltaUs = max(stats.maxDeltaUs, delta))
      return Draw(a.meta.ptsUs, max(a.meta.releaseNs, b.meta.releaseNs), a.meta.format ?: b.meta.format, true)
    }
    // A seek or a loop: the other stream is still at the old position, a frame mixing both would show a jump
    if (delta > MAX_SKEW_US) return Wait(null)
    val leading = if (a.meta.ptsUs > b.meta.ptsUs) a else b
    val lagging = if (leading === a) b else a
    if (leading.drawn) return Idle
    val deadline = leading.acquiredAtNs + unpairedTimeoutNs()
    if (nowNs < deadline) return Wait(deadline)
    leading.drawn = true
    lagging.drawn = true
    stats = stats.copy(unpaired = stats.unpaired + 1)
    return Draw(leading.meta.ptsUs, leading.meta.releaseNs, leading.meta.format, paired = false)
  }

  companion object {
    const val DEFAULT_FRAME_RATE = 30.0

    /** A texture timestamp within this of a release time is that frame. */
    const val MATCH_NS = 2_000_000L

    /** More apart than this, the two streams are at different positions (a seek, a loop): no frame mixes them. */
    const val MAX_SKEW_US = 1_000_000L

    const val MIN_TOLERANCE_US = 1_000L
    const val MIN_UNPAIRED_TIMEOUT_NS = 50_000_000L

    /** Metadata kept per stream: two seconds of a 30 fps stream. */
    const val MAX_QUEUE = 64
  }
}
