package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Where a frame goes, what is counted, and when the aircraft is considered linked or lost */
class FrameRouterTest {
  private val router = FrameRouter()

  private fun control(senderType: Int, commandSet: Int, commandId: Int, body: ByteArray = ByteArray(2)) =
    EnvelopeFrame(
      Channels.CONTROL_PRIMARY,
      P3Decoder.build(
        senderType = senderType,
        receiverType = DeviceTypes.APPLICATION,
        sequence = 1,
        commandSet = commandSet,
        commandId = commandId,
        body = body,
      ),
    )

  @Test
  fun aControlFrameIsCountedByItsSetAndId() {
    router.route(control(DeviceTypes.FLIGHT_CONTROLLER, CommandSets.FLIGHT_CONTROLLER, 67), 1000)
    router.route(control(DeviceTypes.FLIGHT_CONTROLLER, CommandSets.FLIGHT_CONTROLLER, 67), 1100)
    router.route(control(DeviceTypes.FLIGHT_CONTROLLER, CommandSets.FLIGHT_CONTROLLER, 254), 1200)
    val pairs = router.pairCounters()
    assertEquals(2, pairs.size)
    assertEquals(2L, pairs.first { it.commandId == 67 }.count)
    assertEquals("common OSD push, the main flight state message", pairs.first { it.commandId == 67 }.messageName)
    assertNull(pairs.first { it.commandId == 254 }.messageName)
    assertEquals(1L, router.counters.unknownPairs)
    assertEquals(2L, router.counters.knownPairs)
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
