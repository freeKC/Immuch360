package app.alextran.immich.djilink

import com.meta.spatial.runtime.ButtonBits
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The controllers of the flight view change the view only (design 8.3) */
class FlightViewControlsTest {
  private val actions = FlightViewControls::actionsFor

  @Test
  fun eachButtonDoesOneThingToTheView() {
    assertEquals(listOf(FlightViewControls.Action.CLOSE), actions(ButtonBits.ButtonB, 0))
    assertEquals(listOf(FlightViewControls.Action.CLOSE), actions(ButtonBits.ButtonY or ButtonBits.ButtonA, 0))
    assertEquals(listOf(FlightViewControls.Action.TOGGLE_VALUES), actions(ButtonBits.ButtonA, 0))
    assertEquals(listOf(FlightViewControls.Action.TOGGLE_CURVE), actions(ButtonBits.ButtonX, 0))
    assertEquals(listOf(FlightViewControls.Action.RECENTER), actions(ButtonBits.ButtonThumbRL, 0))
    assertEquals(listOf(FlightViewControls.Action.RECENTER), actions(ButtonBits.ButtonThumbLR, 0))
    assertEquals(listOf(FlightViewControls.Action.WIDER), actions(ButtonBits.ButtonThumbRU, 0))
    assertEquals(listOf(FlightViewControls.Action.NARROWER), actions(ButtonBits.ButtonThumbLD, 0))
    assertEquals(listOf(FlightViewControls.Action.TOGGLE_VALUES), actions(0, ButtonBits.ButtonMenu))
  }

  @Test
  fun theTriggerAndTheGripsDoNothing() {
    val idle = ButtonBits.ButtonTriggerL or ButtonBits.ButtonTriggerR or ButtonBits.ButtonSqueezeL or
      ButtonBits.ButtonSqueezeR
    assertTrue(actions(idle, 0).isEmpty())
    // A pinch of a hand is not a button A
    assertTrue(actions(0, ButtonBits.ButtonA).isEmpty())
  }

  @Test
  fun theWidthsStayWithinTheirFourSteps() {
    var index = FlightViewControls.DEFAULT_WIDTH_INDEX
    assertEquals(2.4f, FlightViewControls.WIDTHS_M[index])
    repeat(5) { index = FlightViewControls.nextWidth(index, FlightViewControls.Action.WIDER) }
    assertEquals(4.0f, FlightViewControls.WIDTHS_M[index])
    repeat(5) { index = FlightViewControls.nextWidth(index, FlightViewControls.Action.NARROWER) }
    assertEquals(1.6f, FlightViewControls.WIDTHS_M[index])
  }

  private fun numbers(
    receiving: Boolean,
    state: RelayReceiveState,
    localReplay: Boolean = false,
    replay: Boolean = false,
    phoneHasSource: Boolean = true,
  ) = DjiFlightNumbers(
    receiving = receiving,
    localReplay = localReplay,
    state = state,
    replay = replay,
    phoneHasSource = phoneHasSource,
    replayName = null,
    lastPictureAgoMs = null,
    picturesPerSecond = 0.0,
    receiveToPictureMs = null,
    values = null,
  )

  @Test
  fun theStateLineSaysWhereThePictureComesFromAndWhyItEnded() {
    val labels = FlightViewControls::stateLabels
    assertEquals(listOf("live"), labels(numbers(true, RelayReceiveState.RECEIVING)))
    assertEquals(listOf("replay"), labels(numbers(true, RelayReceiveState.RECEIVING, replay = true)))
    assertEquals(listOf("noSource"), labels(numbers(true, RelayReceiveState.RECEIVING, phoneHasSource = false)))
    assertEquals(listOf("lost"), labels(numbers(true, RelayReceiveState.LOST)))
    assertEquals(listOf("local"), labels(numbers(false, RelayReceiveState.IDLE, localReplay = true)))
    // A reception that ended on its own is never called a capture played on this headset (stage2b-review.md, 1)
    assertEquals(listOf("wrongCode", "ended"), labels(numbers(false, RelayReceiveState.WRONG_CODE)))
    assertEquals(listOf("otherVersion", "ended"), labels(numbers(false, RelayReceiveState.OTHER_VERSION)))
    assertEquals(listOf("unproven", "ended"), labels(numbers(false, RelayReceiveState.PHONE_UNPROVEN)))
    assertEquals(listOf("ended"), labels(numbers(false, RelayReceiveState.IDLE)))
  }

