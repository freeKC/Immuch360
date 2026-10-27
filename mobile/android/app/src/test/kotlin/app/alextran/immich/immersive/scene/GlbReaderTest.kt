package app.alextran.immich.immersive.scene

import app.alextran.immich.immersive.VolumetricSceneSpec
import app.alextran.immich.immersive.scene.SceneTestFiles.MeshData
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The reader of glb-layers-v1 (design-final 2026-10-27, sections 3.1 and 8.2), against the scene of
 * tiny_scene3D.jpg written by make_scene_fixture.py, then against glbs a field away from it: the reader takes our
 * subset and only it, and says "Not a scene made by Immuch360" of anything else, "Made by a newer version" of a later
 * format of ours. The scene the Dart engine of the computers writes is read by SceneCrossContractTest (lot S1).
 */
class GlbReaderTest {
  private fun refused(glb: ByteArray): GlbProblem =
    try {
      GlbReader.read(glb)
      fail("read a glb the reader must refuse")
      error("unreachable")
    } catch (e: GlbException) {
      e.problem
    }

  private fun assertNotOurs(glb: ByteArray, what: String) = assertEquals(what, GlbProblem.NOT_OURS, refused(glb))

  private fun f32(value: Double): Float = value.toFloat()

  /** The glb of the fixture with the value at [path] set to [value], or removed when null */
  private fun tinyWith(vararg path: Any, value: JsonElement?): ByteArray =
    SceneTestFiles.tinyGlbWith(path.toList(), value)

  /** A grid of 3 x 3 vertices at 2 m showing the photo, changed by [change] */
  private fun gridWith(change: (MeshData) -> MeshData): ByteArray =
    SceneTestFiles.glb(listOf(change(SceneTestFiles.grid(3, 3, 2f, 0))), SceneTestFiles.tinyImages())

  @Test
  fun `reads the two layers of the fixture, their textures and what the scene says of itself`() {
    val scene = GlbReader.read(SceneTestFiles.tinyGlb())

    assertEquals(2, scene.meshes.size)
    assertEquals(13, scene.vertices)
    assertEquals(10, scene.triangles)
    val (front, back) = scene.meshes
    assertEquals(9, front.vertexCount)
    assertEquals(SceneLayer.PHOTO, front.layer)
    assertEquals(0, front.texture)
    assertEquals(4, back.vertexCount)
    assertEquals(SceneLayer.BACKGROUND, back.layer)
    assertEquals(1, back.texture)
    // The front layer: 3 x 3 vertices over a field of view of 60 degrees, 2 m deep at the top to 2.5 m at the bottom
    val halfWidth = Math.tan(Math.toRadians(60.0) / 2)
    val halfHeight = halfWidth / (32.0 / 24.0)
    val first = floatArrayOf(f32(-halfWidth * 2), f32(halfHeight * 2), -2f)
    assertArrayEquals(first, front.positions.copyOfRange(0, 3), 0f)
    assertArrayEquals(
      floatArrayOf(f32(halfWidth * 2.5), f32(-halfHeight * 2.5), -2.5f),
      front.positions.copyOfRange(24, 27),
      0f,
    )
    assertArrayEquals(floatArrayOf(0.5f, 0.5f), front.uvs.copyOfRange(8, 10), 0f)
    assertArrayEquals(intArrayOf(0, 3, 1, 1, 3, 4), front.indices.copyOfRange(0, 6))
    assertEquals(24, front.indices.size)
    assertArrayEquals(intArrayOf(0, 2, 1, 1, 2, 3), back.indices)
    assertTrue((0 until 4).all { back.positions[3 * it + 2] == -3f })
    // The textures: JPEGs in the buffer, their size read from their frame
    assertEquals(listOf(32 to 24, 16 to 16), scene.textures.map { it.width to it.height })
    for (texture in scene.textures) {
      assertEquals(0xFF.toByte(), texture.data[texture.offset])
      assertEquals(0xD8.toByte(), texture.data[texture.offset + 1])
      assertEquals(0xD9.toByte(), texture.data[texture.offset + texture.length - 1])
    }
    assertArrayEquals(SceneTestFiles.tinyImages()[1], scene.textures[1].bytes())
    assertEquals("glb-layers-v1", scene.format)
    assertEquals(VolumetricSceneSpec.SafeZone(0.15, 0.09, 0.3, 0.075), scene.safe)
    assertEquals(1.0, scene.scale!!, 0.0)
    assertEquals(60.0, scene.fovDegrees!!, 0.0)
    assertEquals("Immuch360 make_scene_fixture.py scene-v1", scene.generator)
  }

