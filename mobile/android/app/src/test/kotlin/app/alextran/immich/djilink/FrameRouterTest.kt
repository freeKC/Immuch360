package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Where a frame goes, what is counted, and when the aircraft is considered linked or lost */
class FrameRouterTest {
  private val router = FrameRouter()

  private fun control(
    senderType: Int,
    commandSet: Int,
    commandId: Int,
    body: ByteArray = ByteArray(2),
    sequence: Int = 1,
    ackPolicy: Int = 0,
    senderIndex: Int = 0,
  ) =
    EnvelopeFrame(
      Channels.CONTROL_PRIMARY,
      P3Decoder.build(
        senderType = senderType,
        senderIndex = senderIndex,
        receiverType = DeviceTypes.APPLICATION,
        sequence = sequence,
        ackPolicy = ackPolicy,
        commandSet = commandSet,
        commandId = commandId,
        body = body,
      ),
    )

  @Test
  fun aControlFrameIsCountedByItsSetAndId() {
    router.route(control(DeviceTypes.FLIGHT_CONTROLLER, CommandSets.FLIGHT_CONTROLLER, 68), 1000)
    router.route(control(DeviceTypes.FLIGHT_CONTROLLER, CommandSets.FLIGHT_CONTROLLER, 68), 1100)
    router.route(control(DeviceTypes.FLIGHT_CONTROLLER, CommandSets.FLIGHT_CONTROLLER, 254), 1200)
    val pairs = router.pairCounters()
    assertEquals(2, pairs.size)
    assertEquals(2L, pairs.first { it.commandId == 68 }.count)
    // A pair no capture of owned hardware has explained stays a pair of numbers
    assertTrue(pairs.all { it.messageName == null })
    assertEquals(3L, router.counters.unknownPairs)
    assertEquals(0L, router.counters.knownPairs)
    assertTrue(router.telemetry.messages().all { it.name == null })
  }

  @Test
  fun aPairTheCaptureExplainedIsNamedByItsCode() {
    router.route(control(14, CommandSets.FLIGHT_CONTROLLER, 67, ByteArray(85)), 1000)
    assertEquals(TelemetryCodes.FLIGHT_DATA, router.pairCounters().single().messageName)
    assertEquals(1L, router.counters.knownPairs)
    assertEquals(TelemetryCodes.FLIGHT_DATA, router.telemetry.messages().single().name)
    assertEquals(1L, router.telemetryDecoder.values(1000).decoded[TelemetryCodes.FLIGHT_DATA])
  }

  @Test
  fun theAircraftSideIsTheOneOfTheCapture() {
    // The 50 Hz sender of the capture, type 18, keeps the aircraft present on its own
    router.route(control(18, 35, 178, ByteArray(43), senderIndex = 4), 1000)
    assertTrue(router.aircraftLinked(1000))
    assertEquals(1L, router.counters.aircraftSideFrames)
    // The ground side radio relays the flight data: remote side, and it proves no aircraft
    val ground = FrameRouter()
    ground.route(control(14, CommandSets.FLIGHT_CONTROLLER, 67, ByteArray(85)), 1000)
    assertFalse(ground.aircraftLinked(1000))
    assertEquals(1L, ground.counters.controllerSideFrames)
    for (type in listOf(1, 3, 4, 8, 9, 11, 18, 29)) {
      assertTrue("$type", type in FrameRouter.AIRCRAFT_SIDE)
    }
    assertEquals(setOf(6, 13, 14), FrameRouter.REMOTE_SIDE)
  }

  @Test
  fun theRemoteIsPresentByItsOwnFramesOnly() {
    router.route(control(14, 9, 8, byteArrayOf(0x5A)), 1000)
    assertFalse(router.remotePresent(1000))
    router.route(control(DeviceTypes.REMOTE_CONTROLLER, 0, 119, ByteArray(9)), 1100)
    assertTrue(router.remotePresent(1100))
    assertTrue(router.remotePresent(1100 + FrameRouter.AIRCRAFT_SILENCE_MS - 1))
    assertFalse(router.remotePresent(1100 + FrameRouter.AIRCRAFT_SILENCE_MS))
  }

