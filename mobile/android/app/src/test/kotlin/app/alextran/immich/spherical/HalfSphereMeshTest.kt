package app.alextran.immich.spherical

import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The half sphere projection data must decode, in the ProjectionDecoder of Media3, to exactly the mesh of
 * Projection.createEquirectangular(50, 36, 72, 180, 180, stereoMode). Both classes are package private in Media3, so
 * the test reaches them by reflection.
 */
class HalfSphereMeshTest {
  private companion object {
    const val PACKAGE = "androidx.media3.exoplayer.video.spherical"

    /** C.STEREO_MODE_MONO, C.STEREO_MODE_TOP_BOTTOM and C.STEREO_MODE_LEFT_RIGHT */
    val STEREO_MODES = intArrayOf(0, 1, 2)

    val projectionClass: Class<*> = Class.forName("$PACKAGE.Projection")
    val meshClass: Class<*> = Class.forName("$PACKAGE.Projection\$Mesh")
    val subMeshClass: Class<*> = Class.forName("$PACKAGE.Projection\$SubMesh")

    fun createEquirectangular(stereoMode: Int): Any {
      val method = projectionClass.getDeclaredMethod(
        "createEquirectangular",
        Float::class.javaPrimitiveType,
        Int::class.javaPrimitiveType,
        Int::class.javaPrimitiveType,
        Float::class.javaPrimitiveType,
        Float::class.javaPrimitiveType,
        Int::class.javaPrimitiveType,
      )
      method.isAccessible = true
      return method.invoke(null, 50f, 36, 72, 180f, 180f, stereoMode)!!
    }

    fun decode(data: ByteArray, stereoMode: Int): Any? {
      val method = Class.forName("$PACKAGE.ProjectionDecoder")
        .getDeclaredMethod("decode", ByteArray::class.java, Int::class.javaPrimitiveType)
      method.isAccessible = true
      return method.invoke(null, data, stereoMode)
    }

    fun isSupportedByRenderer(projection: Any): Boolean {
      val method = Class.forName("$PACKAGE.ProjectionRenderer").getDeclaredMethod("isSupported", projectionClass)
      method.isAccessible = true
      return method.invoke(null, projection) as Boolean
    }

    fun field(owner: Class<*>, target: Any, name: String): Any? =
      owner.getDeclaredField(name).also { it.isAccessible = true }.get(target)

    fun subMeshes(projection: Any, meshField: String): List<Any> {
      val mesh = field(projectionClass, projection, meshField)!!
      val count = meshClass.getDeclaredMethod("getSubMeshCount").invoke(mesh) as Int
      val getSubMesh = meshClass.getDeclaredMethod("getSubMesh", Int::class.javaPrimitiveType)
      return (0 until count).map { getSubMesh.invoke(mesh, it)!! }
    }

    fun box(type: String, payload: ByteArray): ByteArray =
      ByteBuffer.allocate(8 + payload.size).putInt(8 + payload.size).put(type.toByteArray()).put(payload).array()

    /** "equi" payload: version and flags, then the top, bottom, left and right bounds as 0.32 fractions */
    fun equiPayload(left: Double, right: Double): ByteArray =
      ByteBuffer.allocate(20)
        .putInt(0)
        .putInt(0)
        .putInt(0)
        .putInt((left * 4_294_967_296.0).toLong().toInt())
        .putInt((right * 4_294_967_296.0).toLong().toInt())
        .array()

    fun projBox(vararg children: ByteArray): ByteArray =
      box("proj", children.fold(ByteArray(0)) { all, child -> all + child })

    val PRHD = box("prhd", ByteArray(16))
  }

  @Test
  fun `the strip is the one of Media3`() {
    val strip = HalfSphereMesh.equirectangularStrip()
    val expected = subMeshes(createEquirectangular(0), "leftMesh").single()
    assertArrayEquals(field(subMeshClass, expected, "vertices") as FloatArray, strip.positions, 0f)
    assertArrayEquals(field(subMeshClass, expected, "textureCoords") as FloatArray, strip.textureCoordinates, 0f)
  }

