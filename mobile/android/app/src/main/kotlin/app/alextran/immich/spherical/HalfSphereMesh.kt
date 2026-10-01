package app.alextran.immich.spherical

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.nio.ByteBuffer
import java.util.zip.CRC32
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.sin

/**
 * Projection data that makes the spherical renderer of Media3 draw an equirectangular image over the front half of
 * the sphere only (VR180): longitude -90 to +90 degrees, latitude -90 to +90 degrees. The back half has no geometry
 * and shows the clear colour of the renderer.
 *
 * The renderer draws a full sphere unless the video format carries projection data that its ProjectionDecoder turns
 * into a mesh. That decoder reads mesh projections ("mshp" boxes) but not the bounds of an "equi" box, so the half
 * sphere goes as a mesh: the triangle strip that Media3 builds with Projection.createEquirectangular(radius 50,
 * 36 latitudes, 72 longitudes, 180 degrees vertically, 180 degrees horizontally), stored in a "proj" box the way an
 * MP4 file stores it in Format.projectionData. The stereo mode is not part of the mesh: the renderer applies it to the
 * texture coordinates, so the same data serves mono and 3D videos, each eye getting the same mapping.
 *
 * Layout of the bytes, big endian, every box size counting its own 8 byte header:
 * - "proj" box: size (uint32), "proj"
 *   - "prhd" box: size, "prhd", version 0 (uint8), flags 0 (uint24), yaw, pitch and roll 0 (int32 each)
 *   - "mshp" box: size, "mshp", version 0 (uint8), flags 0 (uint24), CRC32 of the rest of the box (uint32),
 *     encoding "raw "
 *     - "mesh" box: size, "mesh", then
 *       - coordinate count (uint32), then the coordinates (float32): every distinct value of x, y, z, u and v;
 *       - vertex count (uint32), then for each vertex the indexes of its x, y, z, u and v in the coordinates, each
 *         as the zigzag encoded difference with the same index of the previous vertex (0 before the first vertex),
 *         on ceil(log2(coordinate count * 2)) bits, most significant bit first; zero bits up to the next byte;
 *       - vertex list count (uint32, 1), then the list: texture id (uint8, 0), index type (uint8, 1 for a triangle
 *         strip), index count (uint32), then each index into the vertices as the zigzag encoded difference with the
 *         previous index (0 before the first), on ceil(log2(vertex count * 2)) bits; zero bits up to the next byte.
 * The vertices are the distinct vertices of the strip, in the order the strip first uses them; the list rebuilds the
 * strip, with the repeated vertices that join its rows.
 */
internal object HalfSphereMesh {
  const val RADIUS = 50f
  const val LATITUDES = 36
  const val LONGITUDES = 72
  const val VERTICAL_FOV_DEGREES = 180f
  const val HORIZONTAL_FOV_DEGREES = 180f

  /** Index type of a triangle strip, Projection.DRAW_MODE_TRIANGLES_STRIP in Media3 */
  private const val TRIANGLE_STRIP = 1

  private const val COMPONENTS_PER_VERTEX = 5

  /**
   * Built once, on first use, from any thread. Always the same array: the renderer compares the projection data of
   * each frame with the previous one, by reference first, and only decodes it again when it changes.
   */
  val projectionData: ByteArray by lazy { buildProjectionData() }

  /** A triangle strip: x, y and z of each vertex in [positions], its u and v in [textureCoordinates] */
  class Strip(val positions: FloatArray, val textureCoordinates: FloatArray) {
    val vertexCount: Int
      get() = positions.size / 3
  }

  /**
   * The strip of Projection.createEquirectangular in Media3 with the same arguments, float for float: the same
   * operations in the same precision and order, and the repeated vertices that join the rows.
   */
  fun equirectangularStrip(
    radius: Float = RADIUS,
    latitudes: Int = LATITUDES,
    longitudes: Int = LONGITUDES,
    verticalFovDegrees: Float = VERTICAL_FOV_DEGREES,
    horizontalFovDegrees: Float = HORIZONTAL_FOV_DEGREES,
  ): Strip {
    val verticalFov = Math.toRadians(verticalFovDegrees.toDouble()).toFloat()
    val horizontalFov = Math.toRadians(horizontalFovDegrees.toDouble()).toFloat()
    val quadHeight = verticalFov / latitudes
    val quadWidth = horizontalFov / longitudes
    val vertexCount = (2 * (longitudes + 1) + 2) * latitudes
    val positions = FloatArray(vertexCount * 3)
    val textureCoordinates = FloatArray(vertexCount * 2)
    var p = 0
    var t = 0
    for (j in 0 until latitudes) {
      val phiLow = quadHeight * j - verticalFov / 2
      val phiHigh = quadHeight * (j + 1) - verticalFov / 2
      for (i in 0..longitudes) {
        for (k in 0..1) {
          val phi = (if (k == 0) phiLow else phiHigh).toDouble()
          val theta = (quadWidth * i + Math.PI.toFloat() - horizontalFov / 2).toDouble()
          positions[p++] = -(radius * sin(theta) * cos(phi)).toFloat()
          positions[p++] = (radius * sin(phi)).toFloat()
          positions[p++] = (radius * cos(theta) * cos(phi)).toFloat()
          textureCoordinates[t++] = i * quadWidth / horizontalFov
          textureCoordinates[t++] = (j + k) * quadHeight / verticalFov
          // The first vertex of a row and the last one appear twice, so that the rows join with empty triangles
          if ((i == 0 && k == 0) || (i == longitudes && k == 1)) {
            System.arraycopy(positions, p - 3, positions, p, 3)
            p += 3
            System.arraycopy(textureCoordinates, t - 2, textureCoordinates, t, 2)
            t += 2
          }
        }
      }
    }
    return Strip(positions, textureCoordinates)
  }

