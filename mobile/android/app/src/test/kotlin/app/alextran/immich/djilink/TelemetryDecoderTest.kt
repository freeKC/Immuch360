package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The fields of the catalogued pairs, read only from bodies of the observed length */
class TelemetryDecoderTest {
  private val decoder = TelemetryDecoder()

  private fun frame(set: Int, id: Int, body: ByteArray, senderType: Int = 14) = P3Frame(
    version = 1,
    senderType = senderType,
    senderIndex = 0,
    receiverType = DeviceTypes.APPLICATION,
    receiverIndex = 0,
    sequence = 1,
    isAcknowledgement = false,
    ackPolicy = 0,
    encryption = 0,
    commandSet = set,
    commandId = id,
    body = body,
  )

  private fun ByteArray.i16(at: Int, value: Int) = apply {
    this[at] = (value and 0xFF).toByte()
    this[at + 1] = ((value shr 8) and 0xFF).toByte()
  }

  private fun ByteArray.u32(at: Int, value: Long) = apply {
    i16(at, (value and 0xFFFF).toInt())
    i16(at + 2, ((value shr 16) and 0xFFFF).toInt())
  }

  private fun ByteArray.f32(at: Int, value: Float) = u32(at, java.lang.Float.floatToIntBits(value).toLong() and 0xFFFFFFFFL)

  private fun flightBody(): ByteArray = ByteArray(85)
    .i16(16, -5)
    .i16(18, 4)
    .i16(20, -4)
    .i16(22, 0)
    .i16(24, -110)
    .i16(26, 269)
    .i16(28, 1268)
    .apply { this[30] = 12 }
    .u32(32, 0x0080511CL)
    .apply {
      this[36] = 0
      this[40] = 38
      this[41] = 9
    }
    .i16(42, 387)

  @Test
  fun theFlightDataGivesItsFieldsAndUnits() {
    decoder.offer(frame(3, 67, flightBody()), 1000)
    val flight = decoder.values(1000).flight!!.value
    assertEquals(-0.5, flight.heightM, 1e-9)
    assertEquals(listOf(0.4, -0.4, 0.0), flight.speedsMps)
    assertEquals(-11.0, flight.pitchDeg, 1e-9)
    assertEquals(26.9, flight.rollDeg, 1e-9)
    assertEquals(126.8, flight.headingDeg, 1e-9)
    assertEquals(TelemetryFields.MODE_AUTOMATIC_LANDING, flight.mode)
    assertTrue(flight.inAir)
    assertTrue(flight.motorsOn)
    assertEquals(0, flight.satellites)
    // Tenths of a metre (p2/telemetry-proof-2026-10-25.md, 4.4): 9 is 0.9 m; the centimetres of the deep dive were a
    // hand landing, where offset 41 still showed the floor
    assertEquals(0.9, flight.groundHeightM, 1e-9)
    assertEquals(38.7, flight.motorTimeS, 1e-9)
    // Offset 22 is positive down on the wire: 0 here, and the two horizontal components give the speed over ground
    assertEquals(0.0, flight.verticalSpeedMps, 1e-9)
    assertEquals(kotlin.math.hypot(0.4, 0.4), flight.horizontalSpeedMps, 1e-9)
  }

  @Test
  fun theVerticalSpeedReadsPositiveWhileClimbing() {
    assertEquals(-0.2, TelemetryFields.flight(flightBody().i16(22, 2))!!.verticalSpeedMps, 1e-9)
    assertEquals(1.5, TelemetryFields.flight(flightBody().i16(22, -15))!!.verticalSpeedMps, 1e-9)
  }

  @Test
  fun theFlagsClearAtTheLanding() {
    decoder.offer(frame(3, 67, flightBody().u32(32, 0x00805110L)), 1000)
    val flight = decoder.values(1000).flight!!.value
    assertFalse(flight.inAir)
    assertFalse(flight.motorsOn)
  }