  @Test
  fun `reads up to 8 meshes of up to 65 535 vertices, and refuses a ninth mesh or a 65 536th vertex`() {
    val images = SceneTestFiles.tinyImages()
    // 255 x 257 = 65 535 vertices, the most a mesh may hold, then 7 more small meshes
    val largest = SceneTestFiles.grid(255, 257, 2f, 0)
    val eight = listOf(largest) + (1..7).map { SceneTestFiles.grid(2, 2, 3f, 1) }
    val scene = GlbReader.read(SceneTestFiles.glb(eight, images))
    assertEquals(8, scene.meshes.size)
    assertEquals(65_535, scene.meshes[0].vertexCount)
    assertEquals(65_535 + 7 * 4, scene.vertices)
    assertEquals(2 * 254 * 256 + 7 * 2, scene.triangles)
    assertEquals(65_534, scene.meshes[0].indices.max())

    assertNotOurs(SceneTestFiles.glb(eight + SceneTestFiles.grid(2, 2, 3f, 1), images), "nine meshes")
    assertNotOurs(SceneTestFiles.glb(listOf(SceneTestFiles.grid(256, 256, 2f, 0)), images), "65 536 vertices")
  }

  @Test
  fun `a later format of ours is newer, any other glTF is not ours`() {
    assertEquals(
      GlbProblem.NEWER_FORMAT,
      refused(SceneTestFiles.tinyGlbWith(listOf("extras", "immuch360", "format"), JsonPrimitive("glb-layers-v2"))),
    )
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("extras"), null), "no extras")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("extras", "immuch360", "format"), null), "no format")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("extras", "immuch360", "format"), JsonPrimitive("glb")), "format")
    assertNotOurs(
      SceneTestFiles.tinyGlbWith(listOf("extras", "immuch360", "format"), JsonPrimitive("glb-layers-v0")),
      "format v0",
    )
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("asset", "version"), JsonPrimitive("1.0")), "glTF 1.0")
  }

  @Test
  fun `only the extensions of the format may be required`() {
    val draco = buildJsonArray { add(JsonPrimitive("KHR_draco_mesh_compression")) }
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("extensionsRequired"), draco), "Draco required")

    val unlit = buildJsonArray { add(JsonPrimitive("KHR_materials_unlit")) }
    assertEquals(2, GlbReader.read(SceneTestFiles.tinyGlbWith(listOf("extensionsRequired"), unlit)).meshes.size)
    // An extension only used, not required, is left aside as glTF allows
    val used = buildJsonArray {
      add(JsonPrimitive("KHR_materials_unlit"))
      add(JsonPrimitive("EXT_something_new"))
    }
    assertEquals(2, GlbReader.read(SceneTestFiles.tinyGlbWith(listOf("extensionsUsed"), used)).meshes.size)
  }

  @Test
  fun `the geometry must be float32 positions and texture coordinates and uint32 indices, packed`() {
    val images = SceneTestFiles.tinyImages()
    assertNotOurs(SceneTestFiles.glb(listOf(SceneTestFiles.grid(3, 3, 2f, 0)), images, indexType = 5123), "uint16")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("accessors", 0, "componentType"), JsonPrimitive(5123)), "short")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("accessors", 0, "type"), JsonPrimitive("VEC4")), "VEC4")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("accessors", 1, "type"), JsonPrimitive("VEC3")), "uv VEC3")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("accessors", 1, "count"), JsonPrimitive(8)), "uv count")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("accessors", 2, "count"), JsonPrimitive(23)), "not triangles")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("accessors", 0, "normalized"), JsonPrimitive(true)), "normalized")
    assertNotOurs(
      SceneTestFiles.tinyGlbWith(listOf("accessors", 0, "sparse"), buildJsonObject { put("count", 1) }),
      "sparse",
    )
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("bufferViews", 2, "byteStride"), JsonPrimitive(16)), "stride")
    assertNotOurs(tinyWith("meshes", 0, "primitives", 0, "attributes", "TEXCOORD_0", value = null), "uv")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("meshes", 0, "primitives", 0, "indices"), null), "no indices")
    // A packed stride is the same as none
    assertEquals(13, GlbReader.read(tinyWith("bufferViews", 2, "byteStride", value = JsonPrimitive(12))).vertices)
  }

  @Test
  fun `an index past the vertices, or a position that is not a number, is refused`() {
    assertNotOurs(gridWith { MeshData(it.positions, it.uvs, it.indices.also { i -> i[5] = 9 }, 0) }, "index 9 of 9")
    assertNotOurs(gridWith { MeshData(it.positions.also { p -> p[4] = Float.NaN }, it.uvs, it.indices, 0) }, "NaN")
    val far = Float.POSITIVE_INFINITY
    assertNotOurs(gridWith { MeshData(it.positions, it.uvs.also { p -> p[0] = far }, it.indices, 0) }, "infinite uv")
  }

  @Test
  fun `views and accessors must lie within the buffer`() {
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("bufferViews", 4, "byteLength"), JsonPrimitive(4000)), "view past")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("bufferViews", 4, "byteOffset"), JsonPrimitive(1040)), "view end")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("accessors", 0, "count"), JsonPrimitive(10)), "accessor past")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("accessors", 0, "byteOffset"), JsonPrimitive(4)), "offset past")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("bufferViews", 4, "byteOffset"), JsonPrimitive(-4)), "negative")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("accessors", 0, "bufferView"), JsonPrimitive(42)), "no view")
    assertNotOurs(tinyWith("buffers", 0, "uri", value = JsonPrimitive("scene.bin")), "external buffer")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("buffers", 0, "byteLength"), JsonPrimitive(2048)), "buffer past")
  }

  @Test
  fun `the materials must be opaque, show a JPEG of the buffer, and the nodes move nothing`() {
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("materials", 0, "alphaMode"), JsonPrimitive("BLEND")), "blend")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("images", 0, "mimeType"), JsonPrimitive("image/png")), "png")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("images", 0, "uri"), JsonPrimitive("photo.jpg")), "image uri")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("images", 0, "bufferView"), JsonPrimitive(2)), "not a JPEG")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("materials", 1, "pbrMetallicRoughness"), null), "no texture")
    assertNotOurs(
      tinyWith("materials", 1, "pbrMetallicRoughness", "baseColorTexture", "texCoord", value = JsonPrimitive(1)),
      "second uv set",
    )
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("meshes", 1, "primitives", 0, "material"), null), "no material")
    assertNotOurs(tinyWith("meshes", 1, "primitives", 0, "material", value = JsonPrimitive(5)), "material 5")
    assertNotOurs(
      tinyWith("nodes", 1, "translation", value = buildJsonArray { repeat(3) { add(JsonPrimitive(1.0)) } }),
      "moved node",
    )
    assertNotOurs(
      tinyWith("nodes", 0, "rotation", value = buildJsonArray { repeat(4) { add(JsonPrimitive(0.5)) } }),
      "turned root",
    )
    // OPAQUE written, and the mode of triangles left to its default, read the same
    val opaque = SceneTestFiles.tinyGlbWith(listOf("materials", 0, "alphaMode"), JsonPrimitive("OPAQUE"))
    assertEquals(2, GlbReader.read(opaque).meshes.size)
    val noMode = SceneTestFiles.tinyGlbWith(listOf("meshes", 0, "primitives", 0, "mode"), null)
    assertEquals(10, GlbReader.read(noMode).triangles)
  }

  @Test
  fun `one primitive of triangles per mesh`() {
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("meshes", 0, "primitives", 0, "mode"), JsonPrimitive(1)), "lines")
    val twice =
      SceneTestFiles.tinyGlbWith { root ->
        val primitive = (((root["meshes"] as JsonArray)[0] as JsonObject)["primitives"] as JsonArray)[0]
        SceneTestFiles.edit(root, listOf("meshes", 0, "primitives"), JsonArray(listOf(primitive, primitive)))
      }
    assertNotOurs(twice, "two primitives")
    assertNotOurs(SceneTestFiles.tinyGlbWith(listOf("meshes"), JsonArray(emptyList())), "no mesh")
  }

  @Test
  fun `the layer of a mesh is told by its image, the photo being the first`() {
    val images = SceneTestFiles.tinyImages()
    // The photo layer cut in two bands, then the background: the two bands share the photo, its texture is read once
    val bands =
      listOf(SceneTestFiles.grid(3, 2, 2f, 0), SceneTestFiles.grid(3, 2, 2.2f, 0), SceneTestFiles.grid(2, 2, 3f, 1))
    val scene = GlbReader.read(SceneTestFiles.glb(bands, images))
    assertEquals(listOf(SceneLayer.PHOTO, SceneLayer.PHOTO, SceneLayer.BACKGROUND), scene.meshes.map { it.layer })
    assertEquals(listOf(0, 0, 1), scene.meshes.map { it.texture })
    assertEquals(2, scene.textures.size)
    // An image no mesh shows is not a texture of the scene
    val photoOnly = GlbReader.read(SceneTestFiles.glb(listOf(SceneTestFiles.grid(3, 3, 2f, 0)), images))
    assertEquals(listOf(32 to 24), photoOnly.textures.map { it.width to it.height })
  }

  @Test
  fun `a glb cut short or with chunks out of place is not ours`() {
    val glb = SceneTestFiles.tinyGlb()
    assertNotOurs(glb.copyOf(glb.size - 8), "cut")
    assertNotOurs(glb.copyOf(16), "header only")
    assertNotOurs(glb.copyOf().also { it[0] = 'G'.code.toByte() }, "magic")
    assertNotOurs(glb.copyOf().also { it[4] = 1 }, "version 1")
    assertNotOurs(glb.copyOf().also { it[16] = 'X'.code.toByte() }, "JSON chunk type")
    val (json, bin) = SceneTestFiles.split(glb)
    assertNotOurs(SceneTestFiles.pack(json, null), "no binary chunk")
    assertNotOurs(SceneTestFiles.pack(json, bin).also { it[20] = '[' .code.toByte() }, "not JSON")
  }

  @Test
  fun `the size of a JPEG is read from its frame, baseline or progressive`() {
    val texture = SceneTestFiles.tinyImages()[0]
    assertEquals(32 to 24, GlbReader.jpegSize(texture, 0, texture.size))
    // The same frame marked progressive (SOF2)
    val progressive = texture.copyOf()
    val sof =
      (2 until progressive.size - 1).first { progressive[it] == 0xFF.toByte() && progressive[it + 1] == 0xC0.toByte() }
    progressive[sof + 1] = 0xC2.toByte()
    assertEquals(32 to 24, GlbReader.jpegSize(progressive, 0, progressive.size))
    // No frame before the scan, a PNG, nothing at all
    assertEquals(null, GlbReader.jpegSize(texture.copyOf().also { it[sof + 1] = 0xC4.toByte() }, 0, texture.size))
    val png = byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte())
    assertEquals(null, GlbReader.jpegSize(png, 0, 4))
    assertEquals(null, GlbReader.jpegSize(ByteArray(0), 0, 0))
  }
}

