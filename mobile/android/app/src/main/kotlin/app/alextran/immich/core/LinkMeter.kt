package app.alextran.immich.core

import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener

/**
 * What the link of one player brings: the bytes per second received over the last [WINDOW_MS] while the player asked
 * for bytes, the bytes per second the video consumes (the size of its files over its duration), and the time the
 * player asked for bytes since the last progress (each [LinkStartRule.PROGRESS_BYTES] that arrive). Fed by Media3 as
 * the transfer listener of the player's network reads (see [PlayerLink]), read by its load control on the playback
 * thread and by the app on the main thread.
 *
 * The player asks for bytes while its load control wants more media ([setLoadingWanted]) and a read of it is open
 * ([onInitializing] to [onEnd]), or a load failed and Media3 tries again ([onLoadError]). Both measures count that
 * time only, to the millisecond (review of 1 November 2026): a film paused with its buffer full, a clip loaded to its
 * end, asks for nothing, and the next request (a seek, a play) was taken for a dead server at once; a buffer at its
 * bytes cap, which Media3 tops up 1 MiB at a time as the film frees room, measured what the film consumes rather than
 * what the link brings. A new ask after a time without one starts the clock of progress again; the tries after an
 * error keep it, so that a link that sends nothing is still dead [LinkStartRule.DEAD_AFTER_MS] after its last bytes.
 *
 * The clock is a parameter so that the tests drive it; [onInitializing], [onStart], [onBytes], [onEnd],
 * [onLoadError], [onFileSize] and [setLoadingWanted] are the pure part the transfer callbacks, the load control and
 * the load error policy call.
 */
@OptIn(UnstableApi::class)
class LinkMeter(private val clock: () -> Long = { SystemClock.elapsedRealtime() }) : TransferListener {
  companion object {
    const val WINDOW_MS = 4_000L
    const val SLOT_MS = 250L
    /** The slots of the window, and the slot under way */
    private const val SLOTS = (WINDOW_MS / SLOT_MS).toInt() + 1

    /** The read of the pure calls that name none */
    private val ONE_READ = Any()

    /** A first rate is told once this much arrived, or after [FIRST_VALUE_MS] of loading */
    const val FIRST_VALUE_BYTES = 256L * 1024L
    const val FIRST_VALUE_MS = 1_000L

    /** Media the duration needs buffered before the bytes per buffered second stand for the video's need */
    const val NEED_FROM_BUFFER_MS = 2_000L

    /** The total size in a Content-Range header ("bytes 0-99/12345"), or null */
    fun totalOfContentRange(header: String?): Long? {
      val total = header?.substringAfterLast('/', missingDelimiterValue = "")?.trim() ?: return null
      return total.toLongOrNull()?.takeIf { it > 0 }
    }
  }

  private val lock = Any()
  private val slotBytes = LongArray(SLOTS)
  private val slotNumber = LongArray(SLOTS) { -1L }

  /** The ms of each slot the player asked for bytes */
  private val slotAskedMs = LongArray(SLOTS)
  private var lastSlot = -1L

  /** The last answer of the load control: it wants more media */
  private var wanted = true

  /** The network reads open, by their data source: from their request to their end */
  private val reads = HashSet<Any>()

  /** A load failed since the last progress: Media3 tries it again, the bytes are still asked */
  private var failing = false

  /** Where the asked time accounted so far ends, in [clock] time; -1 while the player asks for nothing */
  private var askedFrom = -1L

  /** The time the player asked for bytes since the last progress, or since it asked again after a time without */
  private var askedSinceProgress = 0L
  private var total = 0L
  private var bytesAtProgress = 0L
  private var lastRate: Long? = null
  private var network = false
  private val fileSizes = HashMap<String, Long>()
  private var durationMs = -1L
  private var bufferedPositionMs = -1L

  /** Where the media of this load begins: the place a film resumed at is not media it loaded */
  private var loadedFromMs = -1L

  /** A new video loads: everything measured so far goes */
  fun reset() {
    synchronized(lock) {
      slotBytes.fill(0L)
      slotNumber.fill(-1L)
      slotAskedMs.fill(0L)
      lastSlot = -1L
      wanted = true
      reads.clear()
      failing = false
      askedFrom = -1L
      askedSinceProgress = 0L
      total = 0L
      bytesAtProgress = 0L
      lastRate = null
      network = false
      fileSizes.clear()
      durationMs = -1L
      bufferedPositionMs = -1L
      loadedFromMs = -1L
    }
  }

