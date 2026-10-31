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
 * What the splat module reads, as measured on a Quest 3 on 31 October 2026: SPZ version 2 and the PLY the probe takes;
 * versions 1 and 3 rewritten first, version 4 never handed over, and the last check of the file the module gets.
 */
class SplatModuleFormatTest {
  private val folder: File = Files.createTempDirectory("splat-module").toFile()

  @After
  fun cleanUp() {
    folder.deleteRecursively()
  }

  private fun probe(name: String) = SplatHeader.read(SplatFixtures.file(name))

  @Test
  fun `the module reads SPZ version 2 and the PLY of the probe, nothing else`() {
    assertTrue(SplatModuleFormat.reads(probe("axes_v2.spz")))
    assertTrue(SplatModuleFormat.reads(probe("turns_v2.spz")))
    assertTrue(SplatModuleFormat.reads(probe("axes.ply")))
    assertTrue(SplatModuleFormat.reads(probe("sh3.ply")))
    // Version 3 and 4 abort the process; version 1 loads but its points are not where they should be
    for (name in listOf("axes_v1.spz", "axes_v3.spz", "axes_v4.spz", "turns_v3.spz")) {
      assertFalse(name, SplatModuleFormat.reads(probe(name)))
    }
    // What the probe refuses, the module never gets (a mesh, a point cloud, a compressed PLY abort it too)
    for (name in listOf("mesh_cube.ply", "point_cloud.ply", "compressed.ply", "ascii.ply", "big_endian.ply", "newer.spz")) {
      assertFalse(name, SplatModuleFormat.reads(probe(name)))
    }
  }

  @Test
  fun `versions 1 and 3 are rewritten, version 2 and PLY read as they are, version 4 not at all`() {
    assertTrue(SplatModuleFormat.needsRewrite(probe("axes_v1.spz") as SplatHead))
    assertTrue(SplatModuleFormat.needsRewrite(probe("axes_v3.spz") as SplatHead))
    assertFalse(SplatModuleFormat.needsRewrite(probe("axes_v2.spz") as SplatHead))
    assertFalse(SplatModuleFormat.needsRewrite(probe("axes.ply") as SplatHead))
    assertFalse(SplatModuleFormat.needsRewrite(probe("axes_v4.spz") as SplatHead))
  }

  @Test
  fun `the last check refuses what the module would abort on, and a file that is not what was prepared`() {
    fun copy(name: String, as_: String): File = SplatFixtures.file(name).copyTo(File(folder, as_), overwrite = true)
    assertNull(SplatModuleFormat.check(copy("axes_v2.spz", "a.spz"), 686))
    assertNull(SplatModuleFormat.check(copy("axes.ply", "a.ply"), 686))
    // An SPZ of version 3, as build 38 handed it over
    assertEquals("SPZ version 3", SplatModuleFormat.check(copy("axes_v3.spz", "b.spz"), 686))
    assertEquals("SPZ version 4", SplatModuleFormat.check(copy("axes_v4.spz", "c.spz"), 686))
    // Named after another format, or holding another count than the one prepared
    assertNotNull(SplatModuleFormat.check(copy("axes_v2.spz", "d.ply"), 686))
    assertNotNull(SplatModuleFormat.check(copy("axes.ply", "e.ply"), 685))
    // Gone, cut, or no splat
    assertEquals("no file", SplatModuleFormat.check(File(folder, "gone.spz"), 686))
    assertNotNull(SplatModuleFormat.check(copy("truncated.spz", "f.spz"), 686))
    assertNotNull(SplatModuleFormat.check(copy("mesh_cube.ply", "g.ply"), 8))
  }
}
