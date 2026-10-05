package app.alextran.immich.core.raw

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

/** What the stitch shaders get, for each kind of rawProjection. */
class RawStitchUniformsTest {
  @Test
  fun `the fisheye intrinsics are lens-local canvas pixels`() {
    val values = RawStitchUniforms.fisheye(RawProjection.parse(RawFixtures.B))
    assertArrayEquals(floatArrayOf(4180f, 4180f, 2688f, 2688f), values.getValue("uIntr0"), 1e-3f)
    // Lens 1's cx includes one canvas square, which the shader's local fraction does not
    assertArrayEquals(floatArrayOf(4180f, 4180f, 8064f - 5376f, 2688f), values.getValue("uIntr1"), 1e-3f)
    assertArrayEquals(floatArrayOf(0.39f, 1.28f, -3.94f, 0f), values.getValue("uK0"), 1e-6f)
    assertArrayEquals(floatArrayOf(0f, 1.95f, 0f, 0f), values.getValue("uX0"), 1e-6f)
    assertArrayEquals(floatArrayOf(1f), values.getValue("uTexOf0"), 0f)
    assertArrayEquals(floatArrayOf(0f), values.getValue("uTexOf1"), 0f)
    assertArrayEquals(floatArrayOf(0f, 0f, 1f, 1f), values.getValue("uRegion1"), 0f)
    assertArrayEquals(floatArrayOf(0f), values.getValue("uModel"), 0f)
    assertArrayEquals(floatArrayOf(5376f), values.getValue("uSquare"), 0f)
    assertArrayEquals(
      floatArrayOf(Math.toRadians(100.0).toFloat(), Math.toRadians(85.0).toFloat(), Math.toRadians(95.0).toFloat()),
      values.getValue("uTheta"),
      1e-7f,
    )
  }

  @Test
  fun `the Kannala-Brandt terms and the side by side regions`() {
    val d = RawStitchUniforms.fisheye(RawProjection.parse(RawFixtures.D))
    assertArrayEquals(floatArrayOf(2f), d.getValue("uModel"), 0f)
    assertArrayEquals(floatArrayOf(0.068134f, -0.013797f, 0.0117944f, -0.00733225f), d.getValue("uK0"), 1e-9f)
    assertArrayEquals(floatArrayOf(0.00104408f, 0f, 0f, 0f), d.getValue("uX0"), 1e-9f)
    val a = RawStitchUniforms.fisheye(RawProjection.parse(RawFixtures.A))
    assertArrayEquals(floatArrayOf(0f, 0f, 0.5f, 1f), a.getValue("uRegion0"), 0f)
    assertArrayEquals(floatArrayOf(0.5f, 0f, 0.5f, 1f), a.getValue("uRegion1"), 0f)
    assertArrayEquals(floatArrayOf(8933.2f - 5952f, 2998.62f), a.getValue("uIntr1").sliceArray(2..3), 1e-3f)
  }

  @Test
  fun `matrices are uploaded column major`() {
    val a = RawProjection.parse(RawFixtures.A)
    val values = RawStitchUniforms.fisheye(a)
    val rows = a.lenses[0].viewToLens
    val columns = values.getValue("uViewToLens0")
    for (row in 0 until 3) {
      for (col in 0 until 3) assertEquals(rows[row * 3 + col].toFloat(), columns[col * 3 + row], 0f)
    }
    assertArrayEquals(
      floatArrayOf(1f, 2f, 3f, 4f, 5f, 6f, 7f, 8f, 9f),
      RawStitchUniforms.columnMajor(doubleArrayOf(1.0, 4.0, 7.0, 2.0, 5.0, 8.0, 3.0, 6.0, 9.0)),
      0f,
    )
  }

  @Test
  fun `the equidistant focal comes from the radius and its angle`() {
    val equidistant =
      RawProjection.parse(
        RawFixtures.B.replace("\"model\":\"mei\"", "\"model\":\"equidistant\"")
          .replace("\"fx\":4180.0,\"fy\":4180.0,", "\"radius\":2600.0,\"radiusTheta\":95.0,"),
      )
    val values = RawStitchUniforms.fisheye(equidistant)
    assertArrayEquals(floatArrayOf(1f), values.getValue("uModel"), 0f)
    val focal = (2600.0 / Math.toRadians(95.0)).toFloat()
    assertArrayEquals(floatArrayOf(focal), values.getValue("uEquidistantFocal0"), 1e-3f)
    // Mei and Kannala-Brandt lenses have none
    val mei = RawStitchUniforms.fisheye(RawProjection.parse(RawFixtures.B))
    assertArrayEquals(floatArrayOf(0f), mei.getValue("uEquidistantFocal1"), 0f)
  }

  @Test
  fun `the half texel follows the decoded size of each lens texture`() {
    val b = RawProjection.parse(RawFixtures.B)
    // Declared sizes until the decoder tells: 3840 squares
    val declared = RawStitchUniforms.halfTexels(b, listOf(null, null))
    assertArrayEquals(floatArrayOf(0.5f / 3840, 0.5f / 3840), declared.getValue("uHalfTexel0"), 1e-12f)
    // A transcoded 2880 stream of lens 0's texture (texture 1)
    val decoded = RawStitchUniforms.halfTexels(b, listOf(null, 2880 to 2880))
    assertArrayEquals(floatArrayOf(0.5f / 2880, 0.5f / 2880), decoded.getValue("uHalfTexel0"), 1e-12f)
    assertArrayEquals(floatArrayOf(0.5f / 3840, 0.5f / 3840), decoded.getValue("uHalfTexel1"), 1e-12f)
    // Side by side: both lenses in the one 5760 x 2880 frame
    val a = RawStitchUniforms.halfTexels(RawProjection.parse(RawFixtures.A), listOf(5760 to 2880))
    assertArrayEquals(floatArrayOf(0.5f / 5760, 0.5f / 2880), a.getValue("uHalfTexel1"), 1e-12f)
  }

  @Test
  fun `the EAC faces are matrices of rows right, down and forward with their slots`() {
    val e = RawProjection.parse(RawFixtures.E)
    val values = RawStitchUniforms.eac(e)
    // Face 0: forward (-1, 0, 0), right (0, 0, 1), down (0, -1, 0); column major [r.x, d.x, f.x, r.y, ...]
    assertArrayEquals(floatArrayOf(0f, 0f, -1f, 0f, -1f, 0f, 1f, 0f, 0f), values.getValue("uFace0"), 0f)
    assertArrayEquals(floatArrayOf(1f, 2f), values.getValue("uFaceSlot5"), 0f)
    assertArrayEquals(floatArrayOf(1920f, 1008f, 96f, 2016f), values.getValue("uEac"), 0f)
    assertArrayEquals(floatArrayOf(3936f), values.getValue("uEacRight"), 0f)
    assertArrayEquals(floatArrayOf(5952f, 1920f), values.getValue("uTrackSize"), 0f)
    assertArrayEquals(floatArrayOf(1f, 0f, 0f, 0f, -1f, 0f, 0f, 0f, 1f), values.getValue("uViewToCamera"), 0f)
  }

  @Test
  fun `only the decoded streams are enabled`() {
    assertArrayEquals(floatArrayOf(1f, 1f), RawStitchUniforms.enabled(listOf(0, 1)), 0f)
    assertArrayEquals(floatArrayOf(0f, 1f), RawStitchUniforms.enabled(listOf(1)), 0f)
  }
}
