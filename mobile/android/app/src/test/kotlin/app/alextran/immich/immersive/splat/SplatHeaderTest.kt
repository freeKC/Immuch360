package app.alextran.immich.immersive.splat

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.GZIPOutputStream
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The probe of the head of a splat file (lot S5): the SPZ of Niantic in its versions 1 to 4, the PLY of 3D Gaussian
 * Splatting, and the files refused with their reason, on the fixtures of make_splat_fixtures.py and on the heads of
 * two CC0 files of another writer (InnerScene).
 */
class SplatHeaderTest {
  private val headers = SplatFixtures.expected.getValue("headers").jsonObject

  private fun probe(name: String, fileLength: Long? = null): SplatProbe {
    val bytes = SplatFixtures.bytes(name)
    val length = fileLength ?: headers[name]?.jsonObject?.get("fileBytes")?.jsonPrimitive?.long ?: bytes.size.toLong()
    return SplatHeader.probe(bytes.copyOf(minOf(bytes.size, SplatHeader.HEAD_BYTES)), length)
  }

  private fun expectedCount(name: String): Long = headers.getValue(name).jsonObject.getValue("gaussians").jsonPrimitive.long

  private fun refusal(name: String): SplatFileProblem? = (probe(name) as? SplatProbe.Refused)?.problem

  @Test
  fun `the SPZ of versions 1 to 3 are read from the start of their gzip stream`() {
    for ((name, version) in listOf("axes_v1.spz" to 1, "axes_v2.spz" to 2, "axes_v3.spz" to 3)) {
      val head = probe(name) as SplatProbe.Spz
      assertEquals(name, version, head.version)
      assertEquals(name, expectedCount(name), head.gaussians)
      assertEquals(0, head.shDegree)
      assertEquals(12, head.fractionalBits)
      assertEquals(SplatFormat.SPZ, head.format)
      assertEquals(version, head.formatVersion)
      assertTrue(!head.isZstd)
    }
  }

  @Test
  fun `the SPZ of version 4 is read from its clear header`() {
    val head = probe("axes_v4.spz") as SplatProbe.Spz
    assertEquals(4, head.version)
    assertEquals(expectedCount("axes_v4.spz"), head.gaussians)
    assertEquals(6, head.streams)
    assertEquals(32L, head.tocOffset)
    assertTrue(head.isZstd)
    // As Niantic's writer gives them: no stream for an empty array, so 5 for degree 0, 6 from degree 1, up to degree 4
    for (name in listOf("axes_v4_niantic.spz", "turns_v4.spz", "sh4_v4.spz")) {
      val expected = headers.getValue(name).jsonObject
      val v4 = probe(name) as SplatProbe.Spz
      assertEquals(name, 4, v4.version)
      assertEquals(name, expected.getValue("gaussians").jsonPrimitive.long, v4.gaussians)
      assertEquals(name, expected.getValue("shDegree").jsonPrimitive.int, v4.shDegree)
      assertEquals(name, expected.getValue("streams").jsonPrimitive.int, v4.streams)
      assertEquals(name, 12, v4.fractionalBits)
    }
    assertEquals(72, (probe("sh4_v4.spz") as SplatProbe.Spz).shBytes)
  }

  /** [name] with the little endian long at [at] set to [value] */
  private fun withLong(name: String, at: Int, value: Long): ByteArray =
    SplatFixtures.bytes(name).also { ByteBuffer.wrap(it).order(ByteOrder.LITTLE_ENDIAN).putLong(at, value) }

  private fun refusalOf(bytes: ByteArray, length: Long = bytes.size.toLong()): SplatFileProblem? =
    (SplatHeader.probe(bytes, length) as? SplatProbe.Refused)?.problem