  /** The "proj" box described in the class documentation, for [strip] */
  fun buildProjectionData(strip: Strip = equirectangularStrip()): ByteArray {
    val mesh = box("mesh", meshPayload(strip))
    val encoded = ByteArrayOutputStream().apply {
      write(fourCc("raw "))
      write(mesh)
    }.toByteArray()
    val crc = CRC32().apply { update(encoded) }
    val mshp = box("mshp") {
      writeInt(0) // version and flags
      writeInt(crc.value.toInt())
      write(encoded)
    }
    val prhd = box("prhd") {
      writeInt(0) // version and flags
      writeInt(0) // yaw
      writeInt(0) // pitch
      writeInt(0) // roll
    }
    return box("proj") {
      write(prhd)
      write(mshp)
    }
  }

  private fun meshPayload(strip: Strip): ByteArray {
    // The distinct vertices, in the order the strip first uses them, and the strip as indexes into them
    val vertexIndexes = LinkedHashMap<Vertex, Int>()
    val stripIndexes = IntArray(strip.vertexCount) { v ->
      val vertex = Vertex(
        strip.positions[3 * v].toRawBits(),
        strip.positions[3 * v + 1].toRawBits(),
        strip.positions[3 * v + 2].toRawBits(),
        strip.textureCoordinates[2 * v].toRawBits(),
        strip.textureCoordinates[2 * v + 1].toRawBits(),
      )
      vertexIndexes.getOrPut(vertex) { vertexIndexes.size }
    }

    // The distinct coordinates, and each vertex as the indexes of its five components into them
    val coordinateIndexes = LinkedHashMap<Int, Int>()
    val vertexCoordinates = vertexIndexes.keys.flatMap { vertex ->
      vertex.components().map { bits -> coordinateIndexes.getOrPut(bits) { coordinateIndexes.size } }
    }
    val coordinateCount = coordinateIndexes.size
    val vertexCount = vertexIndexes.size

    val bytes = ByteArrayOutputStream()
    DataOutputStream(bytes).apply {
      writeInt(coordinateCount)
      coordinateIndexes.keys.forEach { writeInt(it) }
      writeInt(vertexCount)
      flush()
    }

    val bits = BitWriter()
    val coordinateBits = deltaBits(coordinateCount)
    val previous = IntArray(COMPONENTS_PER_VERTEX)
    vertexCoordinates.forEachIndexed { n, index ->
      val component = n % COMPONENTS_PER_VERTEX
      bits.write(zigZag(index - previous[component]), coordinateBits)
      previous[component] = index
    }
    bits.alignToByte()

    bits.write(1, 32) // one vertex list
    bits.write(0, 8) // texture id: the video
    bits.write(TRIANGLE_STRIP, 8)
    bits.write(stripIndexes.size, 32)
    val indexBits = deltaBits(vertexCount)
    var previousIndex = 0
    stripIndexes.forEach { index ->
      bits.write(zigZag(index - previousIndex), indexBits)
      previousIndex = index
    }
    bits.alignToByte()

    bytes.write(bits.toByteArray())
    return bytes.toByteArray()
  }

  /** Raw bits of the five components of a vertex (x, y, z, u, v), compared exactly */
  private data class Vertex(val x: Int, val y: Int, val z: Int, val u: Int, val v: Int) {
    fun components(): List<Int> = listOf(x, y, z, u, v)
  }

  /**
   * Width of the index differences for [count] values, computed with the very expression of the decoder so that
   * both always agree: ceil(log2(count * 2)). Wide enough for any difference: zigzag encoded, a difference between
   * -(count - 1) and count - 1 is at most 2 * count - 2.
   */
  private fun deltaBits(count: Int): Int = ceil(Math.log(2.0 * count) / Math.log(2.0)).toInt()

  /** 0, -1, 1, -2, 2... become 0, 1, 2, 3, 4..., the inverse of the decodeZigZag of the decoder */
  private fun zigZag(value: Int): Int = (value shl 1) xor (value shr 31)

  private fun fourCc(type: String): ByteArray = type.toByteArray(Charsets.US_ASCII)

  private fun box(type: String, payload: ByteArray): ByteArray =
    ByteBuffer.allocate(8 + payload.size)
      .putInt(8 + payload.size)
      .put(fourCc(type))
      .put(payload)
      .array()

  private fun box(type: String, writePayload: DataOutputStream.() -> Unit): ByteArray {
    val payload = ByteArrayOutputStream()
    DataOutputStream(payload).apply {
      writePayload()
      flush()
    }
    return box(type, payload.toByteArray())
  }

  /** Writes values on a given number of bits, most significant bit first, like ParsableBitArray reads them */
  private class BitWriter {
    private val bytes = ByteArrayOutputStream()
    private var current = 0
    private var used = 0

    /** [value] on its [count] low bits, up to 32 */
    fun write(value: Int, count: Int) {
      for (bit in count - 1 downTo 0) {
        current = (current shl 1) or ((value ushr bit) and 1)
        if (++used == 8) {
          bytes.write(current)
          current = 0
          used = 0
        }
      }
    }

    /** Zero bits up to the next byte */
    fun alignToByte() {
      if (used > 0) {
        write(0, 8 - used)
      }
    }

    fun toByteArray(): ByteArray {
      alignToByte()
      return bytes.toByteArray()
    }
  }
}