  @Test
  fun requestsLeftUnansweredAreCountedPerPolicyWithTheirRepeats() {
    // The flight controller resends the same request while nobody answers it
    repeat(3) { router.route(control(3, 3, 143, ByteArray(269), sequence = 32744, ackPolicy = 2), 1000L + it) }
    router.route(control(3, 3, 143, ByteArray(269), sequence = 32745, ackPolicy = 2), 1100)
    // The remote asks with policy 1, a new sequence number each time
    repeat(2) { router.route(control(6, 6, 30, ByteArray(6), sequence = 10 + it, ackPolicy = 1), 1200L + it) }
    // A push asks for nothing
    router.route(control(18, 35, 178, ByteArray(43)), 1300)
    val rows = router.requestRows()
    assertEquals(2, rows.size)
    val remote = rows.first { it.ackPolicy == 1 }
    assertEquals(2L, remote.count)
    assertEquals(0L, remote.repeats)
    assertEquals(6, remote.senderType)
    val log = rows.first { it.ackPolicy == 2 }
    assertEquals(4L, log.count)
    assertEquals(2L, log.repeats)
    assertEquals(143, log.commandId)
  }

  @Test
  fun sequenceValuesOf85AndAbove32767AreNormal() {
    router.route(control(3, 3, 9, ByteArray(9), sequence = 85), 1000)
    router.route(control(3, 3, 9, ByteArray(9), sequence = 40_000), 1001)
    router.route(control(3, 3, 9, ByteArray(9), sequence = 65_535), 1002)
    assertEquals(3L, router.counters.controlFrames)
    assertEquals(listOf(65_535, 40_000, 85), router.frames().map { it.sequence })
  }

  @Test
  fun videoUnitsGoToTheirSinkWithTheDetectorOfTheStream() {
    val units = mutableListOf<AccessUnit>()
    var description: StreamDescription? = null
    router.onVideoUnit = { unit, detector, fresh, _ ->
      units.add(unit)
      if (fresh != null) {
        description = fresh
      }
      assertTrue(detector === router.probe.detector)
    }
    val stream = HevcSamples.picture(1) +
      HevcSamples.annexB(HevcSamples.DELIMITER, HevcSamples.VPS, HevcSamples.SPS, HevcSamples.PPS) +
      HevcSamples.annexB(HevcSamples.slice(type = 20), HevcSamples.suffixSei(1), HevcSamples.DELIMITER)
    router.route(EnvelopeFrame(22346, stream), 1000)
    assertEquals(2, units.size)
    assertTrue(units[1].isKey)
    assertNotNull(description)
    assertEquals(ProbeVerdict.H265, router.probe.report().verdict)
    assertEquals(2L, router.assemblerCounters().units)
  }

  @Test
  fun aNewStreamKeepsTheCountersAndForgetsTheAircraft() {
    router.route(control(DeviceTypes.FLIGHT_CONTROLLER, CommandSets.FLIGHT_CONTROLLER, 67), 1000)
    // Half a frame of the old descriptor is left in the decoder of the control channel
    val half = P3Decoder.build(
      senderType = DeviceTypes.FLIGHT_CONTROLLER,
      receiverType = DeviceTypes.APPLICATION,
      sequence = 2,
      commandSet = CommandSets.FLIGHT_CONTROLLER,
      commandId = 68,
      body = ByteArray(10),
    ).copyOf(9)
    router.route(EnvelopeFrame(Channels.CONTROL_PRIMARY, half), 1001)
    router.restartStreams()
    assertFalse(router.aircraftLinked(1002))
    router.route(control(DeviceTypes.FLIGHT_CONTROLLER, CommandSets.FLIGHT_CONTROLLER, 69), 1100)
    assertEquals(2L, router.counters.controlFrames)
    assertEquals(0L, router.controlCounters().headerCrcFailures + router.controlCounters().frameCrcFailures)
    assertTrue(router.aircraftLinked(1100))
  }

