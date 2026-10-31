package app.alextran.immich.core

import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener

/**
 * What the link of one player brings: the bytes per second received over the last [WINDOW_MS] while the player wanted
 * more (the time its load control stopped loading because the buffer was full does not count), the bytes per second
 * the video consumes (the size of its files over its duration), and the time since the last progress (each
 * [LinkStartRule.PROGRESS_BYTES] that arrive). Fed by Media3 as the transfer listener of the player's network reads
 * (see [PlayerLink]), read by its load control on the playback thread and by the app on the main thread.
 *
 * The clock is a parameter so that the tests drive it; [onBytes], [onFileSize] and [setLoadingWanted] are the pure
 * part the transfer callbacks and the load control call.
 */
@OptIn(UnstableApi::class)
class LinkMeter(private val clock: () -> Long = { SystemClock.elapsedRealtime() }) : TransferListener {
  companion object {
    const val WINDOW_MS = 4_000L
    const val SLOT_MS = 250L
    /** The slots of the window, and the slot under way */
    private const val SLOTS = (WINDOW_MS / SLOT_MS).toInt() + 1

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
  private val slotWanted = BooleanArray(SLOTS)
  private var lastSlot = -1L
  private var wanted = true
  private var startedAt = -1L
  private var total = 0L
  private var progressAt = -1L
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
      slotWanted.fill(false)
      lastSlot = -1L
      wanted = true
      startedAt = -1L
      total = 0L
      progressAt = -1L
      bytesAtProgress = 0L
      lastRate = null
      network = false
      fileSizes.clear()
      durationMs = -1L
      bufferedPositionMs = -1L
      loadedFromMs = -1L
    }
  }

  /** The load control wants more media ([wanted]) or holds what it wants */
  fun setLoadingWanted(wanted: Boolean) {
    synchronized(lock) {
      val now = clock()
      fill(now)
      if (this.wanted && !wanted) {
        // The rate as the loading stops: what the link brought while it was asked
        computeRate(now)
      }
      this.wanted = wanted
      if (wanted) {
        slotWanted[index(now / SLOT_MS)] = true
      }
    }
  }

  /** A network read of the player started: the time since progress counts from the first one */
  fun onStart() {
    synchronized(lock) {
      network = true
      if (startedAt < 0) {
        val now = clock()
        fill(now)
        startedAt = now
      }
    }
  }

  /** [count] bytes arrived over the network */
  fun onBytes(count: Long) {
    if (count <= 0) return
    synchronized(lock) {
      val now = clock()
      fill(now)
      network = true
      if (startedAt < 0) startedAt = now
      slotBytes[index(now / SLOT_MS)] += count
      total += count
      if (total - bytesAtProgress >= LinkStartRule.PROGRESS_BYTES) {
        progressAt = now
        bytesAtProgress = total
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

  /** Whether any of the player's reads went over the network since [reset] */
  val isNetwork: Boolean get() = synchronized(lock) { network }

  /** Bytes received since [reset] */
  val receivedBytes: Long get() = synchronized(lock) { total }

  /**
   * Bytes per second received over the last [WINDOW_MS] while the player wanted more; the last value while it wanted
   * none in that window; null before [FIRST_VALUE_BYTES] arrived or [FIRST_VALUE_MS] of wanting passed.
   */
  fun rate(): Long? {
    synchronized(lock) {
      if (!network) return null
      val now = clock()
      fill(now)
      return computeRate(now)
    }
  }

  /** [rate], the slots filled to [now] already */
  private fun computeRate(now: Long): Long? {
    val current = now / SLOT_MS
    var bytes = 0L
    var time = 0L
    for (k in 0 until SLOTS) {
      val slot = current - k
      val i = index(slot)
      if (slotNumber[i] != slot || !slotWanted[i]) continue
      bytes += slotBytes[i]
      time += if (slot == current) (now - slot * SLOT_MS) else SLOT_MS
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

  /** Time since the last progress, or since the first read for a server that never sent; null before any read */
  fun sinceProgressMs(): Long? {
    synchronized(lock) {
      val from = if (progressAt >= 0) progressAt else startedAt
      return if (from < 0) null else (clock() - from).coerceAtLeast(0L)
    }
  }

  private fun index(slot: Long): Int = (slot % SLOTS).toInt()

  /**
   * The slots from the last one touched to [now] get no bytes and the wanted state that held meanwhile; the first
   * call fills the slot under way only (nothing was asked before it)
   */
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
      slotWanted[i] = wanted
    }
    lastSlot = current
  }

  // The transfer callbacks of Media3, on its loading threads: only the reads over the network count

  override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}

  override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {
    if (!isNetwork) return
    onStart()
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

  override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}

  /** The whole size of the file a response is part of: its Content-Range total, else its length read from the start */
  private fun sizeOf(headers: Map<String, List<String>>, dataSpec: DataSpec): Long? {
    fun header(name: String): String? =
      headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value?.firstOrNull()
    totalOfContentRange(header("Content-Range"))?.let { return it }
    val length = header("Content-Length")?.trim()?.toLongOrNull() ?: return null
    return if (dataSpec.position == 0L && length > 0) length else null
  }
}
