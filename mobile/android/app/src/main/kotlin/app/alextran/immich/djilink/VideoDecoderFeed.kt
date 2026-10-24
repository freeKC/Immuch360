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
 * [W] is the handler of the decoder thread; it is a type parameter so that the rules are unit tested without Android.
 */
class DecoderQueue<T : Any, W : Any>(private val bound: Int) {
  private val lock = Any()
  private val pending = ArrayDeque<T>()
  private var overflow = false
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
   * Queues [item] and returns the worker to wake, made by [make] when there is none yet. While closed, returns null:
   * the item is dropped and no worker is made.
   */
  fun offer(item: T, make: () -> W): W? = synchronized(lock) {
    if (closed) {
      return null
    }
    pending.addLast(item)
    if (pending.size > bound) {
      while (pending.size > bound) {
        pending.removeFirst()
        dropped += 1
      }
      overflow = true
    }
    worker ?: make().also { worker = it }
  }

  /** For the decoder thread: true once after an overflow, with the units still waiting dropped and counted */
  fun takeFlush(): Boolean = synchronized(lock) {
    if (!overflow) {
      return false
    }
    overflow = false
    dropped += pending.size
    pending.clear()
    true
  }

  /** The oldest unit, left in the queue until [remove] */
  fun peek(): T? = synchronized(lock) { pending.firstOrNull() }

  /** Takes [item] out if it is still the oldest unit: the bound, a flush or a reset may have dropped it meanwhile */
  fun remove(item: T) = synchronized(lock) {
    if (pending.firstOrNull() === item) {
      pending.removeFirst()
    }
  }

  /** A new source: the waiting units go, and the count of drops starts again */
  fun clear() = synchronized(lock) {
    pending.clear()
    overflow = false
    dropped = 0
  }

  /** Nothing is queued and no worker is made until [open]; returns the worker to shut down, which the queue forgets */
  fun close(): W? = synchronized(lock) {
    closed = true
    pending.clear()
    overflow = false
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
  }

  /**
   * Units waiting for an input buffer, and the handler of the decoder thread they wake: the thread is made by the first
   * unit while the queue is open and ended by [shutdown]
   */
  private val queue = DecoderQueue<Pair<AccessUnit, ResolvedDescription>, Handler>(DecoderPolicy.MAX_QUEUED_UNITS)

  private val handler: Handler? get() = queue.currentWorker

  @Volatile
  private var viewSurface: Surface? = null

  @Volatile
  private var choice = DecoderChoice.AUTOMATIC

  @Volatile
  private var currentStatus = DecoderStatus()

  /** The last key unit, to start a codec with; kept from the threads that submit, used by the decoder thread */
  private val primer = KeyPrimer()

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
  private val queuedAt = LinkedHashMap<Long, Long>()
  private var lastPtsUs = Long.MIN_VALUE
  private var parkingTexture: SurfaceTexture? = null
  private var parkingSurface: Surface? = null
  private var outputSurface: Surface? = null
  private var failure: String? = null
  private var failedForSession = false
  private var startedAtNs: Long? = null
  private var keySinceStart = false

  /** The presentation time of the kept key unit queued to start the running codec, until its picture comes out */
  private var primerPts: Long? = null
  private var primersQueued = 0

  private val drain = Runnable { drainNow() }
  private val renderHeld = Runnable { renderHeldNow() }

  override fun submit(unit: AccessUnit, description: ResolvedDescription) {
    primer.keep(unit, description.description)
    // The bound is a constant of the policy; the policy object itself belongs to the decoder thread. A closed feed
    // drops the unit and makes no thread.
    val target = queue.offer(unit to description, ::makeThread) ?: return
    target.post(drain)
  }

  override fun keepKey(unit: AccessUnit, description: ResolvedDescription) {
    primer.keep(unit, description.description)
  }

