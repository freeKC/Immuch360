package app.alextran.immich.spherical

import java.io.File
import java.io.RandomAccessFile
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The stabilisation table of a 360° player kept on disk for the player the system restores after the process died
 * (issue 14, fix-stab-android-46): what comes back, under which name, what is refused, how many are kept.
 */
class StabilizationStoreTest {
  private val directory: File = Files.createTempDirectory("stabilization").toFile()
  private val store = StabilizationStore(File(directory, "stabilization"))

  @After
  fun cleanUp() {
    directory.deleteRecursively()
  }

  private val url = "https://immich.example/api/assets/1/video/playback?key=secret"

  /** A message of the six frames of the real X5 slice, as setStabilization posts it */
  private fun message(
    url: String = this.url,
    enabled: Boolean = true,
    summary: String? = "X5, 6 frames",
  ): StabilizationInbox.Message {
    val x5 = StabilizationSliceTables.x5
    val times = longArrayOf(0, 33367, 66733, 100100, 133467, 166834)
    val corrections = DoubleArray(24)
    times.forEachIndexed { i, time -> x5.quaternionAt(time).copyInto(corrections, 4 * i) }
    val table = StabilizationTable.of(times, corrections)
    return StabilizationInbox.Message(url, enabled, true, table, summary, times, corrections)
  }

  @Test
  fun theTableComesBackAsFlutterSentIt() {
    val sent = message(enabled = false)
    assertTrue(store.save(sent))
    val back = store.load(url)!!
    assertEquals(url, back.url)
    assertFalse("the setting then", back.enabled)
    assertTrue(back.hasTrack)
    assertEquals("X5, 6 frames", back.summary)
    assertArrayEquals(sent.timesUs, back.timesUs)
    assertArrayEquals(sent.corrections, back.corrections, 0.0)
    for (time in longArrayOf(0, 20_000, 100_100, 1_000_000)) {
      assertArrayEquals(sent.table!!.quaternionAt(time), back.table!!.quaternionAt(time), 0.0)
    }
    // Saved again for the same URL, without a summary this time
    assertTrue(store.save(message(summary = null)))
    assertNull(store.load(url)!!.summary)
    assertEquals(1, File(directory, "stabilization").list()!!.size)
  }

  @Test
  fun theNameOfTheFileIsTheHashOfItsUrlNeverTheUrl() {
    assertTrue(store.save(message()))
    val name = File(directory, "stabilization").list()!!.single()
    assertTrue(name, Regex("[0-9a-f]{64}\\.bin").matches(name))
    assertEquals(StabilizationStore.fileName(url), name)
    val bytes = File(File(directory, "stabilization"), name).readBytes().toString(Charsets.ISO_8859_1)
    assertFalse("the key of the URL is not written", bytes.contains("secret"))
    assertNull("another URL has no table", store.load("$url&other"))
  }

  @Test
  fun aMessageWithoutATableWritesNothing() {
    assertFalse(store.save(StabilizationInbox.Message(url, true, true, null, null)))
    assertFalse(store.save(StabilizationInbox.Message(url, true, false, null, null)))
    assertNull(store.load(url))
  }

  @Test
  fun aFileCutOrDamagedIsRefusedAndSaysWhy() {
    assertTrue(store.save(message()))
    val file = File(File(directory, "stabilization"), StabilizationStore.fileName(url))
    val reasons = mutableListOf<String>()
    RandomAccessFile(file, "rw").use { it.setLength(it.length() / 2) }
    assertNull(store.load(url) { reasons += it })
    // A frame count larger than the file
    RandomAccessFile(file, "rw").use {
      it.seek(5)
      it.writeInt(1_000_000)
    }
    assertNull(store.load(url) { reasons += it })
    // Not a table of this player
    file.writeBytes(ByteArray(64) { 7 })
    assertNull(store.load(url) { reasons += it })
    assertEquals(reasons.toString(), 3, reasons.size)
    // A correction that is no rotation, refused as the player refuses it from Flutter
    val sent = message()
    sent.corrections!![0] = 2.0
    assertTrue(store.save(sent))
    assertNull(store.load(url) { reasons += it })
    assertTrue(reasons.last(), reasons.last().contains("norm"))
  }

  @Test
  fun theLastThreeTablesAreKeptAndAClosedPlayerTakesItsOwn() {
    val urls = (0 until 5).map { "file:///v$it.insv" }
    urls.forEachIndexed { i, u ->
      assertTrue(store.save(message(url = u)))
      File(File(directory, "stabilization"), StabilizationStore.fileName(u)).setLastModified(1_000_000L * (i + 1))
    }
    // Saving the fifth forgot the oldest down to three (the fourth had forgotten the first)
    assertEquals(listOf(false, false, true, true, true), urls.map { store.load(it) != null })
    store.delete(urls[3])
    assertEquals(listOf(false, false, true, false, true), urls.map { store.load(it) != null })
    assertFalse("no part file left", File(directory, "stabilization").list()!!.any { it.endsWith(".part") })
  }
}
