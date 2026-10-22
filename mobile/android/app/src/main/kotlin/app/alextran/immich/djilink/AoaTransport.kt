package app.alextran.immich.djilink

import android.util.Log
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The two streams of an open USB accessory, behind an interface so that the reader, the writer and every codec can be
 * exercised on a pair of pipes with no hardware.
 */
interface AccessoryStreams {
  val input: InputStream
  val output: OutputStream
  fun close()
}

/** Result of the one byte liveness probe: whether the call returned, and how long the call itself took */
data class ProbeResult(val ok: Boolean, val callMs: Long, val error: String? = null)

/**
 * The descriptor of an open accessory: a reader thread, a bounded writer queue and the one byte liveness probe.
 *
 * Two sizes matter and both come from the notes of the P2 study (p2/protocol.md, section 2.4 and 2.5).
 *
 * Reads always ask for [READ_SIZE] bytes, because the kernel accessory driver returns at most one USB transfer per
 * read and throws the rest of that transfer away when the buffer is smaller. A smaller buffer does not slow the
 * stream down, it loses bytes.
 *
 * A write that blocks is information rather than a problem: the kernel only blocks the writer once four transfers are
 * waiting for the host to collect them, so a probe whose call takes a long time says that the remote is not reading
 * our endpoint. That is why [ProbeResult.callMs] exists and why the page shows it.
 *
 * Nothing in stage 1 writes anything but the probe byte, whose value carries no meaning.
 */
class AoaTransport(
  private val streams: AccessoryStreams,
  private val onBytes: (ByteArray, Int) -> Unit,
  private val onWrite: (ByteArray, Boolean) -> Unit = { _, _ -> },
  private val onEnded: (String) -> Unit = {},
  private val queueSize: Int = 64,
  /** Where a failure goes; the tests hand in a logger of their own so that no Android class is needed */
  private val log: (String) -> Unit = { Log.d(TAG, it) },
) {
  companion object {
    private const val TAG = "DjiLinkTransport"

    /** One kernel read, from the notes; never smaller */
    const val READ_SIZE = 16384

    /** Consecutive read or write errors after which the loop gives up */
    const val MAX_CONSECUTIVE_ERRORS = 10
  }

  private class WriteJob(val bytes: ByteArray, val isProbe: Boolean, val reply: ArrayBlockingQueue<ProbeResult>?)

  private val running = AtomicBoolean(false)
  private val queue = ArrayBlockingQueue<WriteJob>(queueSize)
  private var reader: Thread? = null
  private var writer: Thread? = null

  var bytesRead = 0L
    private set
  var reads = 0L
    private set
  var bytesWritten = 0L
    private set
  var writes = 0L
    private set
  var readErrors = 0L
    private set
  var writeErrors = 0L
    private set
  var queueRejections = 0L
    private set

  fun start() {
    if (!running.compareAndSet(false, true)) {
      return
    }
    reader = Thread({ readLoop() }, "DjiLinkRead").apply { isDaemon = true; start() }
    writer = Thread({ writeLoop() }, "DjiLinkWrite").apply { isDaemon = true; start() }
  }

  val isRunning: Boolean get() = running.get()

  /**
   * One byte on the wire and the duration of that call. The byte is not a command and its value means nothing: it is
   * the only definition of "this pipe accepts bytes" that this transport has.
   */
  fun probe(timeoutMs: Long = 2_000): ProbeResult {
    if (!running.get()) {
      return ProbeResult(ok = false, callMs = 0, error = "the transport is not running")
    }
    val reply = ArrayBlockingQueue<ProbeResult>(1)
    if (!queue.offer(WriteJob(ByteArray(1), isProbe = true, reply = reply))) {
      queueRejections += 1
      return ProbeResult(ok = false, callMs = 0, error = "the writer queue is full")
    }
    val result = reply.poll(timeoutMs, TimeUnit.MILLISECONDS)
    return result ?: ProbeResult(ok = false, callMs = timeoutMs, error = "the write did not return in time")
  }

  /**
   * Hands bytes to the writer queue. No caller in stage 1 uses it: the send path of the later stages goes through
   * here so that every byte sent is counted and written into the capture in one place.
   */
  fun send(bytes: ByteArray): Boolean {
    if (!running.get()) {
      return false
    }
    val accepted = queue.offer(WriteJob(bytes, isProbe = false, reply = null))
    if (!accepted) {
      queueRejections += 1
    }
    return accepted
  }

  fun stop(reason: String) {
    if (!running.compareAndSet(true, false)) {
      return
    }
    try {
      streams.close()
    } catch (error: Throwable) {
      log("closing the accessory: ${error.javaClass.simpleName}")
    }
    reader?.interrupt()
    writer?.interrupt()
    reader = null
    writer = null
    onEnded(reason)
  }

  private fun readLoop() {
    val buffer = ByteArray(READ_SIZE)
    var consecutive = 0
    while (running.get()) {
      try {
        val count = streams.input.read(buffer)
        if (count < 0) {
          stop("the accessory stream ended")
          return
        }
        consecutive = 0
        if (count > 0) {
          reads += 1
          bytesRead += count
          onBytes(buffer, count)
        }
      } catch (error: Throwable) {
        if (!running.get()) {
          return
        }
        readErrors += 1
        consecutive += 1
        log("read failed ($consecutive): ${error.javaClass.simpleName}")
        if (consecutive >= MAX_CONSECUTIVE_ERRORS) {
          stop("$MAX_CONSECUTIVE_ERRORS reads in a row failed")
          return
        }
      }
    }
  }

  private fun writeLoop() {
    var consecutive = 0
    while (running.get()) {
      val job = try {
        queue.poll(250, TimeUnit.MILLISECONDS)
      } catch (interrupted: InterruptedException) {
        return
      } ?: continue
      val startedNs = System.nanoTime()
      var error: String? = null
      try {
        streams.output.write(job.bytes)
        streams.output.flush()
        consecutive = 0
        writes += 1
        bytesWritten += job.bytes.size
        onWrite(job.bytes, job.isProbe)
      } catch (failure: Throwable) {
        writeErrors += 1
        consecutive += 1
        error = failure.javaClass.simpleName
        log("write failed ($consecutive): $error")
      }
      val callMs = (System.nanoTime() - startedNs) / 1_000_000
      job.reply?.offer(ProbeResult(ok = error == null, callMs = callMs, error = error))
      if (consecutive >= MAX_CONSECUTIVE_ERRORS) {
        stop("$MAX_CONSECUTIVE_ERRORS writes in a row failed")
        return
      }
    }
  }
}
