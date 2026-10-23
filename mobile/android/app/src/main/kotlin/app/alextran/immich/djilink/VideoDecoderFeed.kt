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
 * The decoder: a MediaCodec in asynchronous mode on its own "DjiLinkDecoder" thread, fed one access unit per input
 * buffer, rendering into the surface of the video view or, when no view is shown, into a parking surface whose
 * pictures are released unseen.
 *
 * It is a decoder fed by hand, not a player: there is no extractor for a raw elementary stream that arrives in
 * fragments over a cable, and no audio clock. Every decision that can be taken without a decoder is in
 * [DecoderPolicy] and [DisplayPacer], which are unit tested; this class does what they say and measures.
 *
 * Configuration, tried in this order until the decoder accepts: the stream description as csd-0 with a 1 MiB input
 * size, realtime priority, KEY_LOW_LATENCY when the decoder reports the feature, and the Qualcomm vendor keys on a
 * Qualcomm decoder only; the same without the vendor keys; the plain configuration. Which one was accepted is on the
 * page.
 *
 * Receive only: nothing here has a handle on the transport.
 */
class VideoDecoderFeed(
  private val statistics: VideoStatistics,
  private val onChange: () -> Unit = {},
  private val clockNs: () -> Long = { SystemClock.elapsedRealtimeNanos() },
) : DecoderSink {
  companion object {
    private const val TAG = "DjiLinkDecoder"
    const val MAX_INPUT_SIZE = 1024 * 1024
    private const val QTI_LOW_LATENCY = "vendor.qti-ext-dec-low-latency.enable"
    private const val QTI_PICTURE_ORDER = "vendor.qti-ext-dec-picture-order.enable"
    private const val SURFACE_SWITCH_TIMEOUT_MS = 500L
    private const val PARKING_WIDTH = 1920
    private const val PARKING_HEIGHT = 1080
  }

  private val lock = Any()

  /** Units waiting for an input buffer, under [lock] */
  private val pending = ArrayDeque<Pair<AccessUnit, ResolvedDescription>>()
  private var overflow = false

  @Volatile
  private var thread: HandlerThread? = null

  @Volatile
  private var handler: Handler? = null

  @Volatile
  private var viewSurface: Surface? = null

  @Volatile
  private var choice = DecoderChoice.AUTOMATIC

  @Volatile
  private var currentStatus = DecoderStatus()

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

  private val drain = Runnable { drainNow() }
  private val renderHeld = Runnable { renderHeldNow() }

  override fun submit(unit: AccessUnit, description: ResolvedDescription) {
    val target = ensureThread()
    synchronized(lock) {
      pending.addLast(unit to description)
      // The bound is a constant of the policy; the policy object itself belongs to the decoder thread
      if (pending.size > DecoderPolicy.MAX_QUEUED_UNITS) {
        overflow = true
      }
    }
    target.post(drain)
  }

  override fun reset() {
    synchronized(lock) {
      pending.clear()
      overflow = false
    }
    handler?.post {
      releaseCodec()
      policyMade = false
      failure = null
      failedForSession = false
      publishStatus()
    }
  }

  override fun status(): DecoderStatus = currentStatus

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

  /** The page session ended: the codec, the parking surface and the thread go */
  fun shutdown() {
    synchronized(lock) {
      pending.clear()
      overflow = false
    }
    val current = thread ?: return
    val target = handler
    thread = null
    handler = null
    target?.post {
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

  private fun ensureThread(): Handler {
    handler?.let { return it }
    synchronized(lock) {
      handler?.let { return it }
      val created = HandlerThread("DjiLinkDecoder").also { it.start() }
      val made = Handler(created.looper)
      thread = created
      handler = made
      return made
    }
  }

  private fun drainNow() {
    while (true) {
      val flush: Boolean
      val next: Pair<AccessUnit, ResolvedDescription>?
      synchronized(lock) {
        flush = overflow
        if (flush) {
          overflow = false
          pending.clear()
        }
        next = pending.firstOrNull()
      }
      if (flush) {
        flushCodec()
        continue
      }
      if (next == null) {
        return
      }
      val (unit, resolved) = next
      if (failedForSession) {
        synchronized(lock) { pending.removeFirstOrNull() }
        continue
      }
      ensurePolicy(resolved.description)
      if (codec == null || policy.mustReconfigure(configured, resolved.description)) {
        if (!startCodec(resolved.description)) {
          synchronized(lock) { pending.removeFirstOrNull() }
          continue
        }
      }
      if (policy.beforeQueue(unit.isKey) == PolicyAction.SWITCH_TO_HARDWARE) {
        Log.i(TAG, "a key picture: the hardware decoder starts again from it")
        if (!startCodec(resolved.description)) {
          synchronized(lock) { pending.removeFirstOrNull() }
          continue
        }
      }
      val current = codec ?: return
      val index = freeInputs.removeFirstOrNull() ?: return
      // An index announced before a flush or a restart is no longer valid: it is dropped, never the unit
      val buffer = runCatching { current.getInputBuffer(index) }.getOrNull() ?: continue
      synchronized(lock) { pending.removeFirstOrNull() }
      queueUnit(current, index, buffer, unit)
      if (policy.afterQueue(unit.isKey) == PolicyAction.SWITCH_TO_SOFTWARE) {
        Log.i(TAG, "no picture from the hardware decoder: the software decoder takes over (${policy.lastSwitchReason})")
        startCodec(resolved.description)
      }
      publishStatus()
    }
  }

  private fun ensurePolicy(description: StreamDescription) {
    if (policyMade) {
      return
    }
    val candidates = HevcDecoders.list(description.info.codedWidth, description.info.codedHeight)
    policy = DecoderPolicy(
      choice = choice,
      hardwareAvailable = candidates.any { it.hardware },
      softwareAvailable = candidates.any { !it.hardware },
    )
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

  /** Releases whatever runs and starts the decoder of the kind the policy holds; false when none would start */
  private fun startCodec(description: StreamDescription): Boolean {
    releaseCodec()
    while (true) {
      val wanted = policy.kind
      val candidates = HevcDecoders.list(description.info.codedWidth, description.info.codedHeight)
        .filter { (it.hardware && wanted == DecoderKind.HARDWARE) || (!it.hardware && wanted == DecoderKind.SOFTWARE) }
      for (candidate in candidates) {
        if (configure(candidate, description)) {
          return true
        }
      }
      if (policy.onKindUnavailable() != PolicyAction.SWITCH_TO_SOFTWARE) {
        failure = if (candidates.isEmpty()) "no-decoder" else "configuration-refused"
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
    // In asynchronous mode a flushed codec asks for input again only once it is started again
    runCatching { current.start() }
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
      statistics.onShown()
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
            statistics.onShown()
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
        PolicyAction.RESTART_SAME, PolicyAction.SWITCH_TO_SOFTWARE, PolicyAction.SWITCH_TO_HARDWARE -> {
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
