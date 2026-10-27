package app.alextran.immich.relief

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The relief cache of the headset (design 3.7): the normalised depth map of a photo in 16 bits under the key Flutter
 * computes, written whole or not at all, 200 MB at most, the least recently read maps going first.
 */
class ReliefCacheTest {
  private val directory: File = Files.createTempDirectory("relief-cache").toFile()
  private var now = 1_800_000_000_000L
  private val problems = mutableListOf<String>()

  private fun cache(maxBytes: Long = ReliefCache.MAX_BYTES) =
    ReliefCache(directory, maxBytes = maxBytes, clock = { now }, onProblem = { problems += it })

  private fun key(n: Int) = "%064x".format(n)

  private fun map(seed: Int, width: Int = 4, height: Int = 4) =
    ReliefMap(width, height, ShortArray(width * height) { ((seed * 977 + it * 131) and 0xFFFF).toShort() })

  @After
  fun cleanUp() {
    directory.deleteRecursively()
  }

  @Test
  fun `the cache folder is ai-relief in the cache directory of the app`() {
    val cacheDir = File("/data/user/0/com.aprogsys.immuch360/cache")
    assertEquals(File(cacheDir, "ai-relief"), ReliefCache.inCacheDir(cacheDir).directory)
    assertEquals(200_000_000L, ReliefCache(directory).maxBytes)
  }

  @Test
  fun `a map is written as its header and its levels in 16 bits, little endian`() {
    val levels = intArrayOf(0, 1, 256, 65535, 32768, 0x1234)
    val file = cache().write(key(1), ReliefMap(3, 2, ShortArray(6) { levels[it].toShort() }))
    assertNotNull(file)
    assertEquals(File(directory, key(1) + ".u16"), file)
    val expected =
      byteArrayOf('I'.code.toByte(), 'M'.code.toByte(), 'R'.code.toByte(), 'L'.code.toByte()) +
        bytes(2, 0, 0, 0, 3, 0, 0, 0, 2, 0, 0, 0) +
        bytes(0, 0, 1, 0, 0, 1, 0xFF, 0xFF, 0, 0x80, 0x34, 0x12)
    assertArrayEquals(expected, file!!.readBytes())
  }

  @Test
  fun `the map of the model takes 710 712 bytes`() {
    assertEquals(710_712L, ReliefCache.fileSize(686, 518))
    val file = cache().write(key(2), map(2, 686, 518))
    assertEquals(710_712L, file!!.length())
  }

  @Test
  fun `what is written is read back`() {
    val cache = cache()
    val written = map(3, 7, 5)
    cache.write(key(3), written)
    val read = cache.read(key(3))
    assertNotNull(read)
    assertEquals(7, read!!.width)
    assertEquals(5, read.height)
    assertArrayEquals(written.levels, read.levels)
  }

  @Test
  fun `a write leaves no partial file and replaces the older map`() {
    val cache = cache()
    cache.write(key(4), map(4))
    cache.write(key(4), map(5))
    assertArrayEquals(map(5).levels, cache.read(key(4))!!.levels)
    assertEquals(listOf(key(4) + ".u16"), directory.list()!!.toList())
  }

  @Test
  fun `a write that cannot finish leaves nothing behind and says why`() {
    File(directory, key(6) + ".u16").mkdirs()
    File(directory, key(6) + ".u16/inside").writeText("x")
    assertNull(cache().write(key(6), map(6)))
    assertTrue(problems.isNotEmpty())
    assertTrue(directory.listFiles()!!.none { it.name.endsWith(".tmp") })
  }

  @Test
  fun `a missing or damaged map is no map, and the damaged file goes`() {
    val cache = cache()
    assertNull(cache.read(key(7)))
    val good = ReliefCache.encode(map(7))
    val damaged =
      mapOf(
        key(8) to good.copyOf().also { it[0] = 'X'.code.toByte() },
        key(9) to good.copyOf().also { it[4] = 1 },
        key(10) to good.copyOf(good.size - 2),
        key(11) to good.copyOf().also { it[8] = 0 },
        key(12) to ByteArray(3),
      )
    for ((key, bytes) in damaged) {
      File(directory, "$key.u16").writeBytes(bytes)
      assertNull(key, cache.read(key))
      assertFalse(key, File(directory, "$key.u16").exists())
    }
  }

