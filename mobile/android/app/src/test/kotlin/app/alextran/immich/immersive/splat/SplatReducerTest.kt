package app.alextran.immich.immersive.splat

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.GZIPInputStream
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The reduction of a splat to its strongest gaussians (lot S5): the scores (opacity times volume, as logarithms), the
 * selection with its ties, and the files written again in their format, the rows of a PLY kept byte for byte, an SPZ
 * as version 2 (the only one the splat module reads), checked against what make_splat_fixtures.py computed. Then the
 * sample of the positions the placement reads.
 */
class SplatReducerTest {
  private val reduction = SplatFixtures.expected.getValue("reduction").jsonObject
  private val keep = reduction.getValue("keep").jsonPrimitive.int

  private fun head(name: String): SplatHead = SplatHeader.probe(SplatFixtures.bytes(name), SplatFixtures.file(name).length()) as SplatHead

  private fun scan(name: String, sampleLimit: Int = SplatReducer.SAMPLE_LIMIT): SplatScan =
    SplatReducer.scan(SplatFixtures.file(name).inputStream(), head(name), sampleLimit)

  private fun expectedKept(name: String): List<Int> =
    reduction.getValue(name).jsonObject.getValue("kept").jsonArray.map { it.jsonPrimitive.int }

  private fun expectedScores(name: String): List<Double> =
    reduction.getValue(name).jsonObject.getValue("scores").jsonArray.map { it.jsonPrimitive.double }

  @Test
  fun `the scores of an SPZ and a PLY are those of the reference`() {
    for (name in listOf("ranked_v3.spz", "ranked.ply")) {
      val scores = scan(name).scores
      val expected = expectedScores(name)
      assertEquals(expected.size, scores.size)
      for (i in expected.indices) assertEquals("$name $i", expected[i], scores[i].toDouble(), 1e-4)
    }
  }

  @Test
  fun `the strongest are kept, a tie going to the lower index`() {
    for (name in listOf("ranked_v3.spz", "ranked.ply")) {
      val kept = SplatReducer.select(scan(name).scores, keep)
      assertEquals(name, expectedKept(name), (0 until 24).filter { kept[it] })
    }
    // Three tied at the cut: the first two of them
    val kept = SplatReducer.select(floatArrayOf(5f, 3f, 1f, 3f, 3f, 0f), 3)
    assertEquals(listOf(0, 1, 3), (0 until 6).filter { kept[it] })
    // A score that is not a number comes last
    val nan = SplatReducer.select(floatArrayOf(Float.NaN, 1f, 2f), 2)
    assertEquals(listOf(1, 2), (0 until 3).filter { nan[it] })
    assertEquals(4, SplatReducer.select(floatArrayOf(1f, 2f, 3f, 4f), 10).cardinality())
    assertEquals(0, SplatReducer.select(floatArrayOf(1f, 2f), 0).cardinality())
  }

  private fun gunzip(bytes: ByteArray): ByteArray = GZIPInputStream(ByteArrayInputStream(bytes)).readBytes()

  private fun written(name: String, kept: java.util.BitSet): ByteArray {
    val out = ByteArrayOutputStream()
    SplatReducer.write(SplatFixtures.file(name).inputStream(), head(name), kept, out)
    return out.toByteArray()
  }

  private fun all(count: Int) = java.util.BitSet().apply { set(0, count) }

  @Test
  fun `an SPZ is written again as version 2 with the kept points of each attribute`() {
    val name = "ranked_v3.spz"
    val kept = SplatReducer.select(scan(name).scores, keep)
    val written = written(name, kept)
    // A version 2 SPZ of 10 points, as the probe reads it: the one version the splat module reads
    val probe = SplatHeader.probe(written, written.size.toLong()) as SplatProbe.Spz
    assertEquals(2, probe.version)
    assertEquals(keep.toLong(), probe.gaussians)
    assertTrue(SplatModuleFormat.reads(probe))
    val before = gunzip(SplatFixtures.bytes(name))
    val after = gunzip(written)
    val indices = expectedKept(name)
    // Positions, alphas, colours and scales copied; the rotations of 4 bytes as 3 (identity: 128, 128, 128)
    var from = 16
    var to = 16
    for (size in listOf(9, 1, 3, 3)) {
      for ((j, i) in indices.withIndex()) {
        assertArrayEquals(
          before.copyOfRange(from + i * size, from + (i + 1) * size),
          after.copyOfRange(to + j * size, to + (j + 1) * size),
        )
      }
      from += 24 * size
      to += indices.size * size
    }
    for (j in indices.indices) assertArrayEquals(byteArrayOf(-128, -128, -128), after.copyOfRange(to + 3 * j, to + 3 * j + 3))
    assertEquals(to + 3 * indices.size, after.size)
    // The header: magic, version 2, the new count, the degree, the fractional bits and the flags of the source
    assertArrayEquals(before.copyOfRange(0, 4), after.copyOfRange(0, 4))
    assertEquals(2, after[4].toInt())
    assertArrayEquals(before.copyOfRange(12, 16), after.copyOfRange(12, 16))
  }

