package app.alextran.immich.immersive.splat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
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
    freeSpace: Long? = 8L shl 30,
    copiesWhole: Boolean = false,
  ): SplatVerdict = SplatGate.check(engine, device, probe, fileBytes, cap, memory, thermal, freeSpace, copiesWhole)

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
  fun `the free memory holds what the module loads, and a hot headset waits`() {
    // 47 819 gaussians of degree 0 decoded (56 bytes each) weigh more than the SPZ of 686 150 bytes: three times them
    val needed = 3 * 47_819L * 56
    assertEquals(needed, SplatGate.memoryNeeded(spz, 686_150, keep = null))
    assertEquals(SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_MEMORY), check(memory = needed - 1))
    assertEquals(SplatVerdict.Open(47_819, keep = null, large = false), check(memory = needed))
    assertEquals(SplatVerdict.Open(47_819, keep = null, large = false), check(memory = null))
    assertEquals(SplatVerdict.Refused(SplatRefusal.TOO_WARM), check(thermal = SplatGate.THERMAL_STATUS_SEVERE))
    assertEquals(SplatVerdict.Open(47_819, keep = null, large = false), check(thermal = 2))
    assertEquals(SplatVerdict.Open(47_819, keep = null, large = false), check(thermal = null))
  }

  @Test
  fun `a large capture reduced to 150 000 gaussians weighs what it shows, not its source`() {
    // The case of the review: 4 million gaussians of degree 3 in a PLY of 992 MB, 2.5 GB free
    val ply = SplatProbe.Ply(4_000_000, 3, null, 1_500, 248, emptyList())
    val fileBytes = 1_500L + 4_000_000L * 248
    val verdict = check(probe = ply, fileBytes = fileBytes, cap = SplatGate.LARGE_GAUSSIANS, memory = 2_500_000_000L)
    assertEquals(SplatVerdict.Open(4_000_000, keep = 150_000, large = true), verdict)
    // Three times the 37 MB the module reads, and the 9 bytes a gaussian the reducer holds for the 4 million
    val needed = SplatGate.memoryNeeded(ply, fileBytes, keep = 150_000)
    val loaded = 37_200_057L + SplatGate.REDUCED_SLACK_BYTES
    assertEquals(3 * loaded + 36_000_000L + SplatGate.REDUCER_OVERHEAD_BYTES, needed)
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_MEMORY),
      check(probe = ply, fileBytes = fileBytes, cap = SplatGate.LARGE_GAUSSIANS, memory = needed - 1),
    )
    // Shown whole, the same splat would weigh its 4 million gaussians: the reduction is what lets it in
    assertTrue(SplatGate.memoryNeeded(ply, fileBytes, keep = null) > 2_500_000_000L)
  }

  @Test
  fun `the cache holds the reduced copy or the copy named after the format, and a download before it starts`() {
    val reserve = SplatGate.CACHE_RESERVE_BYTES
    // 452 451 gaussians in 6 824 362 bytes reduced to 50 000: about a ninth of the file, plus the slack of a header
    val reduced = SplatGate.cacheBytesWritten(6_824_362, 452_451, 50_000, copiesWhole = false)
    assertEquals(754_155L + SplatGate.REDUCED_SLACK_BYTES, reduced)
    val big = spz(452_451)
    assertEquals(
      SplatVerdict.Open(452_451, keep = 50_000, large = false),
      check(probe = big, fileBytes = 6_824_362, freeSpace = reduced + reserve),
    )
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_SPACE),
      check(probe = big, fileBytes = 6_824_362, freeSpace = reduced + reserve - 1),
    )
    // Shown whole where it is, nothing is written: no space asked
    assertEquals(SplatVerdict.Open(47_819, keep = null, large = false), check(freeSpace = 0))
    // Copied whole under the name of its format: the file itself
    assertEquals(686_150L, SplatGate.cacheBytesWritten(686_150, 47_819, null, copiesWhole = true))
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_SPACE),
      check(freeSpace = 686_150 + reserve - 1, copiesWhole = true),
    )
    assertEquals(SplatVerdict.Open(47_819, keep = null, large = false), check(freeSpace = null, copiesWhole = true))
    // A download is weighed before it starts, unless its size is not known
    assertTrue(SplatGate.roomForDownload(686_150, 686_150 + reserve))
    assertFalse(SplatGate.roomForDownload(686_150, 686_150 + reserve - 1))
    assertTrue(SplatGate.roomForDownload(1, 0))
    assertTrue(SplatGate.roomForDownload(686_150, null))
  }

  @Test
  fun `Gaussian splats off, the viewer registers no splat module`() {
    assertTrue(SplatGate.registers(engine = true, device = "eureka", wanted = true))
    assertTrue(SplatGate.registers(engine = true, device = null, wanted = true))
    // The setting off: no feature, whatever the headset
    assertFalse(SplatGate.registers(engine = true, device = "eureka", wanted = false))
    assertFalse(SplatGate.registers(engine = true, device = "panther", wanted = false))
    // Nor in the phone flavour, nor on a Quest 2 or Pro
    assertFalse(SplatGate.registers(engine = false, device = "eureka", wanted = true))
    assertFalse(SplatGate.registers(engine = true, device = "hollywood", wanted = true))
    assertFalse(SplatGate.registers(engine = true, device = "seacliff", wanted = true))
  }

  @Test
  fun `a viewer the module did not start with refuses a splat at once, after the flavour and the headset`() {
    assertNull(SplatGate.viewerRefusal(engine = true, device = "eureka", running = true))
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.MODULE_NOT_RUNNING),
      SplatGate.viewerRefusal(engine = true, device = "eureka", running = false),
    )
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.OLDER_HEADSET),
      SplatGate.viewerRefusal(engine = true, device = "hollywood", running = false),
    )
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.NOT_IN_THIS_VERSION),
      SplatGate.viewerRefusal(engine = false, device = "eureka", running = false),
    )
  }

  @Test
  fun `a PLY is reduced as an SPZ of version 3`() {
    val ply = SplatProbe.Ply(200_000, 0, null, 400, 56, emptyList())
    assertEquals(SplatVerdict.Open(200_000, keep = 50_000, large = false), check(probe = ply, fileBytes = 11_200_400))
  }
}
