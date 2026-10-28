package app.alextran.immich.immersive.scene

import app.alextran.immich.relief.ReliefFixtures
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

/**
 * The photo that carries a scene of the fixtures, tiny_scene3D.jpg (written by
 * .github/desktop/ai/make_scene_fixture.py), and the means to change it: its glb taken apart into its JSON and its
 * binary chunk, a JSON edited at a path, a glb packed again, a glb made from meshes of a chosen size (the writer of the
 * script, in Kotlin), a preview whose packet says something else. The readers are tested against these, never against
 * their own output.
 */
internal object SceneTestFiles {
  /** The bytes of tiny_scene3D.jpg */
  fun tiny(): ByteArray = ReliefFixtures.file("tiny_scene3D.jpg").readBytes()

  /** Where the glb of [file] starts: the last "glTF" of the file */
  fun glbOffset(file: ByteArray): Int {
    for (at in file.size - 12 downTo 0) {
      if (file[at] == 'g'.code.toByte() && file[at + 1] == 'l'.code.toByte() && file[at + 2] == 'T'.code.toByte() &&
        file[at + 3] == 'F'.code.toByte()) {
        return at
      }
    }
    error("no glTF in the file")
  }

  /** The glb of the fixture */
  fun tinyGlb(): ByteArray = tiny().let { it.copyOfRange(glbOffset(it), it.size) }

  /** The JPEG preview of the fixture, its packet included, without the scene */
  fun tinyPreview(): ByteArray = tiny().let { it.copyOfRange(0, glbOffset(it)) }

