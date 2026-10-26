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

/** What the way back to the full stream said for a steady receiver at a drone key picture, for the export */
enum class RelayBackCheck(val wire: String) {
  BACK("back"),

  /** Its oldest unit was not under 50 ms for the last 30 s */
  NOT_QUIET("notQuiet"),

  /** What its path carried is under 1.5 times the drone's rate in the phase that starts */
  NO_ROOM("noRoom"),

  /** It is not on the steady stream by Automatic */
  NOT_STEADY("notSteady"),
}

/** Why the phone made a key picture of its steady stream on demand (p2/relay-bandwidth-2026-10-25.md, 7.5) */
enum class RelayKeyCause(val wire: String) {
  JOIN("join"),
  DROP("drop"),
  SWITCH("switch"),

  /** No key picture came out for 2 s (p2/noon-test-check-2026-10-26.md 3.5) */
  PERIOD("period"),
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
 *    unit under [QUIET_AGE_NS], when what its path carried (the server's [RelayHeadset.capacityBits]: its best second
 *    on the full stream, or on the steady stream in the last [BEST_WINDOW_NS]) is at least [HEADROOM] times the
 *    drone's rate in the phase the key picture starts.
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
   * A drone key unit came, after which the drone sends at about [droneRateBps]; [capacityBps] is what this receiver's
   * path carried. [RelayBackCheck.BACK] when this steady receiver goes back to the full stream at it (and Automatic
   * says full from now on), else why not.
   */
  fun backCheck(nowNs: Long, droneRateBps: Long, capacityBps: Long): RelayBackCheck {
    if (stream != RelayStream.STEADY) {
      return RelayBackCheck.NOT_STEADY
    }
    val quiet = quietSinceNs?.let { nowNs - it >= QUIET_NS } ?: false
    if (!quiet) {
      return RelayBackCheck.NOT_QUIET
    }
    if (capacityBps < HEADROOM * droneRateBps) {
      return RelayBackCheck.NO_ROOM
    }
    stream = RelayStream.FULL
    above = false
    passings.clear()
    quietSinceNs = null
    return RelayBackCheck.BACK
  }

  fun backToFullAt(nowNs: Long, droneRateBps: Long, bestSecondBps: Long): Boolean =
    backCheck(nowNs, droneRateBps, bestSecondBps) == RelayBackCheck.BACK

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
 * The drone's picture rate, from the content times of its units (p2/review-bandwidth-2026-10-25.md M5): 60 a second in
 * flight and 30 on the ground in our captures of 23 and 25 October, so it tells the phase of a flight at a key picture,
 * where the motors read on the controller's 500 ms tick may still say the phase before. It starts again at each key
 * picture (the drone's encoder restarts at the take off and at the landing), and needs [MIN_STEPS] steps. Pure.
 */
class DronePictureRate {
  companion object {
    const val KEPT = 30
    const val MIN_STEPS = 3

    /** 45 a second or more is a flight */
    const val FLYING_FROM = 45
  }

  private val steps = ArrayDeque<Long>()
  private var lastMs: Long? = null

  /** A drone unit with its content time in milliseconds (-1 when it has none) */
  fun onUnit(contentMs: Long, key: Boolean) {
    if (key) {
      steps.clear()
      lastMs = null
    }
    if (contentMs < 0) {
      return
    }
    val last = lastMs
    lastMs = contentMs
    if (last != null && contentMs - last in 1..200) {
      steps.addLast(contentMs - last)
      while (steps.size > KEPT) {
        steps.removeFirst()
      }
    }
  }

  /**
   * Pictures a second of the stream since the last key picture, null while too few units came: from the mean step,
   * the steps over 1.5 times the median left out (a picture lost on the radio)
   */
  fun perSecond(): Int? {
    if (steps.size < MIN_STEPS) {
      return null
    }
    val median = steps.sorted()[steps.size / 2]
    val usual = steps.filter { it * 2 <= median * 3 }
    return kotlin.math.round(1000.0 * usual.size / usual.sum()).toInt()
  }

  /** Whether the drone flies, from its picture rate; null while unknown */
  fun flying(): Boolean? = perSecond()?.let { it >= FLYING_FROM }

  fun reset() {
    steps.clear()
    lastMs = null
  }
}

/**
 * The drone's own rate in each phase of a flight (p2/relay-bandwidth-2026-10-25.md, 7.7): at a drone key picture (a
 * take off or a landing) the rate that follows is not measured yet, so the rate of the same phase earlier in the
 * session is taken, or the rate of 25 October (17.9 Mbit/s in flight, 4.8 on the ground). The phase is the drone's
 * picture rate ([DronePictureRate]), else whether the motors run as the phone's telemetry says; unknown, the higher of
 * the two.
 */
class DroneRateMemory {
  companion object {
    const val FLYING_BPS = 17_900_000L
    const val GROUND_BPS = 4_800_000L
    private const val KEPT = 10
  }

  private val flyingRates = ArrayDeque<Long>()
  private val groundRates = ArrayDeque<Long>()

  /** One second of the drone's stream at [bps], in flight or not ([flying] null: unknown, not kept) */
  fun onSecond(bps: Long, flying: Boolean?) {
    if (bps <= 0 || flying == null) {
      return
    }
    val list = if (flying) flyingRates else groundRates
    list.addLast(bps)
    while (list.size > KEPT) {
      list.removeFirst()
    }
  }

  /** The rate to expect in the phase [flying], in bits per second */
  fun expected(flying: Boolean?): Long = when (flying) {
    true -> median(flyingRates) ?: FLYING_BPS
    false -> median(groundRates) ?: GROUND_BPS
    null -> maxOf(median(flyingRates) ?: FLYING_BPS, median(groundRates) ?: GROUND_BPS)
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
