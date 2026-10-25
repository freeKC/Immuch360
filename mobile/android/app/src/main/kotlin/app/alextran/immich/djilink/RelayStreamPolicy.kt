package app.alextran.immich.djilink

/**
 * "Relay quality" in Advanced (p2/relay-bandwidth-2026-10-25.md, 7.7): Automatic by default, Full stream is the off
 * switch
 */
enum class RelayQuality(val wire: String) {
  AUTOMATIC("automatic"),
  FULL("full"),
  STEADY("steady"),
  ;

  companion object {
    fun of(wire: String?): RelayQuality = entries.firstOrNull { it.wire == wire } ?: AUTOMATIC
  }
}

/** What one receiver gets: the drone's own stream, or the phone's steady stream */
enum class RelayStream(val wire: String) {
  FULL("full"),
  STEADY("steady"),
}

/** Why a receiver's stream changed, for the export and the Diagnostics */
enum class RelaySwitchWhy(val wire: String) {
  /** Its oldest unit passed the first bound twice within 10 s */
  QUEUE_TWICE("queueTwice"),

  /** Its oldest unit passed the second bound once */
  QUEUE_LONG("queueLong"),

  /** Units were dropped for it */
  DROP("drop"),

  /** It needed the steady stream in an earlier flight of this relay session */
  MEMORY("memory"),

  /** The setting asks for it */
  SETTING("setting"),

  /** Back to the drone's stream at a drone key picture: quiet for 30 s, with room for the drone's rate */
  QUIET("quiet"),

  /** The steady stream stopped or cannot be had: back to the drone's stream with a primer */
  TRANSCODER("transcoder"),
}

/** Why the phone made a key picture of its steady stream on demand (p2/relay-bandwidth-2026-10-25.md, 7.5) */
enum class RelayKeyCause(val wire: String) {
  JOIN("join"),
  DROP("drop"),
  SWITCH("switch"),
}

/**
 * The stream a receiver should get, from the setting and what the phone can do (p2/relay-bandwidth-2026-10-25.md, 7.7):
 * a receiver of an earlier build ([capable] false) and a phone without a steady stream ([usable] false) always give the
 * full stream; Full stream and Steady stream force theirs; Automatic follows [automatic], the receiver's own policy.
 */
fun relayTargetStream(quality: RelayQuality, capable: Boolean, usable: Boolean, automatic: RelayStream): RelayStream =
  when {
    !capable || !usable -> RelayStream.FULL
    quality == RelayQuality.FULL -> RelayStream.FULL
    quality == RelayQuality.STEADY -> RelayStream.STEADY
    else -> automatic
  }

/**
 * Automatic, for one receiver (p2/relay-bandwidth-2026-10-25.md, 7.7). The phone decides from what it measures; the
 * receiver only tells its state.
 *
 * 1. On the full stream it goes steady when its oldest queued unit passes [twiceNs] twice within [WINDOW_NS] (each
 *    passing counted once, as the age rises past it), or passes [onceNs] once, or a drop happens. A TV: 400 and 800 ms;
 *    a headset: 200 and 400 ms.
 * 2. On the steady stream it goes back to the full stream only at a drone key picture, after [QUIET_NS] with its oldest
 *    unit under [QUIET_AGE_NS], when the best second it carried in the last [BEST_WINDOW_NS] is at least [HEADROOM]
 *    times the drone's new rate.
 *
 * Pure, with the times given; the server calls it on its tick and at each drone key unit.
 */
class RelayStreamPolicy(headset: Boolean = false) {
  companion object {
    const val TV_TWICE_NS = 400_000_000L
    const val TV_ONCE_NS = 800_000_000L
    const val HEADSET_TWICE_NS = 200_000_000L
    const val HEADSET_ONCE_NS = 400_000_000L
    const val WINDOW_NS = 10_000_000_000L
    const val QUIET_NS = 30_000_000_000L
    const val QUIET_AGE_NS = 50_000_000L
    const val BEST_WINDOW_NS = 120_000_000_000L
    const val HEADROOM = 1.5
  }

  private val twiceNs = if (headset) HEADSET_TWICE_NS else TV_TWICE_NS
  private val onceNs = if (headset) HEADSET_ONCE_NS else TV_ONCE_NS

  /** What Automatic gives this receiver now */
  var stream: RelayStream = RelayStream.FULL
    private set

  private var above = false
  private val passings = ArrayDeque<Long>()
  private var quietSinceNs: Long? = null

