package app.alextran.immich.immersive.scene

import app.alextran.immich.immersive.VolumetricSceneSpec
import app.alextran.immich.immersive.finite
import app.alextran.immich.immersive.integer
import app.alextran.immich.immersive.primitive
import app.alextran.immich.immersive.string
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/**
 * The reader of glb-layers-v1, the binary glTF a photo of Immuch360 carries after its JPEG (design-final 2026-10-27,
 * sections 3.1 and 8.2), and of nothing else: the glTF loader of the SDK is not used (its opacity modes and its memory
 * would have to be proven), and this one is tested in plain JVM code like ReliefMesh.
 *
 * glb-layers-v1, as make_scene_fixture.py writes it and this reader takes it:
 * 1. glTF 2.0 in a glb of version 2 (a JSON chunk, then a binary chunk holding the one buffer),
 *    extras.immuch360.format "glb-layers-v1"; a later "glb-layers-vN" is a newer format of ours, anything else is not
 *    a scene of ours;
 * 2. at most [MAX_MESHES] meshes, each one primitive of triangles (mode 4) of at most [MAX_MESH_VERTICES] vertices:
 *    POSITION float32 VEC3 and TEXCOORD_0 float32 VEC2 (0, 0 at the top left of the texture), packed, finite, indices
 *    uint32 under the vertex count; no sparse accessor;
 * 3. a material per primitive, opaque (alphaMode OPAQUE or none), unlit for us whatever it says, whose base colour
 *    texture (texture coordinates 0) is a JPEG held in the buffer; the sampler is left aside (the viewer filters
 *    linearly and clamps);
 * 4. the nodes move nothing (no matrix, translation, rotation or scale): positions are in metres in the frame of the
 *    camera of the photo, x right, y up, looking towards -z;
 * 5. the layer of a mesh is told by its image: the photo is the first image of the file (images[0]), and every mesh
 *    that shows it belongs to the photo layer, the near one; a mesh that shows another image (the filled background)
 *    belongs to the background layer. The edge of the zone flattens each layer towards its own plane (SceneNavigator).
 *    A layer of more than 65 535 vertices comes cut in bands of rows, several meshes showing the same image;
 * 6. only the extensions KHR_materials_unlit and KHR_xmp_json_ld may be required; one only used is left aside.
 *
 * extras.immuch360 also holds the safe zone, the scale and the field of view, read here as the file says them; the
 * packet at the head of the file is what the viewer goes by (SceneFile).
 */
internal object GlbReader {
  /** The most meshes of a scene, and the most vertices of one mesh (16 bit indices) */
  const val MAX_MESHES = 8
  const val MAX_MESH_VERTICES = 65_535

  /** The format this build reads, extras.immuch360.format */
  const val FORMAT = VolumetricSceneSpec.FORMAT

  private const val GLB_MAGIC = 0x46546C67
  private const val CHUNK_JSON = 0x4E4F534A
  private const val CHUNK_BIN = 0x004E4942
  private const val FLOAT = 5126
  private const val UNSIGNED_INT = 5125
  private const val TRIANGLES = 4

  private val formatName = Regex("glb-layers-v([0-9]+)")

  /** The extensions a scene of ours may require */
  private val knownExtensions = setOf("KHR_materials_unlit", "KHR_xmp_json_ld")

  private val json = Json { ignoreUnknownKeys = true }

  /** The version N of a format "glb-layers-vN", null for another text */
  fun formatVersionOf(format: String?): Int? =
    format?.let { formatName.matchEntire(it)?.groupValues?.get(1)?.toIntOrNull() }

  /** The scene [glb] holds; a [GlbException] when it is not one this build reads */
  fun read(glb: ByteArray): GlbScene {
    val bytes = ByteBuffer.wrap(glb).order(ByteOrder.LITTLE_ENDIAN)
    if (glb.size < 20 || bytes.getInt(0) != GLB_MAGIC || bytes.getInt(4) != 2 || bytes.getInt(8) != glb.size) {
      throw notOurs("not a glb of version 2 of ${glb.size} bytes")
    }
    val jsonLength = bytes.getInt(12)
    if (jsonLength <= 0 || bytes.getInt(16) != CHUNK_JSON || 20L + jsonLength + 8 > glb.size) {
      throw notOurs("no JSON chunk followed by a binary chunk")
    }
    val binStart = 20 + jsonLength + 8
    val binLength = bytes.getInt(20 + jsonLength)
    if (bytes.getInt(24 + jsonLength) != CHUNK_BIN || binLength < 0 || binStart.toLong() + binLength > glb.size) {
      throw notOurs("no binary chunk")
    }
    val root =
      try {
        json.parseToJsonElement(String(glb, 20, jsonLength, Charsets.UTF_8)) as? JsonObject
      } catch (e: Exception) {
        null
      } ?: throw notOurs("the JSON chunk is not a JSON object")
    return Document(root, glb, binStart, binLength).read()
  }

