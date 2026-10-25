package app.alextran.immich.djilink

/** Which kind of decoder is running */
enum class DecoderKind {
  HARDWARE,
  SOFTWARE,
}

/** What the pilot chose on the page; automatic is the default, the other two are for the owner test */
enum class DecoderChoice {
  AUTOMATIC,
  HARDWARE,
  SOFTWARE,
}

/** What the policy asks the decoder feed to do */
enum class PolicyAction {
  NONE,

  /** Release the codec and start the software decoder, from the next unit */
  SWITCH_TO_SOFTWARE,

  /** Release the codec and start a hardware decoder, from the unit about to be queued (a key picture) */
  SWITCH_TO_HARDWARE,

  /** Release the codec and start the decoder the policy now holds ([DecoderPolicy.current]), from the next unit */
  SWITCH_DECODER,

  /** Stop, configure and start the same codec again */
  RESTART_SAME,

  /** Release the codec and say the decoder failed */
  FAIL,
}

/**
 * Every decision of the decoder feed that does not need a decoder to be taken: from counters and a clock only, so
 * that it is unit tested. [VideoDecoderFeed] calls it and does what it says.
 *
 * The policy holds the H.265 decoders of the device in the order of [HevcDecoders.order] (hardware decoders whose name
 * ends in `.low_latency`, the other hardware decoders, the platform software decoder, the other software decoders),
 * kept to the pilot's choice: automatic takes them all, a manual choice only those of its kind. [current] is the one
 * to run.
 *
 * The stream of the 23 October 2026 capture is P pictures with one key picture in 11 s, and a decoder that joins a
 * running stream with a stream description builds the picture up over a few seconds (a concealing decoder) or shows
 * nothing until a key picture (the Qualcomm decoders of the Quest 3, which refuse every unit before one). Hence:
 *
 * 1. **Join without a key picture.** On a hardware decoder chosen automatically, once [JOIN_UNITS] units (3 s) have
 *    been queued since the start or the last flush with no output and no key picture, switch to the software decoder,
 *    once per page session.
 * 2. **Back to hardware at a key picture.** On the software decoder that rule 1 chose, the next key picture restarts
 *    the hardware decoder from that very unit. If it again gives nothing within [RETRY_UNITS] units, the software
 *    decoder stays for the session, and the hardware decoder counts as one that gave no picture (rule 6).
 * 3. **Errors.** A recoverable error restarts the same codec; a transient one is retried with the next unit; a fatal
 *    one releases the codec. [FATAL_ERRORS_ON_HARDWARE] fatal errors on hardware in a session mean software, or the
 *    next hardware decoder on a device that has no software one.
 * 4. **Backlog.** Units wait for input buffers in a queue of [MAX_QUEUED_UNITS] (0.5 s). Above that, the feed flushes
 *    the codec and the queue and goes on with the next unit. A single unit is never dropped on its own: with P
 *    pictures and rare key pictures that damages every following picture until the refresh repairs it.
 * 5. **Resolution change.** A description with another size configures the codec again.
 * 6. **No picture although a key picture came.** A decoder that was given a key picture and shows nothing within
 *    [NO_PICTURE_UNITS] units from it, or within [NO_PICTURE_NS] once at least [NO_PICTURE_MIN_UNITS] units were
 *    queued (a stall of the input does not count against it), is abandoned for the next decoder of the order that has
 *    not failed in this session. The device remembers it ([DecoderMemory], through [takeGaveNoPicture]), so that the
 *    next automatic session starts from the next decoder; a manual choice ignores the memory. When no other decoder is
 *    left the running one stays and the page says so.
 *
 * A decoder the platform refuses to configure is replaced by the next one of the order ([onCandidateRefused]).
 */
