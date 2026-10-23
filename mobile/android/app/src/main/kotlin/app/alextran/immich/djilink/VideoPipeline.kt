package app.alextran.immich.djilink

/**
 * The live video path after the router: the access units of the video channel, the codec and the stream description,
 * then the decoder.
 *
 * ```
 * USB reader thread (or the player of a capture)
 *   EnvelopeDecoder . FrameRouter . AccessUnitAssembler . CodecDetector . VideoPipeline.onUnit
 *                                                                         | one unit at a time, under the page lock
 *                                                                         v
 *                                                       DecoderSink.submit: a bounded queue of units
 *                                                                         |
 * "DjiLinkDecoder" thread: ParameterSetStore . DecoderPolicy . MediaCodec . the surface of the video view
 * ```
 *
 * Everything here is receive only: nothing on this path has a handle on the transport. The pipeline itself is plain
 * Kotlin, so that it is unit tested with a sink of the test's own; [VideoDecoderFeed] is the sink with a decoder.
 */
enum class VideoState {
  /** No video unit has arrived */
  WAITING_FOR_VIDEO,

  /** Units arrive, and there is no stream description to configure a decoder with yet */
  WAITING_FOR_DESCRIPTION,

  /** The decoder joined a running stream: no key picture yet, the picture builds up */
  BUILDING,

  DECODING,

  /** Decoding goes on while no video view is shown */
  HIDDEN,

  /** The decoder failed; [VideoStats.failure] says why */
  FAILED,

  /** H.264 was recognised; it is not decoded in this stage */
  H264_NOT_DECODED,
}

/** What the decoder feed reports about itself */
data class DecoderStatus(
  val name: String? = null,
  val kind: DecoderKind? = null,
  val lowLatency: Boolean = false,
  val switches: Int = 0,
  val choice: DecoderChoice = DecoderChoice.AUTOMATIC,
  val running: Boolean = false,
  /** A short code: no decoder, configuration refused, decoder error and its code */
  val failure: String? = null,
  /** True while the decoder renders into a parking surface because no video view is shown */
  val parked: Boolean = true,
  /** The switch to software of rule 1 or 3, said on the page */
  val lastSwitchReason: DecoderPolicy.SwitchReason? = null,
  /** When the running codec was started, on the pipeline clock; null while none runs */
  val startedAtNs: Long? = null,
  /** Whether a key picture was queued since the running codec started */
  val keySinceStart: Boolean = false,
)

/** The receiving end of the units: the decoder feed, or a test's own */
interface DecoderSink {
  /** Takes one unit and the description to decode it with. Called on the reader thread: must return at once. */
  fun submit(unit: AccessUnit, description: ResolvedDescription)

  /** A new source (a replay starts or stops, a page session ends): the codec stops and the queue empties */
  fun reset()

  fun status(): DecoderStatus
}

/** The counters of the video panel, refreshed four times a second */
data class VideoStats(
  val state: VideoState,
  val failure: String?,
  val codec: VideoCodec,
  val codecEvidence: CodecEvidence,
  val width: Int?,
  val height: Int?,
  val profileName: String?,
  val highTier: Boolean?,
  val levelName: String?,
  val descriptionSource: DescriptionSource?,
  val decoder: DecoderStatus,
  val unitsIn: Long,
  val queued: Long,
  val decoded: Long,
  val shown: Long,
  val droppedAtDisplay: Long,
  val overruns: Long,
  val tooLarge: Long,
  val unitsWithoutDescription: Long,
  val errors: Long,
  val picturesPerSecond: Double,
  val megabitsPerSecond: Double,
  val decodeLastMs: Double?,
  val decodeMedianMs: Double?,
  val decodeP95Ms: Double?,
  val inProcessMedianMs: Double?,
  val inProcessP95Ms: Double?,
  /** From the first unit of the stream to the first picture out of the decoder */
  val firstPictureMs: Long?,
  val lostPictures: Long,
  val encoderRestarts: Long,
  val pictureCounters: Long,
  val keyPictures: Long,
  val keyPictureAgoMs: Long?,
  /** Time since the last picture came out of the decoder; null while none did */
  val lastOutputAgoMs: Long?,
)

