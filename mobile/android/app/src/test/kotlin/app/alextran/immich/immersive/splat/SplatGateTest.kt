package app.alextran.immich.immersive.splat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The gate of the splats in the headset (lot S5): Quest 3 and 3S only, the flavour with the splat module, the count
 * the headset takes (300 000 by default and 1 000 000 with Large splats, from the series on a Quest 3 of 8 November
 * 2026), the reduction beyond it within its limits, the free memory and the heat; every SPZ, version 4 (ZSTD)
 * included, rewritten as version 2, the only one the module reads.
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
    zstd: Boolean = true,
  ): SplatVerdict =
    SplatGate.check(engine, device, probe, fileBytes, cap, memory, thermal, freeSpace, copiesWhole, readsZstd = zstd)

  private fun spz(count: Long, version: Int = 3) = spz.copy(version = version, gaussians = count)

  private fun ply(count: Long) = SplatProbe.Ply(count, 0, null, 400, 56, emptyList())

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
  fun `beyond the count the splat is reduced to it, Large splats taking it to 1 000 000 with a warning`() {
    // The counts of the series on a Quest 3 of 8 November 2026, both under the most the headset reduces
    assertEquals(300_000, SplatGate.SAFE_GAUSSIANS)
    assertEquals(1_000_000, SplatGate.LARGE_GAUSSIANS)
    assertTrue(SplatGate.LARGE_GAUSSIANS < SplatGate.MAX_REDUCIBLE_GAUSSIANS)
    assertEquals(SplatVerdict.Open(452_451, keep = 300_000, large = false), check(probe = spz(452_451)))
    // With Large splats the cactus opens whole, said to be large; beyond the Large count, reduced to it
    assertEquals(
      SplatVerdict.Open(452_451, keep = null, large = true),
      check(probe = spz(452_451), cap = SplatGate.LARGE_GAUSSIANS),
    )
    assertEquals(
      SplatVerdict.Open(1_274_802, keep = 1_000_000, large = true),
      check(probe = spz(1_274_802), cap = SplatGate.LARGE_GAUSSIANS),
    )
    // At the count itself, whole
    assertEquals(SplatVerdict.Open(300_000, keep = null, large = false), check(probe = spz(300_000)))
    // Requests of the former counts, 50 000 and 150 000, are still reduced to them
    assertEquals(SplatVerdict.Open(452_451, keep = 50_000, large = false), check(probe = spz(452_451), cap = 50_000))
    assertEquals(SplatVerdict.Open(452_451, keep = 150_000, large = false), check(probe = spz(452_451), cap = 150_000))
    // A count asked beyond the Large count is taken as the Large count
    assertEquals(
      SplatVerdict.Open(2_500_000, keep = 1_000_000, large = true),
      check(probe = spz(2_500_000), cap = 3_000_000),
    )
  }

  @Test
  fun `1 000 000 gaussians shown whole with Large splats still need the free memory for them and a cool headset`() {
    // 1 000 000 gaussians of degree 3 decoded weigh 236 bytes each, three times that for the module: 708 MB
    val large = SplatProbe.Spz(version = 2, gaussians = 1_000_000, shDegree = 3, fractionalBits = 12, flags = 0)
    val fileBytes = 1_000_000L * 64
    val needed = SplatGate.memoryNeeded(large, fileBytes, keep = null)
    assertEquals(3 * 1_000_000L * 236, needed)
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_MEMORY),
      check(probe = large, fileBytes = fileBytes, cap = SplatGate.LARGE_GAUSSIANS, memory = needed - 1),
    )
    assertEquals(
      SplatVerdict.Open(1_000_000, keep = null, large = true),
      check(probe = large, fileBytes = fileBytes, cap = SplatGate.LARGE_GAUSSIANS, memory = needed),
    )
    val severe = SplatGate.THERMAL_STATUS_SEVERE
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.TOO_WARM),
      check(probe = large, fileBytes = fileBytes, cap = SplatGate.LARGE_GAUSSIANS, thermal = severe),
    )
  }

  @Test
  fun `300 000 gaussians shown whole by default need the free memory for them and a cool headset`() {
    val shown = SplatProbe.Spz(version = 2, gaussians = 300_000, shDegree = 3, fractionalBits = 12, flags = 0)
    val fileBytes = 300_000L * 64
    val needed = SplatGate.memoryNeeded(shown, fileBytes, keep = null)
    assertEquals(3 * 300_000L * 236, needed)
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_MEMORY),
      check(probe = shown, fileBytes = fileBytes, memory = needed - 1),
    )
    assertEquals(
      SplatVerdict.Open(300_000, keep = null, large = false),
      check(probe = shown, fileBytes = fileBytes, memory = needed),
    )
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.TOO_WARM),
      check(probe = shown, fileBytes = fileBytes, thermal = SplatGate.THERMAL_STATUS_SEVERE),
    )
  }

  @Test
  fun `the reduction stops at 4 million gaussians and 1 GiB`() {
    assertEquals(SplatVerdict.Open(4_000_000, keep = 300_000, large = false), check(probe = spz(4_000_000)))
    assertEquals(SplatVerdict.Refused(SplatRefusal.TOO_LARGE, 4_000_001), check(probe = spz(4_000_001)))
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.TOO_LARGE, 452_451),
      check(probe = spz(452_451), fileBytes = (1L shl 30) + 1, memory = null),
    )
  }

  @Test
  fun `a version 4 SPZ opens as the others, rewritten as version 2, reduced beyond the count`() {
    // FreeKC's report of 1 November 2026: axes_v4.spz was refused. Its ZSTD streams are read in the quest flavour and
    // the splat written again as version 2, the only version the module reads (Quest 3, 31 October 2026)
    assertEquals(SplatVerdict.Open(686, keep = null, large = false), check(probe = spz(686, version = 4)))
    assertEquals(SplatVerdict.Open(452_451, keep = 300_000, large = false), check(probe = spz(452_451, version = 4)))
    assertEquals(SplatVerdict.Refused(SplatRefusal.TOO_LARGE, 9_000_000), check(probe = spz(9_000_000, version = 4)))
    assertEquals(SplatVerdict.Refused(SplatRefusal.TOO_WARM), check(probe = spz(686, version = 4), thermal = 4))
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.OLDER_HEADSET),
      check(probe = spz(686, version = 4), device = "hollywood"),
    )
    // A build without the ZSTD decoder says it is not in this version, as for a build without the module
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.NOT_IN_THIS_VERSION),
      check(probe = spz(686, version = 4), zstd = false),
    )
    for (version in 1..3) {
      assertEquals(
        SplatVerdict.Open(47_819, keep = null, large = false),
        check(probe = spz(47_819, version = version), zstd = false),
      )
    }
  }

  @Test
  fun `a version 4 SPZ counts its rewrite in the cache, and its decoder in the memory`() {
    // Its copy as version 2 measured from 0.91 to 1.03 times the version 4 file (four files of 1 November 2026)
    val v4 = spz(47_819, version = 4)
    assertEquals(1.25, SplatGate.rewriteGrowth(v4), 0.0)
    val copy = SplatGate.cacheBytesWritten(686_150, 47_819, null, copiesWhole = false, rewrites = true, growth = 1.25)
    assertEquals(857_688L + SplatGate.REDUCED_SLACK_BYTES, copy)
    val reserve = SplatGate.CACHE_RESERVE_BYTES
    assertEquals(SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_SPACE), check(probe = v4, freeSpace = copy + reserve - 1))
    assertEquals(SplatVerdict.Open(47_819, keep = null, large = false), check(probe = v4, freeSpace = copy + reserve))
    // The window of the decoder on top of what a version 3 of the same size needs (its decoded gaussians weigh more
    // than its file, rewritten or not)
    val v3 = spz(47_819, version = 3)
    assertEquals(
      SplatGate.memoryNeeded(v3, 686_150, null) + SplatGate.ZSTD_DECODER_BYTES,
      SplatGate.memoryNeeded(v4, 686_150, null),
    )
    assertEquals(8L shl 20, SplatGate.ZSTD_DECODER_BYTES)
  }

  @Test
  fun `an SPZ of version 1, 2 or 3 shown whole is rewritten as version 2, and the cache must hold the copy`() {
    val reserve = SplatGate.CACHE_RESERVE_BYTES
    // Version 3: the copy is about the size of the file (a byte less a rotation), with the slack of a header
    val v3 = SplatGate.cacheBytesWritten(686_150, 47_819, null, copiesWhole = false, rewrites = true)
    assertEquals(686_150L + SplatGate.REDUCED_SLACK_BYTES, v3)
    assertEquals(SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_SPACE), check(freeSpace = v3 + reserve - 1))
    assertEquals(SplatVerdict.Open(47_819, keep = null, large = false), check(freeSpace = v3 + reserve))
    // Version 1: its float16 positions take 9 bytes instead of 6, the copy weighed half again as large
    assertEquals(1.5, SplatGate.rewriteGrowth(spz(860, version = 1)), 0.0)
    assertEquals(1.0, SplatGate.rewriteGrowth(spz(860, version = 3)), 0.0)
    assertEquals(
      SplatGate.cacheBytesWritten(860, 686, null, copiesWhole = false, rewrites = true, growth = 1.5),
      1_290L + SplatGate.REDUCED_SLACK_BYTES,
    )
    // Version 2 too, since a version 2 cut or short of its data aborts the module: the copy is about its size
    val v2 = spz(47_819, version = 2)
    assertEquals(1.0, SplatGate.rewriteGrowth(v2), 0.0)
    assertEquals(SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_SPACE), check(probe = v2, freeSpace = v3 + reserve - 1))
    assertEquals(SplatVerdict.Open(47_819, keep = null, large = false), check(probe = v2, freeSpace = v3 + reserve))
    // Only a PLY is read where it is: nothing written, no space asked
    assertEquals(SplatVerdict.Open(47_819, keep = null, large = false), check(probe = ply(47_819), freeSpace = 0))
    assertEquals(0L, SplatGate.cacheBytesWritten(686_150, 47_819, null, copiesWhole = false, rewrites = false))
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
    // A request of 150 000, the Large count of release 43
    val verdict = check(probe = ply, fileBytes = fileBytes, cap = 150_000, memory = 2_500_000_000L)
    assertEquals(SplatVerdict.Open(4_000_000, keep = 150_000, large = false), verdict)
    // Three times the 37 MB the module reads, and the 9 bytes a gaussian the reducer holds for the 4 million
    val needed = SplatGate.memoryNeeded(ply, fileBytes, keep = 150_000)
    val loaded = 37_200_057L + SplatGate.REDUCED_SLACK_BYTES
    assertEquals(3 * loaded + 36_000_000L + SplatGate.REDUCER_OVERHEAD_BYTES, needed)
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_MEMORY),
      check(probe = ply, fileBytes = fileBytes, cap = 150_000, memory = needed - 1),
    )
    // Shown whole, the same splat would weigh its 4 million gaussians: the reduction is what lets it in
    assertTrue(SplatGate.memoryNeeded(ply, fileBytes, keep = null) > 2_500_000_000L)
  }

  @Test
  fun `the cache holds the reduced copy or the copy named after the format, and a download before it starts`() {
    val reserve = SplatGate.CACHE_RESERVE_BYTES
    // 452 451 gaussians in 6 824 362 bytes reduced to 300 000: about two thirds of the file, plus the slack of a header
    val reduced = SplatGate.cacheBytesWritten(6_824_362, 452_451, 300_000, copiesWhole = false)
    assertEquals(4_524_929L + SplatGate.REDUCED_SLACK_BYTES, reduced)
    // And to 50 000, a request of the former default: about a ninth
    val former = SplatGate.cacheBytesWritten(6_824_362, 452_451, 50_000, copiesWhole = false)
    assertEquals(754_155L + SplatGate.REDUCED_SLACK_BYTES, former)
    val big = spz(452_451)
    assertEquals(
      SplatVerdict.Open(452_451, keep = 300_000, large = false),
      check(probe = big, fileBytes = 6_824_362, freeSpace = reduced + reserve),
    )
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_SPACE),
      check(probe = big, fileBytes = 6_824_362, freeSpace = reduced + reserve - 1),
    )
    // Shown whole where it is (a PLY, which is not rewritten), nothing is written: no space asked
    val whole = ply(47_819)
    assertEquals(SplatVerdict.Open(47_819, keep = null, large = false), check(probe = whole, freeSpace = 0))
    // Copied whole under the name of its format: the file itself
    assertEquals(686_150L, SplatGate.cacheBytesWritten(686_150, 47_819, null, copiesWhole = true))
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_SPACE),
      check(probe = whole, freeSpace = 686_150 + reserve - 1, copiesWhole = true),
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
    assertTrue(SplatGate.registers(engine = true, device = "eureka", wanted = true, inThisBuild = true))
    assertTrue(SplatGate.registers(engine = true, device = null, wanted = true, inThisBuild = true))
    // The setting off: no feature, whatever the headset
    assertFalse(SplatGate.registers(engine = true, device = "eureka", wanted = false, inThisBuild = true))
    assertFalse(SplatGate.registers(engine = true, device = "panther", wanted = false, inThisBuild = true))
    // Nor in the phone flavour, nor on a Quest 2 or Pro
    assertFalse(SplatGate.registers(engine = false, device = "eureka", wanted = true, inThisBuild = true))
    assertFalse(SplatGate.registers(engine = true, device = "hollywood", wanted = true, inThisBuild = true))
    assertFalse(SplatGate.registers(engine = true, device = "seacliff", wanted = true, inThisBuild = true))
  }

  @Test
  fun `the store build registers no splat module, whatever the setting says`() {
    fun offers(digest: String) =
      SplatBuild.offersSplats(SplatBuild.kindOf(listOf(SplatBuild.Signer(digest))), inStoreBuild = false)
    val store = offers(SplatBuild.STORE_CERTIFICATE_SHA256)
    val github = offers(SplatBuild.GITHUB_CERTIFICATE_SHA256)
    assertFalse(SplatGate.registers(engine = true, device = "eureka", wanted = true, inThisBuild = store))
    assertFalse(SplatGate.registers(engine = true, device = "panther", wanted = true, inThisBuild = store))
    assertTrue(SplatGate.registers(engine = true, device = "eureka", wanted = true, inThisBuild = github))
  }

  @Test
  fun `a viewer the module did not start with refuses a splat at once, after the flavour and the headset`() {
    assertNull(SplatGate.viewerRefusal(engine = true, device = "eureka", running = true, inThisBuild = true))
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.MODULE_NOT_RUNNING),
      SplatGate.viewerRefusal(engine = true, device = "eureka", running = false, inThisBuild = true),
    )
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.OLDER_HEADSET),
      SplatGate.viewerRefusal(engine = true, device = "hollywood", running = false, inThisBuild = true),
    )
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.NOT_IN_THIS_VERSION),
      SplatGate.viewerRefusal(engine = false, device = "eureka", running = false, inThisBuild = true),
    )
  }

  @Test
  fun `a splat that reaches the viewer of the store build is not in this version of the app`() {
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.NOT_IN_THIS_VERSION),
      SplatGate.viewerRefusal(engine = true, device = "eureka", running = false, inThisBuild = false),
    )
    // Even with a module running, which the store build never registers
    assertEquals(
      SplatVerdict.Refused(SplatRefusal.NOT_IN_THIS_VERSION),
      SplatGate.viewerRefusal(engine = true, device = "eureka", running = true, inThisBuild = false),
    )
  }

  @Test
  fun `a PLY is reduced as an SPZ of version 3`() {
    val ply = SplatProbe.Ply(400_000, 0, null, 400, 56, emptyList())
    assertEquals(SplatVerdict.Open(400_000, keep = 300_000, large = false), check(probe = ply, fileBytes = 22_400_400))
  }
}
