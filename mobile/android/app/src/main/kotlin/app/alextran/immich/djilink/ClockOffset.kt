package app.alextran.immich.djilink

/**
 * The offset of the phone's clock on the headset's, from the pings (p2/design-stage2b.md, 9.2).
 *
 * A ping leaves at headset time t0; the phone notes its receive time p1 and its send time p2 in the pong; the pong
 * arrives at headset time t3. The round trip is (t3 - t0) - (p2 - p1), and the offset of the phone's clock on the
 * headset's is ((p1 - t0) + (p2 - t3)) / 2, exact when both ways took as long. The offset kept is that of the ping with
 * the least round trip among the last [keep] (10 s at two pings a second); its uncertainty is half that round trip.
 * The drift between two device clocks stays far below a millisecond over 10 s. Until [readyAfter] pongs came back, the
 * offset is not given.
 */
class ClockOffset(private val keep: Int = 20, private val readyAfter: Int = 3) {
  private class Sample(val atNs: Long, val offsetNs: Long, val roundTripNs: Long)

  private val samples = ArrayDeque<Sample>()
  private var pongs = 0
  private var lastRoundTrip: Long? = null

  /** The round trip of the last pong, whether or not the offset is ready */
  val lastRoundTripNs: Long? @Synchronized get() = lastRoundTrip

  /** One pong: [t0] and [t3] on this device's clock, [p1] and [p2] on the phone's */
  @Synchronized
  fun onPong(t0: Long, p1: Long, p2: Long, t3: Long) {
    val roundTrip = (t3 - t0) - (p2 - p1)
    if (roundTrip < 0 || t3 < t0 || p2 < p1) {
      // Clocks that went backwards, or a pong that is not the answer to this ping: nothing to learn from it
      return
    }
    pongs += 1
    lastRoundTrip = roundTrip
    samples.addLast(Sample(t3, ((p1 - t0) + (p2 - t3)) / 2, roundTrip))
    while (samples.size > keep) {
      samples.removeFirst()
    }
  }

  @Synchronized
  fun reset() {
    samples.clear()
    pongs = 0
    lastRoundTrip = null
  }

  val ready: Boolean @Synchronized get() = pongs >= readyAfter && samples.isNotEmpty()

  private fun best(): Sample? = samples.minByOrNull { it.roundTripNs }

  /** The phone's clock minus this device's, null until [ready] */
  val offsetNs: Long? @Synchronized get() = if (ready) best()?.offsetNs else null

  /** Half the least round trip, null until [ready] */
  val uncertaintyNs: Long? @Synchronized get() = if (ready) best()?.roundTripNs?.div(2) else null

  /** A time of this device's clock on the phone's, null until [ready] */
  fun toPhone(headsetNs: Long): Long? = offsetNs?.let { headsetNs + it }
}