/**
 * The counters of the video path, with their own lock: the reader thread, the decoder thread and the page each touch
 * them. Rates are over the last second, decode times over the last two seconds.
 */
class VideoStatistics {
  companion object {
    const val RATE_WINDOW_NS = 1_000_000_000L
    const val DECODE_WINDOW_NS = 2_000_000_000L
    private const val MAX_SAMPLES = 512
  }

  private val lock = Any()
  private val arrivals = ArrayDeque<LongArray>()
  private val decodeSamples = ArrayDeque<LongArray>()
  private val inProcessSamples = ArrayDeque<LongArray>()

  private var unitsIn = 0L
  private var queued = 0L
  private var decoded = 0L
  private var shown = 0L
  private var droppedAtDisplay = 0L
  private var overruns = 0L
  private var unitsWithoutDescription = 0L
  private var errors = 0L
  private var keyPictures = 0L
  private var lastKeyNs: Long? = null
  private var firstUnitNs: Long? = null
  private var firstPictureNs: Long? = null
  private var lastOutputNs: Long? = null
  private var lastDecodeNs: Long? = null
  var descriptionSource: DescriptionSource? = null
    get() = synchronized(lock) { field }
    set(value) = synchronized(lock) { field = value }
  var description: StreamDescription? = null
    get() = synchronized(lock) { field }
    set(value) = synchronized(lock) { field = value }

  fun onUnitIn(unit: AccessUnit, nowNs: Long) = synchronized(lock) {
    unitsIn += 1
    if (firstUnitNs == null) {
      firstUnitNs = nowNs
    }
    if (unit.isKey) {
      keyPictures += 1
      lastKeyNs = nowNs
    }
    arrivals.addLast(longArrayOf(nowNs, unit.size.toLong()))
    trim(arrivals, nowNs, RATE_WINDOW_NS)
  }

  fun onWithoutDescription() = synchronized(lock) { unitsWithoutDescription += 1 }

  /** A unit went into a decoder input buffer: [inProcessNs] is from its last fragment to here */
  fun onQueued(inProcessNs: Long, nowNs: Long) = synchronized(lock) {
    queued += 1
    inProcessSamples.addLast(longArrayOf(nowNs, inProcessNs))
    trim(inProcessSamples, nowNs, DECODE_WINDOW_NS)
  }

  /** A picture came out of the decoder, [decodeNs] after its unit was queued (null when that is not known) */
  fun onDecoded(decodeNs: Long?, nowNs: Long) = synchronized(lock) {
    decoded += 1
    lastOutputNs = nowNs
    if (firstPictureNs == null) {
      firstPictureNs = nowNs
    }
    if (decodeNs != null) {
      lastDecodeNs = decodeNs
      decodeSamples.addLast(longArrayOf(nowNs, decodeNs))
      trim(decodeSamples, nowNs, DECODE_WINDOW_NS)
    }
  }

  fun onShown() = synchronized(lock) { shown += 1 }

  fun onDroppedAtDisplay() = synchronized(lock) { droppedAtDisplay += 1 }

  fun onOverrun() = synchronized(lock) { overruns += 1 }

  fun onError() = synchronized(lock) { errors += 1 }

  /** True when a picture came out of the decoder less than [withinNs] ago */
  fun outputWithin(nowNs: Long, withinNs: Long): Boolean = synchronized(lock) {
    val last = lastOutputNs ?: return false
    nowNs - last < withinNs
  }

  fun reset() = synchronized(lock) {
    arrivals.clear()
    decodeSamples.clear()
    inProcessSamples.clear()
    unitsIn = 0
    queued = 0
    decoded = 0
    shown = 0
    droppedAtDisplay = 0
    overruns = 0
    unitsWithoutDescription = 0
    errors = 0
    keyPictures = 0
    lastKeyNs = null
    firstUnitNs = null
    firstPictureNs = null
    lastOutputNs = null
    lastDecodeNs = null
    descriptionSource = null
    description = null
  }