  @Test
  fun theChecksumReportNamesTheSeedRealFramesVoteFor() {
    repeat(5) { index ->
      val built = P3Decoder.build(
        senderType = DeviceTypes.REMOTE_CONTROLLER,
        receiverType = DeviceTypes.APPLICATION,
        sequence = index + 1,
        commandSet = CommandSets.REMOTE_CONTROLLER,
        commandId = 1,
        body = ByteArray(4),
        headerParams = CrcSets.header(0x21),
      )
      router.route(EnvelopeFrame(Channels.CONTROL_PRIMARY, built), index.toLong())
    }
    val report = router.crcReport()
    assertEquals(CrcSets.HEADER_CRC8.label, report.headerParameters)
    assertEquals(0x21, report.headerSeedCandidate)
    assertTrue(report.headerSeedVotes >= 5)
    assertEquals(0L, router.counters.controlFrames)

    val replayed = FrameRouter(headerCrc = CrcSets.header(0x21))
    repeat(5) { index ->
      replayed.route(
        EnvelopeFrame(
          Channels.CONTROL_PRIMARY,
          P3Decoder.build(
            senderType = DeviceTypes.REMOTE_CONTROLLER,
            receiverType = DeviceTypes.APPLICATION,
            sequence = index + 1,
            commandSet = CommandSets.REMOTE_CONTROLLER,
            commandId = 1,
            body = ByteArray(4),
            headerParams = CrcSets.header(0x21),
          ),
        ),
        index.toLong(),
      )
    }
    assertEquals(5L, replayed.counters.controlFrames)
  }

  @Test
  fun aVideoChannelGoesToTheFragmentsAndTheProbe() {
    val payload = byteArrayOf(0, 0, 0, 1, 0x67, 1, 2, 3)
    router.route(EnvelopeFrame(22346, payload), 500)
    assertEquals(1L, router.counters.videoEnvelopes)
    assertEquals(1L, router.video.channels().first().fragments)
    assertEquals(ProbeVerdict.START_CODES_SEEN, router.probe.report().verdict)
    assertEquals(0L, router.counters.controlFrames)
  }

  @Test
  fun anUnknownChannelIsCountedAndNothingIsParsedFromIt() {
    router.route(EnvelopeFrame(40001, byteArrayOf(1, 2, 3)), 10)
    assertEquals(1L, router.counters.unknownChannelEnvelopes)
    assertEquals(ChannelRole.UNKNOWN, router.channelCounters().first().role)
  }

  @Test
  fun theAircraftIsLinkedByAFrameFromItsSideAndLostAfterTheSilence() {
    assertFalse(router.aircraftLinked(0))
    router.route(control(DeviceTypes.FLIGHT_CONTROLLER, CommandSets.FLIGHT_CONTROLLER, 67), 1000)
    assertTrue(router.aircraftLinked(1000))
    assertTrue(router.aircraftLinked(1000 + FrameRouter.AIRCRAFT_SILENCE_MS - 1))
    assertFalse(router.aircraftLinked(1000 + FrameRouter.AIRCRAFT_SILENCE_MS))
  }

  @Test
  fun aFrameFromTheControllerSideNeverMarksAnAircraft() {
    router.route(control(DeviceTypes.REMOTE_CONTROLLER, CommandSets.REMOTE_CONTROLLER, 1), 2000)
    assertFalse(router.aircraftLinked(2000))
    assertEquals(1L, router.counters.controllerSideFrames)
    assertEquals(2000L, router.controllerSeenMs)
  }

  @Test
  fun theKeepAliveExceptionIsOnlyAppliedWhenItsIdIsKnown() {
    // The command id of the common set keep alive message is not established: with no id, no frame is excepted
    val withoutId = FrameRouter()
    withoutId.route(control(DeviceTypes.FLIGHT_CONTROLLER, CommandSets.COMMON, 15), 100)
    assertTrue(withoutId.aircraftLinked(100))
    assertEquals(0L, withoutId.counters.keepAliveExceptions)

    val withId = FrameRouter(keepAliveCommandId = 15)
    withId.route(control(DeviceTypes.FLIGHT_CONTROLLER, CommandSets.COMMON, 15), 100)
    assertFalse(withId.aircraftLinked(100))
    assertEquals(1L, withId.counters.keepAliveExceptions)
  }

  @Test
  fun theFrameListIsNewestFirstAndBounded() {
    val small = FrameRouter(frameLines = 3)
    for (id in 1..5) {
      small.route(control(DeviceTypes.FLIGHT_CONTROLLER, CommandSets.FLIGHT_CONTROLLER, id), id.toLong())
    }
    val lines = small.frames()
    assertEquals(3, lines.size)
    assertEquals(5, lines[0].commandId)
    assertEquals(3, lines[2].commandId)
  }

  @Test
  fun aResetLeavesNothingBehind() {
    router.route(control(DeviceTypes.FLIGHT_CONTROLLER, CommandSets.FLIGHT_CONTROLLER, 67), 1000)
    router.reset()
    assertEquals(0L, router.counters.controlFrames)
    assertTrue(router.pairCounters().isEmpty())
    assertNull(router.aircraftSeenMs)
  }
}