  @Test
  fun `a version 3 SPZ rewritten whole is the version 2 of the reference, every rotation recoded`() {
    // turns_v3.spz: 40 gaussians of degree 1, rotations of every kind; turns_v2.spz: the same as version 2, written
    // by make_splat_fixtures.py from the public description of the format
    val module = SplatFixtures.expected.getValue("moduleSpz").jsonObject
    for ((source, reference) in module.getValue("rewrites").jsonObject) {
      val count = head(source).gaussians.toInt()
      val written = written(source, all(count))
      assertArrayEquals(source, gunzip(SplatFixtures.bytes(reference.jsonPrimitive.content)), gunzip(written))
      val probe = SplatHeader.probe(written, written.size.toLong()) as SplatProbe.Spz
      assertEquals(2, probe.version)
      assertEquals(count.toLong(), probe.gaussians)
    }
  }

  @Test
  fun `a version 1 SPZ reduced keeps the fixed point positions of its kept points`() {
    val name = "axes_v1.spz"
    val kept = java.util.BitSet().apply {
      set(5, 40)
      set(600, 686)
    }
    val after = gunzip(written(name, kept))
    val reference = gunzip(SplatFixtures.bytes("axes_v1_v2.spz"))
    val indices = (0 until 686).filter { kept[it] }
    var from = 16
    var to = 16
    for (size in listOf(9, 1, 3, 3, 3)) {
      for ((j, i) in indices.withIndex()) {
        assertArrayEquals(
          "$size $i",
          reference.copyOfRange(from + i * size, from + (i + 1) * size),
          after.copyOfRange(to + j * size, to + (j + 1) * size),
        )
      }
      from += 686 * size
      to += indices.size * size
    }
    assertEquals(to, after.size)
  }

  @Test
  fun `the recoded rotations turn as the source ones, within the precision of three bytes`() {
    // As the reference measures it: 1 - |q3 . q2| for each rotation of turns_v3.spz
    val worst = SplatFixtures.expected.getValue("moduleSpz").jsonObject.getValue("worstRotation").jsonPrimitive.double
    assertTrue("$worst", worst < 0.005)
    // The identity, a half turn about x, and w negative: the same rotation with w made positive
    val out = ByteArray(3)
    fun recode(comp: Long): List<Int> {
      val bytes = byteArrayOf(comp.toByte(), (comp shr 8).toByte(), (comp shr 16).toByte(), (comp shr 24).toByte())
      SplatReducer.firstThreeOfSmallestThree(bytes, 0, out, 0)
      return out.map { it.toInt() and 0xff }
    }
    assertEquals(listOf(128, 128, 128), recode(3L shl 30))
    // x the largest, the others 0: (1, 0, 0, 0), x stored as 255
    assertEquals(listOf(255, 128, 128), recode(0L shl 30))
    // w the largest and y at -0.5: sign bit of y set, 9 bits of 0.5 / sqrt(1/2) * 511 = 361
    val y = (1L shl 9) or 361L
    val comp = (3L shl 30) or (y shl 10)
    val q = recode(comp)
    assertEquals(128, q[0])
    // About -0.5 * 127.5 + 128 = 64.25
    assertTrue("$q", q[1] in 63..65)
    assertEquals(128, q[2])
  }

  @Test
  fun `a PLY is written again with its header and its kept rows, untouched`() {
    val name = "ranked.ply"
    val source = head(name) as SplatProbe.Ply
    val kept = SplatReducer.select(scan(name).scores, keep)
    val out = ByteArrayOutputStream()
    SplatReducer.write(SplatFixtures.file(name).inputStream(), source, kept, out)
    val written = out.toByteArray()
    val probe = SplatHeader.probe(written, written.size.toLong()) as SplatProbe.Ply
    assertEquals(keep.toLong(), probe.gaussians)
    assertEquals(source.properties, probe.properties)
    val before = SplatFixtures.bytes(name)
    val headerBefore = String(before, 0, source.headerBytes, Charsets.US_ASCII)
    val headerAfter = String(written, 0, probe.headerBytes, Charsets.US_ASCII)
    assertEquals(headerBefore.replace("element vertex 24\n", "element vertex 10\n"), headerAfter)
    for ((j, i) in expectedKept(name).withIndex()) {
      val row = source.rowBytes
      assertArrayEquals(
        before.copyOfRange(source.headerBytes + i * row, source.headerBytes + (i + 1) * row),
        written.copyOfRange(probe.headerBytes + j * row, probe.headerBytes + (j + 1) * row),
      )
    }
    assertEquals(probe.headerBytes + keep * source.rowBytes, written.size)
  }

