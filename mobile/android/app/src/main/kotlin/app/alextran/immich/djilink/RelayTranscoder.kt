package app.alextran.immich.djilink

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * The phone's steady stream as the relay server sees it (p2/relay-bandwidth-2026-10-25.md, 7.2): the server tells it
 * whether it is needed, the rate the receivers allow and the key pictures they need; it gives back its units through
 * [RelayServer.submitSteady]. A fake in the tests.
 */
interface RelaySteadySource {
  /** This phone has an encoder for the steady stream in this relay session: a receiver may be offered it */
  val available: Boolean

  /** An encoder exists and nothing stopped the steady stream: a receiver may be switched to it */
  val usable: Boolean

  /** Encoded units with their parameter sets are coming */
  val producing: Boolean

  /** Why there is no steady stream now ([TranscoderWhy] wire), null while it is usable */
  val why: String?

  /** The relay sends a source and the quality is not Full stream */
  fun setEnabled(on: Boolean, nowNs: Long)

  /** A connected receiver takes the steady stream: decoder 2 runs only then */
  fun setCapableReceivers(any: Boolean, nowNs: Long)

  /** A receiver is on the steady stream or waits for it: the encoder is made at the first need */
  fun setNeeded(needed: Boolean, nowNs: Long)

  fun requestKey(cause: RelayKeyCause, nowNs: Long)

  /** The least rate the steady receivers allow */
  fun setBitrate(bps: Int, nowNs: Long)

  /** 30, or 15 when a receiver's link needs it */
  fun setPictureRate(perSecond: Int, nowNs: Long)

  /** The server's tick, ten times a second: the watchdogs and the waiting key requests */
  fun tick(nowNs: Long)

  /** The one line of the Diagnostics, null when there is no steady stream to describe */
  fun line(nowNs: Long): RelaySteadyLine?

  /** The transcoder section of the phone's export */
  fun report(nowNs: Long): JsonObject?
}

/** The steady stream's line of the Diagnostics (dji_link_relay_steady_line) */
data class RelaySteadyLine(
  val state: String,
  val why: String?,
  val encoderName: String?,
  val width: Int?,
  val height: Int?,
  val perSecond: Int,
  val bitrateBps: Int?,
  val encodeMedianMs: Double?,
  val encodeP95Ms: Double?,
)

enum class TranscoderState(val wire: String) {
  OFF("off"),

  /** Decoder 2 waits for a drone key picture or decodes; no encoder yet */
  STANDBY("standby"),
  RUNNING("running"),

  /** No steady stream on this phone for this relay session */
  UNAVAILABLE("unavailable"),
  STOPPED("stopped"),
}

enum class TranscoderWhy(val wire: String) {
  NO_ENCODER("noEncoder"),
  REFUSED("refused"),
  NO_SECOND_DECODER("noSecondDecoder"),
  TOO_SLOW("tooSlow"),
  DECODER_TOO_SLOW("decoderTooSlow"),
  HOT("hot"),
  FAILED("failed"),
  PILOT_FIRST("pilotFirst"),
}

/** The phone's hardware H.265 encoder, found at the relay start */
data class RelayEncoderInfo(
  val name: String,
  val hardware: Boolean,
  /** It takes a constant bit rate */
  val cbr: Boolean,
)

/** How the encoder was configured, for the export */
data class RelayEncoderSetup(
  val width: Int,
  val height: Int,
  val perSecond: Int,
  /** cbr or vbr */
  val bitrateMode: String,
  /** A latency of one picture was asked and taken; null when the output format does not say */
  val latencyAccepted: Boolean?,
  /** VPS, SPS and PPS before every key picture was asked (whether the encoder did: [RelayTranscoder.report]) */
  val headersOnKeys: Boolean,
  val keyIntervalS: Int,
  /** The fallback level the configuration was taken at: 0 with every key, 3 plain */
  val level: Int,
  /** The colour keys of the encoder's output format (MediaFormat's numbers), null while it has not said them */
  val colorStandard: Int? = null,
  val colorRange: Int? = null,
  val colorTransfer: Int? = null,
)

/**
 * One phase of the pilot's decoder (p2/review-bandwidth-2026-10-25.md M3): the motors running or not, and the drone's
 * picture rate, 60 or 30 a second (0 when not known). Its decode time before decoder 2 ran is kept for each phase.
 */
data class PilotPhase(val flying: Boolean?, val perSecond: Int) {
  companion object {
    fun of(flying: Boolean?, picturesPerSecond: Double?): PilotPhase = PilotPhase(
      flying,
      when {
        picturesPerSecond == null || picturesPerSecond <= 0.0 -> 0
        picturesPerSecond >= 45.0 -> 60
        else -> 30
      },
    )
  }

  /** One picture at this rate, 60 a second when it is not known */
  val periodMs: Double get() = 1000.0 / (if (perSecond > 0) perSecond else 60)

  val wire: String
    get() = (when (flying) {
      true -> "flying"
      false -> "ground"
      null -> "unknown"
    }) + if (perSecond > 0) perSecond.toString() else ""
}

/** The Android side of the transcoder behind an interface, so that its rules run in the JVM tests with fake codecs */
interface RelayCodecs {
  /** The hardware H.265 encoder that takes surface input at 1920x1080 or 1280x720 at 30, null when there is none */
  fun findEncoder(): RelayEncoderInfo?

  /** Decoder 2 for [description] with its GL stage; null when no decoder instance could be made */
  fun openDecoder(description: StreamDescription, core: RelayTranscoder): RelayDecoderPort?

  /** The encoder at [bitrateBps], drawn into by the GL stage of [decoder]; null when it refuses every size */
  fun openEncoder(
    info: RelayEncoderInfo,
    bitrateBps: Int,
    decoder: RelayDecoderPort,
    core: RelayTranscoder,
  ): RelayEncoderPort?
}

interface RelayDecoderPort {
  val name: String

  /** Units wait: the port takes them with [RelayTranscoder.nextInput] on its own thread */
  fun wake()

  fun release()
}

interface RelayEncoderPort {
  val name: String
  val setup: RelayEncoderSetup

  /** PARAMETER_KEY_REQUEST_SYNC_FRAME */
  fun requestKey()

  /** PARAMETER_KEY_VIDEO_BITRATE */
  fun setBitrate(bps: Int)

  fun release()
}

/** One unit for decoder 2, with its presentation time */
class RelayDecoderInput(val unit: AccessUnit, val ptsUs: Long)

/**
 * The steady stream encoded on the phone (p2/relay-bandwidth-2026-10-25.md, 7.2 to 7.5 and 7.11): its rules, apart
 * from the codecs ([RelayCodecs]) so that they are tested with fakes.
 *
 * Decoder 2 takes every drone unit in order, never skipped, from the next drone key picture (a clean start), or from
 * the kept key picture when the steady stream is needed before one came (a dirty start, counted), with the content
 * time as its presentation time. It runs while the relay sends to a receiver that takes the steady stream and the
 * quality is not Full stream. Only the pictures the decimator keeps are rendered, and only while the encoder exists;
 * the encoder (and its GL stage) is made at the first need and released after 60 s without one. Each encoded output is
 * copied once into an access unit with its source's times found back by presentation time, and handed to the server.
 *
 * The pilot's picture comes first: nothing here waits on the pilot's path; the units are shared, never copied; a slow
 * decoder 2 (a unit waiting over 1 s for it once it runs), a slow encoder (encode p95 over 66 ms, plus the pictures it
 * holds when it did not take a latency of one, for 3 s: 15 a second, then stopped 5 s later), a hot phone (moderate: 15
 * a second and at most 6 Mbit/s; severe: stopped until 60 s at light or below), the pilot's decoder affected (an
 * overrun, or its decode p95 over its bound for 3 s: 1.5 times its value in the same phase before decoder 2 ran, or two
 * picture periods when there is none) and repeated codec errors stop it; the server then sends the drone's stream
 * again. A decoder 2 or an encoder that could not be made is tried again 30 s later, three times in a relay session.
 */