  @Test
  fun `only a SHA-256 in hexadecimal is a key`() {
    assertTrue(ReliefCache.isKey(key(1)))
    assertTrue(ReliefCache.isKey("ab".repeat(32)))
    assertFalse(ReliefCache.isKey("AB".repeat(32)))
    assertFalse(ReliefCache.isKey(key(1).drop(1)))
    assertFalse(ReliefCache.isKey(key(1) + "0"))
    assertFalse(ReliefCache.isKey("../" + key(1).drop(3)))
    assertFalse(ReliefCache.isKey(""))
    val cache = cache()
    assertNull(cache.write("../outside", map(1)))
    assertNull(cache.read("../outside"))
    assertFalse(File(directory.parentFile, "outside.u16").exists())
  }

  @Test
  fun `reading a map marks it as used now`() {
    val cache = cache()
    val file = cache.write(key(13), map(13))!!
    assertEquals(now, file.lastModified())
    now += 60_000
    cache.read(key(13))
    assertEquals(now, file.lastModified())
  }

  @Test
  fun `past the cap the least recently read maps go first`() {
    val size = ReliefCache.fileSize(4, 4)
    val cache = cache(maxBytes = 3 * size)
    cache.write(key(1), map(1))
    now += 1000
    cache.write(key(2), map(2))
    now += 1000
    cache.write(key(3), map(3))
    now += 1000
    assertNotNull(cache.read(key(1)))
    now += 1000
    cache.write(key(4), map(4))
    assertNotNull(cache.read(key(1)))
    assertNull(cache.read(key(2)))
    assertNotNull(cache.read(key(3)))
    assertNotNull(cache.read(key(4)))
    assertEquals(3 * size, cache.sizeBytes())
  }

  @Test
  fun `the map just written stays, even alone over the cap`() {
    val cache = cache(maxBytes = 10)
    cache.write(key(1), map(1))
    assertNotNull(cache.read(key(1)))
    now += 1000
    cache.write(key(2), map(2))
    assertNull(cache.read(key(1)))
    assertNotNull(cache.read(key(2)))
  }

  @Test
  fun `partial files of cut writes and files of no map are removed, a young partial file stays`() {
    val stale = File(directory, key(1) + ".u16.123.tmp").apply { writeBytes(ByteArray(40)) }
    stale.setLastModified(now - 6 * 60_000)
    val young = File(directory, key(2) + ".u16.456.tmp").apply { writeBytes(ByteArray(40)) }
    young.setLastModified(now - 60_000)
    val foreign = File(directory, "old-format.u8").apply { writeBytes(ByteArray(5)) }
    val folder = File(directory, "sub").apply { mkdirs() }
    cache().write(key(3), map(3))
    assertFalse(stale.exists())
    assertTrue(young.exists())
    assertFalse(foreign.exists())
    assertTrue("a folder is not ours to remove", folder.exists())
  }

  @Test
  fun `the size counts every file of the cache, and clearing empties it`() {
    val cache = cache()
    assertEquals(0L, ReliefCache(File(directory, "missing")).sizeBytes())
    cache.write(key(1), map(1))
    cache.write(key(2), map(2, 8, 2))
    File(directory, key(3) + ".u16.9.tmp").writeBytes(ByteArray(10))
    assertEquals(ReliefCache.fileSize(4, 4) + ReliefCache.fileSize(8, 2) + 10, cache.sizeBytes())
    assertEquals(ReliefCache.fileSize(4, 4) + ReliefCache.fileSize(8, 2) + 10, cache.clear())
    assertEquals(0L, cache.sizeBytes())
    assertNull(cache.read(key(1)))
  }

  @Test
  fun `a normalised map is kept in 65 536 levels`() {
    val map = ReliefMap.quantize(7, 1, doubleArrayOf(0.0, 0.5, 1.0, 0.25, -0.1, 1.2, Double.NaN))
    // Not a number stays in the middle, as step 1 of relief-v1 makes it here and on the computers
    assertEquals(listOf(0, 32768, 65535, 16384, 0, 65535, 32768), (0 until 7).map { map.level(it) })
    val values = DoubleArray(1000) { it / 999.0 }
    val back = ReliefMap.quantize(1000, 1, values).toNormalized()
    for (i in values.indices) assertEquals(values[i], back[i], 0.5 / 65535 + 1e-12)
    assertEquals(0.0, back[0], 0.0)
    assertEquals(1.0, back[999], 0.0)
  }

  private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }
}
