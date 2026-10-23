package app.alextran.immich.djilink

/** A capture in memory: its bytes and its index, and the name the page shows */
class LoadedCapture(val name: String, val bytes: ByteArray, val index: List<CaptureEntry>)

/**
 * Plays a capture through the same pipeline as the cable, in real time.
 *
 * The inbound reads of the index are fed one by one, each at the moment its monotonic clock says it arrived relative
 * to the first one played, into a parser pair of its own ([decoder], [router]) whose access units go to the same
 * video pipeline and decoder as the live ones. An open or a gap marker restarts the parsers. Starting at a later
 * second skips the reads before it: the parsers then join a running stream, as they do on a cable.
 *
 * The player sends nothing anywhere; it has no handle on a transport. Playing is refused while an accessory is open
 * (one source at a time), and the controller stops it when one opens.
 */
class CapturePlayer(
  /** The page lock: the player routes under it, as the reader thread does */
  private val gate: Any,
  private val clockNs: () -> Long = { System.nanoTime() },
  private val sleepNs: (Long) -> Unit = { nanos -> Thread.sleep(nanos / 1_000_000, (nanos % 1_000_000).toInt()) },
) {
  val decoder = EnvelopeDecoder()
  val router = FrameRouter()

  @Volatile
  var name: String? = null
    private set

  @Volatile
  var playing = false
    private set

  /** Milliseconds of the capture played so far, on its own clock from its first read */
  @Volatile
  var positionMs = 0L
    private set

  @Volatile
  var durationMs = 0L
    private set

  @Volatile
  private var stopRequested = false
  private var thread: Thread? = null

  /** True from [play] to [stop]: the page shows the played capture's video and telemetry */
  val loaded: Boolean get() = name != null

  /**
   * Starts playing [capture] from [startAtMs]. [onNewStream] is called at the start and at each open or gap marker,
   * [onRead] after each read, [onEnd] when the last read was played or [stop] was called.
   */
  fun play(
    capture: LoadedCapture,
    startAtMs: Long,
    onNewStream: () -> Unit,
    onRead: () -> Unit,
    onEnd: () -> Unit,
  ) {
    stop()
    val reads = capture.index.filter { it.direction == CaptureDirection.IN || it.direction.restartsStream }
    val firstNs = reads.firstOrNull { it.direction == CaptureDirection.IN }?.monotonicNs ?: 0L
    val lastNs = reads.lastOrNull { it.direction == CaptureDirection.IN }?.monotonicNs ?: firstNs
    synchronized(gate) {
      decoder.reset()
      decoder.clearCounters()
      router.reset()
      name = capture.name
      durationMs = (lastNs - firstNs) / 1_000_000
      positionMs = startAtMs.coerceIn(0, durationMs)
    }
    stopRequested = false
    playing = true
    val worker = Thread({ run(capture, reads, firstNs, startAtMs, onNewStream, onRead, onEnd) }, "DjiLinkPlayer")
    worker.isDaemon = true
    thread = worker
    worker.start()
  }

  private fun run(
    capture: LoadedCapture,
    reads: List<CaptureEntry>,
    firstNs: Long,
    startAtMs: Long,
    onNewStream: () -> Unit,
    onRead: () -> Unit,
    onEnd: () -> Unit,
  ) {
    try {
      onNewStream()
      val startNs = firstNs + startAtMs * 1_000_000
      val playable = reads.filter { it.direction.restartsStream || it.monotonicNs >= startNs }
      val origin = playable.firstOrNull { it.direction == CaptureDirection.IN }?.monotonicNs ?: startNs
      val wallStart = clockNs()
      for (entry in playable) {
        if (stopRequested) {
          break
        }
        if (entry.direction.restartsStream) {
          synchronized(gate) {
            decoder.reset()
            router.restartStreams()
          }
          onNewStream()
          continue
        }
        val due = wallStart + (entry.monotonicNs - origin)
        val wait = due - clockNs()
        if (wait > 0) {
          sleepNs(wait)
        }
        if (stopRequested) {
          break
        }
        val from = entry.offset.toInt()
        if (from < 0 || from >= capture.bytes.size) {
          continue
        }
        val length = minOf(entry.length, capture.bytes.size - from)
        val nowNs = clockNs()
        synchronized(gate) {
          for (envelope in decoder.offer(capture.bytes, from, length)) {
            router.route(envelope, nowNs / 1_000_000, nowNs)
          }
          positionMs = (entry.monotonicNs - firstNs) / 1_000_000
        }
        onRead()
      }
    } catch (_: InterruptedException) {
      // Stopped while waiting for the next read
    } finally {
      playing = false
      onEnd()
    }
  }

  /** Stops playing; the parsers keep what they read until the next [play] or [unload] */
  fun stop() {
    stopRequested = true
    val worker = thread
    thread = null
    if (worker != null && worker !== Thread.currentThread()) {
      worker.interrupt()
      runCatching { worker.join(1_000) }
    }
    playing = false
  }

  /** Stops and forgets the capture: the page goes back to the cable */
  fun unload() {
    stop()
    synchronized(gate) {
      name = null
      positionMs = 0
      durationMs = 0
      decoder.reset()
      decoder.clearCounters()
      router.reset()
    }
  }
}
