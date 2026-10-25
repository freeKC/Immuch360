package app.alextran.immich.djilink

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** One H.265 decoder of this device, as the selection sees it */
data class DecoderCandidate(
  val name: String,
  val hardware: Boolean,
  /** The platform reports FEATURE_LowLatency for it (Android 11 and later) */
  val lowLatencyFeature: Boolean,
)

/**
 * The H.265 decoders of this device in the order the feed tries them: hardware decoders whose name ends in
 * `.low_latency`, the other hardware decoders, then the platform software decoder. Written from the Android
 * documentation of MediaCodecList and MediaCodecInfo.
 */
object HevcDecoders {
  const val MIME = "video/hevc"
  const val SOFTWARE_NAME = "c2.android.hevc.decoder"
  private const val OLD_SOFTWARE_NAME = "OMX.google.hevc.decoder"

  fun list(width: Int, height: Int): List<DecoderCandidate> {
    val infos = runCatching { MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.toList() }
      .getOrDefault(emptyList())
    val found = mutableListOf<DecoderCandidate>()
    for (info in infos) {
      if (info.isEncoder || info.supportedTypes.none { it.equals(MIME, ignoreCase = true) }) {
        continue
      }
      // A secure decoder needs protected buffers this feed never has
      if (info.name.endsWith(".secure")) {
        continue
      }
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && info.isAlias) {
        continue
      }
      val capabilities = runCatching { info.getCapabilitiesForType(MIME) }.getOrNull() ?: continue
      val fits = runCatching { capabilities.videoCapabilities?.isSizeSupported(width, height) ?: true }
        .getOrDefault(true)
      if (!fits) {
        continue
      }
      val lowLatency = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
        runCatching {
          capabilities.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
        }.getOrDefault(false)
      found.add(DecoderCandidate(info.name, isHardware(info), lowLatency))
    }
    return order(found)
  }

  /** The order of section 3.5 of the design, kept apart from the platform so that it is unit tested */
  fun order(found: List<DecoderCandidate>): List<DecoderCandidate> {
    val hardware = found.filter { it.hardware }
    val software = found.filter { !it.hardware }
    return hardware.filter { it.name.endsWith(".low_latency") } +
      hardware.filter { !it.name.endsWith(".low_latency") } +
      software.filter { it.name == SOFTWARE_NAME } +
      software.filter { it.name == OLD_SOFTWARE_NAME } +
      software.filter { it.name != SOFTWARE_NAME && it.name != OLD_SOFTWARE_NAME }
  }

  /** Android 10 says it; before that, the platform's own software decoders are recognised by their names */
  private fun isHardware(info: MediaCodecInfo): Boolean =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      info.isHardwareAccelerated
    } else {
      !isSoftwareName(info.name)
    }

  fun isSoftwareName(name: String): Boolean =
    name.startsWith("OMX.google.") || name.startsWith("c2.android.") || name.startsWith("OMX.ffmpeg.")

  /** The vendor low latency keys are only for the Qualcomm decoders, whose names start this way */
  fun isQualcomm(name: String): Boolean = name.startsWith("c2.qti") || name.startsWith("OMX.qcom")
}

/**
 * The access units waiting for an input buffer of the decoder, and the decoder thread they wake. The threads that
 * submit (the reader, the player) and the decoder thread share it, so its rules are held under one lock:
 *
 * * the producer holds the bound: past [bound] units the oldest ones are dropped and counted, and a flush is asked of
 *   the decoder thread, which empties what is left. The queue holds whole access units, so a drop never cuts one and
 *   what stays starts on an access unit boundary. A decoder thread stuck inside a vendor call can no longer make the
 *   queue grow without end;
 * * a closed queue takes nothing and makes no worker: after [close], a late unit (a read taken just before the link
 *   stopped, a capture asked for by a page that has closed since) is dropped instead of making a decoder thread and a
 *   codec that nothing would shut down, until an explicit [open].
 *
 * A paced reception replaces the bound by a safety net ([net], p2/review-relay-2026-10-25.md M2): past its age or its
 * bytes, the units before the newest key unit queued go, or when none is queued every unit but the newest; no flush is
 * asked, the decoder keeps its references, and the decoder thread learns it once from [takeNet].
 *
 * [W] is the handler of the decoder thread; it is a type parameter so that the rules are unit tested without Android.
 * [sizeOf], [bornNs] and [isKey] read a unit for the safety net.
 */