  @Test
  fun theMotorsRunWithBitEightAloneAndTheAirIsBitFour() {
    // The spin up before lift off (p2/telemetry-proof-2026-10-25.md, 4.9): 0x08 without 0x04, the motors run on the
    // ground, so the height and the speeds a pilot reads are not given
    val spinning = TelemetryFields.flight(flightBody().u32(32, 0x0080501AL))!!
    assertTrue(spinning.motorsOn)
    assertFalse(spinning.inAir)
    assertNull(spinning.airborne)
    // Lift off: both bits
    val flying = TelemetryFields.flight(flightBody().u32(32, 0x0080501CL))!!
    assertTrue(flying.motorsOn)
    assertTrue(flying.inAir)
    assertEquals(-0.5, flying.airborne!!.heightM, 1e-9)
    // 0x04 without 0x08 never came in our captures: no motors without bit 0x08
    assertFalse(TelemetryFields.flight(flightBody().u32(32, 0x00805014L))!!.motorsOn)
    // The frame of the 23 October morning landing where 0x10 was clear: both bits set, the motors run
    assertTrue(TelemetryFields.flight(flightBody().u32(32, 0x0080510CL))!!.motorsOn)
  }

  /** A flight frame at [atMs] with the height in tenths of a metre and the flags of offset 32 */
  private fun TelemetryDecoder.flightAt(atMs: Long, decimetres: Int, flags: Long = 0x0080501CL) =
    offer(frame(3, 67, flightBody().i16(16, decimetres).u32(32, flags)), atMs)

  /** A range below reading at [atMs], in millimetres, with its reading flag */
  private fun TelemetryDecoder.rangeAt(atMs: Long, millimetres: Int) =
    offer(frame(10, 3, ByteArray(4).i16(0, millimetres).apply { this[2] = 1 }), atMs)

  private fun TelemetryDecoder.pilotHeight(atMs: Long): Double? = values(atMs).flight!!.value.pilotHeightM

  @Test
  fun aJumpNoAircraftMakesHoldsTheHeightBackUntilTheMotorsStop() {
    // A climb at 3 m/s seen at 10 Hz, already in the air when the decoder starts: nothing held
    var atMs = 0L
    for (decimetres in listOf(318, 321, 324, 327)) {
      decoder.flightAt(atMs, decimetres)
      assertEquals(decimetres / 10.0, decoder.pilotHeight(atMs)!!, 1e-9)
      atMs += 100
    }
    // A 16 bit wrap of the 50 Hz values near 32.7 m would turn 32.7 m into -32.8 m (proof 4.1, item 5): held back
    // from that frame on, and the next ones read like a descent from there, held too
    for (decimetres in listOf(-328, -325, -322, -319)) {
      decoder.flightAt(atMs, decimetres)
      val flight = decoder.values(atMs).flight!!.value
      assertTrue(flight.heightHeld)
      assertNull(flight.pilotHeightM)
      // The speeds still come
      assertNotNull(flight.airborne)
      atMs += 100
    }
    // Landed: the motors stop, the hold ends with them
    decoder.flightAt(atMs, 0, flags = 0x00805110L)
    assertFalse(decoder.values(atMs).flight!!.value.heightHeld)
    atMs += 100
    // The next flight: the spin up, the lift off, the range below at 0.4 m, 1.5 s later the height comes again
    decoder.flightAt(atMs, 0, flags = 0x0080501AL)
    atMs += 100
    val liftOff = atMs
    while (atMs <= liftOff + 1_600) {
      decoder.rangeAt(atMs, 400)
      decoder.flightAt(atMs, 3)
      if (atMs - liftOff < HeightHold.LAUNCH_MS) {
        assertNull("$atMs", decoder.pilotHeight(atMs))
      } else {
        assertEquals(0.3, decoder.pilotHeight(atMs)!!, 1e-9)
      }
      atMs += 100
    }
  }

  @Test
  fun aLongGapAllowsTheDistanceFlownMeanwhileButNotAWrap() {
    decoder.flightAt(0, 50)
    // 15 m in 5 s without a frame between: 3 m/s, an aircraft can, the height stays
    decoder.flightAt(5_000, 200)
    assertEquals(20.0, decoder.pilotHeight(5_000)!!, 1e-9)
    decoder.flightAt(9_000, 320)
    assertEquals(32.0, decoder.pilotHeight(9_000)!!, 1e-9)
    // A wrap across 2 s without a frame: 65 m, more than 10 m plus 10 m per second, held
    decoder.flightAt(11_000, -330)
    assertNull(decoder.pilotHeight(11_000))
  }