  /**
   * The width and height of the JPEG in [data] from [offset], [length] bytes long, read from its frame header (any SOF
   * but the DHT, JPG and DAC markers); null when it is not a JPEG or no frame comes before the first scan
   */
  fun jpegSize(data: ByteArray, offset: Int, length: Int): Pair<Int, Int>? {
    fun byte(at: Int): Int = data[offset + at].toInt() and 0xFF
    if (length < 4 || byte(0) != 0xFF || byte(1) != 0xD8) return null
    var at = 2
    while (at + 4 <= length) {
      if (byte(at) != 0xFF) return null
      val marker = byte(at + 1)
      when {
        // Fill bytes before a marker
        marker == 0xFF -> {
          at += 1
          continue
        }
        // Markers without a segment
        marker == 0x01 || marker in 0xD0..0xD7 -> {
          at += 2
          continue
        }
        marker == 0xD9 || marker == 0xDA -> return null
      }
      val segment = (byte(at + 2) shl 8) or byte(at + 3)
      if (segment < 2) return null
      if (marker in 0xC0..0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
        if (at + 9 > length) return null
        val height = (byte(at + 5) shl 8) or byte(at + 6)
        val width = (byte(at + 7) shl 8) or byte(at + 8)
        return if (width > 0 && height > 0) width to height else null
      }
      at += 2 + segment
    }
    return null
  }

  private fun notOurs(why: String) = GlbException(GlbProblem.NOT_OURS, why)

  /** One glb being read: its JSON [root], and its binary chunk at [binStart] in [glb], [binLength] bytes long */
  private class Document(val root: JsonObject, val glb: ByteArray, val binStart: Int, val binLength: Int) {
    val bin: ByteBuffer = ByteBuffer.wrap(glb).order(ByteOrder.LITTLE_ENDIAN)

    fun array(parent: JsonObject, key: String): JsonArray? =
      parent[key]?.takeIf { it !is JsonNull }?.let { it as? JsonArray ?: throw notOurs("$key is not a list") }

    fun objects(key: String): List<JsonObject> =
      array(root, key).orEmpty().map { it as? JsonObject ?: throw notOurs("an entry of $key is not an object") }

    fun obj(parent: JsonObject, key: String): JsonObject? =
      parent[key]?.takeIf { it !is JsonNull }?.let { it as? JsonObject ?: throw notOurs("$key is not an object") }

    fun index(parent: JsonObject, key: String, size: Int): Int {
      val value = parent.integer(key) ?: throw notOurs("no $key")
      if (value !in 0 until size) throw notOurs("$key $value of $size")
      return value
    }

    val buffers = objects("buffers")
    val views = objects("bufferViews")
    val accessors = objects("accessors")
    val images = objects("images")
    val textures = objects("textures")
    val materials = objects("materials")

    // The length of the one buffer, held by the binary chunk
    val bufferLength: Int by lazy {
      if (buffers.size != 1 || buffers[0].containsKey("uri")) throw notOurs("not one buffer held by the glb")
      val length = buffers[0].integer("byteLength") ?: throw notOurs("no byteLength of the buffer")
      if (length < 0 || length > binLength) throw notOurs("a buffer of $length bytes in a chunk of $binLength")
      length
    }

