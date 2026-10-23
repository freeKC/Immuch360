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
}
