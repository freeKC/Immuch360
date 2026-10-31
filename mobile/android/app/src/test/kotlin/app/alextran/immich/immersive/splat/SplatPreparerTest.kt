package app.alextran.immich.immersive.splat

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The reading of a splat file before the module gets it (lot S5): whole, reduced, refused, renamed after its format,
 * an SPZ of version 1 or 3 rewritten as version 2, the last check of what the module gets, and the files of the
 * viewer that go with it.
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

  @Test
  fun `a splat within the count is read where it is, its bounds from all its points`() {
    for (name in listOf("axes_v2.spz", "axes.ply")) {
      val source = copy(name)
      val ready = prepare(source) as SplatPreparation.Ready
      assertEquals(source, ready.file)
      assertFalse(ready.owned)
      assertNull(ready.verdict.keep)
      assertNotNull(ready.bounds)
      assertTrue(SplatPlacement.isObject(ready.bounds))
      // An object: no orientation said by its gaussians, the default holds
      assertNull(ready.upright)
    }
  }

  @Test
  fun `an SPZ of version 1 or 3 within the count is rewritten whole as version 2, never handed over as it is`() {
    // The splat module reads version 2 only and aborts the process on version 3 (Quest 3, 31 October 2026)
    for (name in listOf("axes_v3.spz", "axes_v1.spz", "turns_v3.spz")) {
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
    val plain = copy("axes_v2.spz", "plain.spz")
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