  override fun reset() {
    primer.clear()
    queue.clear()
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
      val index = freeInputs.removeFirstOrNull() ?: return
      // An index announced before a flush or a restart is no longer valid: it is dropped, never the unit
      val buffer = runCatching { current.getInputBuffer(index) }.getOrNull() ?: continue
      val primed = primer.before(unit, resolved.description)
        ?.let { queuePrimer(current, index, buffer, it, beforeUs = unit.lastArrivalNs / 1_000 - 1) }
      if (primed != null) {
        // The unit itself waits for the next input buffer
        if (primed) {
          afterQueue(policy.afterQueue(isKey = true, nowNs = clockNs()), resolved.description)
        }
        publishStatus()
        continue
      }
      queue.remove(next)
      queueUnit(current, index, buffer, unit)
      primer.onQueued(unit.isKey)
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

  private fun queueUnit(current: MediaCodec, index: Int, buffer: ByteBuffer, unit: AccessUnit) {
    val now = clockNs()
    if (buffer.capacity() < unit.size) {
      // A unit the buffer cannot hold is lost, and said so: the buffer goes back empty
      statistics.onError()
      runCatching { current.queueInputBuffer(index, 0, 0, 0, 0) }
      return
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
      return
    }
    if (unit.isKey) {
      keySinceStart = true
    }
    queuedAt[pts] = now
    while (queuedAt.size > 64) {
      queuedAt.remove(queuedAt.keys.first())
    }
    statistics.onQueued(now - unit.lastArrivalNs, now)
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
    val levels = if (HevcDecoders.isQualcomm(candidate.name)) listOf(0, 1, 2) else listOf(1, 2)
    for (level in levels) {
      val format = MediaFormat.createVideoFormat(
        HevcDecoders.MIME,
        description.info.codedWidth,
        description.info.codedHeight,
      )
      format.setByteBuffer("csd-0", ByteBuffer.wrap(description.configuration()))
      format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, MAX_INPUT_SIZE)
      var asksLowLatency = false
      if (level <= 1) {
        format.setInteger(MediaFormat.KEY_PRIORITY, 0)
        if (candidate.lowLatencyFeature && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
          format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
          asksLowLatency = true
        }
      }
      if (level == 0) {
        format.setInteger(QTI_LOW_LATENCY, 1)
        format.setInteger(QTI_PICTURE_ORDER, 1)
        // Public MediaFormat key: clock the decoder for its highest rate rather than for 30 pictures per second (the
        // open source ALVR client does the same on the Quest); a decoder that refuses it falls through to level 1
        format.setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
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
      configured = description
      outputSurface = surface
      freeInputs.clear()
      queuedAt.clear()
      heldOutput = null
      pacer.reset()
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
    configured = null
    freeInputs.clear()
    queuedAt.clear()
    heldOutput = null
    handler?.removeCallbacks(renderHeld)
    pacer.reset()
    startedAtNs = null
    keySinceStart = false
    primerPts = null
  }

  /** Rule 4 of the policy: the codec and the queue are emptied and decoding goes on with the next unit */
  private fun flushCodec() {
    statistics.onOverrun()
    val current = codec ?: return
    runCatching { current.flush() }
    freeInputs.clear()
    queuedAt.clear()
    heldOutput = null
    handler?.removeCallbacks(renderHeld)
    pacer.reset()
    primerPts = null
    // In asynchronous mode a flushed codec asks for input again only once it is started again
    runCatching { current.start() }
    primer.onCodecStarted()
    policy.onFlushed()
    Log.i(TAG, "the decoder could not keep up: flushed")
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
    pacer.reset()
    val switched = runCatching { current.setOutputSurface(target) }.isSuccess
    if (switched) {
      outputSurface = target
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
    if (runCatching { current.releaseOutputBuffer(index, true) }.isSuccess) {
      statistics.onShown(clockNs())
    }
  }

  private fun publishStatus() {
    currentStatus = DecoderStatus(
      name = codecName,
      kind = codecKind,
      lowLatency = lowLatency,
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
      primer.onOutput()
      val now = clockNs()
      val decodeNs = queuedAt.remove(info.presentationTimeUs)?.let { now - it }
      statistics.onDecoded(decodeNs, now)
      policy.onOutput()
      val parked = viewSurface == null || outputSurface === parkingSurface
      if (parked) {
        runCatching { codec.releaseOutputBuffer(index, false) }
        publishStatus()
        return
      }
      when (val decision = pacer.onOutput(now)) {
        DisplayPacer.Decision.RenderNow -> {
          if (runCatching { codec.releaseOutputBuffer(index, true) }.isSuccess) {
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
