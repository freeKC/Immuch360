package app.alextran.immich.spherical

import java.nio.ByteBuffer

/**
 * What the spherical metadata of a video (Spherical Video V2) says about its projection, read from the projection
 * data of its format: the part of the sphere it covers, and whether it is a mesh. MP4 files give the whole "proj" box;
 * Matroska files give the payload of the projection alone (the bounds of an equirectangular image, or a mesh).
 *
 * An "equi" box covers the half sphere when its left and right bounds crop about half of the width (VR180 files crop
 * a quarter on each side), the full sphere otherwise. A mesh ("mshp" box) counts as the half sphere: VR180 cameras
 * write meshes, which the spherical renderer of Media3 draws as they are.
 */
internal class DeclaredProjection(val coverage: SphereCoverage, val mesh: Boolean) {
  companion object {
    private const val BOX_HEADER = 8

    /** "equi" payload: version and flags, then the top, bottom, left and right bounds (uint32 each) */
    private const val EQUI_PAYLOAD = 20
    private const val EQUI_LEFT = 12
    private const val EQUI_RIGHT = 16

    /** Cropped share of the width, left and right bounds together, for which an "equi" box covers the half sphere */
    private val HALF_SPHERE_CROP = 0.4..0.6

    private val PROJ = fourCc("proj")
    private val EQUI = fourCc("equi")
    private val MSHP = fourCc("mshp")
    private val RAW = fourCc("raw ")
    private val DFL8 = fourCc("dfl8")

    /** What [projectionData] declares, null when there is nothing this can read (or no projection data) */
    fun of(projectionData: ByteArray?): DeclaredProjection? {
      if (projectionData == null || projectionData.size < BOX_HEADER) {
        return null
      }
      val data = ByteBuffer.wrap(projectionData)
      if (data.getInt(4) == PROJ) {
        return ofProjBox(data)
      }
      // Matroska: a mesh starts with its version, flags and CRC, then its encoding
      if (projectionData.size >= 12 && data.getInt(8).let { it == RAW || it == DFL8 }) {
        return DeclaredProjection(SphereCoverage.HALF, mesh = true)
      }
      if (projectionData.size == EQUI_PAYLOAD) {
        return ofEquirectangular(data, 0)
      }
      return null
    }

    /** The children of a "proj" box: a header ("prhd"), then the projection itself */
    private fun ofProjBox(data: ByteBuffer): DeclaredProjection? {
      val end = data.limit()
      var position = BOX_HEADER
      while (position + BOX_HEADER <= end) {
        val size = data.getInt(position)
        if (size < BOX_HEADER || size > end - position) {
          return null
        }
        when (data.getInt(position + 4)) {
          EQUI -> return if (size - BOX_HEADER >= EQUI_PAYLOAD) ofEquirectangular(data, position + BOX_HEADER) else null
          MSHP -> return DeclaredProjection(SphereCoverage.HALF, mesh = true)
        }
        position += size
      }
      return null
    }

    /** The bounds are 0.32 fixed point fractions of the full equirectangular image, cropped from each side */
    private fun ofEquirectangular(data: ByteBuffer, payload: Int): DeclaredProjection {
      val crop = fraction(data.getInt(payload + EQUI_LEFT)) + fraction(data.getInt(payload + EQUI_RIGHT))
      val coverage = if (crop in HALF_SPHERE_CROP) SphereCoverage.HALF else SphereCoverage.FULL
      return DeclaredProjection(coverage, mesh = false)
    }

    private fun fraction(bits: Int): Double = (bits.toLong() and 0xFFFFFFFFL) / 4_294_967_296.0

    private fun fourCc(type: String): Int = ByteBuffer.wrap(type.toByteArray(Charsets.US_ASCII)).int
  }
}
