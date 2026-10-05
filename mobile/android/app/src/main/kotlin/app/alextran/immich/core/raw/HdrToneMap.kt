package app.alextran.immich.core.raw

import kotlin.math.exp
import kotlin.math.max
import kotlin.math.pow

/**
 * The HLG and PQ to SDR tone map of the stitch shaders, on the CPU: the reference the tests check the curve with, and
 * the constants the GLSL of [RawStitchShaders] is written from. Both destinations of the stitched frame are 8 bit SDR
 * BT.709 (the SurfaceTexture of the phone's spherical view, the Quest's panel swapchain), so a 10 bit HLG or PQ
 * recording (Insta360 X6, DJI in HLG) is mapped down in the shader after the two lenses are blended.
 *
 * The curve: the BT.2100 inverse OETF (HLG, then its OOTF with gamma 1.2 for a 1000 cd/m2 display) or EOTF (PQ),
 * scaled so that 1.0 is the 203 cd/m2 reference white of BT.2408, a soft shoulder on the luminance above [KNEE], the
 * BT.2020 to BT.709 primaries, and a 2.2 gamma as Media3's SDR output. Media3's own tone map (gamma 1.0736, no
 * exposure) leaves HLG reference white near 0.52, which reads dark on a headset; here it lands near 0.97.
 */
object HdrToneMap {
  /** Luminance (relative to reference white) above which the shoulder compresses: tuned on a device with an X6 clip. */
  const val KNEE = 0.8

  /** Reference white of BT.2408, in cd/m2: SDR white. */
  const val REFERENCE_WHITE_NITS = 203.0

  /** Peak of the HLG reference display the OOTF assumes, and of the PQ signal. */
  const val HLG_PEAK_NITS = 1000.0
  const val PQ_PEAK_NITS = 10000.0

  /** BT.2020 luma weights. */
  val LUMA_2020 = doubleArrayOf(0.2627, 0.6780, 0.0593)

  /** BT.2020 to BT.709 linear primaries, row major (the shader holds the same matrix column major). */
  val BT2020_TO_BT709 =
    doubleArrayOf(
      1.6605, -0.5876, -0.0728,
      -0.1246, 1.1329, -0.0083,
      -0.0182, -0.1006, 1.1187,
    )

  /** BT.2100 HLG inverse OETF: signal E' in 0..1 to scene light in 0..1. */
  fun hlgInverseOetf(signal: Double): Double {
    val a = 0.17883277
    val b = 0.28466892
    val c = 0.55991073
    return if (signal <= 0.5) signal * signal / 3 else (exp((signal - c) / a) + b) / 12
  }

  /** BT.2100 PQ EOTF: signal E' to display light, 1.0 being 10000 cd/m2. */
  fun pqEotf(signal: Double): Double {
    val m1 = 2610.0 / 16384.0
    val m2 = 2523.0 / 4096.0 * 128.0
    val c1 = 3424.0 / 4096.0
    val c2 = 2413.0 / 4096.0 * 32.0
    val c3 = 2392.0 / 4096.0 * 32.0
    val t = signal.coerceIn(0.0, 1.0).pow(1 / m2)
    return (max(t - c1, 0.0) / (c2 - c3 * t)).pow(1 / m1)
  }

  /** The soft shoulder on luminance [y] (1.0 = reference white): the identity up to [KNEE], then towards 1. */
  fun shoulder(y: Double): Double = if (y <= KNEE) y else KNEE + (1 - KNEE) * (1 - exp(-(y - KNEE) / (1 - KNEE)))

  /** The SDR output of an HLG signal [rgb] (BT.2020, non-linear, 0..1). */
  fun hlgToSdr(rgb: DoubleArray): DoubleArray {
    val scene = DoubleArray(3) { hlgInverseOetf(rgb[it]) }
    val sceneLuma = max(dot(scene, LUMA_2020), 1e-6)
    // The OOTF of the reference display, gamma 1.2: 1.0 is then 1000 cd/m2
    val display = DoubleArray(3) { scene[it] * sceneLuma.pow(0.2) }
    return toSdr(DoubleArray(3) { display[it] * HLG_PEAK_NITS / REFERENCE_WHITE_NITS })
  }

  /** The SDR output of a PQ signal [rgb] (BT.2020, non-linear, 0..1). */
  fun pqToSdr(rgb: DoubleArray): DoubleArray =
    toSdr(DoubleArray(3) { pqEotf(rgb[it]) * PQ_PEAK_NITS / REFERENCE_WHITE_NITS })

  /** Light relative to reference white, BT.2020, to the 8 bit SDR BT.709 signal. */
  private fun toSdr(light: DoubleArray): DoubleArray {
    val y = dot(light, LUMA_2020)
    val scale = shoulder(y) / max(y, 1e-6)
    val bt2020 = DoubleArray(3) { light[it] * scale }
    return DoubleArray(3) { row ->
      val linear =
        BT2020_TO_BT709[row * 3] * bt2020[0] + BT2020_TO_BT709[row * 3 + 1] * bt2020[1] +
          BT2020_TO_BT709[row * 3 + 2] * bt2020[2]
      linear.coerceIn(0.0, 1.0).pow(1 / 2.2)
    }
  }

  private fun dot(a: DoubleArray, b: DoubleArray): Double = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
