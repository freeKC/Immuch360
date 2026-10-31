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
 * and the files of the viewer that go with it.
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
    val source = copy("axes_v3.spz")
    val ready = prepare(source) as SplatPreparation.Ready
    assertEquals(source, ready.file)
    assertFalse(ready.owned)
    assertNull(ready.verdict.keep)
    assertNotNull(ready.bounds)
    assertTrue(SplatPlacement.isObject(ready.bounds))
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
  fun `a refused file says why, and a version 4 SPZ shows whole without positions`() {
    val mesh = prepare(copy("mesh_cube.ply")) as SplatPreparation.Stopped
    assertEquals(SplatRefusal.NOT_A_SPLAT, mesh.verdict.refusal)
    assertNull(mesh.head)
    val older = prepare(copy("axes_v3.spz"), device = "hollywood") as SplatPreparation.Stopped
    assertEquals(SplatRefusal.OLDER_HEADSET, older.verdict.refusal)
    val v4 = prepare(copy("axes_v4.spz")) as SplatPreparation.Ready
    assertNull(v4.bounds)
    assertEquals(4, (v4.head as SplatProbe.Spz).version)
  }
}