class DecoderQueue<T : Any, W : Any>(
  bound: Int,
  private val sizeOf: (T) -> Int = { 0 },
  private val bornNs: (T) -> Long = { 0L },
  private val isKey: (T) -> Boolean = { false },
) {
  /** The safety net of a paced reception: the oldest unit's age, the bytes and the units that reach it */
  class Net(val maxAgeNs: Long, val maxBytes: Long, val maxUnits: Int)

  private val lock = Any()

  /** Units kept at most when no [net] is set */
  @Volatile
  var bound: Int = bound

  /** Set for a paced reception, in place of [bound] */
  @Volatile
  var net: Net? = null
  private val pending = ArrayDeque<T>()
  private var bytes = 0L
  private var overflow = false
  private var netReached = false
  private var closed = false
  private var worker: W? = null
  private var dropped = 0L

  /** Units dropped past the bound or at a flush since the last [clear] */
  val droppedUnits: Long get() = synchronized(lock) { dropped }

  val size: Int get() = synchronized(lock) { pending.size }

  val isClosed: Boolean get() = synchronized(lock) { closed }

  /** The worker of the last [offer], until [close] */
  val currentWorker: W? get() = synchronized(lock) { worker }

  /**
   * Queues [item] at [nowNs] and returns the worker to wake, made by [make] when there is none yet. While closed,
   * returns null: the item is dropped and no worker is made.
   */
  fun offer(item: T, nowNs: Long, make: () -> W): W? = synchronized(lock) {
    if (closed) {
      return null
    }
    pending.addLast(item)
    bytes += sizeOf(item)
    val safety = net
    if (safety != null) {
      val oldestAgeNs = if (nowNs == Long.MIN_VALUE) 0L else nowNs - bornNs(pending.first())
      if (bytes > safety.maxBytes || pending.size > safety.maxUnits || oldestAgeNs > safety.maxAgeNs) {
        dropToNet()
      }
    } else if (pending.size > bound) {
      while (pending.size > bound) {
        bytes -= sizeOf(pending.removeFirst())
        dropped += 1
      }
      overflow = true
    }
    worker ?: make().also { worker = it }
  }

  /** Queues [item] with no time: the safety net then looks at the bytes and the units only */
  fun offer(item: T, make: () -> W): W? = offer(item, Long.MIN_VALUE, make)

  /**
   * Under the lock: the units before the newest key unit queued go; when none is queued, or it is the oldest, the units
   * between the oldest key unit kept and the newest unit go. The decoder is not flushed.
   */
  private fun dropToNet() {
    val keyAt = pending.indexOfLast(isKey)
    val from = if (keyAt == 0) 1 else 0
    val until = if (keyAt > 0) keyAt else pending.size - 1
    if (until <= from) {
      return
    }
    val kept = ArrayDeque<T>()
    for ((index, unit) in pending.withIndex()) {
      if (index in from until until) {
        bytes -= sizeOf(unit)
        dropped += 1
      } else {
        kept.addLast(unit)
      }
    }
    pending.clear()
    pending.addAll(kept)
    netReached = true
  }

  /** For the decoder thread: true once after an overflow, with the units still waiting dropped and counted */
  fun takeFlush(): Boolean = synchronized(lock) {
    if (!overflow) {
      return false
    }
    overflow = false
    dropped += pending.size
    pending.clear()
    bytes = 0
    true
  }

  /** For the decoder thread: true once after the safety net dropped units, which it counts and treats as a gap */
  fun takeNet(): Boolean = synchronized(lock) {
    netReached.also { netReached = false }
  }

  /** The bytes of the units waiting */
  val queuedBytes: Long get() = synchronized(lock) { bytes }

  /** The oldest unit, left in the queue until [remove] */
  fun peek(): T? = synchronized(lock) { pending.firstOrNull() }

  /** Takes [item] out if it is still the oldest unit: the bound, a flush or a reset may have dropped it meanwhile */
  fun remove(item: T) = synchronized(lock) {
    if (pending.firstOrNull() === item) {
      pending.removeFirst()
      bytes -= sizeOf(item)
    }
  }

  /** A new source: the waiting units go, and the count of drops starts again */
  fun clear() = synchronized(lock) {
    pending.clear()
    bytes = 0
    overflow = false
    netReached = false
    dropped = 0
  }

  /** Nothing is queued and no worker is made until [open]; returns the worker to shut down, which the queue forgets */
  fun close(): W? = synchronized(lock) {
    closed = true
    pending.clear()
    bytes = 0
    overflow = false
    netReached = false
    worker.also { worker = null }
  }

  /** Takes units again: called by the page session that starts the link or plays a capture */
  fun open() = synchronized(lock) {
    closed = false
  }
}

/**
 * The decoder: a MediaCodec in asynchronous mode on its own "DjiLinkDecoder" thread, fed one access unit per input
 * buffer, rendering into the surface of the video view or, when no view is shown, into a parking surface whose
 * pictures are released unseen.
 *
 * It is a decoder fed by hand, not a player: there is no extractor for a raw elementary stream that arrives in
 * fragments over a cable, and no audio clock. Every decision that can be taken without a decoder is in
 * [DecoderPolicy] and [DisplayPacer], which are unit tested; this class does what they say and measures.
 *
 * Configuration, tried in this order until the decoder accepts: the stream description as csd-0 with a 1 MiB input
 * size, realtime priority, KEY_LOW_LATENCY when the decoder reports the feature, and on a Qualcomm decoder only the
 * Qualcomm vendor keys and the highest operating rate; the same without those; the plain configuration. Which one was
 * accepted is in the log. The decoder itself is the one [DecoderPolicy.current] names.
 *
 * A codec that started on units that are not key pictures and shows nothing gets the last key unit kept
 * ([KeyPrimer]), as the Qualcomm decoders of the Quest need; its own picture is released unseen.
 *
 * A unit received from a phone's relay ([AccessUnit.relay]) is paced (p2/relay-smoothness-2026-10-25.md, 5.1): the
 * [JitterBuffer] gives it a display time on arrival, it waits here until that time less the time decoding takes, every
 * unit is decoded in order, and each picture is released with its display time, or without rendering when it is late
 * and a newer decoded one is due ([PacedRelease]). The queue is then a safety net of [PACED_NET_AGE_NS] or
 * [PACED_NET_BYTES]: dropping units is the phone's decision, which sees the network; past the net units go without a
 * flush, and the kept key picture waits as after a gap ([KeyPrimer]). Every picture of any source is released with an
 * explicit time on the System.nanoTime clock, the one the surface reads.
 *
 * Receive only: nothing here has a handle on the transport.
 */