class DecoderPolicy(
  val choice: DecoderChoice = DecoderChoice.AUTOMATIC,
  candidates: List<DecoderCandidate> = GENERIC_CANDIDATES,
  /** True for a decoder that gave no picture on this device in an earlier session ([DecoderMemory.gaveNoPicture]) */
  private val gaveNoPictureBefore: (String) -> Boolean = { false },
) {
  companion object {
    /**
     * Whether the running decoder is flushed before a key unit: a relayed one ([relayed]) whose parameter sets are not
     * the ones it last took ([fed]) at a size that needs no new configuration. A switch between the drone's stream and
     * the phone's steady stream, or the drone's encoder starting again: the decoder then starts on that key picture
     * with its sets in band, with nothing of the other stream left in it (p2/owner-feedback-2026-10-25.md 2,
     * p2/review-bandwidth-2026-10-25.md M2). A size that changes configures it again instead; the units of this
     * device's own cable never flush it here, so the pilot's decoder is left as it is.
     */
    fun flushBeforeKey(relayed: Boolean, isKey: Boolean, fed: StreamDescription?, next: StreamDescription): Boolean =
      relayed && isKey && fed != null && !next.sameSetsAs(fed) && !next.needsNewConfiguration(fed)

    /** 3 s at 30 pictures per second */
    const val JOIN_UNITS = 90

    /** 1 s at 30 pictures per second */
    const val RETRY_UNITS = 30

    /** Rule 6: units from the first key picture, 1.3 s at 30 pictures per second */
    const val NO_PICTURE_UNITS = 40

    /** Rule 6: time from the first key picture */
    const val NO_PICTURE_NS = 2_000_000_000L

    /** Rule 6: the time alone decides only once this many units went in, so that a stall of the input is not blamed */
    const val NO_PICTURE_MIN_UNITS = 8

    /** 0.5 s at 30 pictures per second */
    const val MAX_QUEUED_UNITS = 15
    const val FATAL_ERRORS_ON_HARDWARE = 2
    const val FATAL_ERRORS_ON_SOFTWARE = 2

    /** One hardware and one software decoder, for a policy whose decoder names do not matter */
    val GENERIC_CANDIDATES = listOf(
      DecoderCandidate("hardware", hardware = true, lowLatencyFeature = false),
      DecoderCandidate(HevcDecoders.SOFTWARE_NAME, hardware = false, lowLatencyFeature = false),
    )
  }

  enum class SwitchReason {
    /** Rule 1: no picture and no key picture after a mid stream join */
    NO_OUTPUT_AFTER_JOIN,

    /** Rule 2 failed: the hardware decoder restarted at a key picture gave nothing again */
    HARDWARE_RETRY_FAILED,

    /** Rule 3: fatal errors on hardware */
    FATAL_ERRORS,

    /** Rule 6: no picture although a key picture came, and the next decoder took over */
    NO_PICTURE_WITH_KEY,

    /** Rule 6: no picture although a key picture came, and no other decoder is left */
    NO_PICTURE_NOTHING_LEFT,
  }

  /** The decoders this policy may run, in the order they are tried */
  val allowed: List<DecoderCandidate> = candidates.filter { it.hardware }.let { hardware ->
    val software = candidates.filter { !it.hardware }
    when {
      choice == DecoderChoice.HARDWARE && hardware.isNotEmpty() -> hardware
      choice == DecoderChoice.SOFTWARE && software.isNotEmpty() -> software
      else -> candidates
    }
  }

  private val automatic: Boolean get() = choice == DecoderChoice.AUTOMATIC

  /** The decoder to run; null when the device has none */
  var current: DecoderCandidate? = startCandidate()
    private set

  /** The decoders skipped at the start of this session because they gave no picture on this device before */
  val skippedAtStart: List<String> = current?.let { start ->
    allowed.takeWhile { it != start }.map { it.name }
  } ?: emptyList()

  /** The kind of [current] */
  val kind: DecoderKind get() = if (current?.hardware == true) DecoderKind.HARDWARE else DecoderKind.SOFTWARE

  /** Changes of decoder in this session, whatever their kind */
  var switches = 0
    private set

  /** True once the software decoder stays for the rest of the session */
  var softwareForSession = false
    private set

  /** Why the last switch happened (or why none could), for the page */
  var lastSwitchReason: SwitchReason? = null
    private set

  var flushes = 0
    private set

  private var unitsSinceStart = 0
  private var outputsSinceStart = 0
  private var keySinceStart = false
  private var firstKeyAtNs: Long? = null
  private var unitsSinceKey = 0
  private var joinRuleUsed = false
  private var onSoftwareByJoin = false
  private var retryingHardware = false
  private var hardwareBeforeJoin: DecoderCandidate? = null
  private var hardwareFatal = 0
  private var softwareFatal = 0

  /** Decoders the platform would not configure in this session */
  private val refused = mutableSetOf<String>()

  /** Decoders given up in this session: no picture although a key picture came, or fatal errors */
  private val abandoned = mutableSetOf<String>()

  /** Decoders that gave no picture with a key picture, waiting for the feed to remember them */
  private val noPictureToRemember = mutableListOf<String>()

  private fun startCandidate(): DecoderCandidate? {
    if (!automatic) {
      return allowed.firstOrNull()
    }
    return allowed.firstOrNull { !gaveNoPictureBefore(it.name) } ?: allowed.firstOrNull()
  }

  private fun usable(candidate: DecoderCandidate): Boolean =
    candidate.name !in refused && candidate.name !in abandoned

  private fun firstUsable(hardware: Boolean): DecoderCandidate? =
    allowed.firstOrNull { it.hardware == hardware && usable(it) }

  private val softwareAvailable: Boolean get() = firstUsable(hardware = false) != null

  /**
   * The decoder to try after [from]: the later ones of the order first, then the earlier ones, never one refused or
   * given up in this session. In an automatic session one that gave no picture on this device before comes only when
   * [allowRemembered] and nothing else is left.
   */
  private fun next(from: DecoderCandidate, allowRemembered: Boolean, hardwareOnly: Boolean = false): DecoderCandidate? {
    val at = allowed.indexOf(from)
    val order = (allowed.drop(at + 1) + allowed.take(maxOf(at, 0)))
      .filter { usable(it) && it != from && (!hardwareOnly || it.hardware) }
    return order.firstOrNull { !(automatic && gaveNoPictureBefore(it.name)) }
      ?: if (allowRemembered) order.firstOrNull() else null
  }

  /** A codec was started, restarted or flushed: the counts of rules 1, 2 and 6 start again */
  fun onStarted() {
    unitsSinceStart = 0
    outputsSinceStart = 0
    keySinceStart = false
    firstKeyAtNs = null
    unitsSinceKey = 0
  }

  /** Before a unit is queued: rule 2, a key picture on the software decoder of rule 1 brings the hardware back */
  fun beforeQueue(isKey: Boolean): PolicyAction {
    val hardware = hardwareBeforeJoin
    if (isKey && automatic && kind == DecoderKind.SOFTWARE && onSoftwareByJoin && !softwareForSession &&
      hardware != null && usable(hardware)
    ) {
      switchTo(hardware)
      onSoftwareByJoin = false
      retryingHardware = true
      return PolicyAction.SWITCH_TO_HARDWARE
    }
    return PolicyAction.NONE
  }

  /**
   * After a unit was queued at [nowNs]: rule 1, the end of rule 2 when the hardware stays silent, and rule 6. A key
   * unit kept from earlier and queued first to start a codec ([KeyPrimer]) counts as a key picture here.
   */
  fun afterQueue(isKey: Boolean, nowNs: Long = 0L): PolicyAction {
    unitsSinceStart += 1
    if (isKey) {
      keySinceStart = true
      if (firstKeyAtNs == null) {
        firstKeyAtNs = nowNs
      }
    }
    if (firstKeyAtNs != null) {
      unitsSinceKey += 1
    }
    if (outputsSinceStart > 0) {
      return PolicyAction.NONE
    }
    if (automatic && kind == DecoderKind.HARDWARE && softwareAvailable) {
      if (retryingHardware && unitsSinceStart >= RETRY_UNITS) {
        retryingHardware = false
        softwareForSession = true
        lastSwitchReason = SwitchReason.HARDWARE_RETRY_FAILED
        current?.let { giveUp(it) }
        switchTo(firstUsable(hardware = false))
        return PolicyAction.SWITCH_TO_SOFTWARE
      }
      if (!retryingHardware && !joinRuleUsed && unitsSinceStart >= JOIN_UNITS && !keySinceStart) {
        joinRuleUsed = true
        onSoftwareByJoin = true
        hardwareBeforeJoin = current
        lastSwitchReason = SwitchReason.NO_OUTPUT_AFTER_JOIN
        switchTo(firstUsable(hardware = false))
        return PolicyAction.SWITCH_TO_SOFTWARE
      }
    }
    return noPicture(nowNs)
  }

  /** Rule 6 */
  private fun noPicture(nowNs: Long): PolicyAction {
    val keyAt = firstKeyAtNs ?: return PolicyAction.NONE
    val running = current ?: return PolicyAction.NONE
    val due = unitsSinceKey >= NO_PICTURE_UNITS ||
      (unitsSinceKey >= NO_PICTURE_MIN_UNITS && nowNs - keyAt >= NO_PICTURE_NS)
    if (!due || running.name in abandoned) {
      return PolicyAction.NONE
    }
    giveUp(running)
    retryingHardware = false
    val following = next(running, allowRemembered = false)
    if (following == null) {
      lastSwitchReason = SwitchReason.NO_PICTURE_NOTHING_LEFT
      return PolicyAction.NONE
    }
    lastSwitchReason = SwitchReason.NO_PICTURE_WITH_KEY
    onSoftwareByJoin = false
    if (!following.hardware) {
      softwareForSession = true
    }
    switchTo(following)
    return PolicyAction.SWITCH_DECODER
  }

  private fun giveUp(candidate: DecoderCandidate) {
    abandoned += candidate.name
    noPictureToRemember += candidate.name
  }

  /** The decoders that gave no picture although a key picture came since the last call, for [DecoderMemory] */
  fun takeGaveNoPicture(): List<String> {
    val names = noPictureToRemember.toList()
    noPictureToRemember.clear()
    return names
  }

  /** A picture came out of the decoder */
  fun onOutput() {
    outputsSinceStart += 1
    if (retryingHardware) {
      // Rule 2 worked: the hardware decoder is back for good
      retryingHardware = false
    }
  }

  /** An error of the running codec: [recoverable] and [transient] as the platform reports them */
  fun onError(recoverable: Boolean, transient: Boolean): PolicyAction {
    if (transient) {
      return PolicyAction.NONE
    }
    if (recoverable) {
      return PolicyAction.RESTART_SAME
    }
    if (kind == DecoderKind.HARDWARE) {
      hardwareFatal += 1
      if (hardwareFatal < FATAL_ERRORS_ON_HARDWARE) {
        return PolicyAction.RESTART_SAME
      }
      if (softwareAvailable && choice != DecoderChoice.HARDWARE) {
        softwareForSession = true
        retryingHardware = false
        lastSwitchReason = SwitchReason.FATAL_ERRORS
        switchTo(firstUsable(hardware = false))
        return PolicyAction.SWITCH_TO_SOFTWARE
      }
      // No software decoder to go to (the Quest 3 has none): the next hardware decoder, if there is one
      val failing = current
      val following = failing?.let { next(it, allowRemembered = true, hardwareOnly = true) }
      if (failing != null && following != null) {
        abandoned += failing.name
        hardwareFatal = 0
        retryingHardware = false
        lastSwitchReason = SwitchReason.FATAL_ERRORS
        switchTo(following)
        return PolicyAction.SWITCH_DECODER
      }
      return PolicyAction.RESTART_SAME
    }
    softwareFatal += 1
    return if (softwareFatal >= FATAL_ERRORS_ON_SOFTWARE) PolicyAction.FAIL else PolicyAction.RESTART_SAME
  }

  /** Rule 4: whether this many units waiting for an input buffer means a flush */
  fun mustFlush(queued: Int): Boolean = queued > MAX_QUEUED_UNITS

  fun onFlushed() {
    flushes += 1
    onStarted()
  }

  /** Rule 5: whether a decoder configured for [current] must be configured again for [next] */
  fun mustReconfigure(current: StreamDescription?, next: StreamDescription): Boolean =
    next.needsNewConfiguration(current)

  /**
   * The platform would not configure [current]: the next decoder of the order, including one that gave no picture
   * before when nothing else is left, or FAIL when there is none. Once no hardware decoder could be made, the software
   * decoder stays for the session.
   */
  fun onCandidateRefused(): PolicyAction {
    val failed = current ?: return PolicyAction.FAIL
    refused += failed.name
    val following = next(failed, allowRemembered = true) ?: return PolicyAction.FAIL
    switchTo(following)
    if (failed.hardware && !following.hardware) {
      softwareForSession = true
      return PolicyAction.SWITCH_TO_SOFTWARE
    }
    return PolicyAction.SWITCH_DECODER
  }

  private fun switchTo(next: DecoderCandidate?) {
    if (next != null && next != current) {
      switches += 1
      current = next
    }
    onStarted()
  }
}