  fun sha256(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

  /** The JSON chunk and the binary chunk of [glb] */
  fun split(glb: ByteArray): Pair<JsonObject, ByteArray> {
    val buffer = ByteBuffer.wrap(glb).order(ByteOrder.LITTLE_ENDIAN)
    val jsonLength = buffer.getInt(12)
    val json = Json.parseToJsonElement(String(glb, 20, jsonLength, Charsets.UTF_8)).jsonObject
    val binLength = buffer.getInt(20 + jsonLength)
    return json to glb.copyOfRange(28 + jsonLength, 28 + jsonLength + binLength)
  }

  /** A glb of [json] and [bin] (no binary chunk when null), each chunk padded to 4 bytes as the format asks */
  fun pack(json: JsonObject, bin: ByteArray?, version: Int = 2): ByteArray {
    var text = json.toString().toByteArray(Charsets.UTF_8)
    text += ByteArray((4 - text.size % 4) % 4) { ' '.code.toByte() }
    val binary = bin?.let { it + ByteArray((4 - it.size % 4) % 4) }
    val total = 12 + 8 + text.size + (if (binary == null) 0 else 8 + binary.size)
    val out =
      ByteBuffer.allocate(total)
        .order(ByteOrder.LITTLE_ENDIAN)
        .putInt(0x46546C67)
        .putInt(version)
        .putInt(total)
        .putInt(text.size)
        .putInt(0x4E4F534A)
        .put(text)
    if (binary != null) out.putInt(binary.size).putInt(0x004E4942).put(binary)
    return out.array()
  }

  /** The glb of the fixture with its JSON changed by [change] */
  fun tinyGlbWith(change: (JsonObject) -> JsonElement): ByteArray {
    val (json, bin) = split(tinyGlb())
    return pack(change(json) as JsonObject, bin)
  }

  /** [root] with the value at [path] (object keys and array indices) replaced by [value], or removed when null */
  fun edit(root: JsonElement, path: List<Any>, value: JsonElement?): JsonElement {
    if (path.isEmpty()) return value ?: error("cannot remove the root")
    return when (val key = path.first()) {
      is String -> {
        val obj = root as JsonObject
        val rest = path.drop(1)
        val map = obj.toMutableMap()
        if (rest.isEmpty() && value == null) map.remove(key)
        else map[key] = edit(obj[key] ?: JsonObject(emptyMap()), rest, value)
        JsonObject(map)
      }
      is Int -> {
        val array = (root as JsonArray).toMutableList()
        array[key] = edit(array[key], path.drop(1), value)
        JsonArray(array)
      }
      else -> error("a path holds keys and indices")
    }
  }

  /** The fixture's glb with the value at [path] set to [value], or removed when null */
  fun tinyGlbWith(path: List<Any>, value: JsonElement?): ByteArray = tinyGlbWith { edit(it, path, value) }

  /** One mesh of [glb]: its positions, texture coordinates, triangle indices and the image its material shows */
  class MeshData(val positions: FloatArray, val uvs: FloatArray, val indices: IntArray, val image: Int)

  /**
   * A glb of glb-layers-v1 holding [meshes] and the JPEG [images], as make_scene_fixture.py writes one: a root node
   * at the centre of the camera, one child per mesh, one material per image, extras.immuch360 with [format]
   */
  fun glb(
    meshes: List<MeshData>,
    images: List<ByteArray>,
    format: String = "glb-layers-v1",
    indexType: Int = 5125,
  ): ByteArray {
    val binary = java.io.ByteArrayOutputStream()
    val views = mutableListOf<JsonObject>()
    val accessors = mutableListOf<JsonObject>()
    fun view(data: ByteArray, target: Int?): Int {
      while (binary.size() % 4 != 0) binary.write(0)
      views +=
        buildJsonObject {
          put("buffer", 0)
          put("byteOffset", binary.size())
          put("byteLength", data.size)
          if (target != null) put("target", target)
        }
      binary.write(data)
      return views.size - 1
    }
    fun little(size: Int): ByteBuffer = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
    fun floats(values: FloatArray): ByteArray =
      little(4 * values.size).apply { values.forEach { putFloat(it) } }.array()
    fun ints(values: IntArray): ByteArray =
      if (indexType == 5123) {
        little(2 * values.size).apply { values.forEach { putShort(it.toShort()) } }.array()
      } else {
        little(4 * values.size).apply { values.forEach { putInt(it) } }.array()
      }
    val imageViews = images.map { view(it, null) }
    val gltfMeshes = mutableListOf<JsonObject>()
    for (mesh in meshes) {
      val count = mesh.positions.size / 3
      val position = view(floats(mesh.positions), 34962)
      accessors +=
        buildJsonObject {
          put("bufferView", position)
          put("componentType", 5126)
          put("count", count)
          put("type", "VEC3")
          val p = mesh.positions
          fun bound(i: Int, max: Boolean) =
            (0 until count).map { p[3 * it + i] }.let { if (max) it.max() else it.min() }
          put("min", buildJsonArray { for (i in 0 until 3) add(JsonPrimitive(bound(i, false))) })
          put("max", buildJsonArray { for (i in 0 until 3) add(JsonPrimitive(bound(i, true))) })
        }
      val uv = view(floats(mesh.uvs), 34962)
      accessors += buildJsonObject {
        put("bufferView", uv)
        put("componentType", 5126)
        put("count", mesh.uvs.size / 2)
        put("type", "VEC2")
      }
      val index = view(ints(mesh.indices), 34963)
      accessors += buildJsonObject {
        put("bufferView", index)
        put("componentType", indexType)
        put("count", mesh.indices.size)
        put("type", "SCALAR")
      }
      val first = accessors.size - 3
      gltfMeshes += buildJsonObject {
        put(
          "primitives",
          buildJsonArray {
            add(
              buildJsonObject {
                put("attributes", buildJsonObject {
                  put("POSITION", first)
                  put("TEXCOORD_0", first + 1)
                })
                put("indices", first + 2)
                put("material", mesh.image)
                put("mode", 4)
              }
            )
          },
        )
      }
    }
    while (binary.size() % 4 != 0) binary.write(0)
    val json = buildJsonObject {
      put("asset", buildJsonObject {
        put("version", "2.0")
        put("generator", "SceneTestFiles")
      })
      put("extensionsUsed", buildJsonArray { add(JsonPrimitive("KHR_materials_unlit")) })
      put("scene", 0)
      put("scenes", buildJsonArray { add(buildJsonObject { put("nodes", buildJsonArray { add(JsonPrimitive(0)) }) }) })
      put(
        "nodes",
        buildJsonArray {
          add(buildJsonObject {
            put("name", "camera")
            put("children", buildJsonArray { meshes.indices.forEach { add(JsonPrimitive(it + 1)) } })
          })
          meshes.indices.forEach { add(buildJsonObject { put("mesh", it) }) }
        },
      )
      put("meshes", JsonArray(gltfMeshes))
      put(
        "materials",
        buildJsonArray {
          images.indices.forEach {
            add(buildJsonObject {
              put("pbrMetallicRoughness", buildJsonObject {
                put("baseColorTexture", buildJsonObject { put("index", it) })
                put("metallicFactor", 0.0)
              })
              put("extensions", buildJsonObject { put("KHR_materials_unlit", buildJsonObject {}) })
            })
          }
        },
      )
      put(
        "textures",
        buildJsonArray {
          images.indices.forEach {
            add(
              buildJsonObject {
                put("sampler", 0)
                put("source", it)
              }
            )
          }
        },
      )
      put("samplers", buildJsonArray { add(buildJsonObject { put("magFilter", 9729); put("minFilter", 9729) }) })
      put(
        "images",
        buildJsonArray {
          imageViews.forEach { add(buildJsonObject { put("bufferView", it); put("mimeType", "image/jpeg") }) }
        },
      )
      put("accessors", JsonArray(accessors))
      put("bufferViews", JsonArray(views))
      put("buffers", buildJsonArray { add(buildJsonObject { put("byteLength", binary.size()) }) })
      put("extras", buildJsonObject {
        put("immuch360", buildJsonObject {
          put("format", format)
          put("safe", buildJsonObject {
            put("lateral", 0.2)
            put("vertical", 0.12)
            put("forward", 0.4)
            put("backward", 0.1)
          })
          put("scale", 1.0)
          put("fovDegrees", 65.0)
        })
      })
    }
    return pack(json, binary.toByteArray())
  }

  /** A grid of [columns] x [rows] vertices at [depth] metres, all its cells drawn, showing [image] */
  fun grid(columns: Int, rows: Int, depth: Float, image: Int): MeshData {
    val positions = FloatArray(3 * columns * rows)
    val uvs = FloatArray(2 * columns * rows)
    for (row in 0 until rows) {
      for (column in 0 until columns) {
        val k = row * columns + column
        val u = column / (columns - 1f)
        val v = row / (rows - 1f)
        positions[3 * k] = (2 * u - 1) * depth
        positions[3 * k + 1] = (1 - 2 * v) * depth
        positions[3 * k + 2] = -depth
        uvs[2 * k] = u
        uvs[2 * k + 1] = v
      }
    }
    val indices = IntArray(6 * (columns - 1) * (rows - 1))
    var n = 0
    for (row in 0 until rows - 1) {
      for (column in 0 until columns - 1) {
        val a = row * columns + column
        intArrayOf(a, a + columns, a + 1, a + 1, a + columns, a + columns + 1).copyInto(indices, n)
        n += 6
      }
    }
    return MeshData(positions, uvs, indices, image)
  }

  /** The two JPEG textures of the fixture: 32 x 24, then 16 x 16 */
  fun tinyImages(): List<ByteArray> {
    val (json, bin) = split(tinyGlb())
    val views = json["bufferViews"] as JsonArray
    return (json["images"] as JsonArray).map { image ->
      val view = views[(image.jsonObject["bufferView"] as JsonPrimitive).content.toInt()].jsonObject
      val offset = (view["byteOffset"] as JsonPrimitive).content.toInt()
      val length = (view["byteLength"] as JsonPrimitive).content.toInt()
      bin.copyOfRange(offset, offset + length)
    }
  }

  /**
   * The preview of the fixture with its packet's [name] attribute set to [value]. The segment lengths of the JPEG are
   * left as they were: the readers find the packet in the text of the head, as the Dart side does, not by its segment.
   */
  fun previewWith(name: String, value: String): ByteArray {
    val text = String(tinyPreview(), Charsets.ISO_8859_1)
    val pattern = Regex("Immuch360:$name=\"[^\"]*\"")
    check(pattern.containsMatchIn(text)) { "no $name in the packet" }
    return pattern.replace(text, "Immuch360:$name=\"$value\"").toByteArray(Charsets.ISO_8859_1)
  }

  /** The preview of the fixture without its packet's [name] attribute, the segment lengths left as they were */
  fun previewWithout(name: String): ByteArray {
    val text = String(tinyPreview(), Charsets.ISO_8859_1)
    val pattern = Regex("\\s+Immuch360:$name=\"[^\"]*\"")
    check(pattern.containsMatchIn(text)) { "no $name in the packet" }
    return pattern.replace(text, "").toByteArray(Charsets.ISO_8859_1)
  }
}
