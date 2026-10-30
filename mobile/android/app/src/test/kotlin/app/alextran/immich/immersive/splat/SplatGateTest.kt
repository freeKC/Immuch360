package app.alextran.immich.immersive.splat

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The gate of the splats in the headset (lot S5): Quest 3 and 3S only, the flavour with the splat module, the count
 * the headset takes (50 000 until measured, 150 000 with Large splats), the reduction beyond it within its limits,
 * the free memory and the heat.
 */
class SplatGateTest {
  private val spz = SplatProbe.Spz(version = 3, gaussians = 47_819, shDegree = 0, fractionalBits = 12, flags = 0)

  private fun check(
    probe: SplatProbe = spz,
    device: String? = "eureka",
    engine: Boolean = true,
    fileBytes: Long = 686_150,
    cap: Int = SplatGate.SAFE_GAUSSIANS,
    memory: Long? = 4L shl 30,
    thermal: Int? = 0,
  ): SplatVerdict = SplatGate.check(engine, device, probe, fileBytes, cap, memory, thermal)

  private fun spz(count: Long, version: Int = 3) = spz.copy(version = version, gaussians = count)

  @Test
  fun `a splat within the count opens whole on a Quest 3, a 3S and a headset this build does not know`() {
    for (device in listOf("eureka", "panther", null, "someday")) {
      assertEquals(device, SplatVerdict.Open(47_819, keep = null, large = false), check(device = device))
    }
  }

  @Test
  fun `the Quest 2 and Pro are refused, and the phone flavour before anything`() {
    assertEquals(SplatVerdict.Refused(SplatRefusal.OLDER_HEADSET), check(device = "hollywood"))
    assertEquals(SplatVerdict.Refused(SplatRefusal.OLDER_HEADSET), check(device = "seacliff"))
    // No splat module in the APK: said first, whatever the headset and the file
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.NOT_IN_THIS_VERSION),
      check(engine = false, device = "hollywood", probe = SplatProbe.Refused(SplatFileProblem.DAMAGED, "")),
    )
  }

  @Test
  fun `a file the probe refused keeps its reason`() {
    val reasons =
      mapOf(
        SplatFileProblem.NOT_A_SPLAT to SplatRefusal.NOT_A_SPLAT,
        SplatFileProblem.COMPRESSED_PLY to SplatRefusal.COMPRESSED_PLY,
        SplatFileProblem.UNSUPPORTED_PLY to SplatRefusal.UNSUPPORTED_PLY,
        SplatFileProblem.NEWER_SPZ to SplatRefusal.NEWER_SPZ,
        SplatFileProblem.DAMAGED to SplatRefusal.DAMAGED,
      )
    for ((problem, refusal) in reasons) {
      assertEquals(SplatVerdict.Refused(refusal), check(probe = SplatProbe.Refused(problem, "")))
    }
  }

  @Test
  fun `beyond the count the splat is reduced to it, Large splats taking it to 150 000 with a warning`() {
    assertEquals(SplatVerdict.Open(452_451, keep = 50_000, large = false), check(probe = spz(452_451)))
    assertEquals(
      SplatVerdict.Open(452_451, keep = 150_000, large = true),
      check(probe = spz(452_451), cap = SplatGate.LARGE_GAUSSIANS),
    )
    // Between the two, whole with Large splats, said to be large
    assertEquals(SplatVerdict.Open(60_000, keep = null, large = true), check(probe = spz(60_000), cap = 150_000))
    // At the count itself, whole
    assertEquals(SplatVerdict.Open(50_000, keep = null, large = false), check(probe = spz(50_000)))
    // A count asked beyond the advice of the SDK is taken as the advice
    assertEquals(SplatVerdict.Open(452_451, keep = 150_000, large = true), check(probe = spz(452_451), cap = 900_000))
  }

  @Test
  fun `the reduction stops at 4 million gaussians, 1 GiB and the version 4 of SPZ`() {
    assertEquals(SplatVerdict.Open(4_000_000, keep = 50_000, large = false), check(probe = spz(4_000_000)))
    assertEquals(SplatVerdict.Refused(SplatRefusal.TOO_LARGE, 4_000_001), check(probe = spz(4_000_001)))
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.TOO_LARGE, 452_451),
      check(probe = spz(452_451), fileBytes = (1L shl 30) + 1, memory = null),
    )
    // Version 4 is ZSTD, which this build does not decompress: whole within the count, else too large
    assertEquals(SplatVerdict.Open(47_819, keep = null, large = false), check(probe = spz(47_819, version = 4)))
    assertEquals(SplatVerdict.Refused(SplatRefusal.TOO_LARGE, 60_000), check(probe = spz(60_000, version = 4)))
  }

  @Test
  fun `the free memory holds three times the file, and a hot headset waits`() {
    assertEquals(SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_MEMORY), check(memory = 3 * 686_150L - 1))
    assertEquals(SplatVerdict.Open(47_819, keep = null, large = false), check(memory = 3 * 686_150L))
    assertEquals(SplatVerdict.Open(47_819, keep = null, large = false), check(memory = null))
    assertEquals(SplatVerdict.Refused(SplatRefusal.TOO_WARM), check(thermal = SplatGate.THERMAL_STATUS_SEVERE))
    assertEquals(SplatVerdict.Open(47_819, keep = null, large = false), check(thermal = 2))
    assertEquals(SplatVerdict.Open(47_819, keep = null, large = false), check(thermal = null))
  }

  @Test
  fun `a PLY is reduced as an SPZ of version 3`() {
    val ply = SplatProbe.Ply(200_000, 0, null, 400, 56, emptyList())
    assertEquals(SplatVerdict.Open(200_000, keep = 50_000, large = false), check(probe = ply, fileBytes = 11_200_400))
  }
}