/**
 * The decoders that gave no picture on this device although they had a key picture (rule 6 of [DecoderPolicy]), kept
 * in the app's own preferences so that the next automatic session starts from the next decoder. An entry holds for the
 * [build] it was written under (the system build and the install of the app): a system update or a new install gives
 * every decoder its chance again, since either may change what the decoder accepts or how it is fed.
 */
class DecoderMemory(
  private val preferences: KeyValueStore,
  private val build: String,
  private val wallMs: () -> Long = { System.currentTimeMillis() },
) {
  companion object {
    const val KEY_PREFIX = "djilink.decoderNoPicture."

    /** A character neither a build fingerprint nor a number holds */
    private const val SEPARATOR = "\u001f"
  }

  fun gaveNoPicture(name: String): Boolean =
    preferences.read(KEY_PREFIX + name)?.substringBefore(SEPARATOR) == build

  fun remember(name: String) {
    preferences.write(KEY_PREFIX + name, build + SEPARATOR + wallMs())
  }

  fun forget(name: String) {
    preferences.write(KEY_PREFIX + name, null)
  }
}

/** A key unit kept to start a decoder with, and the description it was decoded with */
class KeptKey(val unit: AccessUnit, val description: StreamDescription)

/**
 * The MediaCodec documentation ("Stream Boundary and Key Frames") asks that the first unit a decoder takes after
 * start() or flush() be a key picture. The Qualcomm H.265 decoders of the Quest 3 hold to it: before a key picture they
 * refuse every unit ("Unsupported input buffer" in the log, no error to the app) and show nothing, while the remote
 * sends a key picture only when its encoder starts. A headset or a page that joins a running stream would wait for
 * the next one, which may never come. Given a key picture later, even an old one of the same parameter sets, they
 * decode every unit after it (p2/quest-2026-10-24/fix-decoder.md).
 *
 * So the feed keeps the last key unit it saw, or one kept from earlier ([DecoderSink.keepKey]: the one a phone relays
 * to a headset that joins, or the one a phone kept for its remote from an earlier session). When a codec that started
 * or was flushed on units that are not key pictures has shown nothing after [AFTER_UNITS] of them, the kept key unit
 * goes in, once, if it was decoded with the same parameter sets. A decoder that conceals (the Exynos decoder of the
 * S24+) shows a picture before that and never gets it, so it never shows an old picture; one that waits for a key
 * picture starts from the kept one, and the picture builds up from it as the refresh of the stream repairs it.
 *
 * After a gap in the stream the codec is not flushed: a decoder that conceals goes on predicting from its last
 * picture. A gap is a BREAK of a relayed stream (units the phone dropped for this device), a step of the picture
 * counter over one (a picture lost on the radio, p2/review-relay-2026-10-25.md M5), or units the safety net of the
 * queue dropped. If no picture of the unit after the gap, or of a later one, comes out within [BREAK_WAIT_NS] of units,
 * the decoder will not go on without a key picture, and the kept key unit (on a relay, the one the phone sent with the
 * BREAK) goes in once (p2/relay-smoothness-2026-10-25.md, 5.1 item 6). A picture of a unit fed before the gap does not
 * end the wait.
 *
 * [keep] and [clear] come from the threads that submit; the rest belongs to the decoder thread.
 */