class VideoDecoderFeed(
  private val statistics: VideoStatistics,
  private val onChange: () -> Unit = {},
  private val clockNs: () -> Long = { SystemClock.elapsedRealtimeNanos() },
  /** The decoders that gave no picture on this device; null keeps nothing */
  private val memory: DecoderMemory? = null,
) : DecoderSink {
  companion object {
    private const val TAG = "DjiLinkDecoder"
    const val MAX_INPUT_SIZE = 1024 * 1024
    // Qualcomm's public vendor extensions, in the MediaCodec syntax "vendor.<extension>.<parameter>": the extensions
    // qti-ext-dec-low-latency and qti-ext-dec-picture-order with their parameter "enable" are defined in AOSP,
    // hardware/qcom/sdm845/media, mm-video-v4l2/vidc/vdec/src/omx_vdec_extensions.hpp, and the same two keys are set
    // on Qualcomm decoders by Moonlight for Android (MediaCodecHelper.java)
    private const val QTI_LOW_LATENCY = "vendor.qti-ext-dec-low-latency.enable"
    private const val QTI_PICTURE_ORDER = "vendor.qti-ext-dec-picture-order.enable"
    private const val SURFACE_SWITCH_TIMEOUT_MS = 500L
    private const val PARKING_WIDTH = 1920
    private const val PARKING_HEIGHT = 1080

    /**
     * The safety net of a paced reception (p2/review-relay-2026-10-25.md M2): above twice a TV's bound on the phone
     * (3 s) with the jitter buffer's ceiling and the decode lead, so that only a device that cannot keep up reaches it
     */
    const val PACED_NET_AGE_NS = 5_000_000_000L
    const val PACED_NET_BYTES = 16L * 1024 * 1024

    /** And a count of units, for the memory only: 10 s at 60 pictures a second */
    const val PACED_NET_UNITS = 600
    val PACED_NET = DecoderQueue.Net(PACED_NET_AGE_NS, PACED_NET_BYTES, PACED_NET_UNITS)

    /** The operating rate told to every decoder at configuration level 1: the 60 pictures a second of a flight */
    const val OPERATING_RATE = 60

    /** A unit due within this long goes to the decoder now */
    private const val FEED_SLACK_NS = 2_000_000L
    private const val RENDERED_KEPT = 64
  }

  /** A unit queued to the codec: when, and what the relay said of it */
  private class InFlight(val fedNs: Long, val stamp: RelayStamp?)

  /** A decoded picture of a paced reception, until it is released */
  private class Held(val index: Int, val pts: Long, val stamp: RelayStamp)

  /**
   * Units waiting for an input buffer, and the handler of the decoder thread they wake: the thread is made by the first
   * unit while the queue is open and ended by [shutdown]
   */
  private val queue = DecoderQueue<Pair<AccessUnit, ResolvedDescription>, Handler>(
    DecoderPolicy.MAX_QUEUED_UNITS,
    sizeOf = { it.first.size },
    bornNs = { it.first.relay?.arrivalNs ?: it.first.lastArrivalNs },
    isKey = { it.first.isKey },
  )

  private val handler: Handler? get() = queue.currentWorker

  @Volatile
  private var viewSurface: Surface? = null

  @Volatile
  private var choice = DecoderChoice.AUTOMATIC

  @Volatile
  private var currentStatus = DecoderStatus()

  /** The last key unit, to start a codec with; kept from the threads that submit, used by the decoder thread */
  private val primer = KeyPrimer()

  /** The pacing of a relayed stream: placed by the thread that submits, under its own lock */
  @Volatile
  private var jitter = JitterBuffer()

  /** The time the decoder needs before the display, updated by the decoder thread from its measured decode times */
  @Volatile
  private var decodeLeadNs = PacedRender.DEFAULT_LEAD_NS

  /** The counters of a paced reception */
  val smoothing = SmoothingStats()

  /** The times of every relayed unit, made at the first one: 4 MiB, never on a phone that only sends */
  @Volatile
  var timing: UnitTimingRing? = null
    private set

  /** A time of the phone's clock on this one, from the pings of the reception; null until the clocks are aligned */
  @Volatile
  var phoneToLocal: (Long) -> Long? = { null }
  // Everything below belongs to the decoder thread
  private var codec: MediaCodec? = null
  private var codecName: String? = null
  private var codecKind: DecoderKind? = null
  private var lowLatency = false
  private var generation = 0
  private var configured: StreamDescription? = null
  private val freeInputs = ArrayDeque<Int>()
  private var policy = DecoderPolicy()
  private var policyMade = false
  private val pacer = DisplayPacer()
  private var heldOutput: Int? = null
  private val queuedAt = LinkedHashMap<Long, InFlight>()
  private val release = PacedRelease<Held>()
  private val releaseSteps = ArrayList<PacedRelease.Step<Held>>()

  /** The safety net dropped units: the next unit fed comes after a gap */
  private var gapPending = false
  private val rendered = LinkedHashMap<Long, RelayStamp>()
  private var lastOutputNs: Long? = null
  private var nextLeadNs = 0L
  private var operatingRate: Int? = null
  private var lowLatencyFeature = false
  private var configurationLevel: Int? = null
  private var frameRateAsked: Int? = null
  private var lastPtsUs = Long.MIN_VALUE
  private var parkingTexture: SurfaceTexture? = null
  private var parkingSurface: Surface? = null
  private var outputSurface: Surface? = null
  private var failure: String? = null
  private var failedForSession = false
  private var startedAtNs: Long? = null
  private var keySinceStart = false

  /**
   * The parameter sets the running codec last took: its configuration, then the key units fed. A relayed key unit with
   * other sets at the same size flushes it first ([DecoderPolicy.flushBeforeKey])
   */
  private var fedSets: StreamDescription? = null

  /** The presentation time of the kept key unit queued to start the running codec, until its picture comes out */
  private var primerPts: Long? = null
  private var primersQueued = 0

  private val drain = Runnable { drainNow() }
  private val renderHeld = Runnable { renderHeldNow() }
  private val releaseHeld = Runnable { releaseHeldNow() }

  override fun submit(unit: AccessUnit, description: ResolvedDescription) {
    primer.keep(unit, description.description)
    if (!queue.isClosed) {
      unit.relay?.let { place(unit, it) }
    }
    // The bound is a constant of the policy; the policy object itself belongs to the decoder thread. A closed feed
    // drops the unit and makes no thread.
    val target = queue.offer(unit to description, clockNs(), ::makeThread) ?: return
    smoothing.onQueued(queue.size)
    target.post(drain)
  }

  /**
   * The bounds of the jitter buffer of the next reception: a TV's, or a headset's; [lowestDelay] is the headset's
   * choice in Options, with no floor
   */
  fun setPacing(television: Boolean, lowestDelay: Boolean = false) {
    synchronized(jitter) {
      jitter = when {
        television -> JitterBuffer(JitterBuffer.TV_FLOOR_NS, JitterBuffer.TV_CEILING_NS)
        lowestDelay -> JitterBuffer(JitterBuffer.LOWEST_FLOOR_NS, JitterBuffer.HEADSET_CEILING_NS)
        else -> JitterBuffer(JitterBuffer.HEADSET_FLOOR_NS, JitterBuffer.HEADSET_CEILING_NS)
      }
    }
  }

  /** On the thread that submits: the display time of a relayed unit, and its line in the timing ring */
  private fun place(unit: AccessUnit, stamp: RelayStamp) {
    queue.net = PACED_NET
    val source: Int
    val clockMs: Long
    when {
      stamp.contentMs >= 0 -> {
        source = UnitTimingRing.SOURCE_PHONE_CLOCK
        clockMs = stamp.contentMs
      }
      unit.contentMs >= 0 -> {
        source = UnitTimingRing.SOURCE_OWN_CLOCK
        clockMs = unit.contentMs
      }
      else -> {
        source = UnitTimingRing.SOURCE_PHONE_RECEIVE
        clockMs = -1
      }
    }
    val sourceNs = if (clockMs >= 0) clockMs * 1_000_000 else stamp.phoneReceiveNs
    val lead = decodeLeadNs
    val current = jitter
    val placement: JitterBuffer.Placement
    val periodNs: Long
    synchronized(current) {
      placement = current.place(stamp.arrivalNs, sourceNs, (stamp.flags and RelayWire.UNIT_BREAK) != 0, lead)
      periodNs = current.periodNs
    }
    stamp.sourceNs = sourceNs
    stamp.displayNs = placement.displayNs
    stamp.feedAtNs = placement.feedAtNs
    smoothing.onPlaced(placement, periodNs, lead, sourceNs)
    val ring = timing ?: UnitTimingRing().also { timing = it }
    stamp.timingIndex = ring.add(stamp, unit.size, source, clockMs)
  }

  /** The counters of the pacing at [nowNs] */
  fun smoothingNumbers(nowNs: Long = clockNs()): SmoothingNumbers = smoothing.numbers(nowNs)

  /**
   * A new connection to a phone: the counters of the pacing start again. A reconnection within it keeps them, as the
   * receiver keeps its own.
   */
  fun clearSmoothing() {
    smoothing.reset()
  }

  /** A new reception record: the unit timing ring starts again (with the record, not at each reconnection) */
  fun clearTiming() {
    timing = null
  }

  override fun keepKey(unit: AccessUnit, description: ResolvedDescription) {
    primer.keep(unit, description.description)
  }

  override fun reset() {
    primer.clear()
    queue.clear()
    queue.net = null
    // A new stream for the jitter buffer; the counters and the timing ring go on until the controller clears them
    synchronized(jitter) { jitter.reset() }
    smoothing.pause()
    handler?.post {
      releaseCodec()
      policyMade = false
      failure = null
      failedForSession = false
      publishStatus()
    }
  }

  override fun status(): DecoderStatus = currentStatus.copy(unitsDropped = queue.droppedUnits)

  /** A page session starts the link or plays a capture: units are taken again after a [shutdown] */
  fun open() {
    queue.open()
  }

  /** The pilot's choice on the page; the running codec stops and the next unit starts one of that kind */
  fun setChoice(next: DecoderChoice) {
    choice = next
    handler?.post {
      releaseCodec()
      // Chosen on the page: the wait for the new decoder is no freeze
      smoothing.pause()
      policyMade = false
      failure = null
      failedForSession = false
      publishStatus()
    }
  }

  /**
   * The surface of the video view that should show the picture, or null when none is shown. The switch is done before
   * this returns: a view destroys its surface right after telling, whether the picture goes to the parking surface or
   * to another view that still has one (the panel under a full screen route that closes).
   */
  fun setViewSurface(surface: Surface?) {
    viewSurface = surface
    val target = handler ?: return
    if (target.looper.thread === Thread.currentThread()) {
      switchOutput()
      return
    }
    val done = CountDownLatch(1)
    val posted = target.post {
      switchOutput()
      done.countDown()
    }
    if (posted) {
      runCatching { done.await(SURFACE_SWITCH_TIMEOUT_MS, TimeUnit.MILLISECONDS) }
    }
  }

  /**
   * The page session ended: the codec, the parking surface and the thread go, and the feed stays closed until [open],
   * so that a unit still on its way cannot make a thread and a codec again.
   */
  fun shutdown() {
    val target = queue.close() ?: return
    val current = target.looper
    target.post {
      releaseCodec()
      runCatching { parkingSurface?.release() }
      runCatching { parkingTexture?.release() }
      parkingSurface = null
      parkingTexture = null
      policyMade = false
      failure = null
      failedForSession = false
      currentStatus = DecoderStatus(choice = choice)
      current.quitSafely()
    }
  }

  /** Called by the queue under its lock, only while it is open: no thread is made after a [shutdown] */
  private fun makeThread(): Handler {
    val created = HandlerThread("DjiLinkDecoder").also { it.start() }
    return Handler(created.looper)
  }

  private fun drainNow() {
    while (true) {
      if (queue.takeFlush()) {
        flushCodec()
        continue
      }
      if (queue.takeNet()) {
        // The safety net of a paced reception: units went, the codec keeps its references, the next unit follows a gap
        smoothing.onSafetyNet(clockNs())
        gapPending = true
        Log.i(TAG, "this device could not keep up: queued units dropped, the decoder goes on")
      }
      val next = queue.peek() ?: return
      val (unit, resolved) = next
      if (failedForSession) {
        queue.remove(next)
        continue
      }
      ensurePolicy(resolved.description)
      if (codec == null || policy.mustReconfigure(configured, resolved.description)) {
        if (!startCodec(resolved.description)) {
          queue.remove(next)
          continue
        }
      }
      if (policy.beforeQueue(unit.isKey) == PolicyAction.SWITCH_TO_HARDWARE) {
        Log.i(TAG, "a key picture: the hardware decoder starts again from it")
        if (!startCodec(resolved.description)) {
          queue.remove(next)
          continue
        }
      }
      val current = codec ?: return
      val stamp = unit.relay
      if (stamp != null) {
        // A paced unit waits for its time to go to the decoder; the units after it are due later
        val waitNs = stamp.feedAtNs - clockNs()
        if (waitNs > FEED_SLACK_NS) {
          handler?.let {
            it.removeCallbacks(drain)
            it.postDelayed(drain, (waitNs + 999_999) / 1_000_000)
          }
          return
        }
      }
      if (DecoderPolicy.flushBeforeKey(stamp != null, unit.isKey, fedSets, resolved.description)) {
        // A switch between the drone's stream and the phone's steady stream: the decoder starts on this key picture
        flushForSwitch(resolved.description)
        continue
      }
      val index = freeInputs.removeFirstOrNull() ?: return
      // An index announced before a flush or a restart is no longer valid: it is dropped, never the unit
      val buffer = runCatching { current.getInputBuffer(index) }.getOrNull() ?: continue
      val primed = primer.before(unit, resolved.description)
        ?.let { queuePrimer(current, index, buffer, it, beforeUs = unit.lastArrivalNs / 1_000 - 1) }
      if (primed != null) {
        // The unit itself waits for the next input buffer
        if (primed) {
          fedSets = resolved.description
          if (primer.lastWasAfterBreak) {
            smoothing.onPrimerAfterBreak()
          }
          afterQueue(policy.afterQueue(isKey = true, nowNs = clockNs()), resolved.description)
        }
        publishStatus()
        continue
      }
      queue.remove(next)
      val pts = queueUnit(current, index, buffer, unit)
      if (pts != null && unit.isKey) {
        fedSets = resolved.description
      }
      // Units the phone dropped for this device (BREAK), the safety net, or a picture lost on the radio: no flush, the
      // decoder goes on, and the kept key picture waits
      val gapBefore = gapPending || (stamp != null && (stamp.flags and RelayWire.UNIT_BREAK) != 0)
      gapPending = false
      if (pts != null) {
        primer.onQueuedUnit(unit, unit.lastArrivalNs, pts, gapBefore)
      } else {
        primer.onQueued(unit.isKey)
      }
      afterQueue(policy.afterQueue(unit.isKey, clockNs()), resolved.description)
      publishStatus()
    }
  }

  /** Does what the policy said after a unit went in, and remembers a decoder that gave no picture */
  private fun afterQueue(action: PolicyAction, description: StreamDescription) {
    val gaveNothing = policy.takeGaveNoPicture()
    for (name in gaveNothing) {
      Log.i(TAG, "decoder $name gave no picture although it had a key picture: remembered on this device")
      runCatching { memory?.remember(name) }
    }
    when (action) {
      PolicyAction.SWITCH_TO_SOFTWARE, PolicyAction.SWITCH_DECODER -> {
        Log.i(TAG, "no picture from $codecName: ${policy.current?.name} takes over (${policy.lastSwitchReason})")
        startCodec(description)
      }
      else -> if (gaveNothing.isNotEmpty()) {
        Log.i(TAG, "no other decoder is left: $codecName stays")
      }
    }
  }

  /**
   * The kept key unit into [buffer], ahead of the unit waiting: true once queued, false when the codec refused it (the
   * index is spent), null when it does not fit and the waiting unit takes the buffer
   */
  private fun queuePrimer(
    current: MediaCodec,
    index: Int,
    buffer: ByteBuffer,
    unit: AccessUnit,
    beforeUs: Long,
  ): Boolean? {
    if (buffer.capacity() < unit.size) {
      return null
    }
    buffer.clear()
    buffer.put(unit.bytes)
    // Just before the waiting unit, and after everything queued so far
    val pts = if (lastPtsUs == Long.MIN_VALUE) maxOf(beforeUs, 0) else maxOf(beforeUs, lastPtsUs + 1)
    val queued = runCatching { current.queueInputBuffer(index, 0, unit.size, pts, MediaCodec.BUFFER_FLAG_KEY_FRAME) }
    if (queued.isFailure) {
      // The index is spent either way; the waiting unit goes with the next one
      statistics.onError()
      return false
    }
    lastPtsUs = pts
    primerPts = pts
    primersQueued += 1
    Log.i(TAG, "no picture yet and no key picture since the start: the key picture kept from earlier goes in")
    return true
  }

  private fun ensurePolicy(description: StreamDescription) {
    if (policyMade) {
      return
    }
    val candidates = HevcDecoders.list(description.info.codedWidth, description.info.codedHeight)
    val remembered = memory
    policy = DecoderPolicy(
      choice = choice,
      candidates = candidates,
      gaveNoPictureBefore = { name ->
        remembered != null && runCatching { remembered.gaveNoPicture(name) }.getOrDefault(false)
      },
    )
    if (policy.skippedAtStart.isNotEmpty()) {
      Log.i(TAG, "skipped, no picture on this device before: ${policy.skippedAtStart.joinToString()}")
    }
    policyMade = true
  }

  /** Queues [unit] into [buffer]; returns the presentation time given, null when it did not go in */
  private fun queueUnit(current: MediaCodec, index: Int, buffer: ByteBuffer, unit: AccessUnit): Long? {
    val now = clockNs()
    if (buffer.capacity() < unit.size) {
      // A unit the buffer cannot hold is lost, and said so: the buffer goes back empty
      statistics.onError()
      runCatching { current.queueInputBuffer(index, 0, 0, 0, 0) }
      return null
    }
    buffer.clear()
    buffer.put(unit.bytes)
    var pts = unit.lastArrivalNs / 1_000
    if (pts <= lastPtsUs) {
      pts = lastPtsUs + 1
    }
    lastPtsUs = pts
    val flags = if (unit.isKey) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
    val queued = runCatching { current.queueInputBuffer(index, 0, unit.size, pts, flags) }
    if (queued.isFailure) {
      statistics.onError()
      return null
    }
    if (unit.isKey) {
      keySinceStart = true
    }
    val stamp = unit.relay
    queuedAt[pts] = InFlight(now, stamp)
    while (queuedAt.size > 64) {
      queuedAt.remove(queuedAt.keys.first())
    }
    stamp?.let { timing?.onFed(it.timingIndex, now) }
    statistics.onQueued(now - unit.lastArrivalNs, now)
    return pts
  }

  /** Releases whatever runs and starts the decoder the policy holds, or the next ones; false when none would start */
  private fun startCodec(description: StreamDescription): Boolean {
    releaseCodec()
    while (true) {
      val candidate = policy.current
      if (candidate != null && configure(candidate, description)) {
        return true
      }
      if (candidate == null || policy.onCandidateRefused() == PolicyAction.FAIL) {
        failure = if (candidate == null) "no-decoder" else "configuration-refused"
        failedForSession = true
        Log.w(TAG, "no H.265 decoder would start: $failure")
        publishStatus()
        onChange()
        return false
      }
    }
  }

  private fun configure(candidate: DecoderCandidate, description: StreamDescription): Boolean {
    val target = handler ?: return false
    val surface = viewSurface ?: parking()
    // 0: the Qualcomm keys; 1: realtime priority, low latency when reported, and the operating rate of a flight;
    // 2: the same without the operating rate; 3: plain
    val levels = if (HevcDecoders.isQualcomm(candidate.name)) listOf(0, 1, 2, 3) else listOf(1, 2, 3)
    for (level in levels) {
      val format = MediaFormat.createVideoFormat(
        HevcDecoders.MIME,
        description.info.codedWidth,
        description.info.codedHeight,
      )
      format.setByteBuffer("csd-0", ByteBuffer.wrap(description.configuration()))
      format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, MAX_INPUT_SIZE)
      var asksLowLatency = false
      var rate: Int? = null
      if (level <= 2) {
        format.setInteger(MediaFormat.KEY_PRIORITY, 0)
        if (candidate.lowLatencyFeature && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
          format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
          asksLowLatency = true
        }
      }
      if (level == 1) {
        // Public MediaFormat key: a decoder told that it must keep 60 pictures a second, not 30, from the take off
        format.setInteger(MediaFormat.KEY_OPERATING_RATE, OPERATING_RATE)
        rate = OPERATING_RATE
      }
      if (level == 0) {
        format.setInteger(QTI_LOW_LATENCY, 1)
        format.setInteger(QTI_PICTURE_ORDER, 1)
        // Public MediaFormat key: clock the decoder for its highest rate rather than for 30 pictures per second (the
        // open source ALVR client does the same on the Quest); a decoder that refuses it falls through to level 1
        format.setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
        rate = Short.MAX_VALUE.toInt()
        asksLowLatency = true
      }
      val created = runCatching { MediaCodec.createByCodecName(candidate.name) }.getOrNull() ?: return false
      generation += 1
      created.setCallback(Callback(generation), target)
      val accepted = runCatching { created.configure(format, surface, null, 0) }.isSuccess &&
        runCatching { created.start() }.isSuccess
      if (!accepted) {
        runCatching { created.release() }
        continue
      }
      codec = created
      codecName = candidate.name
      codecKind = if (candidate.hardware) DecoderKind.HARDWARE else DecoderKind.SOFTWARE
      lowLatency = asksLowLatency
      lowLatencyFeature = candidate.lowLatencyFeature
      operatingRate = rate
      configurationLevel = level
      configured = description
      fedSets = description
      outputSurface = surface
      freeInputs.clear()
      queuedAt.clear()
      release.clear()
      rendered.clear()
      heldOutput = null
      pacer.reset()
      lastOutputNs = null
      // The time the platform rendered each picture at, for the freezes (Android 6 and later)
      val owner = generation
      runCatching {
        created.setOnFrameRenderedListener({ _, pts, nanoTime -> onRendered(owner, pts, nanoTime) }, target)
      }
      failure = null
      startedAtNs = clockNs()
      keySinceStart = false
      primerPts = null
      primer.onCodecStarted()
      policy.onStarted()
      Log.i(TAG, "decoder ${candidate.name} started, configuration level $level, low latency $asksLowLatency")
      publishStatus()
      onChange()
      return true
    }
    return false
  }

  private fun releaseCodec() {
    val current = codec ?: return
    codec = null
    generation += 1
    runCatching { current.stop() }
    runCatching { current.release() }
    codecName = null
    codecKind = null
    operatingRate = null
    configurationLevel = null
    configured = null
    fedSets = null
    freeInputs.clear()
    queuedAt.clear()
    // The indices held belong to the codec that goes
    release.clear()
    rendered.clear()
    heldOutput = null
    handler?.removeCallbacks(renderHeld)
    handler?.removeCallbacks(releaseHeld)
    pacer.reset()
    // No pause of the freezes: a restart of the decoder in a stream that goes on leaves the picture as it was, and the
    // wait until the new decoder shows counts as a freeze (p2/review-relay-2026-10-25.md M2)
    startedAtNs = null
    keySinceStart = false
    primerPts = null
  }

  /**
   * A relayed key picture with other parameter sets at the same size (p2/owner-feedback-2026-10-25.md 2,
   * p2/review-bandwidth-2026-10-25.md M2): the codec is flushed and starts on it with its sets in band, nothing of the
   * other stream left in it. Not an overrun, not counted as one.
   */
  private fun flushForSwitch(description: StreamDescription) {
    val current = codec ?: return
    runCatching { current.flush() }
    freeInputs.clear()
    queuedAt.clear()
    release.clear()
    rendered.clear()
    heldOutput = null
    handler?.removeCallbacks(renderHeld)
    handler?.removeCallbacks(releaseHeld)
    pacer.reset()
    primerPts = null
    runCatching { current.start() }
    primer.onCodecStarted()
    policy.onStarted()
    fedSets = description
    switchFlushes += 1
    Log.i(TAG, "a relayed key picture with other parameter sets: the decoder flushed, it starts on it")
  }

  /** Flushes before a relayed key picture with other parameter sets, since the page opened */
  @Volatile
  var switchFlushes = 0L
    private set

  /** Rule 4 of the policy: the codec and the queue are emptied and decoding goes on with the next unit */
  private fun flushCodec() {
    statistics.onOverrun()
    val current = codec ?: return
    runCatching { current.flush() }
    freeInputs.clear()
    queuedAt.clear()
    // A flush returns every output buffer to the codec: the indices held are no longer ours
    release.clear()
    rendered.clear()
    heldOutput = null
    handler?.removeCallbacks(renderHeld)
    handler?.removeCallbacks(releaseHeld)
    pacer.reset()
    primerPts = null
    // In asynchronous mode a flushed codec asks for input again only once it is started again
    runCatching { current.start() }
    primer.onCodecStarted()
    policy.onFlushed()
    Log.i(TAG, "the decoder could not keep up: flushed")
  }

  /** Every half second: the lead given to the jitter buffer follows the decode times, and the display rate the stream */
  private fun updateLead(nowNs: Long) {
    if (nowNs < nextLeadNs) {
      return
    }
    nextLeadNs = nowNs + 500_000_000L
    val p95 = statistics.numbers(nowNs).decodeP95Ms?.let { (it * 1e6).toLong() }
    val period = synchronized(jitter) { jitter.periodNs }
    decodeLeadNs = PacedRender.lead(p95, period)
    askFrameRate()
  }

  private fun parking(): Surface {
    parkingSurface?.let { return it }
    val texture = SurfaceTexture(false).apply { setDefaultBufferSize(PARKING_WIDTH, PARKING_HEIGHT) }
    val surface = Surface(texture)
    parkingTexture = texture
    parkingSurface = surface
    return surface
  }

  /** Moves the output to the view's surface, or to the parking surface, keeping the decoder and its references */
  private fun switchOutput() {
    val current = codec
    val target = viewSurface ?: parking()
    if (current == null || outputSurface === target) {
      publishStatus()
      return
    }
    heldOutput?.let { index ->
      runCatching { current.releaseOutputBuffer(index, false) }
      statistics.onDroppedAtDisplay()
    }
    heldOutput = null
    handler?.removeCallbacks(renderHeld)
    dropHeld(current)
    pacer.reset()
    // A freeze under way while the view showed it counts up to now
    smoothing.closeView(clockNs())
    val switched = runCatching { current.setOutputSurface(target) }.isSuccess
    if (switched) {
      outputSurface = target
      frameRateAsked = null
      askFrameRate()
    } else {
      // A decoder that refuses the switch is started again on the new surface; the picture builds up again
      Log.i(TAG, "the decoder refused to switch surfaces: started again")
      configured?.let { startCodec(it) }
    }
    publishStatus()
    onChange()
  }

  private fun renderHeldNow() {
    val current = codec ?: return
    val index = heldOutput ?: return
    if (!pacer.onTimer(clockNs())) {
      return
    }
    heldOutput = null
    if (runCatching { current.releaseOutputBuffer(index, System.nanoTime()) }.isSuccess) {
      statistics.onShown(clockNs())
    }
  }

  /** Outputs held for a paced display, released unseen: a surface switch */
  private fun dropHeld(current: MediaCodec) {
    for (output in release.clear()) {
      runCatching { current.releaseOutputBuffer(output.index, false) }
      timing?.onResult(output.stamp.timingIndex, UnitTimingRing.PARKED)
    }
    handler?.removeCallbacks(releaseHeld)
  }

  /** A time of the pipeline clock on the System.nanoTime clock, which the surface reads */
  private fun toSurfaceClock(ns: Long): Long = System.nanoTime() + (ns - clockNs())

  /** Releases the decoded pictures whose time came, as [PacedRelease] says; a picture still early sets the timer */
  private fun releaseHeldNow() {
    val current = codec ?: return
    val now = clockNs()
    val period = synchronized(jitter) { jitter.periodNs }
    releaseSteps.clear()
    val wakeNs = release.release(now, period, releaseSteps)
    for (step in releaseSteps) {
      when (step) {
        is PacedRelease.Step.Skip -> skipOutput(current, step.item.index, step.item.stamp)
        is PacedRelease.Step.Render -> renderAt(current, step.item.index, step.item.pts, step.item.stamp, step.atNs)
      }
    }
    releaseSteps.clear()
    handler?.let {
      it.removeCallbacks(releaseHeld)
      if (wakeNs != null) {
        it.postDelayed(releaseHeld, ((wakeNs - now + 999_999) / 1_000_000).coerceAtLeast(1))
      }
    }
  }

  private fun skipOutput(current: MediaCodec, index: Int, stamp: RelayStamp) {
    runCatching { current.releaseOutputBuffer(index, false) }
    statistics.onDroppedAtDisplay()
    smoothing.onSkip()
    timing?.onResult(stamp.timingIndex, UnitTimingRing.SKIPPED)
  }

  private fun renderAt(current: MediaCodec, index: Int, pts: Long, stamp: RelayStamp, atNs: Long) {
    if (runCatching { current.releaseOutputBuffer(index, toSurfaceClock(atNs)) }.isFailure) {
      return
    }
    statistics.onShown(clockNs())
    smoothing.onShown(atNs, stamp, phoneToLocal(stamp.phoneReceiveNs))
    timing?.onResult(stamp.timingIndex, UnitTimingRing.SHOWN, atNs)
    rendered[pts] = stamp
    while (rendered.size > RENDERED_KEPT) {
      rendered.remove(rendered.keys.first())
    }
  }

  /** The platform rendered the picture of [pts] at [nanoTime] (System.nanoTime) */
  private fun onRendered(owner: Int, pts: Long, nanoTime: Long) {
    if (owner != generation) {
      return
    }
    val stamp = rendered.remove(pts) ?: return
    val atNs = nanoTime - System.nanoTime() + clockNs()
    smoothing.onRendered(atNs, stamp.sourceNsOrArrival())
    timing?.onRendered(stamp.timingIndex, atNs)
  }

  /**
   * The display of a paced reception is asked to follow the stream's rate where it can switch without a blank (Android
   * 12 and later): 60 pictures a second in flight, 30 on the ground
   */
  private fun askFrameRate() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || queue.net == null) {
      return
    }
    val surface = viewSurface ?: return
    val period = synchronized(jitter) { jitter.periodNs }
    val rate = if (period < 25_000_000L) 60 else 30
    if (rate == frameRateAsked) {
      return
    }
    frameRateAsked = rate
    runCatching {
      surface.setFrameRate(
        rate.toFloat(),
        Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE,
        Surface.CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS,
      )
    }
  }

  private fun publishStatus() {
    currentStatus = DecoderStatus(
      name = codecName,
      kind = codecKind,
      lowLatency = lowLatency,
      lowLatencyFeature = lowLatencyFeature,
      operatingRate = operatingRate,
      configurationLevel = configurationLevel,
      frameRateAsked = frameRateAsked,
      switches = policy.switches,
      choice = choice,
      running = codec != null,
      failure = failure,
      parked = viewSurface == null || outputSurface === parkingSurface,
      lastSwitchReason = policy.lastSwitchReason,
      startedAtNs = startedAtNs,
      keySinceStart = keySinceStart,
      skippedAtStart = policy.skippedAtStart,
      primers = primersQueued,
    )
  }

  private inner class Callback(private val owner: Int) : MediaCodec.Callback() {
    override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
      if (owner != generation) {
        return
      }
      freeInputs.addLast(index)
      drainNow()
    }

    override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
      if (owner != generation) {
        return
      }
      if (primerPts != null && info.presentationTimeUs == primerPts) {
        // The picture of the kept key unit: proof that the decoder decodes, never shown nor counted as a live picture
        primerPts = null
        policy.onOutput()
        runCatching { codec.releaseOutputBuffer(index, false) }
        publishStatus()
        return
      }
      primer.onOutput(info.presentationTimeUs)
      val now = clockNs()
      val flight = queuedAt.remove(info.presentationTimeUs)
      val decodeNs = flight?.let { now - it.fedNs }
      statistics.onDecoded(decodeNs, now)
      policy.onOutput()
      val stamp = flight?.stamp
      val previousOutput = lastOutputNs
      if (flight != null && previousOutput != null && now - previousOutput > PacedRender.STALL_NS &&
        now - flight.fedNs > PacedRender.STALL_NS
      ) {
        // Nothing came out for 200 ms while this unit was in the decoder
        smoothing.onStall()
      }
      lastOutputNs = now
      stamp?.let { timing?.onOutput(it.timingIndex, now) }
      if (stamp != null) {
        updateLead(now)
      }
      val parked = viewSurface == null || outputSurface === parkingSurface
      if (parked) {
        runCatching { codec.releaseOutputBuffer(index, false) }
        if (stamp != null) {
          smoothing.onParked(now)
          timing?.onResult(stamp.timingIndex, UnitTimingRing.PARKED)
        }
        publishStatus()
        return
      }
      if (stamp != null) {
        release.add(Held(index, info.presentationTimeUs, stamp), stamp.displayNs)
        smoothing.onHeld(release.size)
        releaseHeldNow()
        publishStatus()
        return
      }
      when (val decision = pacer.onOutput(now)) {
        DisplayPacer.Decision.RenderNow -> {
          // An explicit time on the surface's clock: the next refresh, whatever the presentation time says
          if (runCatching { codec.releaseOutputBuffer(index, System.nanoTime()) }.isSuccess) {
            statistics.onShown(clockNs())
          }
        }
        is DisplayPacer.Decision.Hold -> {
          if (decision.dropHeld) {
            heldOutput?.let { held ->
              runCatching { codec.releaseOutputBuffer(held, false) }
              statistics.onDroppedAtDisplay()
            }
          }
          heldOutput = index
          handler?.let { target ->
            target.removeCallbacks(renderHeld)
            target.postDelayed(renderHeld, ((decision.atNs - now) / 1_000_000).coerceAtLeast(0))
          }
        }
      }
      publishStatus()
    }

    override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
      if (owner != generation) {
        return
      }
      statistics.onError()
      Log.w(TAG, "decoder error ${error.errorCode}, recoverable ${error.isRecoverable}, transient ${error.isTransient}")
      val description = configured
      when (policy.onError(error.isRecoverable, error.isTransient)) {
        PolicyAction.NONE -> Unit
        PolicyAction.RESTART_SAME, PolicyAction.SWITCH_TO_SOFTWARE, PolicyAction.SWITCH_TO_HARDWARE,
        PolicyAction.SWITCH_DECODER -> {
          if (description != null) {
            startCodec(description)
          }
        }
        PolicyAction.FAIL -> {
          releaseCodec()
          failure = "error-${error.errorCode}"
          failedForSession = true
        }
      }
      publishStatus()
      onChange()
    }

    override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
      if (owner != generation) {
        return
      }
      Log.i(TAG, "output format $format")
    }
  }
}
