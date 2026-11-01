package app.alextran.immich.immersive.splat

import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.util.zip.Deflater
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream
import java.util.zip.Inflater
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The reading of a splat file before the module gets it (lot S5): whole, reduced, refused, renamed after its format,
 * every SPZ rewritten as version 2 (a damaged one refused, never handed over), the last check of what the module
 * gets, and the files of the viewer that go with it.
 */
class SplatPreparerTest {
  private val folder: File = Files.createTempDirectory("splat-prepare").toFile()

  @After
  fun cleanUp() {
    folder.deleteRecursively()
  }

  private fun copy(name: String, as_: String = name): File = SplatFixtures.file(name).copyTo(File(folder, as_))

  private fun prepare(
    source: File,
    owned: Boolean = false,
    cap: Int = SplatGate.SAFE_GAUSSIANS,
    device: String? = "eureka",
    freeCache: Long? = null,
  ): SplatPreparation =
    SplatPreparer.prepare(
      source,
      owned,
      cap,
      engine = true,
      device,
      { null },
      { null },
      folder,
      "splat-",
      freeCache = { freeCache },
    )

  private fun cacheCopies(): List<String> = folder.list().orEmpty().filter { it.startsWith("splat-") }.sorted()

  private fun write(name: String, bytes: ByteArray): File = File(folder, name).apply { writeBytes(bytes) }

  /** The data of the SPZ [name] of the fixtures, its gzip stream inflated */
  private fun payloadOf(name: String): ByteArray = GZIPInputStream(SplatFixtures.file(name).inputStream()).use { it.readBytes() }

