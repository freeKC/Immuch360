package app.alextran.immich.immersive.scene

import app.alextran.immich.immersive.VolumetricSceneSpec
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * The 3D scene a photo of Immuch360 carries after the end of its JPEG (design-final 2026-10-27, sections 3.2 and 8.2),
 * read from the copy the viewer downloaded to its cache. The packet at the head of the file comes first: it wins over
 * the JSON of the request ([specOf]). The scene is then the last SceneLength bytes of the file, a binary glTF of
 * version 2 whose header gives the same length, whose SHA-256 is SceneSha256 in lowercase hexadecimal. A program that
 * saved the JPEG again dropped the tail: that reads as missing ("The 3D scene data is missing from this file"), and
 * the photo stays flat. scene_container.dart reads the same tail on the Dart side with the same problems.
 *
 * Pure JVM, tested by SceneFileTest. The viewer reads the head, asks SceneGate about the request and the size of the
 * file, and only then reads the tail, which it hands to GlbReader.
 */
internal object SceneFile {
  /** The bytes of the head searched for the packet, as the Dart side reads them (128 KiB) */
  const val HEAD_BYTES = 128 * 1024

  /** "glTF" read as a little endian 32 bit number, the first word of a binary glTF */
  const val GLB_MAGIC = 0x46546C67

  /** The version of glTF of the header */
  const val GLB_VERSION = 2

  /** The header of a glb: magic, version, total length */
  const val GLB_HEADER = 12

  /** Our namespace in the packets */
  const val NAMESPACE = "http://ns.aprogsys.com/immuch360/1.0/"

  /** Immuch360:Kind of a photo that carries a scene */
  const val KIND = "VolumetricScene"

  private val sha256Form = Regex("[0-9a-f]{64}")

  /** Where a scene of [sceneLength] bytes lies in a file of [fileLength] bytes; null when the file cannot hold it */
  fun tailOf(fileLength: Long, sceneLength: Long): SceneTail? =
    if (sceneLength < GLB_HEADER || sceneLength > fileLength) null
    else SceneTail(offset = fileLength - sceneLength, length = sceneLength)

  /**
   * The scene of [source]: its last [sceneLength] bytes, when they are a glb of version 2 of that length whose SHA-256
   * is [sceneSha256]. The whole tail is read in memory, so SceneGate weighs the file first.
   */
  fun readTail(source: SceneSource, sceneLength: Long, sceneSha256: String): SceneTailResult {
    val tail = tailOf(source.length, sceneLength) ?: return SceneTailResult.Failed(SceneFileProblem.MISSING)
    if (tail.length > Int.MAX_VALUE) return SceneTailResult.Failed(SceneFileProblem.MISSING)
    val header = ByteBuffer.wrap(source.read(tail.offset, GLB_HEADER)).order(ByteOrder.LITTLE_ENDIAN)
    val problem =
      when {
        header.getInt(0) != GLB_MAGIC -> SceneFileProblem.NOT_GLTF
        header.getInt(4) != GLB_VERSION -> SceneFileProblem.WRONG_VERSION
        header.getInt(8).toLong() and 0xFFFFFFFFL != tail.length -> SceneFileProblem.WRONG_LENGTH
        !sha256Form.matches(sceneSha256) -> SceneFileProblem.WRONG_SUM
        else -> null
      }
    if (problem != null) return SceneTailResult.Failed(problem)
    val glb = source.read(tail.offset, tail.length.toInt())
    if (sha256Of(glb) != sceneSha256) return SceneTailResult.Failed(SceneFileProblem.WRONG_SUM)
    return SceneTailResult.Read(glb)
  }