class KeyPrimer(private val afterUnits: Int = AFTER_UNITS, private val breakWaitNs: Long = BREAK_WAIT_NS) {
  companion object {
    /** A quarter of a second at 30 pictures per second */
    const val AFTER_UNITS = 8

    /** After a gap, this much of the stream without a picture before the kept key unit goes in */
    const val BREAK_WAIT_NS = 250_000_000L
  }

  @Volatile
  private var kept: KeptKey? = null

  /** A codec started and has shown nothing yet */
  private var armed = false
  private var unitsSinceStart = 0
  private var keySinceStart = false

  /** The arrival of the first unit after a gap while no picture of it or after came out, null otherwise */
  private var breakAtNs: Long? = null

  /** The presentation time of the unit after the last gap: only a picture at or after it ends the wait */
  private var breakPts = Long.MIN_VALUE

  /** The picture counter of the last unit queued, null at a start */
  private var lastCounter: Int? = null

  /** Whether the last unit given by [before] was for a gap */
  var lastWasAfterBreak = false
    private set

  /** Whether a key unit is kept */
  val holds: Boolean get() = kept != null

  fun keep(unit: AccessUnit, description: StreamDescription) {
    if (unit.isKey) {
      kept = KeptKey(unit, description)
    }
  }

  /** A new source: what was kept belongs to the old one */
  fun clear() {
    kept = null
  }

