package app.alextran.immich.relief

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.floor

// The relief cache of the Meta Quest (design-final 2026-10-26, section 3.7): the normalised depth map of each photo
// whose relief was estimated, so that reopening it skips the model (0.3 to 0.6 s instead of seconds). In 16 bits, which
// the 2.5D mode (lot A11) moves its mesh with, without steps. In the cache directory of the app, which the system may
// empty and the advanced settings show and clear (lot A9b, through the same ai-relief folder). Plain JVM code, without
// Android, so that the unit tests run it on a real folder.

/**
 * A depth map normalised by relief-v1 (0 far, 1 near), [width] x [height] values row after row, each kept as one of
 * 65 536 levels: `level = floor(d * 65535 + 0.5)`, read back as `level / 65535`
 */
class ReliefMap(val width: Int, val height: Int, val levels: ShortArray) {
  init {
    require(width > 0 && height > 0 && levels.size.toLong() == width.toLong() * height) { "a map of $width x $height" }
  }

  /** The level of the value [index], 0 to [MAX_LEVEL] */
  fun level(index: Int): Int = levels[index].toInt() and 0xFFFF

  /** The values, 0 to 1, for [ReliefSynthesizer.rightEye] */
  fun toNormalized(): DoubleArray = DoubleArray(levels.size) { level(it) / MAX_LEVEL.toDouble() }

  companion object {
    const val MAX_LEVEL = 65535

    /** The map of [normalized] values (0 to 1; outside, or not a number, they are clamped, NaN to 0) */
    fun quantize(width: Int, height: Int, normalized: DoubleArray): ReliefMap =
      ReliefMap(
        width,
        height,
        ShortArray(normalized.size) { i ->
          val v = normalized[i]
          val clamped = if (v > 0.0) (if (v < 1.0) v else 1.0) else 0.0
          floor(clamped * MAX_LEVEL + 0.5).toInt().toShort()
        },
      )
  }
}

/**
 * The maps of the cache in [directory], one file `<key>.u16` per photo: a header of 16 bytes (`IMRL`, the version 2,
 * the width and the height as 32 bit integers) then the levels in 16 bits, all little endian; 710 712 bytes for the
 * 686 x 518 map of the model. The key is the SHA-256 in hexadecimal that Flutter computes from the photo, the model
 * and the settings (reliefCacheKey in lib/domain/models/ai_immersive/stereo_pair_requests.dart): a new model or a new
 * setting misses the cache by itself.
 *
 * A map is written in a partial file renamed once whole: a reader never sees half a map. Partial files older than
 * [partialMaxAgeMillis] that no write of this process is writing were left by a write cut short, and go, as do files of
 * no map (an older format). Past [maxBytes] the maps read the longest ago go first: reading a map dates it now.
 *
 * Nothing here throws on a full disk or a folder that went away: the relief is shown without the cache, and
 * [onProblem] says why, for the log of the app.
 */