  /**
   * A tick of a receiver on the full stream: [oldestAgeNs] now, [dropped] when its queue dropped since the last tick.
   * Returns why it goes steady now, null when it stays.
   */
  fun onFullTick(nowNs: Long, oldestAgeNs: Long, dropped: Boolean): RelaySwitchWhy? {
    if (stream != RelayStream.FULL) {
      return null
    }
    val passed = oldestAgeNs > twiceNs && !above
    above = oldestAgeNs > twiceNs
    if (passed) {
      passings.addLast(nowNs)
    }
    while (passings.isNotEmpty() && nowNs - passings.first() > WINDOW_NS) {
      passings.removeFirst()
    }
    val why = when {
      dropped -> RelaySwitchWhy.DROP
      oldestAgeNs > onceNs -> RelaySwitchWhy.QUEUE_LONG
      passings.size >= 2 -> RelaySwitchWhy.QUEUE_TWICE
      else -> null
    }
    if (why != null) {
      goSteady()
    }
    return why
  }

  /** Automatic goes steady for another reason: the memory of an earlier flight */
  fun goSteady() {
    stream = RelayStream.STEADY
    quietSinceNs = null
    passings.clear()
    above = false
  }

  /** A tick of a receiver on the steady stream: [oldestAgeNs] now, for the quiet before going back */
  fun onSteadyTick(nowNs: Long, oldestAgeNs: Long) {
    if (oldestAgeNs < QUIET_AGE_NS) {
      if (quietSinceNs == null) {
        quietSinceNs = nowNs
      }
    } else {
      quietSinceNs = null
    }
  }

  /**
   * A drone key unit came, after which the drone sends at about [droneRateBps]; [bestSecondBps] is the best second this
   * receiver's socket carried in the last 2 minutes. True when this steady receiver goes back to the full stream at it
   * (and Automatic says full from now on).
   */
  fun backToFullAt(nowNs: Long, droneRateBps: Long, bestSecondBps: Long): Boolean {
    if (stream != RelayStream.STEADY) {
      return false
    }
    val quiet = quietSinceNs?.let { nowNs - it >= QUIET_NS } ?: false
    if (!quiet || bestSecondBps < HEADROOM * droneRateBps) {
      return false
    }
    stream = RelayStream.FULL
    above = false
    passings.clear()
    quietSinceNs = null
    return true
  }

  /**
   * The receiver is on the full stream whatever Automatic said (the steady stream stopped): it starts again from there
   */
  fun backToFull() {
    stream = RelayStream.FULL
    above = false
    passings.clear()
    quietSinceNs = null
  }
}

/**
 * The drone's own rate in each phase of a flight (p2/relay-bandwidth-2026-10-25.md, 7.7): at a drone key picture (a
 * take off or a landing) the rate that follows is not measured yet, so the rate of the same phase earlier in the
 * session is taken, or the rate of 25 October (17.9 Mbit/s in flight, 4.8 on the ground). The phase is whether the
 * motors run, as the phone's telemetry says; unknown, the higher of the two.
 */
class DroneRateMemory {
  companion object {
    const val FLYING_BPS = 17_900_000L
    const val GROUND_BPS = 4_800_000L
    private const val KEPT = 10
  }

  private val flying = ArrayDeque<Long>()
  private val ground = ArrayDeque<Long>()

  /** One second of the drone's stream at [bps], with the motors [motorsOn] (null: unknown, not kept) */
  fun onSecond(bps: Long, motorsOn: Boolean?) {
    if (bps <= 0 || motorsOn == null) {
      return
    }
    val list = if (motorsOn) flying else ground
    list.addLast(bps)
    while (list.size > KEPT) {
      list.removeFirst()
    }
  }

  /** The rate to expect in the phase [motorsOn], in bits per second */
  fun expected(motorsOn: Boolean?): Long = when (motorsOn) {
    true -> median(flying) ?: FLYING_BPS
    false -> median(ground) ?: GROUND_BPS
    null -> maxOf(median(flying) ?: FLYING_BPS, median(ground) ?: GROUND_BPS)
  }

  private fun median(values: ArrayDeque<Long>): Long? =
    values.sorted().let { if (it.isEmpty()) null else it[it.size / 2] }
}

/**
 * The receivers that needed the steady stream in a flight of this relay session (p2/relay-bandwidth-2026-10-25.md,
 * 7.7): each starts the next flight steady, and joins steady while the drone flies. Known by their name and address,
 * since a TV that reconnects is a new connection.
 */
class RelaySteadyMemory {
  private val keys = LinkedHashSet<String>()

  fun key(name: String?, address: String): String = "${name ?: ""}|$address"

  fun remember(key: String) {
    keys.add(key)
    while (keys.size > 32) {
      keys.remove(keys.first())
    }
  }

  fun knows(key: String): Boolean = key in keys

  fun clear() = keys.clear()
}
