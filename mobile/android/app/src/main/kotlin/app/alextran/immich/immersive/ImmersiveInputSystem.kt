package app.alextran.immich.immersive

import android.util.Log
import com.meta.spatial.core.Pose
import com.meta.spatial.core.Query
import com.meta.spatial.core.SystemBase
import com.meta.spatial.runtime.ButtonBits
import com.meta.spatial.toolkit.AvatarAttachment
import com.meta.spatial.toolkit.Controller
import com.meta.spatial.toolkit.ControllerType
import com.meta.spatial.toolkit.Transform

/**
 * Polls the controllers every frame, like the ControllerListenerSystem of Meta's SplatSample, and
 * reports the buttons just pressed plus the head pose. With hand tracking, A and X mean index
 * pinches, so hand buttons are reported separately. A thumbstick push reports one direction only.
 *
 * The presses come from [ControllerEdges], which compares each controller with its own previous
 * state rather than trusting Controller.changedButtons: after a long idle time the controllers
 * sleep, hand tracking may take over, and the SDK may flip isActive or recreate the controller
 * entities, the likely reasons why a user of build 14 found the viewer deaf to the buttons after a
 * long idle time. Every such transition is logged under the Immuch360 tag, and an exception in the
 * viewer never escapes into the SDK, which could otherwise stop running this system.
 */
internal class ImmersiveInputSystem(private val listener: Listener) : SystemBase() {
  interface Listener {
    fun onButtonsPressed(controllerBits: Int, handBits: Int)

    fun onFrame(head: Pose?)
  }

  private val headQuery =
    Query.where { has(AvatarAttachment.id) }
      .filter { isLocal() and by(AvatarAttachment.typeData).isEqualTo("head") }

  private val edges = ControllerEdges { message -> Log.i(TAG, message) }

  override fun execute() {
    var controllerBits = 0
    var handBits = 0
    try {
      val controllers = Query.where { has(Controller.id) }.eval().filter { it.isLocal() }
      val present = HashSet<Long>()
      for (entity in controllers) {
        val controller = entity.getComponent<Controller>()
        val type = controller.type
        val active = controller.isActive
        present.add(entity.id)
        // Inactive controllers are polled too: a press is a press even when the SDK reports the
        // controller asleep, which it may keep doing after a wake up
        val down = edges.pressed(entity.id, active, type.name, controller.buttonState)
        if (down == 0) continue
        if (!active) Log.i(TAG, "buttons 0x${Integer.toHexString(down)} from the inactive $type ${entity.id}")
        if (type == ControllerType.HAND) handBits = handBits or down else controllerBits = controllerBits or down
      }
      edges.retain(present)
    } catch (e: Exception) {
      Log.e(TAG, "controller polling failed", e)
    }
    if (controllerBits != 0 || handBits != 0) {
      try {
        listener.onButtonsPressed(controllerBits, handBits)
      } catch (e: Exception) {
        Log.e(TAG, "button handling failed", e)
      }
    }

    val head =
      try {
        headQuery.eval().firstOrNull()?.getComponent<Transform>()?.transform
      } catch (e: Exception) {
        Log.e(TAG, "head query failed", e)
        null
      }
    try {
      listener.onFrame(head)
    } catch (e: Exception) {
      Log.e(TAG, "frame handling failed", e)
    }
  }
}

/**
 * Edge detection of the buttons of each controller (or tracked hand), kept per entity from one update to the next.
 * A controller seen for the first time, one that becomes active or inactive, and one that switches between hand and
 * controller start again from the buttons they hold at that update: nothing counts as pressed then, so that neither a
 * stale state from before a sleep nor a pinch held while the hands take over fires an action. [log] receives each of
 * those transitions, for logcat. Pure: no Spatial SDK call, unit tested.
 */
internal class ControllerEdges(private val log: (String) -> Unit = {}) {
  private class Seen(var active: Boolean, var type: String, var buttons: Int)

  private val controllers = HashMap<Long, Seen>()

  /**
   * The buttons of controller [id] pressed since its previous update, given whether it is [active], its [type] and the
   * buttons it holds now. A thumbstick push reports one direction only, see [firstDirectionOnly].
   */
  fun pressed(id: Long, active: Boolean, type: String, buttons: Int): Int {
    val seen = controllers[id]
    if (seen == null) {
      log("controller $id appeared: ${describe(active, type)}, buttons ${hex(buttons)}")
      controllers[id] = Seen(active, type, buttons)
      return 0
    }
    if (seen.active != active || seen.type != type) {
      log(
        "controller $id is now ${describe(active, type)} (was ${describe(seen.active, seen.type)}), " +
          "buttons ${hex(buttons)}, edges reset",
      )
      seen.active = active
      seen.type = type
      seen.buttons = buttons
      return 0
    }
    val before = seen.buttons
    seen.buttons = buttons
    var down = buttons and before.inv()
    down = firstDirectionOnly(down, before, LEFT_STICK)
    down = firstDirectionOnly(down, before, RIGHT_STICK)
    return down
  }