    fun read(): GlbScene {
      val asset = obj(root, "asset") ?: throw notOurs("no asset")
      if (asset.string("version") != "2.0") throw notOurs("glTF ${asset.string("version")}")
      val extras = obj(root, "extras")?.let { obj(it, "immuch360") }
      val format = extras?.string("format")
      if (format != FORMAT) {
        val version = formatVersionOf(format)
        if (version != null && version > 1) throw GlbException(GlbProblem.NEWER_FORMAT, "format $format")
        throw notOurs("format $format")
      }
      for (required in array(root, "extensionsRequired").orEmpty()) {
        val name = (required as? JsonPrimitive)?.takeIf { it.isString }?.content
        if (name !in knownExtensions) throw notOurs("requires $required")
      }
      for (node in objects("nodes")) {
        if (listOf("matrix", "translation", "rotation", "scale").any(node::containsKey)) {
          throw notOurs("a node moves its mesh")
        }
      }
      val meshes = objects("meshes")
      if (meshes.isEmpty() || meshes.size > MAX_MESHES) throw notOurs("${meshes.size} meshes")
      // The images the meshes show, in the order they are first shown: the textures of the scene
      val shown = mutableListOf<Int>()
      val read =
        meshes.map { mesh ->
          val primitives = array(mesh, "primitives") ?: throw notOurs("a mesh without primitives")
          if (primitives.size != 1) throw notOurs("a mesh of ${primitives.size} primitives")
          val primitive = primitives[0] as? JsonObject ?: throw notOurs("a primitive is not an object")
          if ((primitive.integer("mode") ?: TRIANGLES) != TRIANGLES) throw notOurs("not triangles")
          val attributes = obj(primitive, "attributes") ?: throw notOurs("no attributes")
          val positions = floats(index(attributes, "POSITION", accessors.size), "VEC3", 3)
          val count = positions.size / 3
          if (count == 0 || count > MAX_MESH_VERTICES) throw notOurs("a mesh of $count vertices")
          val uvs = floats(index(attributes, "TEXCOORD_0", accessors.size), "VEC2", 2)
          if (uvs.size != 2 * count) throw notOurs("${uvs.size / 2} texture coordinates for $count vertices")
          val indices = indices(index(primitive, "indices", accessors.size), count)
          val image = imageOf(index(primitive, "material", materials.size))
          if (image !in shown) shown += image
          GlbMesh(
            positions = positions,
            uvs = uvs,
            indices = indices,
            texture = shown.indexOf(image),
            layer = if (image == 0) SceneLayer.PHOTO else SceneLayer.BACKGROUND,
          )
        }
      val safe = obj(extras, "safe")
      return GlbScene(
        meshes = read,
        textures = shown.map(::texture),
        format = format,
        safe =
          safe?.let {
            val lateral = it.finite("lateral")
            val vertical = it.finite("vertical")
            val forward = it.finite("forward")
            val backward = it.finite("backward")
            if (lateral != null && vertical != null && forward != null && backward != null) {
              VolumetricSceneSpec.SafeZone(lateral, vertical, forward, backward)
            } else {
              null
            }
          },
        scale = extras.finite("scale"),
        fovDegrees = extras.finite("fovDegrees"),
        generator = asset.string("generator"),
      )
    }

    /** The bytes of the view [view] in the glb: its first byte, its length, its stride (0 when none) */
    fun view(view: Int): Triple<Int, Int, Int> {
      val entry = views[view]
      if ((entry.integer("buffer") ?: -1) != 0) throw notOurs("a view of another buffer")
      val offset = entry.integer("byteOffset") ?: 0
      val length = entry.integer("byteLength") ?: throw notOurs("a view without byteLength")
      if (offset < 0 || length < 0 || offset.toLong() + length > bufferLength) {
        throw notOurs("a view of $length bytes at $offset in a buffer of $bufferLength")
      }
      return Triple(binStart + offset, length, entry.integer("byteStride") ?: 0)
    }

    /** The place of the accessor [accessor] of [count] elements of [size] bytes: its first byte in the glb */
    fun place(accessor: JsonObject, count: Int, size: Int): Int {
      if (accessor.containsKey("sparse")) throw notOurs("a sparse accessor")
      if (accessor.primitive("normalized")?.booleanOrNull == true) throw notOurs("a normalized accessor")
      val (start, length, stride) = view(index(accessor, "bufferView", views.size))
      if (stride != 0 && stride != size) throw notOurs("a stride of $stride for elements of $size bytes")
      val offset = accessor.integer("byteOffset") ?: 0
      if (offset < 0 || count < 0 || offset.toLong() + count.toLong() * size > length) {
        throw notOurs("$count elements of $size bytes at $offset in a view of $length")
      }
      return start + offset
    }