  internal data class Numbers(
    val unitsIn: Long,
    val queued: Long,
    val decoded: Long,
    val shown: Long,
    val droppedAtDisplay: Long,
    val overruns: Long,
    val unitsWithoutDescription: Long,
    val errors: Long,
    val picturesPerSecond: Double,
    val megabitsPerSecond: Double,
    val decodeLastMs: Double?,
    val decodeMedianMs: Double?,
    val decodeP95Ms: Double?,
    val inProcessMedianMs: Double?,
    val inProcessP95Ms: Double?,
    val firstPictureMs: Long?,
    val keyPictures: Long,
    val keyPictureAgoMs: Long?,
    val lastOutputAgoMs: Long?,
  )

  internal fun numbers(nowNs: Long): Numbers = synchronized(lock) {
    trim(arrivals, nowNs, RATE_WINDOW_NS)
    trim(decodeSamples, nowNs, DECODE_WINDOW_NS)
    trim(inProcessSamples, nowNs, DECODE_WINDOW_NS)
    val bytes = arrivals.sumOf { it[1] }
    val decodes = decodeSamples.map { it[1] }.sorted()
    val inProcess = inProcessSamples.map { it[1] }.sorted()
    Numbers(
      unitsIn = unitsIn,
      queued = queued,
      decoded = decoded,
      shown = shown,
      droppedAtDisplay = droppedAtDisplay,
      overruns = overruns,
      unitsWithoutDescription = unitsWithoutDescription,
      errors = errors,
      picturesPerSecond = arrivals.size.toDouble(),
      megabitsPerSecond = bytes * 8.0 / 1_000_000.0,
      decodeLastMs = lastDecodeNs?.let { it / 1e6 },
      decodeMedianMs = percentile(decodes, 0.5)?.let { it / 1e6 },
      decodeP95Ms = percentile(decodes, 0.95)?.let { it / 1e6 },
      inProcessMedianMs = percentile(inProcess, 0.5)?.let { it / 1e6 },
      inProcessP95Ms = percentile(inProcess, 0.95)?.let { it / 1e6 },
      firstPictureMs = firstPictureNs?.let { picture -> firstUnitNs?.let { (picture - it) / 1_000_000 } },
      keyPictures = keyPictures,
      keyPictureAgoMs = lastKeyNs?.let { (nowNs - it) / 1_000_000 },
      lastOutputAgoMs = lastOutputNs?.let { (nowNs - it) / 1_000_000 },
    )
  }

  private fun trim(samples: ArrayDeque<LongArray>, nowNs: Long, windowNs: Long) {
    while (samples.isNotEmpty() && (nowNs - samples.first()[0] > windowNs || samples.size > MAX_SAMPLES)) {
      samples.removeFirst()
    }
  }

  private fun percentile(sorted: List<Long>, fraction: Double): Long? {
    if (sorted.isEmpty()) {
      return null
    }
    val index = ((sorted.size - 1) * fraction).toInt().coerceIn(0, sorted.size - 1)
    return sorted[index]
  }
}

/**
 * Glue between the router and the decoder: counts every unit, follows the SEI picture counter, keeps the stream
 * description in the [store], and hands each unit with its description to the [sink]. H.264 is counted and not
 * decoded. Called under the page lock, on the reader thread or the player's.
 */
