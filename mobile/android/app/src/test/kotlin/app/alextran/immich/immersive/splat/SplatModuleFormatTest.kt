package app.alextran.immich.immersive.splat

import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the splat module reads, as measured on a Quest 3 on 31 October 2026: SPZ version 2 and the PLY the probe takes;
 * every SPZ of versions 1 to 3 rewritten first, version 4 never handed over, and the last checks of the file the
 * module gets, its head and, off the main thread, the whole of it.
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
  fun `every SPZ is rewritten, versions 2 and 4 too, a PLY read as it is`() {
    assertTrue(SplatModuleFormat.needsRewrite(probe("axes_v1.spz") as SplatHead))
    assertTrue(SplatModuleFormat.needsRewrite(probe("axes_v3.spz") as SplatHead))
    // A version 2 cut or short of its data aborts the module as surely as a version 3: it is written again too
    assertTrue(SplatModuleFormat.needsRewrite(probe("axes_v2.spz") as SplatHead))
    assertTrue(SplatModuleFormat.needsRewrite(probe("turns_v2.spz") as SplatHead))
    assertFalse(SplatModuleFormat.needsRewrite(probe("axes.ply") as SplatHead))
    // Version 4 (ZSTD), which the module aborts on, as its copy in version 2 (FreeKC's report of 1 November 2026)
    for (name in listOf("axes_v4.spz", "axes_v4_niantic.spz", "turns_v4.spz", "sh4_v4.spz")) {
      assertTrue(name, SplatModuleFormat.needsRewrite(probe(name) as SplatHead))
      assertFalse(name, SplatModuleFormat.reads(probe(name)))
    }
  }

  @Test
  fun `the whole check reads an SPZ to its end, one gzip member holding the data of version 2, nothing more or less`() {
    fun write(name: String, bytes: ByteArray): File = File(folder, name).apply { writeBytes(bytes) }
    val payload = GZIPInputStream(SplatFixtures.file("turns_v2.spz").inputStream()).use { it.readBytes() }
    val whole = gzip(payload)
    assertNull(SplatModuleFormat.checkWhole(write("a.spz", whole), 40))
    assertNull(SplatModuleFormat.checkWhole(SplatFixtures.file("axes_v2.spz").copyTo(File(folder, "b.spz")), 686))
    // A PLY: its head, its rows within the file
    assertNull(SplatModuleFormat.checkWhole(SplatFixtures.file("axes.ply").copyTo(File(folder, "c.ply")), 686))
    val refused =
      mapOf(
        "a stream cut" to whole.copyOf(whole.size - 30),
        "the trailer cut" to whole.copyOf(whole.size - 4),
        "a wrong CRC" to whole.copyOf().also { it[it.size - 8] = (it[it.size - 8].toInt() xor 0xff).toByte() },
        "a wrong length in the trailer" to whole.copyOf().also { it[it.size - 4] = (it[it.size - 4] + 1).toByte() },
        "short of its data" to gzip(payload.copyOf(payload.size - 10)),
        "more data than its head says" to gzip(payload + ByteArray(9)),
        "two members" to gzip(payload.copyOf(16)) + gzip(payload.copyOfRange(16, payload.size)),
        "bytes after the member" to whole + ByteArray(20),
        "the flag of extensions" to gzip(payload.copyOf().also { it[14] = 2 }),
        "version 3" to SplatFixtures.bytes("turns_v3.spz"),
      )
    for ((what, bytes) in refused) {
      assertNotNull(what, SplatModuleFormat.checkWhole(write("d.spz", bytes), 40))
    }
    // And all that the head check refuses
    assertNotNull(SplatModuleFormat.checkWhole(write("e.spz", whole), 41))
    assertNotNull(SplatModuleFormat.checkWhole(write("f.ply", whole), 40))
    assertEquals("no file", SplatModuleFormat.checkWhole(File(folder, "gone.spz"), 40))
  }

  private fun gzip(payload: ByteArray): ByteArray =
    ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(payload) } }.toByteArray()

  @Test
  fun `the splat scenes made on a computer reach the module as they are written, read to their end`() {
    // The SPZ version 2 of make_splat_fixtures.py and the one the Dart writer made (scene_sh3_v2_dart.spz, its gzip)
    val scenes = listOf("sh3_v2.spz" to 8L, "edges_sh3_v2.spz" to 32L, "scene_sh3_v2.spz" to 38L)
    for ((name, gaussians) in scenes + ("scene_sh3_v2_dart.spz" to 38L)) {
      assertTrue(name, SplatModuleFormat.reads(probe(name)))
      val copy = SplatFixtures.file(name).copyTo(File(folder, name), overwrite = true)
      assertNull(name, SplatModuleFormat.checkWhole(copy, gaussians))
      assertEquals(name, SplatModuleFormat.payloadBytes(probe(name) as SplatProbe.Spz), 16L + gaussians * (19 + 45))
    }
    for ((name, gaussians) in listOf("scene_sh3.ply" to 38L, "brush_sh3.ply" to 40L)) {
      assertTrue(name, SplatModuleFormat.reads(probe(name)))
      assertNull(name, SplatModuleFormat.checkWhole(SplatFixtures.file(name).copyTo(File(folder, name)), gaussians))
    }
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
