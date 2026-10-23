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

  /** Stop, configure and start the same codec again */
  RESTART_SAME,

  /** Release the codec and say the decoder failed */
  FAIL,
}

/**
 * Every decision of the decoder feed that does not need a decoder to be taken: from counters and a clock only, so
 * that it is unit tested. [VideoDecoderFeed] calls it and does what it says.
 *
 * The stream of the 23 October 2026 capture is P pictures with one key picture in 11 s, and a decoder that joins a
 * running stream with a stream description builds the picture up over a few seconds (a concealing decoder) or shows
 * nothing until a key picture (some hardware decoders). Hence:
 *
 * 1. **Join without a key picture.** On a hardware decoder chosen automatically, once [JOIN_UNITS] units (3 s) have
 *    been queued since the start or the last flush with no output and no key picture, switch to the software decoder,
 *    once per page session.
 * 2. **Back to hardware at a key picture.** On the software decoder that rule 1 chose, the next key picture restarts
 *    a hardware decoder from that very unit. If it again gives nothing within [RETRY_UNITS] units, the software
 *    decoder stays for the session.
 * 3. **Errors.** A recoverable error restarts the same codec; a transient one is retried with the next unit; a fatal
 *    one releases the codec. [FATAL_ERRORS_ON_HARDWARE] fatal errors on hardware in a session mean software.
 * 4. **Backlog.** Units wait for input buffers in a queue of [MAX_QUEUED_UNITS] (0.5 s). Above that, the feed flushes
 *    the codec and the queue and goes on with the next unit. A single unit is never dropped on its own: with P
 *    pictures and rare key pictures that damages every following picture until the refresh repairs it.
 * 5. **Resolution change.** A description with another size configures the codec again.
 */
class DecoderPolicy(
  val choice: DecoderChoice = DecoderChoice.AUTOMATIC,
  private val hardwareAvailable: Boolean = true,
  private val softwareAvailable: Boolean = true,
) {
  companion object {
    /** 3 s at 30 pictures per second */
    const val JOIN_UNITS = 90

    /** 1 s at 30 pictures per second */
    const val RETRY_UNITS = 30

    /** 0.5 s at 30 pictures per second */
    const val MAX_QUEUED_UNITS = 15
    const val FATAL_ERRORS_ON_HARDWARE = 2
    const val FATAL_ERRORS_ON_SOFTWARE = 2
  }

  /** The kind to start with */
  var kind: DecoderKind = when {
    choice == DecoderChoice.SOFTWARE && softwareAvailable -> DecoderKind.SOFTWARE
    choice == DecoderChoice.HARDWARE && hardwareAvailable -> DecoderKind.HARDWARE
    hardwareAvailable -> DecoderKind.HARDWARE
    else -> DecoderKind.SOFTWARE
  }
    private set

  /** Switches between hardware and software in this session */
  var switches = 0
    private set

  /** True once the software decoder stays for the rest of the session */
  var softwareForSession = false
    private set

  /** Why the last switch to software happened, for the page */
  var lastSwitchReason: SwitchReason? = null
    private set

  var flushes = 0
    private set

  private var unitsSinceStart = 0
  private var outputsSinceStart = 0
  private var keySinceStart = false
  private var joinRuleUsed = false
  private var onSoftwareByJoin = false
  private var retryingHardware = false
  private var hardwareFatal = 0
  private var softwareFatal = 0

  enum class SwitchReason {
    /** Rule 1: no picture and no key picture after a mid stream join */
    NO_OUTPUT_AFTER_JOIN,

    /** Rule 2 failed: the hardware decoder restarted at a key picture gave nothing again */
    HARDWARE_RETRY_FAILED,

    /** Rule 3: fatal errors on hardware */
    FATAL_ERRORS,
  }

  private val automatic: Boolean get() = choice == DecoderChoice.AUTOMATIC

  /** A codec was started, restarted or flushed: the counts of rules 1 and 2 start again */
  fun onStarted() {
    unitsSinceStart = 0
    outputsSinceStart = 0
    keySinceStart = false
  }

  /** Before a unit is queued: rule 2, a key picture on the software decoder of rule 1 brings the hardware back */
  fun beforeQueue(isKey: Boolean): PolicyAction {
    if (isKey && automatic && kind == DecoderKind.SOFTWARE && onSoftwareByJoin && !softwareForSession &&
      hardwareAvailable
    ) {
      switchTo(DecoderKind.HARDWARE)
      onSoftwareByJoin = false
      retryingHardware = true
      return PolicyAction.SWITCH_TO_HARDWARE
    }
    return PolicyAction.NONE
  }

  /** After a unit was queued: rule 1, and the end of rule 2 when the hardware stays silent */
  fun afterQueue(isKey: Boolean): PolicyAction {
    unitsSinceStart += 1
    if (isKey) {
      keySinceStart = true
    }
    if (!automatic || kind != DecoderKind.HARDWARE || !softwareAvailable || outputsSinceStart > 0) {
      return PolicyAction.NONE
    }
    if (retryingHardware && unitsSinceStart >= RETRY_UNITS) {
      retryingHardware = false
      softwareForSession = true
      lastSwitchReason = SwitchReason.HARDWARE_RETRY_FAILED
      switchTo(DecoderKind.SOFTWARE)
      return PolicyAction.SWITCH_TO_SOFTWARE
    }
    if (!retryingHardware && !joinRuleUsed && unitsSinceStart >= JOIN_UNITS && !keySinceStart) {
      joinRuleUsed = true
      onSoftwareByJoin = true
      lastSwitchReason = SwitchReason.NO_OUTPUT_AFTER_JOIN
      switchTo(DecoderKind.SOFTWARE)
      return PolicyAction.SWITCH_TO_SOFTWARE
    }
    return PolicyAction.NONE
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
      if (hardwareFatal >= FATAL_ERRORS_ON_HARDWARE && softwareAvailable && choice != DecoderChoice.HARDWARE) {
        softwareForSession = true
        retryingHardware = false
        lastSwitchReason = SwitchReason.FATAL_ERRORS
        switchTo(DecoderKind.SOFTWARE)
        return PolicyAction.SWITCH_TO_SOFTWARE
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

  /** The feed could not create the kind the policy asked for: the other kind, if there is one */
  fun onKindUnavailable(): PolicyAction {
    if (kind == DecoderKind.HARDWARE && softwareAvailable && choice != DecoderChoice.HARDWARE) {
      softwareForSession = true
      switchTo(DecoderKind.SOFTWARE)
      return PolicyAction.SWITCH_TO_SOFTWARE
    }
    return PolicyAction.FAIL
  }

  private fun switchTo(next: DecoderKind) {
    if (next != kind) {
      switches += 1
    }
    kind = next
    onStarted()
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