class VideoPipeline(
  val store: ParameterSetStore,
  private val sink: DecoderSink,
  val statistics: VideoStatistics = VideoStatistics(),
) {
  companion object {
    /** The decoder is said to have joined a running stream for this long after its first picture without a key one */
    const val BUILDING_NS = 5_000_000_000L
  }

  val pictureCounter = PictureCounterTracker()

  /** The video channel whose units are decoded: the first one that gave a unit */
  var primaryChannel: Int? = null
    private set
  var otherChannelUnits = 0L
    private set

  private var codec = VideoCodec.UNKNOWN
  private var evidence = CodecEvidence.NONE
  private var lastResolved: ResolvedDescription? = null

  /** One unit from the router, with the detector of its stream and the description the unit completed, if any */
  fun onUnit(unit: AccessUnit, detector: CodecDetector, fresh: StreamDescription?, nowNs: Long) {
    val primary = primaryChannel ?: unit.channel.also { primaryChannel = it }
    if (unit.channel != primary) {
      otherChannelUnits += 1
      return
    }
    statistics.onUnitIn(unit, nowNs)
    unit.pictureCounter?.let { pictureCounter.offer(it) }
    codec = detector.codec
    evidence = detector.evidence
    if (fresh != null) {
      store.onSessionDescription(fresh)
    }
    if (codec == VideoCodec.H264) {
      return
    }
    val resolved = store.resolve(detector.showsH265Signature)
    if (resolved == null) {
      statistics.onWithoutDescription()
      return
    }
    lastResolved = resolved
    statistics.description = resolved.description
    statistics.descriptionSource = resolved.source
    sink.submit(unit, resolved)
  }

  /** A new stream of the same source (a new descriptor, a gap of a replay): the session description is read again */
  fun newStream() {
    store.newSession()
    pictureCounter.newStream()
  }

  /** A new source: the decoder stops, the counters start again */
  fun newSource() {
    sink.reset()
    statistics.reset()
    pictureCounter.reset()
    primaryChannel = null
    otherChannelUnits = 0
    codec = VideoCodec.UNKNOWN
    evidence = CodecEvidence.NONE
    lastResolved = null
  }

  fun stats(nowNs: Long, tooLarge: Long): VideoStats {
    val numbers = statistics.numbers(nowNs)
    val decoder = sink.status()
    val description = lastResolved?.description
    val state = when {
      codec == VideoCodec.H264 -> VideoState.H264_NOT_DECODED
      decoder.failure != null && !decoder.running -> VideoState.FAILED
      numbers.unitsIn == 0L -> VideoState.WAITING_FOR_VIDEO
      lastResolved == null -> VideoState.WAITING_FOR_DESCRIPTION
      decoder.running && decoder.parked && numbers.decoded > 0 -> VideoState.HIDDEN
      decoder.running && !decoder.keySinceStart && building(decoder, nowNs, numbers) -> VideoState.BUILDING
      else -> VideoState.DECODING
    }
    return VideoStats(
      state = state,
      failure = decoder.failure,
      codec = codec,
      codecEvidence = evidence,
      width = description?.info?.width,
      height = description?.info?.height,
      profileName = description?.info?.profileName,
      highTier = description?.info?.highTier,
      levelName = description?.info?.levelName,
      descriptionSource = lastResolved?.source,
      decoder = decoder,
      unitsIn = numbers.unitsIn,
      queued = numbers.queued,
      decoded = numbers.decoded,
      shown = numbers.shown,
      droppedAtDisplay = numbers.droppedAtDisplay,
      overruns = numbers.overruns,
      tooLarge = tooLarge,
      unitsWithoutDescription = numbers.unitsWithoutDescription,
      errors = numbers.errors,
      picturesPerSecond = numbers.picturesPerSecond,
      megabitsPerSecond = numbers.megabitsPerSecond,
      decodeLastMs = numbers.decodeLastMs,
      decodeMedianMs = numbers.decodeMedianMs,
      decodeP95Ms = numbers.decodeP95Ms,
      inProcessMedianMs = numbers.inProcessMedianMs,
      inProcessP95Ms = numbers.inProcessP95Ms,
      firstPictureMs = numbers.firstPictureMs,
      lostPictures = pictureCounter.lost,
      encoderRestarts = pictureCounter.restarts,
      pictureCounters = pictureCounter.counters,
      keyPictures = numbers.keyPictures,
      keyPictureAgoMs = numbers.keyPictureAgoMs,
      lastOutputAgoMs = numbers.lastOutputAgoMs,
    )
  }

  /** No key picture since the decoder started, and either no picture yet or the first one less than 5 s ago */
  private fun building(decoder: DecoderStatus, nowNs: Long, numbers: VideoStatistics.Numbers): Boolean {
    val started = decoder.startedAtNs ?: return false
    if (numbers.decoded == 0L) {
      return true
    }
    return nowNs - started < BUILDING_NS
  }
}
