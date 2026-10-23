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
 *
 * A capture is a file someone may have damaged or written by hand. Every read is cut to the bytes of the file before
 * it reaches the parsers, and anything that still goes wrong on the player thread ends the playback with [failure]
 * set, for the page to say, instead of ending the app.
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

  /** The kind of the error that ended the last playback early, or null when it ended normally or was stopped */
  @Volatile
  var failure: String? = null
    private set

  @Volatile
  private var stopRequested = false
  private var thread: Thread? = null

  /** True from [play] to [stop]: the page shows the played capture's video and telemetry */
  val loaded: Boolean get() = name != null

  /** Whether the playback starts again at its start second when it reaches the end */
  @Volatile
  var looping = false
    private set

  /** Loops played to their end since [play] */
  @Volatile
  var loops = 0
    private set

  /**
   * Starts playing [capture] from [startAtMs]. [onNewStream] is called at the start, at each open or gap marker and at
   * the start of each loop, [onRead] after each read, [onEnd] when the last read was played (of the last loop) or
   * [stop] was called. With [loop], the end starts the playback again at the same second, through parsers started
   * again: the first unit of each loop does not continue the last one of the previous loop.
   */
  fun play(
    capture: LoadedCapture,
    startAtMs: Long,
    onNewStream: () -> Unit,
    onRead: () -> Unit,
    onEnd: () -> Unit,
    loop: Boolean = false,
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
      durationMs = ((lastNs - firstNs) / 1_000_000).coerceAtLeast(0)
      positionMs = startAtMs.coerceIn(0, durationMs)
    }
    failure = null
    stopRequested = false
    looping = loop
    loops = 0
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
      val startNs = firstNs + startAtMs * 1_000_000
      val playable = reads.filter { it.direction.restartsStream || it.monotonicNs >= startNs }
      val origin = playable.firstOrNull { it.direction == CaptureDirection.IN }?.monotonicNs ?: startNs
      val hasReads = playable.any { it.direction == CaptureDirection.IN }
      var first = true
      while (first || (looping && hasReads && !stopRequested)) {
        if (!first) {
          // A new loop: the parsers start again, as at an open marker
          synchronized(gate) {
            decoder.reset()
            router.restartStreams()
          }
        }
        first = false
        onNewStream()
        playOnce(capture, playable, origin, firstNs, onNewStream, onRead)
        if (!stopRequested) {
          loops += 1
        }
      }
    } catch (_: InterruptedException) {
      // Stopped while waiting for the next read
    } catch (error: Throwable) {
      // A damaged capture, or a parser that did not expect what it read: the playback ends and the page says why
      failure = error.javaClass.simpleName.ifEmpty { "Throwable" }
    } finally {
      playing = false
      onEnd()
    }
  }

  /** One pass over [playable], paced by the index clock from [origin] */
  private fun playOnce(
    capture: LoadedCapture,
    playable: List<CaptureEntry>,
    origin: Long,
    firstNs: Long,
    onNewStream: () -> Unit,
    onRead: () -> Unit,
  ) {
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
      val (from, length) = entry.rangeIn(capture.bytes.size) ?: continue
      val nowNs = clockNs()
      synchronized(gate) {
        for (envelope in decoder.offer(capture.bytes, from, length)) {
          router.route(envelope, nowNs / 1_000_000, nowNs)
        }
        positionMs = (entry.monotonicNs - firstNs) / 1_000_000
      }
      onRead()
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
    failure = null
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