class ReliefCache(
  val directory: File,
  val maxBytes: Long = MAX_BYTES,
  private val partialMaxAgeMillis: Long = PARTIAL_MAX_AGE_MILLIS,
  private val clock: () -> Long = System::currentTimeMillis,
  private val onProblem: (String) -> Unit = {},
) {
  companion object {
    /** The folder of the cache in the cache directory of the app, getTemporaryDirectory() for Flutter */
    const val FOLDER = "ai-relief"
    const val EXTENSION = ".u16"
    const val PARTIAL_SUFFIX = ".tmp"
    const val HEADER_BYTES = 16
    const val VERSION = 2

    /** 200 MB, about 280 maps of the model */
    const val MAX_BYTES = 200_000_000L
    const val PARTIAL_MAX_AGE_MILLIS = 5 * 60 * 1000L

    /** Larger than any map the model or a later one gives: a header that says more is damaged */
    private const val MAX_SIDE = 16384
    private val MAGIC = byteArrayOf('I'.code.toByte(), 'M'.code.toByte(), 'R'.code.toByte(), 'L'.code.toByte())
    private val KEY = Regex("[0-9a-f]{64}")

    // The partial files this process is writing, for every cache on the folder: the cleaning leaves them alone
    private val writing = mutableSetOf<String>()

    /** The cache of the app, given its cache directory (Context.getCacheDir()) */
    fun inCacheDir(cacheDir: File, onProblem: (String) -> Unit = {}) =
      ReliefCache(File(cacheDir, FOLDER), onProblem = onProblem)

    /** Whether [key] is a SHA-256 in lower case hexadecimal, the only name a map takes */
    fun isKey(key: String): Boolean = KEY.matches(key)

    /** The size of the file of a map of [width] x [height] */
    fun fileSize(width: Int, height: Int): Long = HEADER_BYTES + 2L * width * height

    /** The file of [map] */
    fun encode(map: ReliefMap): ByteArray {
      val buffer = ByteBuffer.allocate(fileSize(map.width, map.height).toInt()).order(ByteOrder.LITTLE_ENDIAN)
      buffer.put(MAGIC).putInt(VERSION).putInt(map.width).putInt(map.height)
      buffer.asShortBuffer().put(map.levels)
      return buffer.array()
    }

    /** The map [bytes] hold, null when they are not a whole map of this version */
    fun decode(bytes: ByteArray): ReliefMap? {
      if (bytes.size < HEADER_BYTES) return null
      val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
      for (b in MAGIC) if (buffer.get() != b) return null
      val version = buffer.int
      val width = buffer.int
      val height = buffer.int
      if (version != VERSION || width !in 1..MAX_SIDE || height !in 1..MAX_SIDE) return null
      if (bytes.size.toLong() != fileSize(width, height)) return null
      val levels = ShortArray(width * height)
      buffer.asShortBuffer().get(levels)
      return ReliefMap(width, height, levels)
    }
  }

  /** The file of the map of [key], written or not */
  fun fileFor(key: String): File {
    require(isKey(key)) { "not a key of the relief cache" }
    return File(directory, key + EXTENSION)
  }

  /** The map of [key] when it is in the cache, marked as read now; null otherwise. A damaged file is removed. */
  @Synchronized
  fun read(key: String): ReliefMap? {
    if (!isKey(key)) {
      onProblem("Relief cache: refused the key ${key.take(80)}")
      return null
    }
    val file = fileFor(key)
    if (!file.isFile) return null
    val bytes =
      try {
        file.readBytes()
      } catch (error: IOException) {
        onProblem("Relief cache: could not read ${file.name}: $error")
        return null
      }
    val map = decode(bytes)
    if (map == null) {
      onProblem("Relief cache: ${file.name} is damaged, removed")
      file.delete()
      return null
    }
    if (!file.setLastModified(clock())) onProblem("Relief cache: could not mark ${file.name} as read")
    return map
  }

  /**
   * Writes [map] as the map of [key], then removes what the cache no longer keeps (see [trim]). The file written, or
   * null when it could not be.
   */
  @Synchronized
  fun write(key: String, map: ReliefMap): File? {
    if (!isKey(key)) {
      onProblem("Relief cache: refused the key ${key.take(80)}")
      return null
    }
    val file = fileFor(key)
    var partial: File? = null
    try {
      if (!directory.isDirectory && !directory.mkdirs() && !directory.isDirectory) {
        throw IOException("could not make the folder ${directory.name}")
      }
      partial = File.createTempFile("$key$EXTENSION.", PARTIAL_SUFFIX, directory)
      synchronized(writing) { writing += partial.path }
      FileOutputStream(partial).use { stream ->
        stream.write(encode(map))
        stream.fd.sync()
      }
      if (!partial.renameTo(file)) throw IOException("could not rename ${partial.name} to ${file.name}")
      file.setLastModified(clock())
    } catch (error: IOException) {
      onProblem("Relief cache: could not write ${file.name}: $error")
      return null
    } catch (error: SecurityException) {
      onProblem("Relief cache: could not write ${file.name}: $error")
      return null
    } finally {
      partial?.let {
        // Still there only when the write failed
        if (it.exists()) it.delete()
        synchronized(writing) { writing -= it.path }
      }
    }
    trim(except = file)
    return file
  }

  /**
   * Removes the partial files of writes cut short and the files of no map, then the maps read the longest ago until the
   * cache holds [maxBytes] at most. [except], the map just written, always stays. Folders are left alone.
   */
  @Synchronized
  fun trim(except: File? = null) {
    val entries = directory.listFiles() ?: return
    val now = clock()
    val maps = mutableListOf<File>()
    for (entry in entries) {
      if (!entry.isFile) continue
      val name = entry.name
      when {
        name.endsWith(PARTIAL_SUFFIX) -> {
          val ours = synchronized(writing) { entry.path in writing }
          if (!ours && now - entry.lastModified() > partialMaxAgeMillis) entry.delete()
        }
        name.endsWith(EXTENSION) && isKey(name.removeSuffix(EXTENSION)) -> if (entry != except) maps += entry
        else -> entry.delete()
      }
    }
    // Dated once: the order must not change while it is sorted
    val newestFirst =
      maps
        .map { CachedMap(it, it.lastModified(), it.length()) }
        .sortedWith(compareByDescending<CachedMap> { it.date }.thenBy { it.file.name })
    var kept = except?.takeIf { it.isFile }?.length() ?: 0L
    var full = false
    for (map in newestFirst) {
      // Once one does not fit, every older one goes too: the oldest go first
      if (!full && kept + map.size <= maxBytes) {
        kept += map.size
      } else {
        full = true
        map.file.delete()
      }
    }
  }

  /** Bytes the files of the cache take, partial files included; 0 when there is no cache */
  fun sizeBytes(): Long = directory.listFiles()?.filter { it.isFile }?.sumOf { it.length() } ?: 0L

  /** Removes every file of the cache; the bytes freed */
  @Synchronized
  fun clear(): Long {
    var freed = 0L
    for (entry in directory.listFiles() ?: return 0L) {
      if (!entry.isFile) continue
      val size = entry.length()
      if (entry.delete()) freed += size
    }
    return freed
  }
}

private class CachedMap(val file: File, val date: Long, val size: Long)