  @Test
  fun `the positions of a small splat are all sampled, decoded as the reference does`() {
    val percentiles = SplatFixtures.expected.getValue("percentiles").jsonObject
    for (name in listOf("axes_v3.spz", "axes_v1.spz")) {
      val scan = scan(name)
      val count = head(name).gaussians.toInt()
      assertEquals(count, scan.sampleCount)
      assertArrayEquals((0 until count).toList().toIntArray(), scan.sampleIndices)
      val expected = percentiles.getValue(name).jsonObject
      val bounds = SplatPlacement.boundsOf(scan, null)!!
      for ((k, axis) in listOf("x", "y", "z").withIndex()) {
        val (low, high) = expected.getValue(axis).jsonArray.map { it.jsonPrimitive.double }
        assertEquals("$name $axis", low, bounds.low[k], 1e-6)
        assertEquals("$name $axis", high, bounds.high[k], 1e-6)
      }
    }
    // The PLY gives the same positions as the SPZ of version 3, but for its finer precision
    val ply = SplatPlacement.boundsOf(scan("axes.ply"), null)!!
    val spz = SplatPlacement.boundsOf(scan("axes_v3.spz"), null)!!
    for (k in 0 until 3) assertEquals(spz.high[k], ply.high[k], 1e-3)
  }

  @Test
  fun `a large splat is sampled at a fixed stride, and only its kept points place it`() {
    val scan = scan("axes_v3.spz", sampleLimit = 100)
    // 686 points at a stride of 7
    assertEquals(98, scan.sampleCount)
    assertEquals(7, scan.sampleIndices[1])
    val kept = java.util.BitSet().apply { set(0, 350) }
    val bounds = SplatPlacement.boundsOf(scan, kept)!!
    // The first 350 points are the 100 of +X and 150 of +Y and 100 of +Z
    assertTrue(bounds.high[2] < 1.01)
  }

  @Test
  fun `a rewrite reads its source to the end of its gzip stream, a trailer cut or a wrong CRC is damaged`() {
    // The module would read the copy written by the viewer, whole and clean; the source, though, is damaged, and its
    // points may not be what was written: said as such rather than shown
    val source = SplatFixtures.bytes("turns_v2.spz")
    val head = head("turns_v2.spz")
    val cut = source.copyOf(source.size - 4)
    val crc = source.copyOf().also { it[it.size - 8] = (it[it.size - 8].toInt() xor 0xff).toByte() }
    for ((what, bytes) in listOf("trailer cut" to cut, "wrong CRC" to crc)) {
      try {
        SplatReducer.write(ByteArrayInputStream(bytes), head, all(40), ByteArrayOutputStream())
        fail(what)
      } catch (e: SplatReadException) {
        assertEquals(what, SplatFileProblem.DAMAGED, e.problem)
      }
    }
    // A reduction reads it to its end too
    try {
      SplatReducer.write(ByteArrayInputStream(crc), head, java.util.BitSet().apply { set(0, 10) }, ByteArrayOutputStream())
      fail("reduced")
    } catch (e: SplatReadException) {
      assertEquals(SplatFileProblem.DAMAGED, e.problem)
    }
  }

  @Test
  fun `a stream cut short or a cancelled reading stops with its reason`() {
    val bytes = SplatFixtures.bytes("axes.ply")
    val source = head("axes.ply")
    try {
      SplatReducer.scan(ByteArrayInputStream(bytes.copyOf(bytes.size - 10)), source)
      fail()
    } catch (e: SplatReadException) {
      assertEquals(SplatFileProblem.DAMAGED, e.problem)
    }
    try {
      SplatReducer.scan(SplatFixtures.file("axes_v3.spz").inputStream(), head("axes_v3.spz"), cancelled = { true })
      fail()
    } catch (e: SplatCancelledException) {
      // Stopped at its first check
    }
    try {
      SplatReducer.scan(SplatFixtures.file("axes_v4.spz").inputStream(), head("axes_v4.spz"))
      fail()
    } catch (e: SplatReadException) {
      // ZSTD is not read here
      assertEquals(SplatFileProblem.NEWER_SPZ, e.problem)
    }
  }
}