  @Test
  fun aHandLaunchShowsNoHeightUntilTheDroneHasLeftTheHand() {
    // The 09:42 launch: bit 0x04 while the drone is still on the hand, the range below at 3 cm, the height 0.3 m
    decoder.flightAt(0, 4, flags = 0x0080501AL)
    var atMs = 100L
    while (atMs <= 2_000) {
      decoder.rangeAt(atMs, 30)
      decoder.flightAt(atMs, 3)
      assertNull("$atMs", decoder.pilotHeight(atMs))
      atMs += 100
    }
    // It leaves the hand: the range below reads more than 0.15 m, the height comes at the next frame
    decoder.rangeAt(atMs, 180)
    decoder.flightAt(atMs, 3)
    assertEquals(0.3, decoder.pilotHeight(atMs)!!, 1e-9)
    // Without any reading of the range below, the height comes 5 s after the lift off
    val other = TelemetryDecoder()
    other.flightAt(0, 0, flags = 0x0080501AL)
    other.flightAt(100, 5)
    other.flightAt(5_000, 20)
    assertNull(other.pilotHeight(5_000))
    other.flightAt(5_100, 21)
    assertEquals(2.1, other.pilotHeight(5_100)!!, 1e-9)
  }

  @Test
  fun offsetFortyIsNeverReadAsABattery() {
    decoder.offer(frame(3, 67, flightBody()), 1000)
    val values = decoder.values(1000)
    // Byte 40 of the flight data is a counter on this aircraft: no battery value comes from that pair
    assertNull(values.battery)
    assertNull(values.remoteBatteryPercent)
  }

  @Test
  fun aWrongLengthDecodesNothingAndCountsAMismatch() {
    decoder.offer(frame(3, 67, ByteArray(55)), 1000)
    decoder.offer(frame(13, 2, ByteArray(40)), 1000)
    val values = decoder.values(1000)
    assertNull(values.flight)
    assertNull(values.battery)
    assertEquals(2L, values.layoutMismatches)
  }

  @Test
  fun theGimbalGivesTheClockTheHeadingsAndAUnitQuaternion() {
    // A rotation of 64.69 degrees about the vertical axis
    val yaw = Math.toRadians(64.69)
    val body = ByteArray(50)
      .i16(4, 647)
      .u32(12, 92_737)
      .u32(16, 6469)
      .i16(20, -187)
      .i16(22, 124)
      .f32(24, kotlin.math.cos(yaw / 2).toFloat())
      .f32(28, 0f)
      .f32(32, 0f)
      .f32(36, kotlin.math.sin(yaw / 2).toFloat())
    decoder.offer(frame(4, 5, body, senderType = 4), 1000)
    val gimbal = decoder.values(1000).gimbal!!.value
    assertEquals(64.7, gimbal.headingDeg, 1e-9)
    assertEquals(92_737L, gimbal.clockMs)
    assertEquals(64.69, gimbal.headingFineDeg, 1e-9)
    assertEquals(-1.87, gimbal.angle1Deg, 1e-9)
    assertEquals(1.24, gimbal.angle2Deg, 1e-9)
    assertEquals(64.69, TelemetryFields.yawOf(gimbal.quaternion), 1e-3)
  }

  @Test
  fun aNegativeFineHeadingIsReadAsOneAndBytesEighteenAndNineteenAreNotPartOfIt() {
    // The 24 October 2026 flight capture: -175.59 degrees, bytes 18 and 19 zero, read 479.77 by a 32 bit read
    val body = ByteArray(50).i16(4, -1756).i16(16, -17559).i16(18, 0)
    decoder.offer(frame(4, 5, body, senderType = 4), 1000)
    val gimbal = decoder.values(1000).gimbal!!.value
    assertEquals(-175.6, gimbal.headingDeg, 1e-9)
    assertEquals(-175.59, gimbal.headingFineDeg, 1e-9)
  }