    fun floats(accessor: Int, type: String, components: Int): FloatArray {
      val entry = accessors[accessor]
      if (entry.integer("componentType") != FLOAT || entry.string("type") != type) {
        throw notOurs("accessor $accessor is not float32 $type")
      }
      val count = entry.integer("count") ?: throw notOurs("accessor $accessor without count")
      val start = place(entry, count, 4 * components)
      return FloatArray(count * components) { i ->
        bin.getFloat(start + 4 * i).also { if (!it.isFinite()) throw notOurs("accessor $accessor holds $it") }
      }
    }

    fun indices(accessor: Int, vertices: Int): IntArray {
      val entry = accessors[accessor]
      if (entry.integer("componentType") != UNSIGNED_INT || entry.string("type") != "SCALAR") {
        throw notOurs("indices not uint32")
      }
      val count = entry.integer("count") ?: throw notOurs("indices without count")
      if (count == 0 || count % 3 != 0) throw notOurs("$count indices, not triangles")
      val start = place(entry, count, 4)
      return IntArray(count) { i ->
        bin.getInt(start + 4 * i).also { if (it !in 0 until vertices) throw notOurs("index $it of $vertices vertices") }
      }
    }

    /** The image material [material] shows, checked: opaque, a base colour texture of texture coordinates 0 */
    fun imageOf(material: Int): Int {
      val entry = materials[material]
      val mode = entry.string("alphaMode")
      if (entry.containsKey("alphaMode") && mode != "OPAQUE") throw notOurs("alphaMode $mode")
      val texture = obj(entry, "pbrMetallicRoughness")?.let { obj(it, "baseColorTexture") }
        ?: throw notOurs("material $material shows no texture")
      if ((texture.integer("texCoord") ?: 0) != 0) throw notOurs("a second set of texture coordinates")
      val source = textures[index(texture, "index", textures.size)]
      return index(source, "source", images.size)
    }

    /** The JPEG of image [image], held in the buffer */
    fun texture(image: Int): GlbTexture {
      val entry = images[image]
      if (entry.containsKey("uri") || entry.string("mimeType") != "image/jpeg") {
        throw notOurs("image $image not a JPEG of the glb")
      }
      val (start, length, _) = view(index(entry, "bufferView", views.size))
      val (width, height) = jpegSize(glb, start, length) ?: throw notOurs("image $image is not a JPEG")
      return GlbTexture(data = glb, offset = start, length = length, width = width, height = height)
    }
  }
}

/** Why a glb cannot be shown */
internal enum class GlbProblem {
  /** Not a glTF of our subset: "Not a scene made by Immuch360" */
  NOT_OURS,

  /** A later format of ours (glb-layers-v2 or above): "Made by a newer version of Immuch360" */
  NEWER_FORMAT,
}

internal class GlbException(val problem: GlbProblem, message: String) : Exception(message)

/** The layer a mesh belongs to: the photo (near), or the filled background behind its breaks */
internal enum class SceneLayer {
  PHOTO,
  BACKGROUND,
}

/**
 * A scene read from its glb: its [meshes], the [textures] they show, and what extras.immuch360 says of it (null when
 * the file does not say it)
 */
internal class GlbScene(
  val meshes: List<GlbMesh>,
  val textures: List<GlbTexture>,
  val format: String,
  val safe: VolumetricSceneSpec.SafeZone?,
  val scale: Double?,
  val fovDegrees: Double?,
  val generator: String?,
) {
  val vertices: Int
    get() = meshes.sumOf { it.vertexCount }

  val triangles: Int
    get() = meshes.sumOf { it.indices.size / 3 }
}

/**
 * One mesh: x, y, z of each vertex in metres in the frame of the camera, u, v of each vertex, three indices per
 * triangle (counter clockwise seen from the camera), the index of its texture in [GlbScene.textures], and its layer
 */
internal class GlbMesh(
  val positions: FloatArray,
  val uvs: FloatArray,
  val indices: IntArray,
  val texture: Int,
  val layer: SceneLayer,
) {
  val vertexCount: Int
    get() = positions.size / 3
}

/** A JPEG texture, [length] bytes of [data] from [offset] (decoded where it lies, no copy), its size in pixels */
internal class GlbTexture(val data: ByteArray, val offset: Int, val length: Int, val width: Int, val height: Int) {
  fun bytes(): ByteArray = data.copyOfRange(offset, offset + length)
}
