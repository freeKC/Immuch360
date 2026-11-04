package app.alextran.immich.immersive

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The start-up cleaning of the immersive viewer (plan of 3 November 2026, lot L4): the leftovers of earlier viewings
 * go, the splat viewer's folder of the cache, where the scenes of the splat photos are kept, stays whole.
 */
class ImmersiveCacheCleaningTest {
  @Test
  fun `the originals and splats of earlier viewings go, the folders of the cache stay`() {
    val cache = Files.createTempDirectory("immersive-cache").toFile()
    try {
      val original = File(cache, "immersive_original_123").apply { writeText("a") }
      val splat = File(cache, "immersive_splat_456.part").apply { writeText("b") }
      val other = File(cache, "picked-splat").apply { writeText("c") }
      val folder = File(cache, "splat_viewer").apply { mkdirs() }
      val scene = File(folder, "server-asset-0123456789abcdef.spz").apply { writeText("d") }
      val inside = File(folder, "immersive_splat_789").apply { writeText("e") }

      val prefixes = listOf("immersive_original_", "immersive_splat_")
      val leftovers = ImmersiveCacheCleaning.leftovers(cache.listFiles(), prefixes)
      assertEquals(setOf(original, splat), leftovers.toSet())
      leftovers.forEach { it.delete() }

      assertTrue(other.exists())
      assertTrue(folder.isDirectory)
      assertTrue(scene.exists())
      assertTrue("only the top of the cache is cleaned", inside.exists())
    } finally {
      cache.deleteRecursively()
    }
  }

  @Test
  fun `a cache that could not be listed leaves nothing to delete`() {
    assertEquals(emptyList<File>(), ImmersiveCacheCleaning.leftovers(null, listOf("immersive_original_")))
  }
}
