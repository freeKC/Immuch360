package app.alextran.immich.djilink

/**
 * The bit rate the link of one steady receiver allows (p2/relay-bandwidth-2026-10-25.md, 7.6), decided on the relay's
 * tick (ten times a second) from what the phone measures of that receiver: the age of the oldest unit queued for it,
 * what its socket carried in the last second, its longest write of a picture that is not a key picture and its drops.
 *
 * 1. It starts at [START_BPS].
 * 2. The oldest unit older than [downAgeNs] (250 ms, a headset 150 ms): 0.8 times what the last second carried, at most
 *    every [DOWN_EVERY_NS].
 * 3. A drop: 0.7 times what the last second carried.
 * 4. Clear for [UP_AFTER_NS]: times 1.25. A tick is clear when the oldest is under [CLEAR_AGE_NS] and no write took
 *    over [CLEAR_WRITE_NS]; [UP_AFTER_NS] is clear when at least [CLEAR_SHARE] of its ticks are, so that the key
 *    picture the encoder makes every 2 s, whose write and the units behind it may take longer, does not hold the rate
 *    down for the flight (p2/review-bandwidth-2026-10-25.md M4). A tick of rule 2 or 3 starts the time again.
 * 5. Within [MIN_BPS] and [MAX_BPS]; a rule that lowers it never raises it.
 * 6. At [MIN_BPS] and still over [downAgeNs]: 15 pictures a second ([slow]), back to 30 after [SLOW_BACK_NS] under
 *    [CLEAR_AGE_NS] at [SLOW_BACK_BPS] or more.
 *
 * Replayed on the capacity the Wi-Fi had in the flights of 25 October, with a key picture of eight P pictures every
 * 2 s, one after each drop and the writes they block, this gives about 20 clean drops in 250 s and the queue under
 * 0.3 s at the end of about 90 % of the seconds; from 1.5 Mbit/s on a constant 10 Mbit/s link it reaches the link
 * within 20 s (RelayRateControlTest). Pure, with the times given.
 */
class RelayRateController(headset: Boolean = false) {
  companion object {
    const val START_BPS = 8_000_000
    const val MIN_BPS = 1_500_000
    const val MAX_BPS = 12_000_000
    const val DOWN_AGE_NS = 250_000_000L
    const val HEADSET_DOWN_AGE_NS = 150_000_000L
    const val DOWN_EVERY_NS = 500_000_000L
    const val DOWN_FACTOR = 0.8
    const val DROP_FACTOR = 0.7
    const val CLEAR_AGE_NS = 50_000_000L
    const val CLEAR_WRITE_NS = 50_000_000L
    const val UP_AFTER_NS = 2_000_000_000L
    const val CLEAR_SHARE = 0.9
    const val UP_FACTOR = 1.25
    const val SLOW_BACK_NS = 5_000_000_000L
    const val SLOW_BACK_BPS = 3_000_000

    fun clamp(bps: Double): Int = bps.coerceIn(MIN_BPS.toDouble(), MAX_BPS.toDouble()).toInt()
  }

  private val downAgeNs = if (headset) HEADSET_DOWN_AGE_NS else DOWN_AGE_NS

  /** The rate this receiver's link allows now, in bits per second */
  var allowedBps: Int = START_BPS
    private set

  /** 15 pictures a second: the floor was not enough */
  var slow: Boolean = false
    private set

  var changes: Long = 0
    private set
  var minBps: Int = START_BPS
    private set
  var maxBps: Int = START_BPS
    private set

  private var lastDownNs: Long? = null

  /** Since when the rate was neither lowered nor raised, null right after a lowering */
  private var clearSinceNs: Long? = null

  /** The ticks of the last [UP_AFTER_NS] since then: their time, and 1 when clear */
  private val recent = ArrayDeque<LongArray>()
  private var slowClearSinceNs: Long? = null