  /** Forgets the controllers that are gone (the SDK may recreate them after a sleep), logging each one. */
  fun retain(present: Set<Long>) {
    val iterator = controllers.entries.iterator()
    while (iterator.hasNext()) {
      val (id, seen) = iterator.next()
      if (id in present) continue
      log("controller $id is gone (was ${describe(seen.active, seen.type)})")
      iterator.remove()
    }
  }

  /**
   * The SDK thresholds each thumbstick axis separately: a diagonal push crosses the left threshold on one
   * frame and the up threshold on the next, two direction edges for one gesture. Keeps the first direction
   * of a push: drops the direction edges of [stick] when that stick already held a direction in the
   * previous update ([before]), and keeps a single one when several cross on the same frame (the lowest
   * bit, left or right before up or down).
   */
  private fun firstDirectionOnly(down: Int, before: Int, stick: Int): Int {
    val directions = down and stick
    if (directions == 0) return down
    val kept = if ((before and stick) != 0) 0 else directions.takeLowestOneBit()
    return (down and stick.inv()) or kept
  }

  private fun describe(active: Boolean, type: String): String =
    "${type.lowercase()}, ${if (active) "active" else "inactive"}"

  private fun hex(bits: Int): String = "0x${Integer.toHexString(bits)}"

  companion object {
    /** Direction bits of each thumbstick. */
    val LEFT_STICK =
      ButtonBits.ButtonThumbLL or ButtonBits.ButtonThumbLR or ButtonBits.ButtonThumbLU or ButtonBits.ButtonThumbLD
    val RIGHT_STICK =
      ButtonBits.ButtonThumbRL or ButtonBits.ButtonThumbRR or ButtonBits.ButtonThumbRU or ButtonBits.ButtonThumbRD
  }
}

/**
 * What the immersive viewer does with the buttons just pressed (ImmersiveInputSystem.Listener.onButtonsPressed),
 * decided apart from the viewer so that it can be tested:
 * - B or Y goes back to the app, and nothing else happens on that update;
 * - thumbstick left or right asks for the previous or the next media, up or down seeks a video or turns a photo,
 *   which the viewer shows on its small feedback line, never by bringing the info panel up;
 * - A, X, grip or menu on a controller, and the menu gesture of a hand, show or hide the info panel; an index pinch
 *   (A or X of a hand) only shows a hidden panel, since a pinch on a panel button must not hide the panel it clicks;
 * - the trigger plays or pauses a video while the panel is hidden (on the panel it clicks a button).
 * Bits that only a controller has (B, Y, the thumbsticks) count as controller bits even when the SDK files them under
 * a hand: after the controllers wake up, the SDK may still take them for hands for a while.
 */
internal object ImmersiveControls {
  enum class Action { CLOSE, PREVIOUS, NEXT, STICK_UP, STICK_DOWN, TOGGLE_PANEL, SHOW_PANEL, PLAY_PAUSE }

  /** The actions for [controllerBits] and [handBits] pressed on the same update, in the order to run them. */
  fun actionsFor(controllerBits: Int, handBits: Int, panelVisible: Boolean): List<Action> {
    val controllerOnly =
      ButtonBits.ButtonB or ButtonBits.ButtonY or ControllerEdges.LEFT_STICK or ControllerEdges.RIGHT_STICK
    val controller = controllerBits or (handBits and controllerOnly)
    val hand = handBits and controllerOnly.inv()
    if ((controller and (ButtonBits.ButtonB or ButtonBits.ButtonY)) != 0) return listOf(Action.CLOSE)
    val actions = mutableListOf<Action>()
    when {
      (controller and (ButtonBits.ButtonThumbLL or ButtonBits.ButtonThumbRL)) != 0 -> actions += Action.PREVIOUS
      (controller and (ButtonBits.ButtonThumbLR or ButtonBits.ButtonThumbRR)) != 0 -> actions += Action.NEXT
      (controller and (ButtonBits.ButtonThumbLU or ButtonBits.ButtonThumbRU)) != 0 -> actions += Action.STICK_UP
      (controller and (ButtonBits.ButtonThumbLD or ButtonBits.ButtonThumbRD)) != 0 -> actions += Action.STICK_DOWN
    }
    val panelToggle =
      ButtonBits.ButtonA or ButtonBits.ButtonX or ButtonBits.ButtonMenu or ButtonBits.ButtonSqueezeL or
        ButtonBits.ButtonSqueezeR
    var visibleAfter = panelVisible
    if ((controller and panelToggle) != 0 || (hand and ButtonBits.ButtonMenu) != 0) {
      actions += Action.TOGGLE_PANEL
      visibleAfter = !panelVisible
    } else if (!panelVisible && (hand and (ButtonBits.ButtonA or ButtonBits.ButtonX)) != 0) {
      actions += Action.SHOW_PANEL
      visibleAfter = true
    }
    // With the panel shown, the trigger clicks its buttons instead
    if (!visibleAfter && (controller and (ButtonBits.ButtonTriggerL or ButtonBits.ButtonTriggerR)) != 0) {
      actions += Action.PLAY_PAUSE
    }
    return actions
  }
}