  /** A codec started or was flushed */
  fun onCodecStarted() {
    armed = true
    unitsSinceStart = 0
    keySinceStart = false
    lastCounter = null
  }

  /** A unit of the stream went into the codec */
  fun onQueued(isKey: Boolean) {
    unitsSinceStart += 1
    if (isKey) {
      keySinceStart = true
      breakAtNs = null
    }
  }

  /**
   * [unit] went into the codec with [pts]; it arrived at [arrivalNs]. [gapBefore] says that units before it went (a
   * BREAK, the safety net); a step of its picture counter over one says the same of the radio. A key unit is no gap.
   */
  fun onQueuedUnit(unit: AccessUnit, arrivalNs: Long, pts: Long, gapBefore: Boolean) {
    onQueued(unit.isKey)
    val counter = unit.pictureCounter
    val previous = lastCounter
    lastCounter = counter
    if (unit.isKey) {
      return
    }
    val stepped = counter != null && previous != null && (counter - previous + 65_536) % 65_536 != 1
    if (gapBefore || stepped) {
      onGap(arrivalNs, pts)
    }
  }

  /** The unit after a gap went into the codec: it arrived at [arrivalNs] and was queued with [pts] */
  fun onGap(arrivalNs: Long, pts: Long) {
    // The wait counts from the first gap; only a picture after the last one ends it
    breakAtNs = breakAtNs ?: arrivalNs
    breakPts = pts
  }