  /**
   * One tick at [nowNs]: [oldestAgeNs] of the oldest unit queued (0 when none waits), [carriedBps] written in the last
   * second, [longestWriteNs] of the writes since the last tick, [dropped] when the queue dropped since. True when the
   * allowed rate or [slow] changed.
   */
  fun onTick(nowNs: Long, oldestAgeNs: Long, carriedBps: Long, longestWriteNs: Long, dropped: Boolean): Boolean {
    val before = allowedBps
    val wasSlow = slow
    when {
      dropped -> {
        lower(DROP_FACTOR * carriedBps)
        lastDownNs = nowNs
        clearSinceNs = null
        recent.clear()
      }
      oldestAgeNs > downAgeNs -> {
        val last = lastDownNs
        if (last == null || nowNs - last >= DOWN_EVERY_NS) {
          lower(DOWN_FACTOR * carriedBps)
          lastDownNs = nowNs
        }
        clearSinceNs = null
        recent.clear()
        if (allowedBps <= MIN_BPS) {
          slow = true
        }
      }
      else -> {
        val since = clearSinceNs ?: nowNs.also {
          clearSinceNs = it
          recent.clear()
        }
        val clear = oldestAgeNs < CLEAR_AGE_NS && longestWriteNs <= CLEAR_WRITE_NS
        recent.addLast(longArrayOf(nowNs, if (clear) 1 else 0))
        while (recent.isNotEmpty() && nowNs - recent.first()[0] >= UP_AFTER_NS) {
          recent.removeFirst()
        }
        if (nowNs - since >= UP_AFTER_NS && recent.sumOf { it[1] } >= CLEAR_SHARE * recent.size) {
          allowedBps = clamp(allowedBps * UP_FACTOR)
          // The next raise is judged on the ticks after this one
          clearSinceNs = nowNs
          recent.clear()
        }
      }
    }
    if (slow && !wasSlow) {
      slowClearSinceNs = null
    } else if (slow) {
      if (oldestAgeNs < CLEAR_AGE_NS && allowedBps >= SLOW_BACK_BPS) {
        val since = slowClearSinceNs
        if (since == null) {
          slowClearSinceNs = nowNs
        } else if (nowNs - since >= SLOW_BACK_NS) {
          slow = false
          slowClearSinceNs = null
        }
      } else {
        slowClearSinceNs = null
      }
    }
    if (allowedBps != before) {
      changes += 1
      minBps = minOf(minBps, allowedBps)
      maxBps = maxOf(maxBps, allowedBps)
    }
    return allowedBps != before || slow != wasSlow
  }

  /** A rule that lowers the rate never raises it, even when the last second carried a backlog away fast */
  private fun lower(target: Double) {
    allowedBps = minOf(allowedBps, clamp(target))
  }
}

/**
 * The bit rate the phone's encoder runs at (p2/relay-bandwidth-2026-10-25.md, 7.6): the least rate the receivers on
 * the steady stream or waiting for it allow, under the thermal cap when there is one, set at most every [everyNs] (an
 * encoder takes a new rate at its next picture). With none, the rate given last is forgotten and
 * [RelayRateController.START_BPS] is given once, at once the next time: an encoder made for the next receiver starts
 * at the rate of a receiver nothing is known of, not at the one the last receiver left
 * (p2/noon-test-check-2026-10-26.md C9). Pure.
 */
class RelayEncoderRate(private val everyNs: Long = EVERY_NS) {
  companion object {
    const val EVERY_NS = 500_000_000L
  }

  /** The rate last given to the encoder, null before the first */
  var currentBps: Int? = null
    private set
  private var lastSetNs: Long? = null

  /** The rate to give the encoder now, or null when it stays as it is (unchanged, or set less than [everyNs] ago) */
  fun next(allowed: List<Int>, capBps: Int?, nowNs: Long): Int? {
    if (allowed.isEmpty()) {
      // No receiver on the steady stream: the next one's rate is given as soon as it comes
      lastSetNs = null
      val given = currentBps ?: return null
      if (given == RelayRateController.START_BPS) {
        return null
      }
      currentBps = RelayRateController.START_BPS
      return RelayRateController.START_BPS
    }
    var target = allowed.min()
    if (capBps != null) {
      target = minOf(target, capBps)
    }
    if (target == currentBps) {
      return null
    }
    val last = lastSetNs
    if (last != null && nowNs - last < everyNs) {
      return null
    }
    currentBps = target
    lastSetNs = nowNs
    return target
  }

  fun reset() {
    currentBps = null
    lastSetNs = null
  }
}

/**
 * The unsent bytes the kernel may hold for a steady receiver (TCP_NOTSENT_LOWAT, p2/relay-bandwidth-2026-10-25.md,
 * 7.6): 100 ms of its rate, at least [MIN_BYTES]. At 2 Mbit/s the fixed 256 KiB of the full stream would hide a whole
 * second in the kernel, out of reach of the drop rule and of the rate controller.
 */
object RelayLowWater {
  const val MIN_BYTES = 32 * 1024

  fun bytesFor(bps: Int): Int = maxOf(MIN_BYTES, (bps.toLong() / 8 / 10).toInt())

  /** Set again only when the bound moves by more than a quarter */
  fun shouldApply(current: Int?, next: Int): Boolean = current == null || kotlin.math.abs(next - current) * 4 > current
}