  @Test
  fun `a version 4 SPZ whose table of contents does not match its arrays is damaged`() {
    // The table of axes_v4_niantic.spz: 5 streams of 9, 1, 3, 3 and 4 bytes a point, from byte 32
    val good = SplatFixtures.bytes("axes_v4_niantic.spz")
    assertNull(refusalOf(good))
    // A decompressed size that is not the one of its array
    assertEquals(SplatFileProblem.DAMAGED, refusalOf(withLong("axes_v4_niantic.spz", 32 + 8, 686L * 9 + 1)))
    // A compressed size that runs past the end of the file, or streams that end before it
    assertEquals(SplatFileProblem.DAMAGED, refusalOf(withLong("axes_v4_niantic.spz", 32, 100_000)))
    assertEquals(SplatFileProblem.DAMAGED, refusalOf(good, good.size + 1L))
    assertEquals(SplatFileProblem.DAMAGED, refusalOf(good.copyOf(good.size - 1)))
    // Fewer streams than arrays, or a sixth one for harmonics of degree 0 that is not empty
    val four = good.copyOf().also { it[15] = 4 }
    assertEquals(SplatFileProblem.DAMAGED, refusalOf(four))
    val sixth = withLong("axes_v4.spz", 32 + 5 * 16 + 8, 1)
    assertEquals(SplatFileProblem.DAMAGED, refusalOf(sixth))
    // Positions that a fixed point of 24 bits cannot hold
    val bits = good.copyOf().also { it[13] = 0 }
    assertEquals(SplatFileProblem.DAMAGED, refusalOf(bits))
    // Harmonics past degree 4
    val degree = good.copyOf().also { it[12] = 5 }
    assertEquals(SplatFileProblem.DAMAGED, refusalOf(degree))
  }

  @Test
  fun `the PLY of a splat gives its count, its degree, its rows and the tool its comment names`() {
    val axes = probe("axes.ply") as SplatProbe.Ply
    assertEquals(expectedCount("axes.ply"), axes.gaussians)
    assertEquals(0, axes.shDegree)
    assertEquals("make_splat_fixtures.py", axes.tool)
    assertEquals(56, axes.rowBytes)
    assertEquals(SplatFormat.PLY, axes.format)
    assertEquals(1, axes.formatVersion)
    val bytes = SplatFixtures.bytes("axes.ply")
    assertEquals(bytes.size.toLong(), axes.headerBytes + axes.gaussians * axes.rowBytes)
    assertEquals(0, axes.offsetOf("x"))
    assertEquals(24, axes.offsetOf("opacity"))
    assertEquals(28, axes.offsetOf("scale_0"))

    val sh3 = probe("sh3.ply") as SplatProbe.Ply
    assertEquals(8L, sh3.gaussians)
    assertEquals(3, sh3.shDegree)
    assertEquals(headers.getValue("sh3.ply").jsonObject.getValue("rowBytes").jsonPrimitive.int, sh3.rowBytes)
    assertNull(sh3.tool)
  }

  @Test
  fun `the heads of two files of another writer read with the length of the whole file`() {
    val register = probe("cash_register_head.spz") as SplatProbe.Spz
    assertEquals(3, register.version)
    assertEquals(47819L, register.gaussians)
    val tape = probe("measuring_tape_head.ply") as SplatProbe.Ply
    assertEquals(19469L, tape.gaussians)
    // x y z, the normals, f_dc, opacity, three scales, four rotations
    assertEquals(68, tape.rowBytes)
    assertNull(tape.tool)
    // The same head with a file shorter than its rows: cut
    assertEquals(
      SplatFileProblem.DAMAGED,
      (probe("measuring_tape_head.ply", fileLength = 1_000_000) as SplatProbe.Refused).problem,
    )
  }

  @Test
  fun `a mesh, a point cloud, a compressed PLY, ASCII and big endian are refused with their reason`() {
    assertEquals(SplatFileProblem.NOT_A_SPLAT, refusal("mesh_cube.ply"))
    assertEquals(SplatFileProblem.NOT_A_SPLAT, refusal("point_cloud.ply"))
    assertEquals(SplatFileProblem.COMPRESSED_PLY, refusal("compressed.ply"))
    assertEquals(SplatFileProblem.UNSUPPORTED_PLY, refusal("ascii.ply"))
    assertEquals(SplatFileProblem.UNSUPPORTED_PLY, refusal("big_endian.ply"))
    // Its header ends past the 64 KiB the probe reads
    assertEquals(SplatFileProblem.DAMAGED, refusal("long_header.ply"))
  }

