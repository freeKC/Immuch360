package app.alextran.immich.djilink

/**
 * The video payloads, kept as fragments with the time they arrived and nothing else.
 *
 * Reception, demultiplexing, assembly and rendering are four separate steps here on purpose. This class is the first
 * one: a payload on a video channel is a fragment, it is not a picture, and nothing claims it is. The counters are
 * what makes latency measurable later instead of promised now.
 *
 * Only the size and the arrival time of a fragment are kept. The bytes themselves are in the capture when the pilot
 * records one; holding the last payloads here as well would keep megabytes nobody reads.
 */
data class VideoFragment(val channel: Int, val size: Int, val arrivedMs: Long)

data class VideoChannelCounters(
  val channel: Int,
  val fragments: Long = 0,
  val bytes: Long = 0,
  val largestFragment: Int = 0,
  val firstArrivalMs: Long = 0,
  val lastArrivalMs: Long = 0,
  /**
   * Arrivals more than [VideoFragments.GAP_MS] apart, which is all a gap can honestly mean without a sequence
   * number
   */
  val gaps: Long = 0,
  val longestGapMs: Long = 0,
)

class VideoFragments(private val keepPerChannel: Int = 64) {
  companion object {
    /** Above this, two arrivals are counted as a gap. There is no sequence number on this channel to do better. */
    const val GAP_MS = 200L
  }

  private val counters = linkedMapOf<Int, VideoChannelCounters>()
  private val recent = linkedMapOf<Int, ArrayDeque<VideoFragment>>()

  fun record(channel: Int, payload: ByteArray, nowMs: Long): VideoFragment {
    val previous = counters[channel]
    val gap = if (previous == null) 0L else nowMs - previous.lastArrivalMs
    counters[channel] = VideoChannelCounters(
      channel = channel,
      fragments = (previous?.fragments ?: 0) + 1,
      bytes = (previous?.bytes ?: 0) + payload.size,
      largestFragment = maxOf(previous?.largestFragment ?: 0, payload.size),
      firstArrivalMs = previous?.firstArrivalMs ?: nowMs,
      lastArrivalMs = nowMs,
      gaps = (previous?.gaps ?: 0) + if (previous != null && gap > GAP_MS) 1 else 0,
      longestGapMs = maxOf(previous?.longestGapMs ?: 0, if (previous != null) gap else 0),
    )
    val fragment = VideoFragment(channel, payload.size, nowMs)
    val queue = recent.getOrPut(channel) { ArrayDeque() }
    queue.addLast(fragment)
    while (queue.size > keepPerChannel) {
      queue.removeFirst()
    }
    return fragment
  }

  fun channels(): List<VideoChannelCounters> = counters.values.sortedBy { it.channel }

  fun recentFragments(channel: Int): List<VideoFragment> = recent[channel]?.toList() ?: emptyList()

  fun reset() {
    counters.clear()
    recent.clear()
  }
}
