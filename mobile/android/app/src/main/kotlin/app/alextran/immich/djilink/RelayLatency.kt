package app.alextran.immich.djilink

/** What the headset shows of the way from the phone (p2/design-stage2b.md, 9.3), in milliseconds */
data class RelayLatencyNumbers(
  /** Phone receive time (the last fragment of a unit) to the record complete here: [phoneQueue] plus [network] */
  val relayDelayMedianMs: Double?,
  val relayDelayP95Ms: Double?,
  /** On the phone, the last fragment to the start of the write: in process plus the headset's queue there */
  val phoneQueueMedianMs: Double?,
  /** The start of the write to the record complete here: kernel buffers, Wi-Fi, TCP */
  val networkMedianMs: Double?,
  val networkP95Ms: Double?,
  /** Half the least round trip of the pings kept */
  val clockUncertaintyMs: Double?,
  /** The first to the last fragment of a picture, on the phone */
  val arrivalSpreadMedianMs: Double?,
  /** Units received in the last second */
  val unitsPerSecond: Double,
) {
  companion object {
    val EMPTY = RelayLatencyNumbers(null, null, null, null, null, null, null, 0.0)

    /** Relay delay plus this device's in process and decode medians: phone receive to picture here */
    fun receiveToPicture(relayDelayMs: Double?, inProcessMs: Double?, decodeMs: Double?): Double? {
      if (relayDelayMs == null || decodeMs == null) {
        return null
      }
      return relayDelayMs + (inProcessMs ?: 0.0) + decodeMs
    }

    /**
     * How long after the phone's own screen this device shows a picture: [receiveToPictureMs] minus the phone's in
     * process and decode medians, which come with its telemetry. This device's glass to glass is about the phone's plus
     * this.
     */
    fun behindPhone(receiveToPictureMs: Double?, phoneInProcessMs: Double?, phoneDecodeMs: Double?): Double? {
      if (receiveToPictureMs == null || phoneDecodeMs == null) {
        return null
      }
      return receiveToPictureMs - (phoneInProcessMs ?: 0.0) - phoneDecodeMs
    }
  }
}

/**
 * The delay a receiver shows (p2/review-relay-2026-10-25.md M1), in milliseconds: phone receive to picture shown
 * measured on the pictures shown over 10 s ([medianMs]) and over the last 2 s at most ([nowMs]); when it cannot be
 * measured yet (the clocks not aligned), an estimate without the jitter buffer, with its own wording ([estimateMs]);
 * and nothing at all while no picture was shown for [STALE_MS], since a number would then look normal while the screen
 * stands still.
 */
data class ShownDelay(val medianMs: Double?, val nowMs: Double?, val estimateMs: Double?) {
  companion object {
    /** The red line of a picture that stopped says so from this age on */
    const val STALE_MS = 500.0

    val NONE = ShownDelay(null, null, null)

    /**
     * Since the last picture: shown here for a relayed stream that is paced (render skips leave the decoder busy while
     * the screen stands still), out of the decoder otherwise
     */
    fun pictureAgoMs(receiving: Boolean, smoothing: SmoothingNumbers, lastOutputAgoMs: Long?): Long? =
      if (receiving && smoothing.paced) smoothing.lastPictureAgoMs?.toLong() else lastOutputAgoMs

    fun of(smoothing: SmoothingNumbers, relayDelayMs: Double?, inProcessMs: Double?, decodeMs: Double?): ShownDelay {
      if (smoothing.paced) {
        val ago = smoothing.lastPictureAgoMs
        if (ago == null || ago > STALE_MS) {
          return NONE
        }
      }
      val median = smoothing.phoneToShownMedianMs
      if (median != null) {
        return ShownDelay(median, smoothing.phoneToShownNowMs ?: median, null)
      }
      return ShownDelay(null, null, RelayLatencyNumbers.receiveToPicture(relayDelayMs, inProcessMs, decodeMs))
    }
  }
}

/**
 * The stamps of the units received in the last [windowNs], with their arrival here: the medians and 95th percentiles
 * are computed when asked, with the clock offset known then, so that the units received before the clocks were aligned
 * count too.
 */
class RelayLatency(private val windowNs: Long = 2_000_000_000L, private val maxSamples: Int = 512) {
  private class Sample(val arrivalNs: Long, val firstNs: Long, val lastNs: Long, val sendNs: Long)

  private val samples = ArrayDeque<Sample>()

  @Synchronized
  fun onUnit(arrivalNs: Long, header: RelayUnitHeader) {
    samples.addLast(Sample(arrivalNs, header.firstArrivalNs, header.lastArrivalNs, header.sendNs))
    trim(arrivalNs)
  }

  @Synchronized
  fun reset() = samples.clear()

  @Synchronized
  fun numbers(nowNs: Long, clock: ClockOffset): RelayLatencyNumbers {
    trim(nowNs)
    if (samples.isEmpty()) {
      return RelayLatencyNumbers.EMPTY.copy(clockUncertaintyMs = clock.uncertaintyNs?.let { it / 1e6 })
    }
    val offset = clock.offsetNs
    val spread = samples.map { it.lastNs - it.firstNs }.sorted()
    val queue = samples.map { it.sendNs - it.lastNs }.sorted()
    val network = if (offset == null) emptyList() else samples.map { it.arrivalNs + offset - it.sendNs }.sorted()
    val relay = if (offset == null) emptyList() else samples.map { it.arrivalNs + offset - it.lastNs }.sorted()
    val lastSecond = samples.count { nowNs - it.arrivalNs <= 1_000_000_000L }
    return RelayLatencyNumbers(
      relayDelayMedianMs = percentile(relay, 0.5),
      relayDelayP95Ms = percentile(relay, 0.95),
      phoneQueueMedianMs = percentile(queue, 0.5),
      networkMedianMs = percentile(network, 0.5),
      networkP95Ms = percentile(network, 0.95),
      clockUncertaintyMs = clock.uncertaintyNs?.let { it / 1e6 },
      arrivalSpreadMedianMs = percentile(spread, 0.5),
      unitsPerSecond = lastSecond.toDouble(),
    )
  }

  private fun trim(nowNs: Long) {
    while (samples.isNotEmpty() && (nowNs - samples.first().arrivalNs > windowNs || samples.size > maxSamples)) {
      samples.removeFirst()
    }
  }

  private fun percentile(sorted: List<Long>, fraction: Double): Double? {
    if (sorted.isEmpty()) {
      return null
    }
    val index = ((sorted.size - 1) * fraction).toInt().coerceIn(0, sorted.size - 1)
    return sorted[index] / 1e6
  }
}