  @Test
  fun `SPZ heads that are wrong are refused, a newer version said apart`() {
    assertEquals(SplatFileProblem.DAMAGED, refusal("bad_magic.spz"))
    assertEquals(SplatFileProblem.DAMAGED, refusal("reserved.spz"))
    assertEquals(SplatFileProblem.DAMAGED, refusal("truncated.spz"))
    assertEquals(SplatFileProblem.NEWER_SPZ, refusal("newer.spz"))
    // A clear header of version 5
    val clear = ByteBuffer.allocate(32).order(ByteOrder.LITTLE_ENDIAN)
    clear.putInt(SplatHeader.SPZ_MAGIC).putInt(5).putInt(10).put(0).put(12).put(0).put(6).putInt(32)
    assertEquals(SplatFileProblem.NEWER_SPZ, (SplatHeader.probe(clear.array(), 4096) as SplatProbe.Refused).problem)
    // A version 4 header inside gzip is no SPZ of Niantic
    assertEquals(SplatFileProblem.DAMAGED, (SplatHeader.probe(gzip(spzHeader(4)), 100) as SplatProbe.Refused).problem)
    // No point at all
    assertEquals(
      SplatFileProblem.DAMAGED,
      (SplatHeader.probe(gzip(spzHeader(3, count = 0)), 100) as SplatProbe.Refused).problem,
    )
  }

  @Test
  fun `a PLY the module was never seen to read is refused, harmonics past degree 3, or values not stored as floats`() {
    // Measured on the Quest 3 (31 October 2026): degrees 0 to 3, floats or doubles. Anything else could abort it
    for ((rest, degree) in listOf(0 to 0, 9 to 1, 24 to 2, 45 to 3)) {
      assertEquals("$rest", degree, (probePly(rest = rest) as SplatProbe.Ply).shDegree)
    }
    val doubles = mapOf("x" to "double", "rot_0" to "double", "f_rest_7" to "double")
    assertEquals(3, (probePly(rest = 45, types = doubles) as SplatProbe.Ply).shDegree)
    // Degree 4 (72 coefficients), and counts that are no degree
    for (rest in listOf(72, 12, 3, 46)) {
      assertEquals("$rest", SplatFileProblem.UNSUPPORTED_PLY, (probePly(rest = rest) as SplatProbe.Refused).problem)
    }
    // Rotations, colours or harmonics as bytes or integers
    val types = listOf("rot_0" to "uchar", "rot_3" to "ushort", "f_dc_1" to "uchar", "f_rest_4" to "uchar", "f_dc_0" to "int")
    for ((name, type) in types) {
      assertEquals(
        "$name $type",
        SplatFileProblem.UNSUPPORTED_PLY,
        (probePly(rest = 9, types = mapOf(name to type)) as SplatProbe.Refused).problem,
      )
    }
  }

  @Test
  fun `an SPZ whose fixed point positions cannot be read is damaged`() {
    // 1 to 23 fractional bits fit a 24 bit position; 1 shl 32 is 1 on the JVM, which put a splat 4 096 times too far
    for (bits in listOf(1, 12, 23)) {
      val head = SplatHeader.probe(gzip(spzHeader(2, fractional = bits)), 100) as SplatProbe.Spz
      assertEquals("$bits", bits, head.fractionalBits)
    }
    for ((version, bits) in listOf(2 to 0, 2 to 24, 2 to 32, 3 to 0, 3 to 40)) {
      assertEquals(
        "version $version, $bits bits",
        SplatFileProblem.DAMAGED,
        (SplatHeader.probe(gzip(spzHeader(version, fractional = bits)), 100) as SplatProbe.Refused).problem,
      )
    }
    // Version 1 stores its positions as float16: its header may say anything, the rewrite gives 12
    assertEquals(0, (SplatHeader.probe(gzip(spzHeader(1, fractional = 0)), 100) as SplatProbe.Spz).fractionalBits)
  }

  @Test
  fun `anything else is no splat`() {
    for (bytes in listOf(ByteArray(0), "hello".toByteArray(), ByteArray(100) { it.toByte() })) {
      assertEquals(SplatFileProblem.NOT_A_SPLAT, (SplatHeader.probe(bytes, 100) as SplatProbe.Refused).problem)
    }
  }