  @Test
  fun theBatteryGivesVoltsAmpsCapacityAndCharge() {
    val body = ByteArray(44)
      .u32(1, 6180)
      .u32(5, -7256L and 0xFFFFFFFFL)
      .u32(9, 1525)
      .u32(13, 582)
      .i16(17, 269)
      .apply {
        this[19] = 2
        this[20] = 38
      }
    decoder.offer(frame(13, 2, body, senderType = 11), 1000)
    val battery = decoder.values(1000).battery!!.value
    assertEquals(6.18, battery.voltageV, 1e-9)
    assertEquals(-7.256, battery.currentA, 1e-9)
    assertEquals(1525L, battery.fullMah)
    assertEquals(582L, battery.remainingMah)
    assertEquals(26.9, battery.temperatureC, 1e-9)
    assertEquals(2, battery.cells)
    assertEquals(38, battery.percent)
  }

  @Test
  fun theLinkPushesAndTheRemoteBattery() {
    decoder.offer(frame(9, 8, byteArrayOf(0xDA.toByte()), senderType = 9), 1000)
    decoder.offer(frame(9, 8, byteArrayOf(0x5A), senderType = 14), 1000)
    decoder.offer(frame(9, 54, ByteArray(4).f32(0, 5.87f)), 1000)
    decoder.offer(frame(6, 30, byteArrayOf(0x14, 0x05, 0, 0, 50, 0), senderType = 6), 1000)
    decoder.offer(frame(35, 178, ByteArray(43).u32(0, 81_528)), 1000)
    val values = decoder.values(1000)
    assertEquals(90, values.link.signalAircraftSide!!.value)
    assertEquals(90, values.link.signalRemoteSide!!.value)
    assertEquals(5.87, values.link.liveRateMbps!!.value, 1e-5)
    assertEquals(50, values.remoteBatteryPercent!!.value)
    assertEquals(81_528L, values.link.aircraftClockMs!!.value)
    assertEquals(0L, values.layoutMismatches)
  }

  @Test
  fun aGroupIsStaleAfterThreeOfItsIntervalsAndNeverBefore1500Ms() {
    for (at in 0L..900L step 100L) {
      decoder.offer(frame(3, 67, flightBody()), at)
    }
    assertFalse(decoder.values(900 + 1_500).flight!!.stale)
    assertTrue(decoder.values(900 + 1_501).flight!!.stale)
    val slow = TelemetryDecoder()
    for (at in 0L..4_000L step 1_000L) {
      slow.offer(frame(13, 2, ByteArray(44)), at)
    }
    assertFalse(slow.values(4_000 + 3_000).battery!!.stale)
    assertTrue(slow.values(4_000 + 3_001).battery!!.stale)
    assertEquals(3_001L, slow.values(4_000 + 3_001).battery!!.ageMs)
  }

  @Test
  fun theClockJitterIsArrivalMinusClockAboveItsMinimum() {
    // A 50 Hz clock that arrives with 0 to 40 ms of delay
    val delays = listOf(0L, 10L, 40L, 5L, 0L, 20L, 0L, 15L, 0L, 30L)
    for ((index, delay) in delays.withIndex()) {
      val clock = 81_528L + index * 20L
      decoder.offer(frame(35, 178, ByteArray(43).u32(0, clock), senderType = 18), 10_000 + index * 20L + delay)
    }
    val link = decoder.values(10_300).link
    assertEquals(30.0, link.clockJitterP95Ms!!, 1e-9)
    assertEquals(0.0, link.clockDriftMs!!, 1e-9)
  }

  @Test
  fun theModuleStatusCountsAsLivenessOnly() {
    decoder.offer(frame(33, 6, byteArrayOf(0, 0x52, 0x80.toByte()), senderType = 8), 1000)
    decoder.offer(frame(33, 8, ByteArray(92), senderType = 18), 1000)
    assertEquals(2L, decoder.values(1000).decoded[TelemetryCodes.MODULE_STATUS])
    assertEquals(2, decoder.moduleSenders())
  }

  @Test
  fun everyCataloguedPairIsNamedWithTheCaptureThatNamedIt() {
    for (
      pair in listOf(
        3 to 67, 4 to 5, 13 to 2, 6 to 30, 9 to 8, 9 to 54, 35 to 178, 33 to 6, 33 to 8, 9 to 117, 10 to 3, 36 to 8,
      )
    ) {
      val entry = MessageCatalogue.named(pair.first, pair.second)
      assertNotNull("$pair", entry)
      assertTrue(entry!!.observation.contains("dji-link-20261023-102731"))
    }
    assertNull(MessageCatalogue.named(3, 143))
  }
}