  /** Whether the player asks for bytes now, see the class */
  private val asked: Boolean get() = wanted && (reads.isNotEmpty() || failing)

  /**
   * Applies [block] to the state at [now], the asked time accounted to it first: an ask that begins after a time
   * without one starts the clock of progress again (unless a load failed: its tries keep it), an ask that ends
   * keeps the rate it measured
   */
  private inline fun change(now: Long, block: () -> Unit) {
    account(now)
    val before = asked
    block()
    val after = asked
    if (!before && after) {
      askedFrom = now
      if (!failing) askedSinceProgress = 0L
    } else if (before && !after) {
      askedFrom = -1L
      computeRate(now)
    }
  }

  /** The load control wants more media ([wanted]) or holds what it wants */
  fun setLoadingWanted(wanted: Boolean) {
    synchronized(lock) { change(clock()) { this.wanted = wanted } }
  }

  /** A network read of the player ([read], its data source) is asked of the server: no answer yet */
  fun onInitializing(read: Any = ONE_READ) {
    synchronized(lock) {
      change(clock()) {
        network = true
        reads.add(read)
      }
    }
  }

  /** The server answered a network read of the player ([read]): its bytes come */
  fun onStart(read: Any = ONE_READ) = onInitializing(read)

  /** A network read of the player ([read]) ended: the file read to its end, a seek, an error */
  fun onEnd(read: Any = ONE_READ) {
    synchronized(lock) { change(clock()) { reads.remove(read) } }
  }

  /** A load of the player failed: Media3 tries it again (see StreamLoadErrorPolicy), the bytes are still asked */
  fun onLoadError() {
    synchronized(lock) { change(clock()) { failing = true } }
  }

  /** [count] bytes arrived over the network */
  fun onBytes(count: Long) {
    if (count <= 0) return
    synchronized(lock) {
      val now = clock()
      change(now) {
        network = true
        // Bytes come from an open read, whatever was said of it
        if (reads.isEmpty()) reads.add(ONE_READ)
      }
      slotBytes[index(now / SLOT_MS)] += count
      total += count
      if (total - bytesAtProgress >= LinkStartRule.PROGRESS_BYTES) {
        askedSinceProgress = 0L
        bytesAtProgress = total
        failing = false
      }
    }
  }

  /** The file at [key] (its URI) has [size] bytes: the video consumes the sizes of its files over its duration */
  fun onFileSize(key: String, size: Long) {
    if (size <= 0) return
    synchronized(lock) { fileSizes[key] = size }
  }

  /**
   * The duration of the video and how far it is loaded, from the load control, in ms (negative when unknown);
   * [positionMs] is the playback position, the first one after [reset] being where the load began
   */
  fun onTimeline(durationMs: Long, bufferedPositionMs: Long, positionMs: Long = 0L) {
    synchronized(lock) {
      this.durationMs = durationMs
      this.bufferedPositionMs = bufferedPositionMs
      if (loadedFromMs < 0 && positionMs >= 0) loadedFromMs = positionMs
    }
  }

  /** Whether any of the player's reads went over the network since [reset], from its request on */
  val isNetwork: Boolean get() = synchronized(lock) { network }

  /** Bytes received since [reset] */
  val receivedBytes: Long get() = synchronized(lock) { total }

  /**
   * Bytes received per second the player asked for bytes, over the last [WINDOW_MS]; the last value while it asked
   * for none in that window; null before [FIRST_VALUE_BYTES] arrived or [FIRST_VALUE_MS] of asking passed.
   */
  fun rate(): Long? {
    synchronized(lock) {
      if (!network) return null
      val now = clock()
      account(now)
      return computeRate(now)
    }
  }

  /** [rate], the asked time accounted to [now] already */
  private fun computeRate(now: Long): Long? {
    val current = now / SLOT_MS
    var bytes = 0L
    var time = 0L
    for (k in 0 until SLOTS) {
      val slot = current - k
      val i = index(slot)
      if (slotNumber[i] != slot) continue
      bytes += slotBytes[i]
      time += slotAskedMs[i]
    }
    if (time <= 0L) return lastRate
    if (lastRate == null && time < FIRST_VALUE_MS && bytes < FIRST_VALUE_BYTES) return null
    return (bytes * 1000L / time).also { lastRate = it }
  }