  @Test
  fun `the tool is what a comment of the PLY names, never guessed`() {
    assertEquals("Postshot", SplatHeader.toolOf("Generated by Postshot"))
    assertEquals("Polycam 3.2", SplatHeader.toolOf("Exported from Polycam 3.2"))
    assertEquals("SuperSplat", SplatHeader.toolOf("created with SuperSplat"))
    assertEquals("Brush", SplatHeader.toolOf("Made with Brush"))
    assertNull(SplatHeader.toolOf("vertices 1234"))
    assertNull(SplatHeader.toolOf("Generated by "))
    // A long name is cut, not refused
    assertEquals(SplatHeader.MAX_TOOL_LENGTH, SplatHeader.toolOf("Generated by " + "x".repeat(200))!!.length)
    // The first comment that names one, in a header
    val header =
      "ply\nformat binary_little_endian 1.0\ncomment vertices kept\ncomment Exported from Scaniverse\n" +
        splatProperties(2) + "end_header\n"
    val ply = SplatHeader.probe(header.toByteArray() + ByteArray(2 * 68), (header.length + 2 * 68).toLong())
    assertEquals("Scaniverse", (ply as SplatProbe.Ply).tool)
  }

  @Test
  fun `a negative count is a damaged file, never a splat of -5 gaussians`() {
    // The header of negative_count.ply says element vertex -5 over four rows of the axes
    assertEquals(SplatFileProblem.DAMAGED, refusal("negative_count.ply"))
    val probe = probe("negative_count.ply")
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.DAMAGED),
      SplatGate.check(true, "eureka", probe, 1_000, SplatGate.SAFE_GAUSSIANS, null, null),
    )
    // Nor does a negative count of faces make a mesh pass for a splat
    val mesh =
      ("ply\nformat binary_little_endian 1.0\n" + splatProperties(1) + "element face -12\n" +
          "property list uchar int vertex_indices\nend_header\n")
        .toByteArray(Charsets.US_ASCII)
    assertEquals(
      SplatFileProblem.DAMAGED,
      (SplatHeader.probe(mesh + ByteArray(68), mesh.size + 68L) as SplatProbe.Refused).problem,
    )
  }

  @Test
  fun `the probe reads no more than its head`() {
    val bytes = SplatFixtures.bytes("long_header.ply")
    assertTrue(bytes.size > SplatHeader.HEAD_BYTES)
    // Given the whole file, it still looks at its first 64 KiB only
    assertEquals(
      SplatFileProblem.DAMAGED,
      (SplatHeader.probe(bytes, bytes.size.toLong()) as SplatProbe.Refused).problem,
    )
  }

  private fun splatProperties(count: Int): String =
    "element vertex $count\n" +
      listOf("x", "y", "z", "f_dc_0", "f_dc_1", "f_dc_2", "opacity", "scale_0", "scale_1", "scale_2").joinToString("") {
        "property float $it\n"
      } +
      (0 until 4).joinToString("") { "property float rot_$it\n" } +
      "property float nx\nproperty float ny\nproperty float nz\n"

  private fun spzHeader(version: Int, count: Int = 10, fractional: Int = 12): ByteArray {
    val buffer = ByteBuffer.allocate(16 + 64).order(ByteOrder.LITTLE_ENDIAN)
    buffer.putInt(SplatHeader.SPZ_MAGIC).putInt(version).putInt(count).put(0).put(fractional.toByte()).put(0).put(0)
    return buffer.array()
  }

  /** The probe of a PLY of 2 gaussians with [rest] f_rest_*, every property a float but those [types] names */
  private fun probePly(rest: Int, types: Map<String, String> = emptyMap()): SplatProbe {
    val names =
      listOf("x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2") + (0 until rest).map { "f_rest_$it" } +
        listOf("opacity", "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3")
    val sizes = mapOf("float" to 4, "double" to 8, "uchar" to 1, "ushort" to 2, "int" to 4)
    val header =
      "ply\nformat binary_little_endian 1.0\nelement vertex 2\n" +
        names.joinToString("") { "property ${types[it] ?: "float"} $it\n" } + "end_header\n"
    val row = names.sumOf { sizes.getValue(types[it] ?: "float") }
    val bytes = header.toByteArray(Charsets.US_ASCII) + ByteArray(2 * row)
    return SplatHeader.probe(bytes, bytes.size.toLong())
  }

  private fun gzip(bytes: ByteArray): ByteArray {
    val out = ByteArrayOutputStream()
    GZIPOutputStream(out).use { it.write(bytes) }
    return out.toByteArray()
  }
}