  /** The SHA-256 of [bytes] in lowercase hexadecimal (about 30 ms for 8 MB on the headset) */
  fun sha256Of(bytes: ByteArray): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
    val out = StringBuilder(64)
    for (byte in digest) {
      out.append(HEX[(byte.toInt() shr 4) and 0xF]).append(HEX[byte.toInt() and 0xF])
    }
    return out.toString()
  }

  private const val HEX = "0123456789abcdef"

  /**
   * The request the viewer opens: the one of the [head] when the head holds our packet (null when that packet names a
   * scene this build cannot read, or misses a field), the JSON [request] only for a file without our packet.
   */
  fun specOf(head: SceneHead?, request: VolumetricSceneSpec?): VolumetricSceneSpec? =
    if (head != null) head.spec else request

  /**
   * Our packet in the first [HEAD_BYTES] of [source], found as the Dart side finds it (ImmersiveXmp.findIn): by our
   * namespace in the text, then the packet around it; null when the head holds none. A field missing or a value that
   * cannot be right leaves [SceneHead.spec] null, the rest still read.
   */
  fun readHead(source: SceneSource): SceneHead? {
    val head = source.read(0, minOf(source.length, HEAD_BYTES.toLong()).toInt())
    // ISO 8859-1 keeps one character per byte, so the places found in the text are places in the bytes
    val text = String(head, Charsets.ISO_8859_1)
    var from = 0
    while (true) {
      val at = text.indexOf(NAMESPACE, from)
      if (at < 0) return null
      val start =
        text.lastIndexOf("<x:xmpmeta", at).takeIf { it >= 0 } ?: text.lastIndexOf("<rdf:RDF", at).coerceAtLeast(0)
      val close = text.indexOf("</x:xmpmeta>", at)
      val end =
        if (close >= 0) close + "</x:xmpmeta>".length
        else text.indexOf("</rdf:RDF>", at).let { if (it < 0) text.length else it + "</rdf:RDF>".length }
      val packet = String(head, start, end - start, Charsets.UTF_8)
      parsePacket(packet)?.let { return it }
      from = at + NAMESPACE.length
    }
  }

  /** What [packet] says of the scene, null when it binds no prefix to our namespace */
  fun parsePacket(packet: String): SceneHead? {
    val prefix =
      Regex("xmlns:([A-Za-z_][\\w.-]*)\\s*=\\s*[\"']${Regex.escape(NAMESPACE)}[\"']").find(packet)?.groupValues?.get(1)
        ?: return null
    fun value(name: String): String? {
      val qualified = Regex.escape("$prefix:$name")
      Regex("(?<![\\w:.-])$qualified\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')").find(packet)?.let { match ->
        return unescape(match.groups[1]?.value ?: match.groups[2]?.value ?: "")
      }
      return Regex("<$qualified(?:\\s[^>]*)?>([^<]*)</$qualified\\s*>").find(packet)?.let {
        unescape(it.groupValues[1].trim())
      }
    }
    val formatVersion = value("FormatVersion")?.toIntOrNull()
    val kind = value("Kind")
    val sceneFormat = value("SceneFormat")
    val readable = (formatVersion ?: 1) <= SUPPORTED_FORMAT_VERSION && kind == KIND
    val spec = if (readable) requestOf(::value) else null
    return SceneHead(formatVersion = formatVersion, kind = kind, sceneFormat = sceneFormat, spec = spec)
  }

  /** The version of our packets this build reads (Immuch360:FormatVersion) */
  const val SUPPORTED_FORMAT_VERSION = 1

  /**
   * The request the fields of a packet make, through the reader of the JSON so that both refuse the same values:
   * numbers must read as numbers, the origin is written with a capital in the packet and without one in the JSON, the
   * quality flags are a list separated by commas, a missing scale is 1 (the Dart side reads it so)
   */
  private fun requestOf(value: (String) -> String?): VolumetricSceneSpec? {
    fun whole(name: String): JsonPrimitive? = value(name)?.toLongOrNull()?.let(::JsonPrimitive)
    fun decimal(name: String): JsonPrimitive? =
      value(name)?.toDoubleOrNull()?.takeIf { it.isFinite() }?.let(::JsonPrimitive)
    val root = buildJsonObject {
      put("kind", VolumetricSceneSpec.KIND)
      put("version", VolumetricSceneSpec.VERSION)
      value("SceneFormat")?.let { put("format", it) }
      whole("SceneLength")?.let { put("sceneLength", it) }
      value("SceneSha256")?.let { put("sceneSha256", it) }
      whole("SceneMeshes")?.let { put("meshes", it) }
      whole("SceneVertices")?.let { put("vertices", it) }
      whole("SceneTriangles")?.let { put("triangles", it) }
      whole("SceneTextureMax")?.let { put("textureMax", it) }
      // A scale written but not a number leaves the request without one, so it is refused
      put("scale", if (value("SceneScale") == null) JsonPrimitive(1.0) else decimal("SceneScale") ?: JsonNull)
      val lateral = decimal("SafeLateral")
      val vertical = decimal("SafeVertical")
      val forward = decimal("SafeForward")
      val backward = decimal("SafeBackward")
      if (lateral != null && vertical != null && forward != null && backward != null) {
        put(
          "safe",
          buildJsonObject {
            put("lateral", lateral)
            put("vertical", vertical)
            put("forward", forward)
            put("backward", backward)
          },
        )
      }
      decimal("FieldOfView")?.let { put("fovDegrees", it) }
      value("Origin")?.let { put("origin", it.replaceFirstChar { first -> first.lowercaseChar() }) }
      val flags = value("QualityFlags").orEmpty().split(',').map { it.trim() }.filter { it.isNotEmpty() }
      put("flags", JsonArray(flags.map(::JsonPrimitive)))
    }
    return VolumetricSceneSpec.fromJson(root)
  }

  private val entity = Regex("&(#x[0-9A-Fa-f]+|#[0-9]+|amp|lt|gt|quot|apos);")

  /** [value] with its entities decoded, one that names no character left as written (xmpUnescape of the Dart side) */
  fun unescape(value: String): String =
    entity.replace(value) { match ->
      val name = match.groupValues[1]
      when {
        name == "amp" -> "&"
        name == "lt" -> "<"
        name == "gt" -> ">"
        name == "quot" -> "\""
        name == "apos" -> "'"
        name.startsWith("#x") -> character(name.substring(2).toIntOrNull(16)) ?: match.value
        else -> character(name.substring(1).toIntOrNull()) ?: match.value
      }
    }

  private fun character(code: Int?): String? =
    if (code == null || code < 0 || code > 0x10FFFF) null else String(Character.toChars(code))
}

