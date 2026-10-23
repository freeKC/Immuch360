package app.alextran.immich.djilink

import java.io.File
import java.security.MessageDigest
import kotlin.math.abs
import kotlin.math.sqrt
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The capture of 23 October 2026 (FreeKC's RC-N3 and Neo 2 on a Galaxy S24+) through the whole receive chain, up to the
 * decoder input. The capture is not in the repository: it holds the video of a home and the serial numbers of the
 * hardware. It is read from the folder in DJI_CAPTURE_DIR, else ~/dji-capture/2026-10-23/ (the build host), and the
 * tests are skipped when it is absent (the CI).
 *
 * The expected numbers come from p2/capture-2026-10-23.md and the oracle assembler_expect.py of the stage 2 design,
 * computed with Python decoders that are not this code. A difference is investigated and explained, never adjusted
 * away.
 */
class CaptureVideoReplayTest {
  companion object {
    const val NAME = "dji-link-20261023-102731"
    const val SHA256 = "8541e5d3395f12ac16e42d5fb86465f57ce7efb37ee8166a00c2260a742141bc"

    fun folder(): File = File(
      System.getenv("DJI_CAPTURE_DIR") ?: (System.getProperty("user.home") + "/dji-capture/2026-10-23")
    )

    /** The bytes and the index of the capture, or the test is skipped */
    fun load(): Pair<ByteArray, List<CaptureEntry>> {
      val bin = File(folder(), "$NAME.bin")
      val index = File(folder(), "$NAME.idx.csv")
      assumeTrue("the capture of 23 October 2026 is not on this machine", bin.isFile && index.isFile)
      val bytes = bin.readBytes()
      val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
      assertEquals("the capture is the one of 23 October 2026", SHA256, digest)
      return bytes to CaptureReplay.parseIndex(index.readText())
    }
  }

  private class Seen(val atMs: Long, val frame: P3Frame)

  @Test
  fun theWholeReceiveChainGivesTheNumbersOfTheCapture() {
    val (bytes, index) = load()
    val units = mutableListOf<AccessUnit>()
    var description: StreamDescription? = null
    val frames = mutableListOf<Seen>()
    val result = CaptureReplay.replay(
      bytes = bytes,
      index = index,
      onVideoUnit = { unit, _, fresh, _ ->
        units.add(unit)
        if (fresh != null) {
          description = fresh
        }
      },
      onControlFrame = { frame, atMs -> frames.add(Seen(atMs, frame)) },
    )
    val firstMs = index.first { it.direction == CaptureDirection.IN }.monotonicNs / 1_000_000
    val closeMs = index.last().monotonicNs / 1_000_000

    // Envelope layer, with the padding rule
    assertEquals("resynchronisations", 1L, result.envelopes.resynchronisations)
    assertEquals("discarded bytes", 2889L, result.envelopes.discardedBytes)
    assertEquals("padding bytes", 1_213_508L, result.envelopes.paddingBytes)
    assertEquals(listOf(22345 to 2660L, 22346 to 1890L), result.channels.map { it.channel to it.envelopes })

    // Control frames
    assertEquals(2660L, result.control.frames)
    assertEquals(0L, result.control.headerCrcFailures)
    assertEquals(0L, result.control.frameCrcFailures)
    assertTrue(frames.all { it.frame.version == 1 && it.frame.encryption == 0 })
    val combinations = frames.map {
      val f = it.frame
      val kind = (if (f.isAcknowledgement) 0x80 else 0) or (f.ackPolicy shl 5) or f.encryption
      listOf(f.senderType, f.senderIndex, f.receiverType, f.receiverIndex, f.commandSet, f.commandId, kind)
    }.toSet()
    assertEquals("sender, receiver, set, id and kind combinations", 77, combinations.size)

    // Access units
    val assembler = result.assembler
    assertEquals(1890L, assembler.fragments)
    assertEquals(4080, assembler.largestFragment)
    assertEquals("bytes before the first unit", 21_644L, assembler.bytesBeforeFirstUnit)
    assertEquals(336, units.size)
    assertTrue(units.all { it.startsWithDelimiter })
    assertTrue(units.all { it.closedBy == AccessUnitClose.BOUNDARY })
    assertEquals(0L, assembler.closedByShortFragment)
    val keys = units.withIndex().filter { it.value.isKey }.map { it.index }
    assertEquals(listOf(29), keys)
    assertEquals(listOf(35, 32, 33, 34, 20, 40, 40, 40), units[29].nalTypes.toList())
    assertEquals(335, units.count { !it.isKey && it.hasSlice })
    val sizes = units.map { it.size }.sorted()
    assertEquals(713, sizes.first())
    assertEquals(38_012, sizes.last())
    assertEquals(19_997, sizes[sizes.size / 2])
    assertEquals("an unfinished picture when the cable was pulled", 8167, result.pendingVideoBytes)

    // The picture counter of SEI 240
    val counter = PictureCounterTracker()
    units.forEach { unit -> unit.pictureCounter?.let { counter.offer(it) } }
    assertEquals(336L, counter.counters)
    assertEquals(334L, counter.steps)
    assertEquals(1L, counter.restarts)
    assertEquals(0L, counter.lost)

    // The stream's own description is the profile seed
    val read = description!!
    val seed = ProfileRegistry.seed20261023!!
    assertArrayEquals(seed.vps, read.vps)
    assertArrayEquals(seed.sps, read.sps)
    assertArrayEquals(seed.pps, read.pps)
    assertEquals(1920, read.info.width)
    assertEquals(1080, read.info.height)
    assertEquals("Main", read.info.profileName)
    assertTrue(read.info.highTier)
    assertEquals(150, read.info.levelIdc)

    // Flight data
    val flight = frames.filter { it.frame.commandSet == 3 && it.frame.commandId == 67 }
    assertEquals(113, flight.size)
    assertTrue(flight.all { it.frame.body.size == 85 })
    val readings = flight.map { (it.atMs - firstMs) to TelemetryFields.flight(it.frame.body)!! }
    assertEquals(12, readings.first().second.mode)
    val normal = readings.first { it.second.mode == 6 }.first
    assertTrue("mode 6 at $normal ms", normal in 400L..800L)
    assertTrue(readings.takeWhile { it.first < normal }.all { it.second.mode == 12 })
    val landed = readings.first { !it.second.inAir }.first
    assertTrue("in the air cleared at $landed ms", landed in 300L..700L)
    assertTrue(readings.filter { it.first >= landed }.all { !it.second.inAir && !it.second.motorsOn })
    val motorTimes = readings.map { it.second.motorTimeS }
    assertEquals(38.3, motorTimes.first(), 0.05)
    assertEquals(38.7, motorTimes.max(), 0.05)
    val frozen = motorTimes.indexOfFirst { abs(it - motorTimes.max()) < 1e-9 }
    assertTrue(motorTimes.drop(frozen).all { abs(it - motorTimes.max()) < 1e-9 })
    // 126.8 degrees at most, 126.7 at the first frame, 63.5 at the last; the aircraft was turned down to 50.5 on the way
    // (read the same by the capture reader's own Python decoder)
    assertEquals(126.7, readings.first().second.headingDeg, 1e-9)
    assertEquals(126.8, readings.maxOf { it.second.headingDeg }, 1e-9)
    assertEquals(63.5, readings.last().second.headingDeg, 1e-9)
    assertEquals(50.5, readings.minOf { it.second.headingDeg }, 1e-9)
    val heights = readings.map { it.second.heightM }
    assertTrue(heights.all { it == -0.4 || it == -0.5 || it == 0.0 })
    assertEquals(0.0, heights.last(), 1e-9)

    // Gimbal
    val gimbal = frames.filter { it.frame.commandSet == 4 && it.frame.commandId == 5 }
    assertEquals(113, gimbal.size)
    assertTrue(gimbal.all { it.frame.body.size == 50 })
    val gimbals = gimbal.map { TelemetryFields.gimbal(it.frame.body)!! }
    for (reading in gimbals) {
      val norm = sqrt(reading.quaternion.sumOf { it * it })
      assertEquals(1.0, norm, 1e-6)
      val yaw = TelemetryFields.yawOf(reading.quaternion)
      val difference = ((yaw - reading.headingFineDeg) % 360 + 540) % 360 - 180
      assertTrue("yaw $yaw against ${reading.headingFineDeg}", abs(difference) <= 0.01)
    }
    assertEquals(81_537L, gimbals.minOf { it.clockMs })
    assertEquals(92_737L, gimbals.maxOf { it.clockMs })

    // Battery
    val battery = frames.filter { it.frame.commandSet == 13 && it.frame.commandId == 2 }
    assertEquals(11, battery.size)
    val batteries = battery.map { TelemetryFields.battery(it.frame.body)!! }
    assertTrue(batteries.all { it.percent == 38 && it.cells == 2 })
    assertEquals(6.180, batteries.minOf { it.voltageV }, 1e-9)
    assertEquals(6.756, batteries.maxOf { it.voltageV }, 1e-9)
    assertEquals(-7.256, batteries.minOf { it.currentA }, 1e-9)
    assertEquals(-0.706, batteries.maxOf { it.currentA }, 1e-9)
    // The remaining capacity is 38.1 to 38.2 % of the full one at every sample, so the charge byte is that ratio rounded
    // down (2 to 3 mAh above 38 % exactly, read the same by the capture reader's own Python decoder)
    assertTrue(batteries.all { it.remainingMah * 100 / it.fullMah == it.percent.toLong() })

    // Link and remote
    val remote = frames.filter { it.frame.commandSet == 6 && it.frame.commandId == 30 }
    assertEquals(11, remote.size)
    assertTrue(remote.all { TelemetryFields.remoteBattery(it.frame.body) == 50 })
    val signals = frames.filter { it.frame.commandSet == 9 && it.frame.commandId == 8 }
    assertTrue(signals.all { TelemetryFields.signal(it.frame.body) == 90 })
    assertEquals(setOf(9, 14), signals.map { it.frame.senderType }.toSet())
    val rates = frames.filter { it.frame.commandSet == 9 && it.frame.commandId == 54 }
      .map { TelemetryFields.liveRate(it.frame.body)!! }
    assertEquals(5, rates.size)
    assertEquals(5.1, rates.min(), 0.05)
    assertEquals(6.4, rates.max(), 0.05)
    val clocks = frames.filter { it.frame.commandSet == 35 && it.frame.commandId == 178 }
      .map { TelemetryFields.aircraftClock(it.frame.body)!! }
    assertEquals(562, clocks.size)
    assertEquals(81_528L, clocks.min())
    assertEquals(92_757L, clocks.max())

    // Liveness: aircraft and remote present from the first second to the close
    val aircraftTimes = frames.filter { it.frame.senderType in FrameRouter.AIRCRAFT_SIDE }.map { it.atMs }
    val remoteTimes = frames.filter { it.frame.senderType == DeviceTypes.REMOTE_CONTROLLER }.map { it.atMs }
    for (times in listOf(aircraftTimes, remoteTimes)) {
      assertTrue(times.first() - firstMs < 1_000)
      assertTrue(times.zipWithNext().all { (a, b) -> b - a < FrameRouter.AIRCRAFT_SILENCE_MS })
      assertTrue(closeMs - times.last() < FrameRouter.AIRCRAFT_SILENCE_MS)
    }

    // Requests left unanswered
    val byPolicy = result.requests.groupBy { it.ackPolicy }
    assertEquals(22L, byPolicy.getValue(1).sumOf { it.count })
    assertEquals(10L, byPolicy.getValue(1).sumOf { it.repeats })
    assertEquals(10L, byPolicy.getValue(1).single { it.senderType == 6 && it.commandSet == 6 && it.commandId == 30 }.repeats)
    assertEquals(119L, byPolicy.getValue(2).sumOf { it.count })
    assertEquals(49L, byPolicy.getValue(2).sumOf { it.repeats })
    assertEquals(49L, byPolicy.getValue(2).single { it.senderType == 3 && it.commandSet == 3 && it.commandId == 143 }.repeats)

    // No layout mismatch in the whole ring
    assertEquals(0L, result.telemetryValues!!.layoutMismatches)
  }
}