class RelayTranscoder(
  private val codecs: RelayCodecs,
  private val clockNs: () -> Long = { System.nanoTime() },
  /** The encoded units, to [RelayServer.submitSteady]; called on the encoder's thread, never under this lock */
  private val emit: (AccessUnit, ResolvedDescription) -> Unit = { _, _ -> },
  private val onChange: () -> Unit = {},
  /**
   * Where codecs are made: a thread of its own ("DjiRelayStart"), never the cable's reader thread that called [offer]
   * nor the relay's tick, so that making decoder 2 or the encoder (100 to 300 ms) never holds the pilot's units; the
   * tests run it in place
   */
  private val worker: (Runnable) -> Unit = defaultWorker(),
) : RelaySteadySource {
  companion object {
    private const val TAG = "DjiRelayTranscoder"
    const val START_BPS = RelayRateController.START_BPS
    const val INPUT_MAX_AGE_NS = 1_000_000_000L
    const val INPUT_MAX_UNITS = 240
    const val SLOW_ENCODE_NS = 66_000_000L
    const val SLOW_FOR_NS = 3_000_000_000L
    const val SLOW_STOP_NS = 5_000_000_000L
    const val GL_WAIT_NS = 100_000_000L
    const val RELEASE_AFTER_NS = 60_000_000_000L
    const val ERRORS_WINDOW_NS = 60_000_000_000L
    const val ERRORS_STOP = 3
    const val HOT_CAP_BPS = 6_000_000
    const val COOL_FOR_NS = 60_000_000_000L
    const val PILOT_FACTOR = 1.5
    const val PILOT_MARGIN_MS = 5.0
    const val PILOT_FOR_NS = 3_000_000_000L

    /** With no decode time of the pilot in this phase before decoder 2 ran: this many picture periods */
    const val PILOT_PERIODS = 2.0

    /** Decode times kept for each phase while decoder 2 is off: 10 s of the controller's 500 ms tick */
    const val PILOT_KEPT = 20

    /** An encoder that did not take a latency of one picture may hold this many before its output */
    const val HELD_PICTURES = 3

    /** A decoder 2 or an encoder that could not be made: tried again after this long, this many times a session */
    const val RETRY_NS = 30_000_000_000L
    const val CREATION_TRIES = 3
    const val TIMELINE_SECONDS = 7_200
    const val TIMELINE_HEADER = "second,decoded,kept,encoded,kB,bitrateKbps,encodeP95Ms,inputQueueMs,thermal"
    private const val COLUMNS = 9

    /** PowerManager.THERMAL_STATUS_LIGHT, MODERATE and SEVERE */
    const val THERMAL_LIGHT = 1
    const val THERMAL_MODERATE = 2
    const val THERMAL_SEVERE = 3

    private fun log(message: String) {
      runCatching { android.util.Log.i(TAG, message) }
    }

    private fun defaultWorker(): (Runnable) -> Unit {
      val executor = java.util.concurrent.Executors.newSingleThreadExecutor { task ->
        Thread(task, "DjiRelayStart").apply { isDaemon = true }
      }
      return { task -> executor.execute(task) }
    }
  }

  private val lock = Any()
  private var started = false
  private var startedAtNs = 0L
  private var info: RelayEncoderInfo? = null
  private var unavailable: TranscoderWhy? = null
  private var stopped: TranscoderWhy? = null
  private var stoppedAtNs: Long? = null
  private var enabled = false
  private var capable = false
  private var needed = false
  private var notNeededSinceNs: Long? = null

  // Decoder 2
  private var decoder: RelayDecoderPort? = null

  /** Decoder 2 is being made: the units that come meanwhile wait in [input] */
  private var opening = false

  /** Raised whenever the codecs are forgotten: a decoder made for an earlier generation is released at once */
  private var generation = 0
  private var makingEncoder = false
  private var decoderDescription: StreamDescription? = null
  private var decoderName: String? = null
  private var cleanStarts = 0L
  private var dirtyStarts = 0L

  /** A unit waiting for decoder 2, with the time it entered the input */
  private class Waiting(val unit: AccessUnit, val atNs: Long)

  private val input = ArrayDeque<Waiting>()

  /** When the running decoder 2 was handed over: a unit's wait counts from then at the earliest */
  private var decoderSinceNs: Long? = null
  private var inputMaxUnits = 0
  private var inputMaxNs = 0L

  /** A decoder 2 or an encoder that could not be made: when it is tried again (null: not, or no more) */
  private var retryAtNs: Long? = null
  private var creationFailures = 0
  private var creationRetries = 0
  private var lastKey: KeptKey? = null
  private val pts = MonotonicPts()
  private val ptsMap = RelayPtsMap()
  private val queuedAt = HashMap<Long, Long>()
  private val decimator = RelayDecimator(30)

  // The encoder and its stream
  private var encoder: RelayEncoderPort? = null
  private var setup: RelayEncoderSetup? = null
  private var steadyDescription: StreamDescription? = null
  private val drawnAt = HashMap<Long, Long>()
  private var counter = 0
  private var keys = RelayKeyRequests()

  /** The coded size of the steady stream's last sets: the same as the drone's, or a receiver configures again */
  private var steadyCodedWidth: Int? = null
  private var steadyCodedHeight: Int? = null
  private var keysOut = 0L
  private var bitrateBps = START_BPS
  private var askedBps = START_BPS
  private var askedPerSecond = 30
  private var bitrateChanges = 0L
  private var bitrateMin: Int? = null
  private var bitrateMax: Int? = null
  private val bitrateSeconds = ArrayList<Int>()

  // Counters
  private var unitsIn = 0L
  private var decoded = 0L
  private var kept = 0L
  private var encoded = 0L
  private var encodedBytes = 0L
  private var unitsWithoutSets = 0L
  private var setsAdded = 0L
  private var decodeTimes = DurationHistogram()
  private var encodeTimes = DurationHistogram()
  private var receiveToEncoded = DurationHistogram()
  private val recentEncodes = ArrayDeque<LongArray>()
  private var glWaits = 0L
  private var slowSinceNs: Long? = null
  private var slowAtFifteenNs: Long? = null
  private val errors = ArrayDeque<Long>()
  private val failures = ArrayDeque<Pair<Long, String>>()
  private var glErrors = 0

  // Thermal and the pilot's decoder
  private var thermalAtStart: Int? = null
  private var thermalNow: Int? = null
  private var thermalMax: Int? = null
  private var coolSinceNs: Long? = null

  /**
   * The pilot's decode p95 in each phase while decoder 2 was off, kept across relay sessions: a fact of this phone,
   * not of a session (p2/review-bandwidth-2026-10-25.md M3)
   */
  private val pilotBaselines = HashMap<PilotPhase, ArrayDeque<Double>>()
  private var pilotBefore: Double? = null
  private var pilotBoundMs: Double? = null
  private var pilotPhase: PilotPhase? = null
  private var pilotDuring = DurationHistogram(100_000L)
  private var pilotOverrunsAtStart: Long? = null
  private var pilotHighSinceNs: Long? = null

  // The battery: the current drawn before decoder 2 ran and while it runs, and the time the encoder ran
  private val batteryBefore = ArrayDeque<Long>()
  private val batteryWhile = ArrayList<Long>()
  private var encoderSinceNs: Long? = null
  private var encoderRunNs = 0L

  // Timeline
  private val timeline = IntArray(TIMELINE_SECONDS * COLUMNS)
  private var seconds = 0L
  private var nextSecondNs: Long? = null
  private var decodedAtSample = 0L
  private var keptAtSample = 0L
  private var encodedAtSample = 0L
  private var bytesAtSample = 0L

  /** Decoder 2 is running */
  val decoding: Boolean get() = synchronized(lock) { decoder != null }

  val state: TranscoderState
    get() = synchronized(lock) { stateLocked() }

  private fun stateLocked(): TranscoderState = when {
    unavailable != null -> TranscoderState.UNAVAILABLE
    stopped != null -> TranscoderState.STOPPED
    encoder != null -> TranscoderState.RUNNING
    started && enabled && capable -> TranscoderState.STANDBY
    else -> TranscoderState.OFF
  }

  /** Also while a failed creation waits to be tried again: a receiver that joins meanwhile is offered it */
  override val available: Boolean
    get() = synchronized(lock) { started && info != null && (unavailable == null || retryAtNs != null) }

  override val usable: Boolean
    get() = synchronized(lock) { started && info != null && unavailable == null && stopped == null }

  override val producing: Boolean
    get() = synchronized(lock) { encoder != null && steadyDescription != null && stopped == null }

  override val why: String?
    get() = synchronized(lock) {
      when {
        !started -> null
        else -> (unavailable ?: stopped)?.wire
      }
    }

  // The relay's life

  /**
   * The relay starts: the encoder is looked for once, and what the last session counted starts again (the pilot's
   * decode times of each phase stay: they describe this phone)
   */
  fun start(nowNs: Long = clockNs()) {
    val found = runCatching { codecs.findEncoder() }.getOrNull()
    synchronized(lock) {
      started = true
      startedAtNs = nowNs
      info = found
      unavailable = if (found == null) TranscoderWhy.NO_ENCODER else null
      stopped = null
      stoppedAtNs = null
      nextSecondNs = nowNs + 1_000_000_000L
      resetSessionLocked()
    }
    log(if (found == null) "no hardware H.265 encoder: no steady stream" else "encoder ${found.name}, cbr ${found.cbr}")
    onChange()
  }

  /** The relay stops: every codec goes */
  fun stop() {
    val (dec, enc) = synchronized(lock) {
      started = false
      enabled = false
      needed = false
      val pair = decoder to encoder
      clearCodecsLocked()
      pair
    }
    enc?.let { runCatching { it.release() } }
    dec?.let { runCatching { it.release() } }
    onChange()
  }

  override fun setEnabled(on: Boolean, nowNs: Long) = applyRun { enabled = on }

  override fun setCapableReceivers(any: Boolean, nowNs: Long) = applyRun { capable = any }

  override fun setNeeded(needed: Boolean, nowNs: Long) {
    applyRun {
      if (needed && !this.needed) {
        notNeededSinceNs = null
      } else if (!needed && this.needed) {
        notNeededSinceNs = nowNs
      }
      this.needed = needed
    }
    // Asked on every tick while needed: a task only when there is something to make
    val make = needed && synchronized(lock) { runsLocked() && encoder == null && !makingEncoder && !opening }
    if (make) {
      worker(Runnable { ensureEncoder(nowNs) })
    }
  }

  /** A change of [enabled], [capable] or [needed]: decoder 2 and the encoder go when they may no longer run */
  private inline fun applyRun(change: () -> Unit) {
    val released = synchronized(lock) {
      change()
      if (!started || !enabled || !capable) {
        val pair = decoder to encoder
        clearCodecsLocked()
        pair
      } else {
        null
      }
    }
    released?.second?.let { runCatching { it.release() } }
    released?.first?.let { runCatching { it.release() } }
  }

  /** Under [lock], at [start]: the counters, the failures, the timeline and the rates of the last session go */
  private fun resetSessionLocked() {
    retryAtNs = null
    creationFailures = 0
    creationRetries = 0
    cleanStarts = 0
    dirtyStarts = 0
    inputMaxUnits = 0
    inputMaxNs = 0
    counter = 0
    keys = RelayKeyRequests()
    keysOut = 0
    bitrateBps = START_BPS
    askedBps = START_BPS
    askedPerSecond = 30
    bitrateChanges = 0
    bitrateMin = null
    bitrateMax = null
    bitrateSeconds.clear()
    unitsIn = 0
    decoded = 0
    kept = 0
    encoded = 0
    encodedBytes = 0
    unitsWithoutSets = 0
    setsAdded = 0
    decodeTimes = DurationHistogram()
    encodeTimes = DurationHistogram()
    receiveToEncoded = DurationHistogram()
    recentEncodes.clear()
    glWaits = 0
    slowSinceNs = null
    slowAtFifteenNs = null
    errors.clear()
    failures.clear()
    glErrors = 0
    thermalAtStart = null
    thermalMax = thermalNow
    coolSinceNs = null
    pilotBefore = null
    pilotBoundMs = null
    pilotPhase = null
    pilotDuring = DurationHistogram(100_000L)
    pilotOverrunsAtStart = null
    pilotHighSinceNs = null
    batteryBefore.clear()
    batteryWhile.clear()
    encoderSinceNs = null
    encoderRunNs = 0
    timeline.fill(0)
    seconds = 0
    decodedAtSample = 0
    keptAtSample = 0
    encodedAtSample = 0
    bytesAtSample = 0
    setup = null
    decoderName = null
    steadyCodedWidth = null
    steadyCodedHeight = null
  }

  /** Under [lock]: decoder 2 and the encoder forgotten (the caller releases them outside the lock) */
  private fun clearCodecsLocked() {
    decoder = null
    decoderSinceNs = null
    encoder = null
    decoderDescription = null
    steadyDescription = null
    opening = false
    makingEncoder = false
    generation += 1
    input.clear()
    queuedAt.clear()
    drawnAt.clear()
    ptsMap.clear()
    decimator.reset()
  }

  // From the router: the drone's units, on the reader thread of the cable; returns at once

  fun offer(unit: AccessUnit, description: ResolvedDescription) {
    var open: StreamDescription? = null
    var stop: TranscoderWhy? = null
    var wake: RelayDecoderPort? = null
    var made = 0
    var old: Pair<RelayDecoderPort?, RelayEncoderPort?>? = null
    val nowNs = clockNs()
    synchronized(lock) {
      if (unit.isKey) {
        lastKey = KeptKey(unit, description.description)
      }
      if (!runsLocked()) {
        return
      }
      unitsIn += 1
      val running = decoder
      when {
        running == null && !opening -> if (unit.isKey) {
          // A clean start
          open = description.description
          opening = true
          input.clear()
          input.addLast(Waiting(unit, nowNs))
          cleanStarts += 1
        }
        running != null && unit.isKey && !description.description.sameSetsAs(decoderDescription) -> {
          // New parameter sets at an encoder restart of the drone: decoder 2 is made again at this key, and the units
          // after it wait for the new one, never the old
          old = running to encoder
          decoder = null
          decoderSinceNs = null
          decoderDescription = null
          encoder = null
          steadyDescription = null
          drawnAt.clear()
          open = description.description
          opening = true
          input.clear()
          input.addLast(Waiting(unit, nowNs))
          cleanStarts += 1
        }
        else -> {
          input.addLast(Waiting(unit, nowNs))
          wake = running
        }
      }
      stop = checkInputLocked(nowNs)
      made = generation
    }
    old?.let { (oldDecoder, oldEncoder) ->
      oldEncoder?.let { runCatching { it.release() } }
      oldDecoder?.let { runCatching { it.release() } }
    }
    if (stop != null) {
      stopFor(stop!!, nowNs, "input ${inputAgeMs(nowNs)} ms")
      return
    }
    open?.let { description -> worker(Runnable { openDecoder(description, nowNs, made) }) }
    wake?.wake()
  }

  /** A key unit kept from earlier (the remote's previous session): a dirty start may begin from it */
  fun keepKey(unit: AccessUnit, description: ResolvedDescription) {
    if (!unit.isKey) {
      return
    }
    synchronized(lock) {
      if (lastKey == null) {
        lastKey = KeptKey(unit, description.description)
      }
    }
  }

  /**
   * A new source: decoder 2 and the encoder go, and start again from the next key picture of the new one while the
   * steady stream is needed
   */
  fun reset() {
    val (dec, enc) = synchronized(lock) {
      lastKey = null
      val pair = decoder to encoder
      clearCodecsLocked()
      pair
    }
    enc?.let { runCatching { it.release() } }
    dec?.let { runCatching { it.release() } }
    onChange()
  }

  private fun runsLocked(): Boolean = started && enabled && capable && info != null && unavailable == null &&
    stopped == null

  /**
   * Under [lock]: decoder 2 or the encoder could not be made. No steady stream for 30 s, then it is tried again; after
   * [CREATION_TRIES] failures in a relay session, none until the next one (p2/review-bandwidth-2026-10-25.md m5)
   */
  private fun failCreationLocked(why: TranscoderWhy, nowNs: Long, what: String) {
    creationFailures += 1
    failures.addLast(nowNs to what)
    trimFailures()
    unavailable = why
    retryAtNs = if (creationFailures < CREATION_TRIES) nowNs + RETRY_NS else null
  }

  /**
   * Under [lock]: how long the oldest unit waited for a running decoder 2, from the time it entered the input or the
   * time decoder 2 started, whichever is later (p2/review-bandwidth-2026-10-25.md B1). The kept key unit of a dirty
   * start, received tens of seconds before, entered just now; while decoder 2 is being made only the count is bounded.
   */
  private fun inputAgeLocked(nowNs: Long): Long {
    val first = input.firstOrNull() ?: return 0
    val since = decoderSinceNs
    if (decoder == null || since == null) {
      return 0
    }
    return (nowNs - maxOf(first.atNs, since)).coerceAtLeast(0)
  }

  private fun checkInputLocked(nowNs: Long): TranscoderWhy? {
    if (input.isEmpty()) {
      return null
    }
    val age = inputAgeLocked(nowNs)
    inputMaxUnits = maxOf(inputMaxUnits, input.size)
    inputMaxNs = maxOf(inputMaxNs, age)
    return if (age > INPUT_MAX_AGE_NS || input.size > INPUT_MAX_UNITS) TranscoderWhy.DECODER_TOO_SLOW else null
  }

  private fun inputAgeMs(nowNs: Long): Long = synchronized(lock) { inputAgeLocked(nowNs) / 1_000_000 }

  /**
   * Decoder 2 for [description], its first units already in [input]. An encoder made before draws from the GL stage
   * of the decoder it was made with, so it goes too and is made again on the new one while needed (its first output is
   * a key picture with its parameter sets).
   */
  private fun openDecoder(description: StreamDescription, nowNs: Long, made: Int) {
    val (oldDecoder, oldEncoder) = synchronized(lock) {
      val pair = decoder to encoder
      decoder = null
      encoder = null
      steadyDescription = null
      drawnAt.clear()
      pair
    }
    oldEncoder?.let { runCatching { it.release() } }
    oldDecoder?.let { runCatching { it.release() } }
    if (synchronized(lock) { generation != made }) {
      return
    }
    val port = runCatching { codecs.openDecoder(description, this) }.getOrNull()
    if (port == null) {
      val retry = synchronized(lock) {
        if (generation == made) {
          failCreationLocked(TranscoderWhy.NO_SECOND_DECODER, clockNs(), "no second decoder")
          clearCodecsLocked()
        }
        retryAtNs != null
      }
      log("no second decoder: no steady stream" + if (retry) " for 30 s" else "")
      onChange()
      return
    }
    val keep = synchronized(lock) {
      if (!runsLocked() || generation != made) {
        false
      } else {
        decoder = port
        decoderSinceNs = clockNs()
        decoderDescription = description
        decoderName = port.name
        opening = false
        pilotOverrunsAtStart = null
        pilotHighSinceNs = null
        if (thermalAtStart == null) {
          thermalAtStart = thermalNow
        }
        true
      }
    }
    if (!keep) {
      // Stopped, turned off or reset while it was made
      runCatching { port.release() }
      return
    }
    port.wake()
    onChange()
    if (synchronized(lock) { needed }) {
      ensureEncoder(nowNs)
    }
  }

  /** The encoder at the first need: from a dirty start when decoder 2 has not started yet */
  private fun ensureEncoder(nowNs: Long) {
    var dirty: KeptKey? = null
    var found: RelayEncoderInfo? = null
    var rate = START_BPS
    var stamp = 0
    val ready = synchronized(lock) {
      if (!runsLocked() || !needed || encoder != null || makingEncoder || opening) {
        return
      }
      if (decoder == null) {
        val key = lastKey ?: return
        dirty = key
        opening = true
        input.clear()
        // It entered the input now, whenever the phone received it
        input.addLast(Waiting(key.unit, clockNs()))
        dirtyStarts += 1
        stamp = generation
        null
      } else {
        makingEncoder = true
        found = info
        rate = minOf(askedBps, capLocked() ?: askedBps)
        decoder
      }
    }
    val kept = dirty
    if (kept != null) {
      // A dirty start: the kept key picture first, then the live units; its picture repairs over seconds
      openDecoder(kept.description, nowNs, stamp)
      return
    }
    val dec = ready ?: return
    val made = found?.let { encoderInfo ->
      runCatching { codecs.openEncoder(encoderInfo, rate, dec, this) }.getOrNull()
    }
    if (made == null) {
      var retry = false
      val (gone, release) = synchronized(lock) {
        makingEncoder = false
        if (decoder !== dec || !runsLocked()) {
          // Decoder 2 and its GL stage went while the encoder was made (new parameter sets at a take off, a reset):
          // not a refusal of the encoder; the next decoder 2 makes it again (p2/review-bandwidth-2026-10-25.md M1)
          true to null
        } else {
          failCreationLocked(TranscoderWhy.REFUSED, clockNs(), "encoder refused")
          retry = retryAtNs != null
          val pair = decoder
          clearCodecsLocked()
          false to pair
        }
      }
      release?.let { runCatching { it.release() } }
      if (gone) {
        log("decoder 2 went while the encoder was made: made again with the next one")
        return
      }
      log("the encoder refused 1920x1080 and 1280x720: no steady stream" + if (retry) " for 30 s" else "")
      onChange()
      return
    }
    val keep = synchronized(lock) {
      makingEncoder = false
      decoder === dec && runsLocked()
    }
    if (!keep) {
      runCatching { made.release() }
      return
    }
    synchronized(lock) {
      encoder = made
      setup = made.setup
      bitrateBps = minOf(askedBps, capLocked() ?: askedBps)
      noteBitrateLocked(bitrateBps)
      keys.onEncoderStarted()
      decimator.reset()
      decimator.perSecond = perSecondLocked()
      slowSinceNs = null
      slowAtFifteenNs = null
    }
    val setupMade = made.setup
    log("encoder ${made.name} ${setupMade.width}x${setupMade.height} ${setupMade.bitrateMode} level ${setupMade.level}")
    onChange()
  }

  // Decoder 2's thread

  /** The next unit for decoder 2, in order, with its presentation time; null when none waits */
  fun nextInput(nowNs: Long = clockNs()): RelayDecoderInput? = synchronized(lock) {
    val unit = input.removeFirstOrNull()?.unit ?: return null
    val contentUs = if (unit.contentMs >= 0) unit.contentMs * 1_000 else unit.lastArrivalNs / 1_000
    val ptsUs = pts.of(contentUs)
    val source = RelaySourceStamp(unit.firstArrivalNs, unit.lastArrivalNs, unit.contentMs, unit.pictureCounter ?: -1)
    ptsMap.put(ptsUs, source)
    queuedAt[ptsUs] = nowNs
    if (queuedAt.size > 512) {
      queuedAt.keys.sorted().take(256).forEach { queuedAt.remove(it) }
    }
    RelayDecoderInput(unit, ptsUs)
  }

  /** A picture came out of decoder 2: true when it goes to the encoder (rendered), false when released unseen */
  fun onDecoded(ptsUs: Long, nowNs: Long = clockNs()): Boolean = synchronized(lock) {
    decoded += 1
    queuedAt.remove(ptsUs)?.let { decodeTimes.add(nowNs - it) }
    if (encoder == null || stopped != null) {
      return false
    }
    val keep = decimator.keep(ptsUs)
    if (keep) {
      kept += 1
    }
    keep
  }

  /** The GL stage drew the picture of [ptsUs] into the encoder's surface; its swap waited [waitNs] */
  fun onDrawn(ptsUs: Long, nowNs: Long = clockNs(), waitNs: Long = 0) {
    synchronized(lock) {
      drawnAt[ptsUs] = nowNs
      if (drawnAt.size > 256) {
        drawnAt.keys.sorted().take(128).forEach { drawnAt.remove(it) }
      }
      if (waitNs > GL_WAIT_NS) {
        glWaits += 1
        if (slowSinceNs == null) {
          slowSinceNs = nowNs - SLOW_FOR_NS
        }
      }
    }
  }

  // The encoder's thread

  /** One output buffer of the encoder, copied: the codec configuration, or a picture with its key flag */
  fun onEncoded(bytes: ByteArray, ptsUs: Long, config: Boolean, key: Boolean, nowNs: Long = clockNs()) {
    var out: Pair<AccessUnit, ResolvedDescription>? = null
    synchronized(lock) {
      // The configuration buffer may come out before the encoder is handed back to this class
      if (encoder == null && !makingEncoder) {
        return
      }
      if (config) {
        EncodedUnits.descriptionOf(bytes)?.let { noteSetsLocked(it) }
        return
      }
      val stamp = ptsMap.find(ptsUs)
      var unit = EncodedUnits.unitOf(bytes, stamp, nowNs, counter) ?: return
      if (unit.hasParameterSets) {
        EncodedUnits.descriptionOf(bytes)?.let { noteSetsLocked(it) }
      }
      val description = steadyDescription
      if (description == null) {
        unitsWithoutSets += 1
        return
      }
      if (unit.isKey) {
        keysOut += 1
      }
      if (unit.isKey && !unit.hasParameterSets) {
        // An encoder that would not put its sets before each key picture: they go in band all the same, so that a
        // receiver switching to this stream finds them with the key picture whatever its decoder does with PARAMETERS
        unit = EncodedUnits.unitOf(description.configuration() + bytes, stamp, nowNs, counter) ?: return
        setsAdded += 1
      }
      counter += 1
      encoded += 1
      encodedBytes += unit.size
      drawnAt.remove(ptsUs)?.let { drawn ->
        val took = nowNs - drawn
        encodeTimes.add(took)
        recentEncodes.addLast(longArrayOf(nowNs, took))
      }
      while (recentEncodes.isNotEmpty() && nowNs - recentEncodes.first()[0] > SLOW_FOR_NS) {
        recentEncodes.removeFirst()
      }
      stamp?.let { receiveToEncoded.add(nowNs - it.lastArrivalNs) }
      if (unit.isKey || key) {
        keys.onKey(nowNs)
      }
      out = unit to ResolvedDescription(description, DescriptionSource.SESSION)
    }
    out?.let { (unit, description) -> runCatching { emit(unit, description) } }
  }

  /**
   * Under [lock]: the steady stream's sets, said in the log when they change (the encoder's SPS for the notes), with
   * the coded size: 1088 lines where the drone codes 1080 means a receiver's decoder is configured again at each switch
   */
  private fun noteSetsLocked(description: StreamDescription) {
    val info = description.info
    if (!description.sameSetsAs(steadyDescription)) {
      log(
        "steady stream sets ${info.width}x${info.height} coded ${info.codedWidth}x${info.codedHeight} " +
          "${info.profileName} level ${info.levelName}: VPS ${StreamDescription.hex(description.vps)} SPS " +
          "${StreamDescription.hex(description.sps)} PPS ${StreamDescription.hex(description.pps)}",
      )
    }
    steadyDescription = description
    steadyCodedWidth = info.codedWidth
    steadyCodedHeight = info.codedHeight
  }

  // Errors

  fun onDecoderError(message: String, recoverable: Boolean, nowNs: Long = clockNs()) =
    onCodecError("decoder: $message", recoverable, encoderSide = false, nowNs)

  fun onEncoderError(message: String, recoverable: Boolean, nowNs: Long = clockNs()) =
    onCodecError("encoder: $message", recoverable, encoderSide = true, nowNs)

  /** An EGL error or an abandoned surface: the GL stage (decoder 2 and the encoder with it) is made again once */
  fun onGlError(message: String, nowNs: Long = clockNs()) {
    val again = synchronized(lock) {
      glErrors += 1
      failures.addLast(nowNs to "gl: $message")
      trimFailures()
      glErrors > 1
    }
    if (again) {
      stopFor(TranscoderWhy.FAILED, nowNs, "gl: $message")
      return
    }
    worker(Runnable { remake(nowNs, encoderOnly = false) })
  }

  private fun onCodecError(message: String, recoverable: Boolean, encoderSide: Boolean, nowNs: Long) {
    val fatal = synchronized(lock) {
      failures.addLast(nowNs to message)
      trimFailures()
      errors.addLast(nowNs)
      while (errors.isNotEmpty() && nowNs - errors.first() > ERRORS_WINDOW_NS) {
        errors.removeFirst()
      }
      !recoverable || errors.size >= ERRORS_STOP
    }
    if (fatal) {
      stopFor(TranscoderWhy.FAILED, nowNs, message)
      return
    }
    worker(Runnable { remake(nowNs, encoderOnly = encoderSide) })
  }

  /** A recoverable error: the encoder made again with a key picture asked; decoder 2 too unless [encoderOnly] */
  private fun remake(nowNs: Long, encoderOnly: Boolean) {
    val (dec, enc) = synchronized(lock) {
      val pair = (if (encoderOnly) null else decoder) to encoder
      encoder = null
      steadyDescription = null
      drawnAt.clear()
      if (!encoderOnly) {
        decoder = null
        decoderSinceNs = null
        decoderDescription = null
        input.clear()
        queuedAt.clear()
      }
      pair
    }
    enc?.let { runCatching { it.release() } }
    dec?.let { runCatching { it.release() } }
    ensureEncoder(nowNs)
    onChange()
  }

  private fun trimFailures() {
    while (failures.size > 16) {
      failures.removeFirst()
    }
  }

  /** Stops the steady stream for [why]: every codec goes; the server sends the drone's stream again */
  private fun stopFor(why: TranscoderWhy, nowNs: Long, detail: String) {
    val (dec, enc) = synchronized(lock) {
      if (stopped != null || !started) {
        return
      }
      stopped = why
      stoppedAtNs = nowNs
      coolSinceNs = null
      failures.addLast(nowNs to "${why.wire}: $detail")
      trimFailures()
      val pair = decoder to encoder
      clearCodecsLocked()
      pair
    }
    enc?.let { runCatching { it.release() } }
    dec?.let { runCatching { it.release() } }
    log("stopped: ${why.wire} ($detail)")
    onChange()
  }

  // From the server

  override fun requestKey(cause: RelayKeyCause, nowNs: Long) {
    val port = synchronized(lock) {
      val ask = keys.request(cause, nowNs)
      if (ask) encoder else null
    }
    port?.let { runCatching { it.requestKey() } }
  }

  override fun setBitrate(bps: Int, nowNs: Long) {
    val apply = synchronized(lock) {
      askedBps = bps
      applyBitrateLocked()
    }
    apply?.let { (port, rate) -> runCatching { port.setBitrate(rate) } }
  }

  /** Under [lock]: the rate to give the encoder now, the asked one under the thermal cap, null when unchanged */
  private fun applyBitrateLocked(): Pair<RelayEncoderPort, Int>? {
    val target = minOf(askedBps, capLocked() ?: askedBps)
    val port = encoder ?: return null
    if (target == bitrateBps) {
      return null
    }
    bitrateBps = target
    bitrateChanges += 1
    noteBitrateLocked(target)
    return port to target
  }

  private fun noteBitrateLocked(bps: Int) {
    bitrateMin = minOf(bitrateMin ?: bps, bps)
    bitrateMax = maxOf(bitrateMax ?: bps, bps)
  }

  override fun setPictureRate(perSecond: Int, nowNs: Long) {
    synchronized(lock) {
      askedPerSecond = perSecond
      decimator.perSecond = perSecondLocked()
    }
  }

  private fun capLocked(): Int? = if ((thermalNow ?: 0) >= THERMAL_MODERATE) HOT_CAP_BPS else null

  private fun perSecondLocked(): Int =
    if (askedPerSecond <= 15 || (thermalNow ?: 0) >= THERMAL_MODERATE || slowAtFifteenNs != null) 15 else 30

  // From the controller

  /** PowerManager's thermal status */
  fun onThermal(status: Int, nowNs: Long = clockNs()) {
    val apply = synchronized(lock) {
      thermalNow = status
      thermalMax = maxOf(thermalMax ?: status, status)
      if (thermalAtStart == null && decoder != null) {
        thermalAtStart = status
      }
      decimator.perSecond = perSecondLocked()
      if (status > THERMAL_LIGHT) {
        coolSinceNs = null
      } else if (coolSinceNs == null && stopped == TranscoderWhy.HOT) {
        coolSinceNs = nowNs
      }
      applyBitrateLocked()
    }
    apply?.let { (port, rate) -> runCatching { port.setBitrate(rate) } }
    if (status >= THERMAL_SEVERE) {
      stopFor(TranscoderWhy.HOT, nowNs, "thermal status $status")
    }
  }

  /**
   * The pilot's decoder: its overruns since the page opened and its decode p95 of the last 2 s, in the phase [flying]
   * (the motors) at [picturesPerSecond] (the drone's rate). While decoder 2 is off, the p95 is kept for that phase.
   * While it runs, an overrun stops the steady stream at once, and a p95 over the bound for 3 s too: 1.5 times and 5 ms
   * over the median kept for the same phase, or two picture periods when none is kept (decoder 2 started with the
   * link, or the phase is new), never under one period (p2/review-bandwidth-2026-10-25.md M3).
   */
  fun onPilot(
    overruns: Long,
    decodeP95Ms: Double?,
    nowNs: Long = clockNs(),
    flying: Boolean? = null,
    picturesPerSecond: Double? = null,
  ) {
    val phase = PilotPhase.of(flying, picturesPerSecond)
    val why = synchronized(lock) {
      if (decoder == null) {
        decodeP95Ms?.let { value ->
          val kept = pilotBaselines.getOrPut(phase) { ArrayDeque() }
          kept.addLast(value)
          while (kept.size > PILOT_KEPT) {
            kept.removeFirst()
          }
        }
        pilotOverrunsAtStart = null
        pilotHighSinceNs = null
        return
      }
      val at = pilotOverrunsAtStart
      if (at == null) {
        pilotOverrunsAtStart = overruns
      }
      decodeP95Ms?.let { pilotDuring.add((it * 1e6).toLong()) }
      if (phase != pilotPhase) {
        // A new phase (a take off, a landing): its own bound, counted from now
        pilotPhase = phase
        pilotHighSinceNs = null
      }
      val before = pilotBaselines[phase]?.let { values -> values.sorted()[values.size / 2] }
      val bound = pilotBound(before, phase)
      pilotBefore = before
      pilotBoundMs = bound
      val high = decodeP95Ms != null && decodeP95Ms > bound
      if (high) {
        if (pilotHighSinceNs == null) pilotHighSinceNs = nowNs
      } else {
        pilotHighSinceNs = null
      }
      when {
        at != null && overruns > at -> "overruns ${overruns - at}"
        pilotHighSinceNs?.let { nowNs - it >= PILOT_FOR_NS } == true ->
          "decode p95 $decodeP95Ms ms over $bound ms (${phase.wire}, before ${before ?: "none"})"
        else -> null
      }
    }
    if (why != null) {
      stopFor(TranscoderWhy.PILOT_FIRST, nowNs, why)
    }
  }

  /** The pilot's decode p95 bound while decoder 2 runs, in milliseconds */
  private fun pilotBound(before: Double?, phase: PilotPhase): Double {
    val rule = before?.let { maxOf(PILOT_FACTOR * it, it + PILOT_MARGIN_MS) } ?: (PILOT_PERIODS * phase.periodMs)
    return maxOf(rule, phase.periodMs)
  }

  /**
   * The battery's current now, in microamperes as BatteryManager says it (negative while discharging on most phones):
   * kept apart before decoder 2 runs and while it runs, for the export (p2/relay-bandwidth-2026-10-25.md, 7.11)
   */
  fun onBattery(currentMicroAmps: Int?) = synchronized(lock) {
    val current = currentMicroAmps?.toLong() ?: return@synchronized
    if (decoder == null) {
      batteryBefore.addLast(current)
      while (batteryBefore.size > 120) {
        batteryBefore.removeFirst()
      }
    } else if (batteryWhile.size < 14_400) {
      batteryWhile.add(current)
    }
  }

  // The tick

  override fun tick(nowNs: Long) {
    var stop: Pair<TranscoderWhy, String>? = null
    var askKey: RelayEncoderPort? = null
    var release: RelayEncoderPort? = null
    var cooled = false
    synchronized(lock) {
      if (!started) {
        return
      }
      val ranSince = encoderSinceNs
      if (encoder != null) {
        if (ranSince != null) {
          encoderRunNs += nowNs - ranSince
        }
        encoderSinceNs = nowNs
      } else {
        encoderSinceNs = null
      }
      val retry = retryAtNs
      if (unavailable != null && retry != null && nowNs >= retry) {
        // A creation that failed is tried again at the next need
        unavailable = null
        retryAtNs = null
        creationRetries += 1
        cooled = true
      }
      checkInputLocked(nowNs)?.let { stop = it to "input over 1 s" }
      // The encoder's speed: p95 of the last 3 s of encodes over 66 ms (plus the pictures it holds when it did not take
      // a latency of one, p2/review-bandwidth-2026-10-25.md m2), or the GL stage waiting over 100 ms
      val running = encoder
      if (running != null && stop == null) {
        val p95 = percentile(recentEncodes.map { it[1] }, 0.95)
        val slow = p95 != null && p95 > slowBoundNsLocked(running) && recentEncodes.size >= 10
        if (slow) {
          if (slowSinceNs == null) slowSinceNs = nowNs
        } else if (slowAtFifteenNs == null) {
          slowSinceNs = null
        }
        val since = slowSinceNs
        if (since != null && nowNs - since >= SLOW_FOR_NS && slowAtFifteenNs == null) {
          slowAtFifteenNs = nowNs
          decimator.perSecond = perSecondLocked()
          log("the encoder is slow: 15 pictures a second")
        }
        val fifteen = slowAtFifteenNs
        if (fifteen != null && nowNs - fifteen >= SLOW_STOP_NS) {
          if (slow) {
            stop = TranscoderWhy.TOO_SLOW to "encode p95 ${(p95 ?: 0) / 1_000_000} ms"
          } else {
            slowAtFifteenNs = null
            slowSinceNs = null
            decimator.perSecond = perSecondLocked()
          }
        }
      }
      if (keys.due(nowNs)) {
        askKey = encoder
      }
      val notNeeded = notNeededSinceNs
      if (!needed && encoder != null && notNeeded != null && nowNs - notNeeded >= RELEASE_AFTER_NS) {
        release = encoder
        encoder = null
        steadyDescription = null
      }
      if (stopped == TranscoderWhy.HOT) {
        if ((thermalNow ?: 0) <= THERMAL_LIGHT) {
          val cool = coolSinceNs ?: nowNs.also { coolSinceNs = it }
          if (nowNs - cool >= COOL_FOR_NS) {
            stopped = null
            stoppedAtNs = null
            coolSinceNs = null
            cooled = true
          }
        } else {
          coolSinceNs = null
        }
      }
      sampleLocked(nowNs)
    }
    askKey?.let { runCatching { it.requestKey() } }
    release?.let { runCatching { it.release() } }
    stop?.let { (why, detail) -> stopFor(why, nowNs, detail) }
    if (release != null || cooled) {
      onChange()
    }
  }

  /** Under [lock]: the encode time over which [port] is slow, at the picture rate of now */
  private fun slowBoundNsLocked(port: RelayEncoderPort): Long {
    if (port.setup.latencyAccepted == true) {
      return SLOW_ENCODE_NS
    }
    return SLOW_ENCODE_NS + HELD_PICTURES * 1_000_000_000L / perSecondLocked()
  }

  private fun sampleLocked(nowNs: Long) {
    val due = nextSecondNs ?: return
    if (nowNs < due) {
      return
    }
    nextSecondNs = maxOf(due + 1_000_000_000L, nowNs + 500_000_000L)
    val at = ((seconds % TIMELINE_SECONDS) * COLUMNS).toInt()
    timeline[at] = ((nowNs - startedAtNs) / 1_000_000_000L).toInt()
    timeline[at + 1] = (decoded - decodedAtSample).toInt()
    timeline[at + 2] = (kept - keptAtSample).toInt()
    timeline[at + 3] = (encoded - encodedAtSample).toInt()
    timeline[at + 4] = ((encodedBytes - bytesAtSample) / 1024).toInt()
    timeline[at + 5] = if (encoder != null) bitrateBps / 1000 else -1
    timeline[at + 6] = percentile(recentEncodes.map { it[1] }, 0.95)?.let { (it / 1_000_000).toInt() } ?: -1
    timeline[at + 7] = (inputAgeLocked(nowNs) / 1_000_000).toInt()
    timeline[at + 8] = thermalNow ?: -1
    seconds += 1
    decodedAtSample = decoded
    keptAtSample = kept
    encodedAtSample = encoded
    bytesAtSample = encodedBytes
    if (encoder != null) {
      bitrateSeconds.add(bitrateBps)
      if (bitrateSeconds.size > TIMELINE_SECONDS) {
        bitrateSeconds.removeAt(0)
      }
    }
  }

  private fun percentile(values: List<Long>, fraction: Double): Long? {
    if (values.isEmpty()) {
      return null
    }
    val sorted = values.sorted()
    return sorted[((sorted.size - 1) * fraction).toInt()]
  }

  /** The picture rate the steady stream runs at now */
  val perSecond: Int get() = synchronized(lock) { perSecondLocked() }

  /** The bit rate the encoder runs at now, null while there is none */
  val bitrateNowBps: Int? get() = synchronized(lock) { if (encoder != null) bitrateBps else null }

  override fun line(nowNs: Long): RelaySteadyLine? = synchronized(lock) {
    if (!started) {
      return null
    }
    RelaySteadyLine(
      state = stateLocked().wire,
      why = (unavailable ?: stopped)?.wire,
      encoderName = encoder?.name ?: info?.name,
      width = (encoder?.setup ?: setup)?.width,
      height = (encoder?.setup ?: setup)?.height,
      perSecond = perSecondLocked(),
      bitrateBps = if (encoder != null) bitrateBps else null,
      encodeMedianMs = encodeTimes.percentileMs(0.5),
      encodeP95Ms = encodeTimes.percentileMs(0.95),
    )
  }

  /** The timeline lines kept, oldest first */
  fun timelineLines(): List<String> {
    val (copy, count) = synchronized(lock) { timeline.copyOf() to seconds }
    return timelineLinesOf(copy, count)
  }

  private fun timelineLinesOf(copy: IntArray, count: Long): List<String> {
    val first = maxOf(0L, count - TIMELINE_SECONDS)
    return (first until count).map { index ->
      val at = ((index % TIMELINE_SECONDS) * COLUMNS).toInt()
      (0 until COLUMNS).joinToString(",") { copy[at + it].toString() }
    }
  }

  /** The keys asked by cause, for the tests */
  fun keyCounts(): Map<RelayKeyCause, Long> = synchronized(lock) { keys.byCause.toMap() }

  fun keysSent(): Long = synchronized(lock) { keys.sent }

  /**
   * The transcoder section of the export. Its numbers are read under the lock and copied; the sorts and the timeline's
   * lines are made outside it, so that a save during a flight does not hold [offer] (p2/review-bandwidth-2026-10-25.md
   * m8).
   */
  override fun report(nowNs: Long): JsonObject? {
    val bitrates: IntArray
    val before: LongArray
    val whileRunning: LongArray
    val copy: IntArray
    val count: Long
    val head = synchronized(lock) {
      if (!started && info == null && unavailable == null) {
        return null
      }
      bitrates = bitrateSeconds.toIntArray()
      before = batteryBefore.toLongArray()
      whileRunning = batteryWhile.toLongArray()
      copy = timeline.copyOf()
      count = seconds
      headLocked(nowNs)
    }
    bitrates.sort()
    before.sort()
    whileRunning.sort()
    val lines = timelineLinesOf(copy, count)
    return JsonObject(
      head + mapOf(
        "bitrateMedianKbps" to JsonPrimitive(bitrates.getOrNull(bitrates.size / 2)?.div(1000)),
        "batteryMicroAmpsBeforeMedian" to JsonPrimitive(before.getOrNull(before.size / 2)),
        "batteryMicroAmpsWhileMedian" to JsonPrimitive(whileRunning.getOrNull(whileRunning.size / 2)),
        "timelineColumns" to JsonPrimitive(TIMELINE_HEADER),
        "timeline" to buildJsonArray { lines.forEach { add(JsonPrimitive(it)) } },
      ),
    )
  }

  /** Under [lock]: every number of the export that needs no sort */
  private fun headLocked(nowNs: Long): JsonObject {
    val encoderInfo = info
    val made = encoder?.setup ?: setup
    val spanS = ((nowNs - startedAtNs) / 1e9).coerceAtLeast(1e-3)
    return buildJsonObject {
      put("state", stateLocked().wire)
      put("why", (unavailable ?: stopped)?.wire)
      put("retryInS", retryAtNs?.let { ((it - nowNs) / 1e9).coerceAtLeast(0.0) })
      put("creationFailures", creationFailures)
      put("creationRetries", creationRetries)
      put("decoderName", decoderName)
      put("cleanStarts", cleanStarts)
      put("dirtyStarts", dirtyStarts)
      put("encoderName", encoderInfo?.name)
      put("encoderHardware", encoderInfo?.hardware)
      put("encoderCbr", encoderInfo?.cbr)
      put("width", made?.width)
      put("height", made?.height)
      // The coded size of the steady stream's sets: a receiver's decoder is configured again at each switch when it is
      // not the drone's (1920x1080 on 23 October)
      put("codedWidth", steadyCodedWidth)
      put("codedHeight", steadyCodedHeight)
      put("perSecond", perSecondLocked())
      put("bitrateMode", made?.bitrateMode)
      put("latencyAccepted", made?.latencyAccepted)
      put("headersOnKeys", made?.headersOnKeys)
      // Whether every key picture came out with its sets in band, null before the first
      put("headersOnKeysTaken", if (keysOut == 0L) null else setsAdded == 0L)
      put("keyIntervalS", made?.keyIntervalS)
      put("configurationLevel", made?.level)
      put("colorStandard", made?.colorStandard)
      put("colorRange", made?.colorRange)
      put("colorTransfer", made?.colorTransfer)
      put("unitsIn", unitsIn)
      put("decoded", decoded)
      put("kept", kept)
      put("encoded", encoded)
      put("encodedBytes", encodedBytes)
      put("encodedWithoutSets", unitsWithoutSets)
      put("keySetsAddedInBand", setsAdded)
      put("megabitsPerSecondMean", encodedBytes * 8.0 / 1e6 / spanS)
      put("bitrateNowKbps", if (encoder != null) bitrateBps / 1000 else null)
      put("bitrateMinKbps", bitrateMin?.div(1000))
      put("bitrateMaxKbps", bitrateMax?.div(1000))
      put("bitrateChanges", bitrateChanges)
      put("keysPeriodic", keys.keysPeriodic)
      put("keysAsked", keys.keysAsked)
      put("keyRequests", buildJsonObject { keys.byCause.forEach { (cause, count) -> put(cause.wire, count) } })
      put("keyRequestsSent", keys.sent)
      put("keyRequestsCoalesced", keys.coalesced)
      put("decodeMedianMs", decodeTimes.percentileMs(0.5))
      put("decodeP95Ms", decodeTimes.percentileMs(0.95))
      put("decodeMaxMs", decodeTimes.maxMs)
      put("encodeMedianMs", encodeTimes.percentileMs(0.5))
      put("encodeP95Ms", encodeTimes.percentileMs(0.95))
      put("encodeMaxMs", encodeTimes.maxMs)
      put("receiveToEncodedMedianMs", receiveToEncoded.percentileMs(0.5))
      put("receiveToEncodedP95Ms", receiveToEncoded.percentileMs(0.95))
      put("receiveToEncodedMaxMs", receiveToEncoded.maxMs)
      put("inputQueueMaxUnits", inputMaxUnits)
      put("inputQueueMaxMs", inputMaxNs / 1_000_000)
      put("glWaitsOver100Ms", glWaits)
      put("slowAt15", slowAtFifteenNs != null)
      put("thermalAtStart", thermalAtStart)
      put("thermalMax", thermalMax)
      put("thermalNow", thermalNow)
      put("pilotPhase", pilotPhase?.wire)
      put("pilotDecodeP95BeforeMs", pilotBefore)
      put("pilotBoundMs", pilotBoundMs)
      put(
        "pilotDecodeP95BeforeByPhaseMs",
        buildJsonObject {
          pilotBaselines.entries.sortedBy { it.key.wire }.forEach { (phase, values) ->
            put(phase.wire, values.sorted()[values.size / 2])
          }
        },
      )
      put("pilotDecodeP95WhileMedianMs", pilotDuring.percentileMs(0.5))
      put("pilotDecodeP95WhileMaxMs", pilotDuring.maxMs)
      put("encoderRunningS", encoderRunNs / 1e9)
      put(
        "failures",
        buildJsonArray {
          failures.forEach { (at, what) ->
            add(
              buildJsonObject {
                put("atS", (at - startedAtNs) / 1e9)
                put("what", what)
              },
            )
          }
        },
      )
    }
  }
}