  /**
   * Bytes per second the video consumes at normal speed: the size of its files over its duration, else the bytes
   * received per second of media loaded once [NEED_FROM_BUFFER_MS] is, counted from where the load began (a film
   * resumed at 2 minutes said it needed 20 kbit/s while its index arrived, 31 October 2026); null when neither is known
   */
  fun need(): Long? {
    synchronized(lock) {
      val sizes = fileSizes.values.sum()
      if (sizes > 0 && durationMs > 0) return sizes * 1000L / durationMs
      val loadedMs = bufferedPositionMs - loadedFromMs.coerceAtLeast(0L)
      if (loadedMs >= NEED_FROM_BUFFER_MS && total > 0) return total * 1000L / loadedMs
      return null
    }
  }

  /** [rate] over [need] at [speed]: media seconds that arrive per second; null when either is unknown */
  fun ratio(speed: Float = 1f): Double? {
    val rate = rate() ?: return null
    val need = need()?.takeIf { it > 0 } ?: return null
    return rate.toDouble() / (need.toDouble() * speed.coerceAtLeast(0.1f))
  }

  /**
   * The time the player asked for bytes since the last progress, or since it asked again after a time without (the
   * request of a seek, of a play after a pause), a server that never sent included; null before any network read
   */
  fun sinceProgressMs(): Long? {
    synchronized(lock) {
      if (!network) return null
      account(clock())
      return askedSinceProgress
    }
  }

  private fun index(slot: Long): Int = Math.floorMod(slot, SLOTS.toLong()).toInt()

  /** The time asked from [askedFrom] to [now] goes to the clock of progress and to the slots of the window */
  private fun account(now: Long) {
    fill(now)
    val from = askedFrom
    if (from < 0 || now <= from) return
    askedSinceProgress += now - from
    var t = maxOf(from, (now / SLOT_MS - SLOTS + 1) * SLOT_MS)
    while (t < now) {
      val slot = t / SLOT_MS
      val end = minOf(now, (slot + 1) * SLOT_MS)
      slotAskedMs[index(slot)] += end - t
      t = end
    }
    askedFrom = now
  }

  /** The slots from the last one touched to [now] start empty; the first call starts the slot under way only */
  private fun fill(now: Long) {
    val current = now / SLOT_MS
    if (lastSlot >= 0 && current <= lastSlot) return
    val from = when {
      lastSlot < 0 -> current
      current - lastSlot > SLOTS -> current - SLOTS + 1
      else -> lastSlot + 1
    }
    for (slot in from..current) {
      val i = index(slot)
      slotNumber[i] = slot
      slotBytes[i] = 0L
      slotAskedMs[i] = 0L
    }
    lastSlot = current
  }

  // The transfer callbacks of Media3, on its loading threads: only the reads over the network count. A read is asked
  // from its request: a server that takes the request and never answers is a network link with no progress (review
  // of 1 November 2026: it kept Media3's rule, a few tries and a fatal error, and was never said to be dead)

  override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
    if (isNetwork) onInitializing(source)
  }

  override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
    if (!isNetwork) return
    onStart(source)
    val headers = try {
      source.responseHeaders
    } catch (e: Exception) {
      emptyMap()
    }
    val size = sizeOf(headers, dataSpec)
    if (size != null) onFileSize(dataSpec.uri.toString(), size)
  }

  override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) {
    if (isNetwork) onBytes(bytesTransferred.toLong())
  }

  override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
    if (isNetwork) onEnd(source)
  }

  /** The whole size of the file a response is part of: its Content-Range total, else its length read from the start */
  private fun sizeOf(headers: Map<String, List<String>>, dataSpec: DataSpec): Long? {
    fun header(name: String): String? =
      headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value?.firstOrNull()
    totalOfContentRange(header("Content-Range"))?.let { return it }
    val length = header("Content-Length")?.trim()?.toLongOrNull() ?: return null
    return if (dataSpec.position == 0L && length > 0) length else null
  }
}