  private fun gzip(payload: ByteArray): ByteArray =
    ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(payload) } }.toByteArray()

  /** [payload] in one gzip member of stored blocks, so that its bytes stand in the file as they are */
  private fun storedGzip(payload: ByteArray): ByteArray {
    val out = ByteArrayOutputStream()
    object : GZIPOutputStream(out) {
        init {
          def.setLevel(Deflater.NO_COMPRESSION)
        }
      }
      .use { it.write(payload) }
    return out.toByteArray()
  }

  /** [stored] (a stored gzip of [payload]) cut just after the byte [at] of its payload, as a copy that stopped */
  private fun cutAt(stored: ByteArray, payload: ByteArray, at: Int): ByteArray {
    val tail = payload.copyOfRange(at - 32, at)
    val start = (0..stored.size - tail.size).first { i -> tail.indices.all { stored[i + it] == tail[it] } }
    return stored.copyOf(start + tail.size)
  }

  /** The data of each gzip member of [bytes], in order; a cut member, or bytes that are no member, fail the test */
  private fun members(bytes: ByteArray): List<ByteArray> {
    val members = mutableListOf<ByteArray>()
    var at = 0
    while (at < bytes.size) {
      assertTrue("a gzip member at $at", bytes.size - at > 18 && bytes[at] == 0x1f.toByte() && bytes[at + 1] == 0x8b.toByte())
      // The header java.util.zip writes: 10 bytes, no extra field, name or comment
      assertEquals(0, bytes[at + 3].toInt())
      val inflater = Inflater(true)
      inflater.setInput(bytes, at + 10, bytes.size - at - 10)
      val out = ByteArrayOutputStream()
      val buffer = ByteArray(4096)
      while (!inflater.finished()) {
        val n = inflater.inflate(buffer)
        if (n == 0 && inflater.needsInput()) fail("the member at $at is cut")
        out.write(buffer, 0, n)
      }
      at = bytes.size - inflater.remaining + 8
      inflater.end()
      assertTrue("the trailer of the member", at <= bytes.size)
      members += out.toByteArray()
    }
    return members
  }

  @Test
  fun `a PLY within the count is read where it is, its bounds from all its points`() {
    val source = copy("axes.ply")
    val ready = prepare(source) as SplatPreparation.Ready
    assertEquals(source, ready.file)
    assertFalse(ready.owned)
    assertNull(ready.verdict.keep)
    assertNotNull(ready.bounds)
    assertTrue(SplatPlacement.isObject(ready.bounds))
    // An object: no orientation said by its gaussians, the default holds
    assertNull(ready.upright)
    // An SPZ of version 2 is placed the same, from its rewritten copy
    val spz = prepare(copy("axes_v2.spz")) as SplatPreparation.Ready
    assertTrue(SplatPlacement.isObject(spz.bounds))
    assertNull(spz.upright)
  }

  @Test
  fun `every SPZ within the count is rewritten whole as version 2, never handed over as it is`() {
    // The splat module reads version 2 only and aborts the process on version 3 (Quest 3, 31 October 2026), and on a
    // version 2 cut or short of its data (review of the fix, 31 October): even a version 2 goes through the rewrite
    for (name in listOf("axes_v3.spz", "axes_v1.spz", "turns_v3.spz", "axes_v2.spz", "turns_v2.spz")) {
      val mine = copy(name)
      val ready = prepare(mine) as SplatPreparation.Ready
      assertTrue(name, ready.owned)
      assertTrue(name, ready.file != mine && ready.file.name.startsWith("splat-") && ready.file.name.endsWith(".spz"))
      val written = SplatHeader.read(ready.file) as SplatProbe.Spz
      assertEquals(name, 2, written.version)
      assertEquals(name, (SplatHeader.read(mine) as SplatHead).gaussians, written.gaussians)
      assertNull(ready.verdict.keep)
      // The head of the source still names the file in the panel and in the memory of its orientation
      assertEquals(mine.length(), ready.sourceBytes)
      assertTrue(mine.exists())
    }
    // A download of the viewer goes once rewritten
    val download = copy("axes_v3.spz", "download.part")
    val ready = prepare(download, owned = true) as SplatPreparation.Ready
    assertFalse(download.exists())
    assertEquals(2, (SplatHeader.read(ready.file) as SplatProbe.Spz).version)
    // A version 2 comes out as one gzip member written by the viewer, its data byte for byte
    for (name in listOf("axes_v2.spz", "turns_v2.spz")) {
      val rewritten = prepare(copy(name, "again-$name")) as SplatPreparation.Ready
      assertEquals(name, listOf(payloadOf(name).toList()), members(rewritten.file.readBytes()).map { it.toList() })
    }
  }

  @Test
  fun `a version 2 SPZ cut or short of its data is refused as damaged, never handed to the module`() {
    // turns_v2: 40 gaussians of degree 1, 1 136 bytes of data, its harmonics from byte 776 on. The module aborts the
    // whole process on such a file ("decompressGzipped: failed", "deserializePackedGaussians: read error", SIGABRT,
    // Quest 3, 31 October 2026), while the first reading stops at the scales and never sees the cut
    val payload = payloadOf("turns_v2.spz")
    assertEquals(1_136, payload.size)
    val whole = gzip(payload)
    val damaged =
      mapOf(
        "cut in its harmonics" to cutAt(storedGzip(payload), payload, 1_000),
        "short of its last 10 bytes" to gzip(payload.copyOf(payload.size - 10)),
        "a header that says more harmonics than its data holds" to gzip(payload.copyOf().also { it[12] = 3 }),
        "its gzip trailer cut" to whole.copyOf(whole.size - 4),
        "a wrong CRC" to whole.copyOf().also { it[it.size - 8] = (it[it.size - 8].toInt() xor 0xff).toByte() },
      )
    for ((what, bytes) in damaged) {
      for (owned in listOf(false, true)) {
        val source = write(if (owned) "download.part" else "turns.spz", bytes)
        // As the viewer does: the exception says "This splat file is damaged or incomplete", the files go at the end
        val files = SplatCacheFiles(if (owned) source else null)
        try {
          val preparation = files.prepared(prepare(source, owned = owned))
          fail("$what, owned $owned: ${(preparation as? SplatPreparation.Ready)?.file?.name ?: preparation}")
        } catch (e: SplatReadException) {
          assertEquals(what, SplatFileProblem.DAMAGED, e.problem)
        } finally {
          files.release()
        }
        // Nothing of it left in the cache, the download gone; the file of the user stays
        assertEquals(what, emptyList<String>(), cacheCopies())
        assertEquals(what, !owned, source.exists())
        source.delete()
      }
    }
  }

  @Test
  fun `a version 2 SPZ in two members, with bytes after it or the flag of extensions, comes out as one clean member`() {
    val payload = payloadOf("turns_v2.spz")
    val inputs =
      mapOf(
        "two gzip members" to gzip(payload.copyOf(16)) + gzip(payload.copyOfRange(16, payload.size)),
        "bytes after the gzip member" to gzip(payload) + "GARBAGE".repeat(20).toByteArray(),
        "the flag of extensions, no extension" to gzip(payload.copyOf().also { it[14] = 2 }),
      )
    for ((what, bytes) in inputs) {
      val source = write("odd.spz", bytes)
      val ready = prepare(source) as SplatPreparation.Ready
      assertTrue(what, ready.owned && ready.file != source)
      assertEquals(what, listOf(payload.toList()), members(ready.file.readBytes()).map { it.toList() })
      ready.file.delete()
    }
  }

  @Test
  fun `whatever the path, the file handed to the module is one it reads, with the count expected`() {
    val splats =
      listOf("axes.ply", "axes_v1.spz", "axes_v2.spz", "axes_v3.spz", "ranked.ply", "ranked_v3.spz", "sh3.ply", "turns_v3.spz")
    for (name in splats) {
      for (cap in listOf(SplatGate.SAFE_GAUSSIANS, 10)) {
        for (owned in listOf(false, true)) {
          val source = copy(name, if (owned) "download-$cap.part" else "$cap-$name")
          val ready = prepare(source, owned = owned, cap = cap) as SplatPreparation.Ready
          val expected = ready.verdict.keep?.toLong() ?: ready.head.gaussians
          assertNull("$name $cap $owned", SplatModuleFormat.check(ready.file, expected))
          if (ready.owned) ready.file.delete()
        }
      }
    }
  }

  @Test
  fun `beyond the count a reduced copy is read, and a download of the viewer goes`() {
    val source = copy("ranked.ply", "download.part")
    val ready = prepare(source, owned = true, cap = 10) as SplatPreparation.Ready
    assertTrue(ready.owned)
    assertTrue(ready.file.name.startsWith("splat-") && ready.file.name.endsWith(".ply"))
    assertEquals(10L, (SplatHeader.read(ready.file) as SplatHead).gaussians)
    assertEquals(10, ready.verdict.keep)
    assertFalse(source.exists())
    // The file of the user stays
    val mine = copy("ranked_v3.spz")
    val reduced = prepare(mine, cap = 10) as SplatPreparation.Ready
    assertTrue(mine.exists())
    assertTrue(reduced.file.name.endsWith(".spz"))
  }

  @Test
  fun `a file named after another format is read under the name of its own`() {
    val mine = copy("axes_v3.spz", "axes.ply")
    val ready = prepare(mine) as SplatPreparation.Ready
    assertTrue(ready.file.name.endsWith(".spz"))
    assertTrue(ready.owned)
    assertTrue(mine.exists())
    val download = copy("axes.ply", "download.part")
    val renamed = prepare(download, owned = true) as SplatPreparation.Ready
    assertTrue(renamed.file.name.endsWith(".ply"))
    assertFalse(download.exists())
  }

  @Test
  fun `an extension in capitals reaches the module in lower case`() {
    // A SCENE.SPZ picked in the headset: a file of the user, copied under the lower case name
    val mine = copy("axes_v3.spz", "AXES.SPZ")
    val ready = prepare(mine) as SplatPreparation.Ready
    assertTrue(ready.file.name, ready.file.name.endsWith(".spz"))
    assertTrue(ready.owned)
    assertTrue(mine.exists())
    assertEquals(mine.length(), ready.sourceBytes)
    // A download of the viewer named so is renamed, not copied
    val download = copy("axes.ply", "SCENE.PLY")
    val renamed = prepare(download, owned = true) as SplatPreparation.Ready
    assertTrue(renamed.file.name, renamed.file.name.endsWith(".ply"))
    assertFalse(download.exists())
    // Already in lower case: read where it is
    val plain = copy("axes.ply", "plain.ply")
    assertEquals(plain, (prepare(plain) as SplatPreparation.Ready).file)
  }

  @Test
  fun `a cache without room for the reduced copy refuses before writing anything`() {
    val mine = copy("ranked.ply")
    val stopped = prepare(mine, cap = 10, freeCache = 0) as SplatPreparation.Stopped
    assertEquals(SplatRefusal.NOT_ENOUGH_SPACE, stopped.verdict.refusal)
    assertEquals(emptyList<String>(), cacheCopies())
    // With room, the reduced copy is written, and the size of its source is kept for the memory of its orientation
    val ready = prepare(mine, cap = 10, freeCache = 1L shl 30) as SplatPreparation.Ready
    assertEquals(mine.length(), ready.sourceBytes)
    assertTrue(ready.file.length() < mine.length())
  }

  @Test
  fun `what the stage did not take leaves the cache, a file of the user never`() {
    // Ready but never handed over (a cancellation once prepared): the reduced copy and the download go
    val download = copy("ranked.ply", "download.part")
    val files = SplatCacheFiles(download)
    val ready = files.prepared(prepare(download, owned = true, cap = 10)) as SplatPreparation.Ready
    assertTrue(ready.file.exists())
    files.release()
    assertFalse(ready.file.exists())
    assertFalse(download.exists())
    assertEquals(emptyList<String>(), cacheCopies())
    // Handed over: the stage keeps it
    val kept = SplatCacheFiles(null)
    val shown = kept.prepared(prepare(copy("ranked_v3.spz"), cap = 10)) as SplatPreparation.Ready
    kept.handOver()
    kept.release()
    assertTrue(shown.file.exists())
    // A file of the user read where it is stays, handed over or not
    val mine = copy("axes_v3.spz", "mine.spz")
    val own = SplatCacheFiles(null)
    own.prepared(prepare(mine))
    own.release()
    assertTrue(mine.exists())
    // Refused: the download goes
    val refused = copy("mesh_cube.ply", "refused.part")
    val stopped = SplatCacheFiles(refused)
    stopped.prepared(prepare(refused, owned = true))
    stopped.release()
    assertFalse(refused.exists())
  }

  @Test
  fun `a refused file says why, and a version 4 SPZ is refused before anything is written`() {
    val mesh = prepare(copy("mesh_cube.ply")) as SplatPreparation.Stopped
    assertEquals(SplatRefusal.NOT_A_SPLAT, mesh.verdict.refusal)
    assertNull(mesh.head)
    val older = prepare(copy("axes_v3.spz"), device = "hollywood") as SplatPreparation.Stopped
    assertEquals(SplatRefusal.OLDER_HEADSET, older.verdict.refusal)
    // The module aborts the process on version 4: it never gets it, whole or not
    val v4 = prepare(copy("axes_v4.spz")) as SplatPreparation.Stopped
    assertEquals(SplatRefusal.SPZ_V4, v4.verdict.refusal)
    assertEquals(4, (v4.head as SplatProbe.Spz).version)
    assertEquals(emptyList<String>(), cacheCopies())
  }
}
