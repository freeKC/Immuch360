package android.opengl

import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The four methods of android.opengl.Matrix that Media3's FrameRotationQueue calls, for the unit tests that run it on
 * the JVM, where android.jar has stubs only (StabilizedFramesTest). Column major 4 x 4 matrices, as OpenGL: the
 * rotation of setRotateM is the one of glRotatef, right handed, by an angle in degrees about an axis made unit long.
 */
object Matrix {
  @JvmStatic
  fun length(x: Float, y: Float, z: Float): Float = sqrt(x * x + y * y + z * z)

  @JvmStatic
  fun setIdentityM(sm: FloatArray, smOffset: Int) {
    for (i in 0 until 16) sm[smOffset + i] = if (i % 5 == 0) 1f else 0f
  }

  @JvmStatic
  fun setRotateM(rm: FloatArray, rmOffset: Int, a: Float, x: Float, y: Float, z: Float) {
    val n = length(x, y, z)
    val (ux, uy, uz) = Triple(x / n, y / n, z / n)
    val radians = Math.toRadians(a.toDouble())
    val c = cos(radians).toFloat()
    val s = sin(radians).toFloat()
    val t = 1 - c
    setIdentityM(rm, rmOffset)
    // Element (row r, column k) at rmOffset + 4 k + r
    rm[rmOffset + 0] = ux * ux * t + c
    rm[rmOffset + 1] = uy * ux * t + uz * s
    rm[rmOffset + 2] = uz * ux * t - uy * s
    rm[rmOffset + 4] = ux * uy * t - uz * s
    rm[rmOffset + 5] = uy * uy * t + c
    rm[rmOffset + 6] = uz * uy * t + ux * s
    rm[rmOffset + 8] = ux * uz * t + uy * s
    rm[rmOffset + 9] = uy * uz * t - ux * s
    rm[rmOffset + 10] = uz * uz * t + c
  }

  @JvmStatic
  fun multiplyMM(
    result: FloatArray,
    resultOffset: Int,
    lhs: FloatArray,
    lhsOffset: Int,
    rhs: FloatArray,
    rhsOffset: Int,
  ) {
    val out = FloatArray(16)
    for (r in 0 until 4) {
      for (k in 0 until 4) {
        var sum = 0f
        for (m in 0 until 4) sum += lhs[lhsOffset + 4 * m + r] * rhs[rhsOffset + 4 * k + m]
        out[4 * k + r] = sum
      }
    }
    out.copyInto(result, resultOffset)
  }
}
