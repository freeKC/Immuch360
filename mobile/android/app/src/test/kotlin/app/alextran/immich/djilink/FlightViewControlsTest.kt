package app.alextran.immich.djilink

import com.meta.spatial.runtime.ButtonBits
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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

  /** The red line of the strip: no picture, a picture that stopped, or one shown 500 ms or more behind the phone */
  @Test
  fun theStripWarnsOfAPictureThatStoppedOrComesLate() {
    val line = FlightViewControls::stripLine
    assertEquals(FlightViewControls.StripLine.NO_PICTURE, line(null, null))
    assertEquals(FlightViewControls.StripLine.STALE, line(900, 180.0))
    assertEquals(FlightViewControls.StripLine.NONE, line(40, 320.0))
    assertEquals(FlightViewControls.StripLine.NONE, line(40, null))
    assertEquals(FlightViewControls.StripLine.DELAY_HIGH, line(40, 500.0))
    assertEquals(FlightViewControls.StripLine.DELAY_HIGH, line(40, 1_240.0))
  }

  private fun flight(motorTimeS: Double = 41.6, motorsOn: Boolean = false) = FlightReading(
    heightM = 12.3,
    speedsMps = listOf(0.0, 0.0, 0.0),
    pitchDeg = 0.0,
    rollDeg = 0.0,
    headingDeg = -175.6,
    mode = 12,
    inAir = motorsOn,
    motorsOn = motorsOn,
    satellites = 0,
    groundHeightM = 0.0,
    motorTimeS = motorTimeS,
    flags = 0L,
    verticalSpeedMps = 1.5,
    horizontalSpeedMps = 4.2,
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
    percent: Int = 34,
    motorsOn: Boolean = false,
  ) = TelemetryValues(
    flight = flightStale?.let { Timed(flight(motorsOn = motorsOn), 80, it) },
    gimbal = null,
    battery = batteryStale?.let { Timed(battery(percent), 300, it) },
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
    "cell.droneBattery.label" to "Drone battery",
    "cell.droneBattery.value" to "{value} %",
    "cell.motorTime.label" to "Motor time",
    "cell.motorTime.value" to "{value}",
    "batteryLow" to "low",
  )

  private fun cells(values: TelemetryValues?, labels: Map<String, String> = gated) =
    FlightViewControls.cells(values, labels, FlightViewControls.RIGHT_FIELDS).map { "${it.label}|${it.value}" }

  @Test
  fun theRightColumnShowsTheGatedFieldsOnly() {
    assertEquals(listOf("Drone battery|34 %", "Motor time|0:41"), cells(values()))
    // The remote's battery, the signal and the heading arrive too, but have no template: no cell
    assertTrue(FlightViewControls.cells(values(), gated, FlightViewControls.LEFT_FIELDS).isEmpty())
  }

  @Test
  fun aStaleGroupHasNoCellAndNothingArrivedHasNone() {
    assertEquals(listOf("Motor time|0:41"), cells(values(batteryStale = true)))
    assertEquals(listOf("Drone battery|34 %"), cells(values(flightStale = true)))
    assertTrue(cells(values(flightStale = true, batteryStale = true)).isEmpty())
    assertTrue(cells(null).isEmpty())
    assertTrue(cells(values(flightStale = null, batteryStale = null)).isEmpty())
    // Without any template, nothing is shown whatever arrives
    assertTrue(cells(values(), emptyMap()).isEmpty())
  }

  @Test
  fun theDroneBatteryUnderTwentyIsLow() {
    val low = FlightViewControls.cells(values(percent = 19), gated, FlightViewControls.RIGHT_FIELDS).first()
    assertTrue(low.low)
    assertEquals("Drone battery low", low.label)
    assertFalse(FlightViewControls.cells(values(percent = 20), gated, FlightViewControls.RIGHT_FIELDS).first().low)
  }

  @Test
  fun aGateOpenedLaterNeedsOnlyItsTemplates() {
    val more = gated + mapOf(
      "cell.height.label" to "Height",
      "cell.height.value" to "{value} m",
      "cell.verticalSpeed.label" to "Vertical",
      "cell.verticalSpeed.value" to "{value} m/s",
      "cell.speed.label" to "Speed",
      "cell.speed.value" to "{value} m/s",
      "cell.remoteBattery.label" to "Remote",
      "cell.remoteBattery.value" to "{value} %",
      "cell.heading.label" to "",
      "cell.heading.value" to "{value}\u00b0",
      "cell.landing.label" to "",
      "cell.landing.value" to "Landing",
    )
    assertEquals(
      listOf("Height|12.3 m", "Vertical|\u2191 1.5 m/s", "Speed|4.2 m/s"),
      FlightViewControls.cells(values(motorsOn = true), more, FlightViewControls.LEFT_FIELDS)
        .map { "${it.label}|${it.value}" },
    )
    assertEquals(
      listOf("Drone battery|34 %", "Motor time|0:41", "Remote|48 %", "|-176\u00b0", "|Landing"),
      cells(values(motorsOn = true), more),
    )
    // On the ground the drone holds a stale speed: no cell for it
    assertEquals(
      listOf("Height|12.3 m", "Vertical|\u2191 1.5 m/s"),
      FlightViewControls.cells(values(motorsOn = false), more, FlightViewControls.LEFT_FIELDS)
        .map { "${it.label}|${it.value}" },
    )
  }

  @Test
  fun theFormatsAreThoseOfThePhone() {
    assertEquals("12.3", FlightViewControls.height(12.34))
    assertEquals("-0.5", FlightViewControls.height(-0.5))
    assertEquals("123", FlightViewControls.height(123.4))
    assertEquals("\u2191 1.2", FlightViewControls.verticalSpeed(1.2))
    assertEquals("\u2193 0.2", FlightViewControls.verticalSpeed(-0.2))
    assertEquals("0.0", FlightViewControls.verticalSpeed(0.04))
    assertEquals("0.0", FlightViewControls.verticalSpeed(-0.04))
  }

  private val alertLabels = mapOf(
    "obstacleClose" to "Obstacle close: {distance} m",
    "obstacleClosePlain" to "Obstacle close",
    "obstacleStopped" to "Obstacle data stopped: look at the drone.",
    "obstacleLeft" to "On the left",
    "obstacleUnconfirmed" to "Not confirmed yet",
  )

  @Test
  fun theAlertBannerSaysTheDistanceTheSideAndWhenItsDataStopped() {
    assertNull(FlightViewControls.alertLines(ObstacleDecision.OFF, alertLabels))
    val on = ObstacleDecision(true, 1.84, null, 400, stopped = false, listening = true)
    assertEquals("Obstacle close: 1.8 m" to "Not confirmed yet", FlightViewControls.alertLines(on, alertLabels))
    assertEquals(
      "Obstacle close: 1.8 m" to "On the left  Not confirmed yet",
      FlightViewControls.alertLines(on.copy(side = ObstacleSide.LEFT), alertLabels),
    )
    assertEquals(
      "Obstacle close" to null,
      FlightViewControls.alertLines(on.copy(distanceM = null), alertLabels - "obstacleUnconfirmed"),
    )
    assertEquals(
      "Obstacle data stopped: look at the drone." to null,
      FlightViewControls.alertLines(ObstacleDecision.OFF.copy(stopped = true), alertLabels),
    )
  }

  @Test
  fun theColumnsSitPastTheVideosEdgesAtEveryWidth() {
    for (width in FlightViewControls.WIDTHS_M) {
      val offset = FlightViewControls.columnOffsetM(width, 0.36f, 0.05f)
      assertEquals(width / 2f + 0.23f, offset, 1e-5f)
      // Within 45 degrees of the centre of a flat video seen from 2.5 m
      assertTrue(Math.toDegrees(kotlin.math.atan((offset / 2.5f).toDouble())) < 45.0)
    }
  }

  @Test
  fun theMotorTimeIsMinutesAndSeconds() {
    assertEquals("0:00", FlightViewControls.minutesSeconds(0.0))
    assertEquals("0:41", FlightViewControls.minutesSeconds(41.6))
    assertEquals("1:05", FlightViewControls.minutesSeconds(65.0))
    assertEquals("12:00", FlightViewControls.minutesSeconds(720.9))
  }
}
