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

  private val ringLabels = mapOf("obstacleDistance" to "{distance} m")

  private fun ring(on: Boolean = true, stopped: Boolean = false, nearest: Double? = 1.44): ObstacleDecision {
    val arcs = if (nearest == null) emptyList() else listOf(ObstacleRing.arc(30.0, nearest, RingSettings()))
    return ObstacleDecision.OFF.copy(on = on, stopped = stopped, arcs = arcs, nearestM = nearest, even = false)
  }

  @Test
  fun theHaloIsTenCentimetresLargerThanTheVideoAtTheReferenceWidthAndScalesWithIt() {
    assertEquals(0.10f, FlightViewControls.haloMarginM(2.4f), 1e-6f)
    val (width, height) = FlightViewControls.haloSizeM(2.4f)
    assertEquals(2.6f, width, 1e-5f)
    assertEquals(1.55f, height, 1e-5f)
    for (videoWidth in FlightViewControls.WIDTHS_M) {
      val margin = FlightViewControls.haloMarginM(videoWidth)
      val (w, h) = FlightViewControls.haloSizeM(videoWidth)
      assertEquals(videoWidth + 2 * margin, w, 1e-5f)
      assertEquals(videoWidth * 9f / 16f + 2 * margin, h, 1e-5f)
      // The panel registered at the reference size, scaled as the video is, is exactly this halo
      val scale = videoWidth / 2.4f
      assertEquals(2.6f * scale, w, 1e-4f)
    }
  }

  @Test
  fun theRingShowsOnlyWithArcsAndItsNumberOnlyWhenAskedWithTheValues() {
    assertFalse(FlightViewControls.ringShows(ObstacleDecision.OFF))
    assertFalse(FlightViewControls.ringShows(ring(nearest = null)))
    assertTrue(FlightViewControls.ringShows(ring()))
    assertTrue(FlightViewControls.ringShows(ring(on = false, stopped = true)))
    assertEquals("1.4 m", FlightViewControls.ringNumber(ring(), ringLabels, numbersOn = true, valuesShown = true))
    // Asked on this headset (on by default in Flutter), hidden by A with the values, never once the data stopped
    assertNull(FlightViewControls.ringNumber(ring(), ringLabels, numbersOn = false, valuesShown = true))
    assertNull(FlightViewControls.ringNumber(ring(), ringLabels, numbersOn = true, valuesShown = false))
    assertNull(FlightViewControls.ringNumber(ring(on = false, stopped = true), ringLabels, true, true))
    assertNull(FlightViewControls.ringNumber(ring(), emptyMap(), numbersOn = true, valuesShown = true))
  }

  @Test
  fun theCirclesPanelStaysInsideTheVideoAndHoldsTheCircleAndItsNumber() {
    // At the reference width: a video 1.35 m tall, a circle of 0.3375 m, 0.061 m thick, 0.12 m for the number
    assertEquals(2f * (0.3375f + 0.06075f + 0.12f), FlightViewControls.circleSideM(2.4f), 1e-5f)
    for (videoWidth in FlightViewControls.WIDTHS_M) {
      val side = FlightViewControls.circleSideM(videoWidth)
      val height = videoWidth * 9f / 16f
      // Inside the video's rectangle at every width, so it never covers the strip or the columns
      assertTrue(side < height)
      // Registered at the reference size and scaled as the video is
      assertEquals(FlightViewControls.circleSideM(2.4f) * videoWidth / 2.4f, side, 1e-4f)
      // The circle drawn in it has a radius of a quarter of the video's height
      val part = FlightViewControls.circleVideoHeightPart(videoWidth)
      assertEquals(height, side * part, 1e-4f)
      assertEquals(height / 4f, (side * part * RingCircle.RADIUS_PART).toFloat(), 1e-4f)
    }
  }

  @Test
  fun anyButtonBringsTheWarningsBack() {
    assertTrue(FlightViewControls.recalls(ButtonBits.ButtonTriggerR, 0))
    assertTrue(FlightViewControls.recalls(ButtonBits.ButtonSqueezeL, 0))
    assertTrue(FlightViewControls.recalls(ButtonBits.ButtonA, 0))
    assertTrue(FlightViewControls.recalls(0, ButtonBits.ButtonMenu))
    assertFalse(FlightViewControls.recalls(0, 0))
  }

  @Test
  fun anErrorThatNeedsAnActionStaysAndTheRedLineStaysWhileTheVideoIsHidden() {
    val keeps = FlightViewControls::stateKeeps
    assertFalse(keeps(listOf("live")))
    assertFalse(keeps(listOf("replay")))
    assertFalse(keeps(listOf("lost")))
    assertFalse(keeps(listOf("local")))
    assertTrue(keeps(listOf("noSource")))
    assertTrue(keeps(listOf("wrongCode", "ended")))
    assertTrue(keeps(listOf("otherVersion", "ended")))
    assertTrue(keeps(listOf("unproven", "ended")))
    assertTrue(keeps(listOf("ended")))
    val red = FlightViewControls::redLineKeeps
    // A picture that stopped under 2 s ago still shows: its line comes and goes
    assertFalse(red(FlightViewControls.StripLine.STALE, 900))
    // The video is hidden: the one line that says why stays
    assertTrue(red(FlightViewControls.StripLine.STALE, 2_400))
    assertTrue(red(FlightViewControls.StripLine.NO_PICTURE, null))
    // A late picture is a warning over a picture that shows
    assertFalse(red(FlightViewControls.StripLine.DELAY_HIGH, 40))
    assertFalse(red(FlightViewControls.StripLine.NONE, null))
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