  @Test
  fun `the projection data decodes to the 180 degree equirectangular mesh of Media3`() {
    val data = HalfSphereMesh.projectionData
    for (stereoMode in STEREO_MODES) {
      val expected = createEquirectangular(stereoMode)
      val decoded = decode(data, stereoMode)
      assertNotNull("stereo mode $stereoMode", decoded)
      decoded!!
      assertEquals(stereoMode, field(projectionClass, decoded, "stereoMode"))
      assertEquals(true, field(projectionClass, decoded, "singleMesh"))
      assertTrue(isSupportedByRenderer(decoded))
      for (meshField in listOf("leftMesh", "rightMesh")) {
        val expectedSubMesh = subMeshes(expected, meshField).single()
        val decodedSubMesh = subMeshes(decoded, meshField).single()
        for (name in listOf("textureId", "mode")) {
          assertEquals(
            "$name, stereo mode $stereoMode",
            field(subMeshClass, expectedSubMesh, name),
            field(subMeshClass, decodedSubMesh, name),
          )
        }
        for (name in listOf("vertices", "textureCoords")) {
          assertArrayEquals(
            "$name, stereo mode $stereoMode",
            field(subMeshClass, expectedSubMesh, name) as FloatArray,
            field(subMeshClass, decodedSubMesh, name) as FloatArray,
            0f,
          )
        }
      }
    }
  }

  @Test
  fun `the mesh covers the front half of the sphere only`() {
    val positions = HalfSphereMesh.equirectangularStrip().positions
    // The camera looks along -z: the front half has z <= 0, up to rounding at the sides
    for (v in positions.indices step 3) {
      assertTrue("vertex ${v / 3} z ${positions[v + 2]}", positions[v + 2] <= 1e-4f)
    }
    val textureCoordinates = HalfSphereMesh.equirectangularStrip().textureCoordinates
    assertEquals(0f, textureCoordinates.min(), 0f)
    assertEquals(1f, textureCoordinates.max(), 0f)
  }

  @Test
  fun `the projection data is built once`() {
    assertSame(HalfSphereMesh.projectionData, HalfSphereMesh.projectionData)
  }

  @Test
  fun `the projection data declares a mesh on the half sphere`() {
    val declared = DeclaredProjection.of(HalfSphereMesh.projectionData)
    assertEquals(SphereCoverage.HALF, declared?.coverage)
    assertEquals(true, declared?.mesh)
  }

  @Test
  fun `equi bounds cropping half of the width declare the half sphere`() {
    val declared = DeclaredProjection.of(projBox(PRHD, box("equi", equiPayload(0.25, 0.25))))
    assertEquals(SphereCoverage.HALF, declared?.coverage)
    assertEquals(false, declared?.mesh)
  }

  @Test
  fun `equi bounds without crop declare the full sphere`() {
    val declared = DeclaredProjection.of(projBox(PRHD, box("equi", equiPayload(0.0, 0.0))))
    assertEquals(SphereCoverage.FULL, declared?.coverage)
    assertEquals(false, declared?.mesh)
    assertEquals(SphereCoverage.FULL, DeclaredProjection.of(projBox(box("equi", equiPayload(0.1, 0.1))))?.coverage)
    assertEquals(SphereCoverage.FULL, DeclaredProjection.of(projBox(box("equi", equiPayload(0.4, 0.4))))?.coverage)
  }

  @Test
  fun `matroska projection payloads are read too`() {
    assertEquals(SphereCoverage.HALF, DeclaredProjection.of(equiPayload(0.25, 0.25))?.coverage)
    assertEquals(SphereCoverage.FULL, DeclaredProjection.of(equiPayload(0.0, 0.0))?.coverage)
    // A mesh payload: version, flags, CRC, encoding
    val mesh = ByteBuffer.allocate(16).putInt(0).putInt(0).put("dfl8".toByteArray()).putInt(0).array()
    assertEquals(true, DeclaredProjection.of(mesh)?.mesh)
  }

  @Test
  fun `nothing readable declares nothing`() {
    assertNull(DeclaredProjection.of(null))
    assertNull(DeclaredProjection.of(ByteArray(0)))
    assertNull(DeclaredProjection.of(ByteArray(7)))
    assertNull(DeclaredProjection.of(projBox(PRHD)))
    assertNull(DeclaredProjection.of(projBox(PRHD, box("cbmp", ByteArray(12)))))
    // A child box running past the end
    val broken = projBox(PRHD, box("equi", equiPayload(0.25, 0.25))).copyOf(40)
    assertNull(DeclaredProjection.of(broken))
    assertFalse(DeclaredProjection.of(projBox(box("equi", equiPayload(0.25, 0.25))))?.mesh ?: true)
  }
}