  @Test
  fun aStoppedPictureIsNeverShownAsLive() {
    assertTrue(FlightViewControls.staleLine(null))
    assertFalse(FlightViewControls.staleLine(400))
    assertTrue(FlightViewControls.staleLine(501))
    assertFalse(FlightViewControls.hideVideo(1_999))
    assertTrue(FlightViewControls.hideVideo(2_001))
    assertTrue(FlightViewControls.hideVideo(null))
  }

  private fun flight(motorTimeS: Double = 41.6, motorsOn: Boolean = false) = FlightReading(
    heightM = 0.0,
    speedsMps = listOf(0.0, 0.0, 0.0),
    pitchDeg = 0.0,
    rollDeg = 0.0,
    headingDeg = -175.6,
    mode = 6,
    inAir = motorsOn,
    motorsOn = motorsOn,
    satellites = 0,
    groundHeightM = 0.0,
    motorTimeS = motorTimeS,
    flags = 0L,
  )

  private fun battery(percent: Int = 34) = BatteryReading(
    voltageV = 6.935,
    currentA = -0.7,
    fullMah = 1615,
    remainingMah = 557,
    temperatureC = 28.3,
    cells = 2,
    percent = percent,
    status = 0L,
  )

  private fun values(
    flightStale: Boolean? = false,
    batteryStale: Boolean? = false,
    remote: Int? = 48,
  ) = TelemetryValues(
    flight = flightStale?.let { Timed(flight(), 80, it) },
    gimbal = null,
    battery = batteryStale?.let { Timed(battery(), 300, it) },
    remoteBatteryPercent = remote?.let { Timed(it, 500, false) },
    link = LinkReadings(
      signalAircraftSide = Timed(90, 100, false),
      signalRemoteSide = Timed(90, 100, false),
      liveRateMbps = Timed(5.9, 900, false),
      aircraftClockMs = null,
      clockJitterP95Ms = null,
      clockDriftMs = null,
    ),
    layoutMismatches = 0,
    decoded = emptyMap(),
  )

  /** The templates Flutter passes for the fields its gate opens: the drone's battery and the motor time */
  private val gated = mapOf(
    "droneBattery" to "Drone {value} %",
    "motorTime" to "Motor time {value}",
    "noValues" to "No flight data has arrived.",
    "valuesStale" to "These values are no longer updated",
  )

  @Test
  fun theValuesLineShowsTheGatedFieldsOnlyOnOneLine() {
    assertEquals("Drone 34 %   Motor time 0:41", FlightViewControls.valuesLine(values(), gated))
    // The remote's battery, the signal and the rate arrive too, but have no template: never shown
    val line = FlightViewControls.valuesLine(values(), gated)
    assertFalse(line.contains("48"))
    assertFalse(line.contains("90"))
    assertFalse(line.contains("\n"))
  }

  @Test
  fun aStaleGroupIsLeftOutAndAllStaleSaysSo() {
    assertEquals("Motor time 0:41", FlightViewControls.valuesLine(values(batteryStale = true), gated))
    assertEquals("Drone 34 %", FlightViewControls.valuesLine(values(flightStale = true), gated))
    assertEquals(
      "These values are no longer updated",
      FlightViewControls.valuesLine(values(flightStale = true, batteryStale = true), gated),
    )
  }

  @Test
  fun nothingArrivedForTheGatedFieldsSaysSo() {
    assertEquals("No flight data has arrived.", FlightViewControls.valuesLine(null, gated))
    assertEquals(
      "No flight data has arrived.",
      FlightViewControls.valuesLine(values(flightStale = null, batteryStale = null), gated),
    )
    // Without any template, nothing is shown whatever arrives
    assertEquals("", FlightViewControls.valuesLine(values(), emptyMap()))
  }

  @Test
  fun aGateOpenedLaterNeedsOnlyItsTemplate() {
    val more = gated + mapOf(
      "remoteBattery" to "Remote {value} %?",
      "motors" to "Motors {value}",
      "heading" to "Heading {value}",
      "on" to "on",
      "off" to "off",
    )
    assertEquals(
      "Drone 34 %   Motor time 0:41   Motors off   Heading -175.6   Remote 48 %?",
      FlightViewControls.valuesLine(values(), more),
    )
  }

  @Test
  fun theMotorTimeIsMinutesAndSeconds() {
    assertEquals("0:00", FlightViewControls.minutesSeconds(0.0))
    assertEquals("0:41", FlightViewControls.minutesSeconds(41.6))
    assertEquals("1:05", FlightViewControls.minutesSeconds(65.0))
    assertEquals("12:00", FlightViewControls.minutesSeconds(720.9))
  }
}
