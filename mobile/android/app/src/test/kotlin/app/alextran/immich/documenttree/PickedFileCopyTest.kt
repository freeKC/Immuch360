package app.alextran.immich.documenttree

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Where a file picked with pickFile is copied (lot S5): a safe name, its extension kept, the folder holding it alone */
class PickedFileCopyTest {
  @Test
  fun `a name keeps its extension and loses what a path would take`() {
    assertEquals("gsplat-cactus.spz", PickedFileCopy.safeName("gsplat-cactus.spz"))
    assertEquals("a_b_c.ply", PickedFileCopy.safeName("a/b\\c.ply"))
    assertEquals("x_y.spz", PickedFileCopy.safeName("x:y.spz"))
    assertEquals("hidden.spz", PickedFileCopy.safeName("..hidden.spz"))
    assertEquals("file", PickedFileCopy.safeName(null))
    assertEquals("file", PickedFileCopy.safeName("  "))
    val long = PickedFileCopy.safeName("n".repeat(300) + ".spz")
    assertEquals(PickedFileCopy.MAX_NAME, long.length)
    assertTrue(long.endsWith(".spz"))
  }

  @Test
  fun `the folder holds the last copy only`() {
    val cache = Files.createTempDirectory("picked").toFile()
    try {
      val first = PickedFileCopy.targetFor(cache, "picked-splat", "a.spz").apply { writeText("a") }
      val second = PickedFileCopy.targetFor(cache, "picked-splat", "b.ply")
      assertFalse(first.exists())
      assertEquals(File(cache, "picked-splat"), second.parentFile)
      assertTrue(second.parentFile!!.isDirectory)
    } finally {
      cache.deleteRecursively()
    }
  }
}