/** The bytes of a file, read by range: the cached copy of the viewer, or bytes in memory */
internal interface SceneSource {
  val length: Long

  /** [count] bytes from [offset], both within the file */
  fun read(offset: Long, count: Int): ByteArray

  companion object {
    fun of(bytes: ByteArray): SceneSource =
      object : SceneSource {
        override val length: Long = bytes.size.toLong()

        override fun read(offset: Long, count: Int): ByteArray =
          bytes.copyOfRange(offset.toInt(), offset.toInt() + count)
      }

    /** [file], open for reading; the caller closes it */
    fun of(file: RandomAccessFile): SceneSource =
      object : SceneSource {
        override val length: Long = file.length()

        override fun read(offset: Long, count: Int): ByteArray {
          val out = ByteArray(count)
          file.seek(offset)
          file.readFully(out)
          return out
        }
      }
  }
}

/** The place of a scene in its file: its first byte and its length */
internal data class SceneTail(val offset: Long, val length: Long)

/** Why the scene of a file cannot be read (SceneTailProblem of scene_container.dart) */
internal enum class SceneFileProblem {
  /** No packet names the scene, or the file is shorter than the scene it names */
  MISSING,

  /** The bytes where the scene should start are not a binary glTF (the JPEG was saved again by another program) */
  NOT_GLTF,

  /** A binary glTF of another version */
  WRONG_VERSION,

  /** The header gives another length than the packet */
  WRONG_LENGTH,

  /** The bytes are not those the packet sums, or the sum is not in lowercase hexadecimal */
  WRONG_SUM,
}

/** What reading the tail gave: the [Read.glb] bytes, or the [Failed.problem] */
internal sealed interface SceneTailResult {
  class Read(val glb: ByteArray) : SceneTailResult

  data class Failed(val problem: SceneFileProblem) : SceneTailResult
}

/**
 * What the packet at the head of a file says of its scene: Immuch360:FormatVersion, Kind and SceneFormat as written
 * (SceneGate tells a newer version by them), and the request its fields make, null when the packet is of a newer
 * version, of another kind, of another scene format, or misses a field or holds a value that cannot be right.
 */
internal data class SceneHead(
  val formatVersion: Int?,
  val kind: String?,
  val sceneFormat: String?,
  val spec: VolumetricSceneSpec?,
)
