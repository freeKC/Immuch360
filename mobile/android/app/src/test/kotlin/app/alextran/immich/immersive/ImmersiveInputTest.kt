package app.alextran.immich.immersive

import app.alextran.immich.immersive.ImmersiveControls.Action
import com.meta.spatial.core.Quaternion
import com.meta.spatial.core.Vector3
import com.meta.spatial.runtime.ButtonBits
import kotlin.math.cos
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ImmersiveInputTest {
  private val log = mutableListOf<String>()
  private val edges = ControllerEdges { log += it }

  private fun actions(controller: Int = 0, hand: Int = 0, panelVisible: Boolean = false): List<Action> =
    ImmersiveControls.actionsFor(controller, hand, panelVisible)

  // Edges

  @Test
  fun `a press counts once, on the update it goes down`() {
    assertEquals(0, edges.pressed(1, true, "CONTROLLER", 0))
    assertEquals(ButtonBits.ButtonA, edges.pressed(1, true, "CONTROLLER", ButtonBits.ButtonA))
    assertEquals(0, edges.pressed(1, true, "CONTROLLER", ButtonBits.ButtonA))
    assertEquals(0, edges.pressed(1, true, "CONTROLLER", 0))
    assertEquals(ButtonBits.ButtonA, edges.pressed(1, true, "CONTROLLER", ButtonBits.ButtonA))
  }

  @Test
  fun `a controller seen for the first time starts from what it holds`() {
    assertEquals(0, edges.pressed(7, true, "CONTROLLER", ButtonBits.ButtonSqueezeR))
    assertEquals(0, edges.pressed(7, true, "CONTROLLER", ButtonBits.ButtonSqueezeR))
    assertTrue(log.single().startsWith("controller 7 appeared"))
  }

  @Test
  fun `a controller that wakes up starts again from its buttons, then presses count again`() {
    edges.pressed(1, true, "CONTROLLER", 0)
    // Asleep with A held, as the SDK may leave it
    assertEquals(0, edges.pressed(1, false, "CONTROLLER", ButtonBits.ButtonA))
    // Awake: what it holds at that update is the new start, a stale A does not toggle the panel
    assertEquals(0, edges.pressed(1, true, "CONTROLLER", ButtonBits.ButtonA))
    assertEquals(0, edges.pressed(1, true, "CONTROLLER", 0))
    assertEquals(ButtonBits.ButtonA, edges.pressed(1, true, "CONTROLLER", ButtonBits.ButtonA))
    assertTrue(log.any { it.contains("is now controller, inactive") })
    assertTrue(log.any { it.contains("is now controller, active") })
  }

  @Test
  fun `a press from a controller the SDK still reports inactive is not lost`() {
    edges.pressed(1, false, "CONTROLLER", 0)
    assertEquals(ButtonBits.ButtonTriggerR, edges.pressed(1, false, "CONTROLLER", ButtonBits.ButtonTriggerR))
  }

  @Test
  fun `hands taking over from the controllers start from their pinch`() {
    edges.pressed(2, true, "CONTROLLER", 0)
    assertEquals(0, edges.pressed(2, true, "HAND", ButtonBits.ButtonA))
    assertEquals(0, edges.pressed(2, true, "HAND", ButtonBits.ButtonA))
    assertEquals(0, edges.pressed(2, true, "HAND", 0))
    assertEquals(ButtonBits.ButtonA, edges.pressed(2, true, "HAND", ButtonBits.ButtonA))
    assertTrue(log.any { it.contains("is now hand, active (was controller, active)") })
  }

  @Test
  fun `controllers that are gone are forgotten, and a recreated one starts afresh`() {
    edges.pressed(1, true, "CONTROLLER", 0)
    edges.pressed(2, true, "CONTROLLER", 0)
    edges.retain(setOf(2))
    assertTrue(log.any { it.startsWith("controller 1 is gone") })
    assertEquals(0, edges.pressed(1, true, "CONTROLLER", ButtonBits.ButtonX))
    assertEquals(ButtonBits.ButtonX, edges.pressed(2, true, "CONTROLLER", ButtonBits.ButtonX))
  }

  @Test
  fun `a diagonal thumbstick push gives its first direction only`() {
    edges.pressed(1, true, "CONTROLLER", 0)
    assertEquals(ButtonBits.ButtonThumbRL, edges.pressed(1, true, "CONTROLLER", ButtonBits.ButtonThumbRL))
    // The up threshold crossed on the next update, the stick still held left: no second direction
    val diagonal = ButtonBits.ButtonThumbRL or ButtonBits.ButtonThumbRU
    assertEquals(0, edges.pressed(1, true, "CONTROLLER", diagonal))
    // Both thresholds on the same update: left or right before up or down
    edges.pressed(1, true, "CONTROLLER", 0)
    assertEquals(ButtonBits.ButtonThumbRL, edges.pressed(1, true, "CONTROLLER", diagonal))
  }

  @Test
  fun `the two thumbsticks and the buttons are told apart`() {
    edges.pressed(1, true, "CONTROLLER", ButtonBits.ButtonThumbLU)
    val both = ButtonBits.ButtonThumbLU or ButtonBits.ButtonThumbRD or ButtonBits.ButtonB
    assertEquals(ButtonBits.ButtonThumbRD or ButtonBits.ButtonB, edges.pressed(1, true, "CONTROLLER", both))
  }

  // Actions

  @Test
  fun `B or Y closes and nothing else happens`() {
    assertEquals(listOf(Action.CLOSE), actions(controller = ButtonBits.ButtonB or ButtonBits.ButtonA))
    assertEquals(listOf(Action.CLOSE), actions(controller = ButtonBits.ButtonY or ButtonBits.ButtonTriggerR))
  }

  @Test
  fun `the thumbstick never touches the info panel`() {
    for (visible in listOf(false, true)) {
      assertEquals(listOf(Action.PREVIOUS), actions(controller = ButtonBits.ButtonThumbLL, panelVisible = visible))
      assertEquals(listOf(Action.NEXT), actions(controller = ButtonBits.ButtonThumbLR, panelVisible = visible))
      assertEquals(listOf(Action.TURN_LEFT), actions(controller = ButtonBits.ButtonThumbRL, panelVisible = visible))
      assertEquals(listOf(Action.TURN_RIGHT), actions(controller = ButtonBits.ButtonThumbRR, panelVisible = visible))
      assertEquals(listOf(Action.STICK_UP), actions(controller = ButtonBits.ButtonThumbRU, panelVisible = visible))
      assertEquals(listOf(Action.STICK_DOWN), actions(controller = ButtonBits.ButtonThumbLD, panelVisible = visible))
    }
  }

  @Test
  fun `the right thumbstick held left or right turns again after a delay, then at an interval`() {
    val held = ButtonBits.ButtonThumbRR
    assertEquals(0, edges.pressed(1, true, "CONTROLLER", 0, nowMs = 1000))
    assertEquals(held, edges.pressed(1, true, "CONTROLLER", held, nowMs = 1000))
    // Held, but not for long enough yet
    assertEquals(0, edges.pressed(1, true, "CONTROLLER", held, nowMs = 1000 + ControllerEdges.TURN_REPEAT_DELAY_MS - 1))
    assertEquals(held, edges.pressed(1, true, "CONTROLLER", held, nowMs = 1000 + ControllerEdges.TURN_REPEAT_DELAY_MS))
    val second = 1000 + ControllerEdges.TURN_REPEAT_DELAY_MS + ControllerEdges.TURN_REPEAT_INTERVAL_MS
    assertEquals(0, edges.pressed(1, true, "CONTROLLER", held, nowMs = second - 1))
    assertEquals(held, edges.pressed(1, true, "CONTROLLER", held, nowMs = second))
    // Released: nothing more, and a new push starts over with its own delay
    assertEquals(0, edges.pressed(1, true, "CONTROLLER", 0, nowMs = second + 1000))
    assertEquals(0, edges.pressed(1, true, "CONTROLLER", 0, nowMs = second + 2000))
    assertEquals(held, edges.pressed(1, true, "CONTROLLER", held, nowMs = second + 3000))
    assertEquals(0, edges.pressed(1, true, "CONTROLLER", held, nowMs = second + 3000 + 100))
  }

  @Test
  fun `the other thumbstick directions and the buttons do not repeat`() {
    for (bit in listOf(ButtonBits.ButtonThumbLL, ButtonBits.ButtonThumbRU, ButtonBits.ButtonA)) {
      val own = ControllerEdges()
      own.pressed(2, true, "CONTROLLER", 0, nowMs = 0)
      assertEquals(bit, own.pressed(2, true, "CONTROLLER", bit, nowMs = 0))
      assertEquals(0, own.pressed(2, true, "CONTROLLER", bit, nowMs = 5000))
    }
  }

  @Test
  fun `a turn held across a controller reset does not repeat`() {
    val held = ButtonBits.ButtonThumbRL
    edges.pressed(1, true, "CONTROLLER", 0, nowMs = 0)
    assertEquals(held, edges.pressed(1, true, "CONTROLLER", held, nowMs = 0))
    assertEquals(0, edges.pressed(1, false, "CONTROLLER", held, nowMs = 100))
    assertEquals(0, edges.pressed(1, false, "CONTROLLER", held, nowMs = 5000))
  }

  @Test
  fun `A, X, grip and menu show or hide the info panel`() {
    val toggles =
      listOf(
        ButtonBits.ButtonA,
        ButtonBits.ButtonX,
        ButtonBits.ButtonSqueezeL,
        ButtonBits.ButtonSqueezeR,
        ButtonBits.ButtonMenu,
      )
    for (bit in toggles) {
      assertEquals(listOf(Action.TOGGLE_PANEL), actions(controller = bit, panelVisible = false))
      assertEquals(listOf(Action.TOGGLE_PANEL), actions(controller = bit, panelVisible = true))
    }
  }

  @Test
  fun `the menu gesture toggles the panel, a pinch only shows a hidden one`() {
    assertEquals(listOf(Action.TOGGLE_PANEL), actions(hand = ButtonBits.ButtonMenu, panelVisible = true))
    assertEquals(listOf(Action.SHOW_PANEL), actions(hand = ButtonBits.ButtonA, panelVisible = false))
    assertEquals(listOf(Action.SHOW_PANEL), actions(hand = ButtonBits.ButtonX, panelVisible = false))
    // A pinch on a panel button clicks it, the panel stays
    assertEquals(emptyList<Action>(), actions(hand = ButtonBits.ButtonA, panelVisible = true))
  }

  @Test
  fun `the trigger plays or pauses while the panel is hidden only`() {
    assertEquals(listOf(Action.PLAY_PAUSE), actions(controller = ButtonBits.ButtonTriggerR, panelVisible = false))
    assertEquals(emptyList<Action>(), actions(controller = ButtonBits.ButtonTriggerL, panelVisible = true))
    // A pinch is no trigger
    assertEquals(emptyList<Action>(), actions(hand = ButtonBits.ButtonTriggerR, panelVisible = false))
    // The panel shown by the same update takes the trigger
    assertEquals(
      listOf(Action.TOGGLE_PANEL),
      actions(controller = ButtonBits.ButtonA or ButtonBits.ButtonTriggerR, panelVisible = false),
    )
  }

  @Test
  fun `controller buttons the SDK files under a hand still work`() {
    assertEquals(listOf(Action.CLOSE), actions(hand = ButtonBits.ButtonB))
    assertEquals(listOf(Action.TURN_RIGHT), actions(hand = ButtonBits.ButtonThumbRR))
    assertEquals(
      listOf(Action.STICK_UP, Action.SHOW_PANEL),
      actions(hand = ButtonBits.ButtonThumbRU or ButtonBits.ButtonA),
    )
  }

  @Test
  fun `actions run in order, thumbstick then panel then trigger`() {
    assertEquals(
      listOf(Action.STICK_DOWN, Action.TOGGLE_PANEL),
      actions(controller = ButtonBits.ButtonThumbRD or ButtonBits.ButtonX, panelVisible = true),
    )
    assertEquals(
      listOf(Action.TURN_RIGHT, Action.TOGGLE_PANEL, Action.PLAY_PAUSE),
      actions(
        controller = ButtonBits.ButtonThumbRR or ButtonBits.ButtonX or ButtonBits.ButtonTriggerL,
        panelVisible = true,
      ),
    )
  }

  // Turn direction

  private fun turn(action: Action, reversed: Boolean = false): Float =
    ImmersiveControls.snapTurnDegrees(action, STEP, reversed)

  @Test
  fun `the right thumbstick turns the view the way it is pushed`() {
    // The viewer turns the sphere, not the user: a view turning left is a sphere turning by a positive yaw
    assertEquals(STEP, turn(Action.TURN_LEFT), 0f)
    assertEquals(-STEP, turn(Action.TURN_RIGHT), 0f)
  }

  @Test
  fun `the reverse setting turns the other way, as builds 17 to 28 did`() {
    assertEquals(-STEP, turn(Action.TURN_LEFT, reversed = true), 0f)
    assertEquals(STEP, turn(Action.TURN_RIGHT, reversed = true), 0f)
  }

  @Test
  fun `only the right thumbstick left and right turn the sphere`() {
    for (action in Action.entries.filter { it != Action.TURN_LEFT && it != Action.TURN_RIGHT }) {
      for (reversed in listOf(false, true)) assertEquals("$action", 0f, turn(action, reversed), 0f)
    }
  }

  @Test
  fun `a left push brings what was on the left in front, and the image moves to the right`() {
    // Spatial SDK coordinates: left handed, +x right, +y up, +z forward; the sphere turns as the viewer sets it
    val sphere = Quaternion(0f, turn(Action.TURN_LEFT), 0f)
    val step = Math.toRadians(STEP.toDouble())
    val onTheLeft = Vector3(-sin(step).toFloat(), 0f, cos(step).toFloat())
    assertDirection("what was ${STEP.toInt()} degrees on the left", Vector3(0f, 0f, 1f), sphere * onTheLeft)
    val ahead = sphere * Vector3(0f, 0f, 1f)
    assertTrue("what was in front goes to the right: $ahead", ahead.x > 0.4f)
    // A right push brings what was on the right in front
    val right = Quaternion(0f, turn(Action.TURN_RIGHT), 0f)
    val onTheRight = Vector3(sin(step).toFloat(), 0f, cos(step).toFloat())
    assertDirection("what was ${STEP.toInt()} degrees on the right", Vector3(0f, 0f, 1f), right * onTheRight)
  }

  @Test
  fun `with the reverse setting a left push brings what was on the right in front`() {
    val sphere = Quaternion(0f, turn(Action.TURN_LEFT, reversed = true), 0f)
    val step = Math.toRadians(STEP.toDouble())
    val onTheRight = Vector3(sin(step).toFloat(), 0f, cos(step).toFloat())
    assertDirection("what was ${STEP.toInt()} degrees on the right", Vector3(0f, 0f, 1f), sphere * onTheRight)
  }

  // A 3D scene (design-final 2026-10-27, section 3.3)

  private fun sceneActions(controller: Int = 0, hand: Int = 0, panelVisible: Boolean = false): List<Action> =
    ImmersiveControls.actionsFor(controller, hand, panelVisible, scene = true)

  @Test
  fun `in a scene the thumbsticks glide and reset, neither previous, next, turn nor resize`() {
    val directions = ControllerEdges.LEFT_STICK or ControllerEdges.RIGHT_STICK
    for (bit in (0 until 32).map { 1 shl it }.filter { directions and it != 0 }) {
      assertEquals("direction 0x${Integer.toHexString(bit)}", emptyList<Action>(), sceneActions(controller = bit))
    }
    assertEquals(listOf(Action.RESET), sceneActions(controller = ButtonBits.ButtonThumbLClick))
    assertEquals(listOf(Action.RESET), sceneActions(controller = ButtonBits.ButtonThumbRClick))
    // Filed under a hand after a wake up, a click is still a controller's
    assertEquals(listOf(Action.RESET), sceneActions(hand = ButtonBits.ButtonThumbRClick))
    // Out of a scene a click does nothing, as before
    assertEquals(emptyList<Action>(), actions(controller = ButtonBits.ButtonThumbLClick))
  }

  @Test
  fun `in a scene B or Y go back, A, X, grip and menu keep the panel, the trigger plays nothing`() {
    assertEquals(listOf(Action.CLOSE), sceneActions(controller = ButtonBits.ButtonB or ButtonBits.ButtonThumbLClick))
    assertEquals(listOf(Action.TOGGLE_PANEL), sceneActions(controller = ButtonBits.ButtonA))
    assertEquals(listOf(Action.TOGGLE_PANEL), sceneActions(controller = ButtonBits.ButtonSqueezeL, panelVisible = true))
    assertEquals(listOf(Action.SHOW_PANEL), sceneActions(hand = ButtonBits.ButtonX))
    assertEquals(emptyList<Action>(), sceneActions(controller = ButtonBits.ButtonTriggerR))
    assertEquals(
      listOf(Action.RESET, Action.TOGGLE_PANEL),
      sceneActions(controller = ButtonBits.ButtonThumbRClick or ButtonBits.ButtonA),
    )
  }

  @Test
  fun `the left thumbstick held glides one way or the other on each axis, a diagonal on both`() {
    assertEquals(0.0 to 0.0, SceneStick.of(0))
    assertEquals(1.0 to 0.0, SceneStick.of(ButtonBits.ButtonThumbLR))
    assertEquals(-1.0 to 0.0, SceneStick.of(ButtonBits.ButtonThumbLL))
    assertEquals(0.0 to 1.0, SceneStick.of(ButtonBits.ButtonThumbLU))
    assertEquals(0.0 to -1.0, SceneStick.of(ButtonBits.ButtonThumbLD))
    assertEquals(1.0 to 1.0, SceneStick.of(ButtonBits.ButtonThumbLR or ButtonBits.ButtonThumbLU))
    // Both ways at once cancel; the right thumbstick and the buttons do not glide
    assertEquals(0.0 to 0.0, SceneStick.of(ButtonBits.ButtonThumbLL or ButtonBits.ButtonThumbLR))
    assertEquals(0.0 to 0.0, SceneStick.of(ControllerEdges.RIGHT_STICK or ButtonBits.ButtonA))
  }

  private fun assertDirection(message: String, expected: Vector3, actual: Vector3) {
    assertEquals("$message, x", expected.x, actual.x, 1e-4f)
    assertEquals("$message, y", expected.y, actual.y, 1e-4f)
    assertEquals("$message, z", expected.z, actual.z, 1e-4f)
  }

  private companion object {
    /** The snap turn of the viewer */
    const val STEP = 30f
  }
}