  /** A picture of presentation time [pts] came out: the codec decodes; a picture from before a gap does not count */
  fun onOutput(pts: Long = Long.MAX_VALUE) {
    armed = false
    if (pts >= breakPts) {
      breakAtNs = null
    }
  }

  /**
   * Before [unit] goes to a codec: the kept key unit to queue first, or null when none is needed or fits. [unitNs] is
   * the arrival of the unit, which the wait after a BREAK is counted in.
   */
  fun before(unit: AccessUnit, description: StreamDescription, unitNs: Long = unit.lastArrivalNs): AccessUnit? {
    if (unit.isKey) {
      return null
    }
    val atStart = armed && !keySinceStart && unitsSinceStart >= afterUnits
    val breakAt = breakAtNs
    val afterBreak = breakAt != null && unitNs - breakAt >= breakWaitNs
    if (!atStart && !afterBreak) {
      return null
    }
    val key = kept ?: return null
    if (!key.description.sameSetsAs(description)) {
      return null
    }
    armed = false
    breakAtNs = null
    lastWasAfterBreak = !atStart
    return key.unit
  }
}

/**
 * Late output at display time. Each picture is rendered as soon as it comes out of the decoder, except inside a
 * burst: a picture that arrives less than [windowNs] after the last one shown is held, a newer one replaces it (the
 * older is released without rendering and counted), and the held one is rendered at the end of the window. So a
 * steady stream is shown with no added wait, and a burst after a stall collapses to its newest picture. There is no
 * audio clock and no reordering in this stream.
 */
class DisplayPacer(private val windowNs: Long = WINDOW_NS) {
  companion object {
    const val WINDOW_NS = 8_000_000L
  }

  sealed class Decision {
    /** Render this output now */
    object RenderNow : Decision()

    /** Hold this output and render it at [atNs]; [dropHeld] says the previously held one is released unseen */
    data class Hold(val atNs: Long, val dropHeld: Boolean) : Decision()
  }

  private var lastShownNs: Long? = null
  private var holding = false

  fun onOutput(nowNs: Long): Decision {
    val last = lastShownNs
    if (!holding && (last == null || nowNs - last >= windowNs)) {
      lastShownNs = nowNs
      return Decision.RenderNow
    }
    val dropHeld = holding
    holding = true
    return Decision.Hold(atNs = (last ?: nowNs) + windowNs, dropHeld = dropHeld)
  }

  /** The end of the window came: the held output is rendered now */
  fun onTimer(nowNs: Long): Boolean {
    if (!holding) {
      return false
    }
    holding = false
    lastShownNs = nowNs
    return true
  }

  /** A flush or a new codec: nothing is held any more */
  fun reset() {
    holding = false
    lastShownNs = null
  }
}
