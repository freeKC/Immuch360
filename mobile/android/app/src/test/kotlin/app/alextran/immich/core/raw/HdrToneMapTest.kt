package app.alextran.immich.core.raw

import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The HLG and PQ to SDR curve of the stitch shaders (section 9 of the Android two track design). */
class HdrToneMapTest {
  private fun hlgGrey(signal: Double): Double = HdrToneMap.hlgToSdr(doubleArrayOf(signal, signal, signal))[1]

  @Test
  fun `HLG reference values on a grey`() {
    assertEquals(0.0, hlgGrey(0.0), 1e-6)
    assertEquals(0.250, hlgGrey(0.25), 1e-3)
    assertEquals(0.532, hlgGrey(0.5), 1e-3)
    // Reference white (75 percent HLG) near the top of the SDR range, not at Media3's 0.52
    assertEquals(0.966, hlgGrey(0.75), 1e-3)
    assertEquals(1.000, hlgGrey(1.0), 1e-3)
  }

  @Test
  fun `the curve is monotonic over the whole signal range`() {
    var previous = -1.0
    for (i in 0..1000) {
      val value = hlgGrey(i / 1000.0)
      assertTrue("at ${i / 1000.0}", value >= previous - 1e-12)
      previous = value
    }
    previous = -1.0
    for (i in 0..1000) {
      val value = HdrToneMap.pqToSdr(DoubleArray(3) { i / 1000.0 })[1]
      assertTrue("PQ at ${i / 1000.0}", value >= previous - 1e-12)
      previous = value
    }
  }

  @Test
  fun `the shoulder is continuous at the knee and stays below 1`() {
    val knee = HdrToneMap.KNEE
    assertEquals(knee, HdrToneMap.shoulder(knee), 0.0)
    assertTrue(abs(HdrToneMap.shoulder(knee + 1e-9) - knee) < 1e-8)
    // Its slope is 1 at the knee: no visible bend where it starts
    assertEquals(1.0, (HdrToneMap.shoulder(knee + 1e-6) - HdrToneMap.shoulder(knee)) / 1e-6, 1e-4)
    // It tends to 1 and never passes it
    assertTrue(HdrToneMap.shoulder(2.0) < 1.0)
    assertTrue(HdrToneMap.shoulder(100.0) <= 1.0)
  }

  @Test
  fun `PQ reference white lands near 0 point 966`() {
    // The PQ signal of 203 cd/m2
    val m1 = 2610.0 / 16384.0
    val m2 = 2523.0 / 4096.0 * 128.0
    val c1 = 3424.0 / 4096.0
    val c2 = 2413.0 / 4096.0 * 32.0
    val c3 = 2392.0 / 4096.0 * 32.0
    val y = Math.pow(203.0 / 10000.0, m1)
    val signal = Math.pow((c1 + c2 * y) / (1 + c3 * y), m2)
    assertEquals(203.0 / 10000.0, HdrToneMap.pqEotf(signal), 1e-9)
    assertEquals(0.966, HdrToneMap.pqToSdr(DoubleArray(3) { signal })[0], 1e-3)
  }

  @Test
  fun `the primaries keep a grey grey`() {
    val out = HdrToneMap.hlgToSdr(doubleArrayOf(0.6, 0.6, 0.6))
    assertEquals(out[0], out[1], 1e-3)
    assertEquals(out[1], out[2], 1e-3)
  }
}
