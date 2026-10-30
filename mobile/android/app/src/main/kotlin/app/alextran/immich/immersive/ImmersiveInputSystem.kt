package app.alextran.immich.immersive

import android.os.SystemClock
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
internal class ImmersiveInputSystem(
  private val listener: Listener,
  private val now: () -> Long = { SystemClock.uptimeMillis() },
) : SystemBase() {
  interface Listener {
    fun onButtonsPressed(controllerBits: Int, handBits: Int)

    /**
     * The buttons held now on every controller, every frame before [onFrame]: the left thumbstick held glides in a 3D
     * scene (see SceneStick). Nothing by default.
     */
    fun onButtonsHeld(controllerBits: Int) = Unit

    /** Whether [onControllerRays] is wanted on this frame: while a flat screen shows. False by default. */
    fun wantsControllerRays(): Boolean = false

    /**
     * The pose of each controller found on this frame, its forward being its ray (the grips move and resize a flat
     * screen with it, see ScreenGrip), every frame [wantsControllerRays] says so, before [onFrame]. Nothing by default.
     */
    fun onControllerRays(rays: Map<GripSide, Pose>) = Unit

    fun onFrame(head: Pose?)
  }

  private val headQuery = attachmentQuery("head")

  /** The controllers, by the side of their grip: the attachments of the avatar the SDK names after each hand. */
  private val controllerQueries =
    mapOf(GripSide.LEFT to attachmentQuery("left_controller"), GripSide.RIGHT to attachmentQuery("right_controller"))

  private val edges = ControllerEdges { message -> Log.i(TAG, message) }

  override fun execute() {
    var controllerBits = 0
    var handBits = 0
    var heldBits = 0
    try {
      val controllers = Query.where { has(Controller.id) }.eval().filter { it.isLocal() }
      val present = HashSet<Long>()
      for (entity in controllers) {
        val controller = entity.getComponent<Controller>()
        val type = controller.type
        val active = controller.isActive
        present.add(entity.id)
        // Held, whatever the SDK calls the controller: the thumbsticks are a controller's even under a hand
        heldBits = heldBits or controller.buttonState
        // Inactive controllers are polled too: a press is a press even when the SDK reports the
        // controller asleep, which it may keep doing after a wake up
        val down = edges.pressed(entity.id, active, type.name, controller.buttonState, now())
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

    try {
      listener.onButtonsHeld(heldBits)
    } catch (e: Exception) {
      Log.e(TAG, "held buttons handling failed", e)
    }

    try {
      if (listener.wantsControllerRays()) {
        val rays = HashMap<GripSide, Pose>(2)
        for ((side, query) in controllerQueries) {
          query.eval().firstOrNull()?.getComponent<Transform>()?.transform?.let { rays[side] = it }
        }
        listener.onControllerRays(rays)
      }
    } catch (e: Exception) {
      Log.e(TAG, "controller rays failed", e)
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

  /** The local attachment of the avatar of [type] ("head", "left_controller", "right_controller"). */
  private fun attachmentQuery(type: String) =
    Query.where { has(AvatarAttachment.id) }.filter { isLocal() and by(AvatarAttachment.typeData).isEqualTo(type) }
}

/**
 * Edge detection of the buttons of each controller (or tracked hand), kept per entity from one update to the next.
 * A controller seen for the first time, one that becomes active or inactive, and one that switches between hand and
 * controller start again from the buttons they hold at that update: nothing counts as pressed then, so that neither a
 * stale state from before a sleep nor a pinch held while the hands take over fires an action. [log] receives each of
 * those transitions, for logcat. The right thumbstick held left or right repeats its press (see [TURN_BITS]): a
 * sweep around the sphere is one long push, not a series of flicks. Pure: no Spatial SDK call, unit tested.
 */
internal class ControllerEdges(private val log: (String) -> Unit = {}) {
  private class Seen(var active: Boolean, var type: String, var buttons: Int) {
    /** The turn direction being held, and when it fires again (uptime ms); 0 when none is held. */
    var turnBit = 0
    var turnRepeatAt = 0L
  }

  private val controllers = HashMap<Long, Seen>()

  /**
   * The buttons of controller [id] pressed since its previous update, given whether it is [active], its [type] and the
   * buttons it holds now at [nowMs] (uptime). A thumbstick push reports one direction only, see [firstDirectionOnly].
   * A turn direction of the right thumbstick ([TURN_BITS]) still held [TURN_REPEAT_DELAY_MS] after its press is
   * reported again, then every [TURN_REPEAT_INTERVAL_MS], until the stick comes back.
   */
  fun pressed(id: Long, active: Boolean, type: String, buttons: Int, nowMs: Long = 0L): Int {
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
      seen.turnBit = 0
      return 0
    }
    val before = seen.buttons
    seen.buttons = buttons
    var down = buttons and before.inv()
    down = firstDirectionOnly(down, before, LEFT_STICK)
    down = firstDirectionOnly(down, before, RIGHT_STICK)
    return down or turnRepeat(seen, down, buttons, nowMs)
  }

  /** The turn direction to report again because the right thumbstick is still held, or 0. */
  private fun turnRepeat(seen: Seen, down: Int, buttons: Int, nowMs: Long): Int {
    val pressedTurn = down and TURN_BITS
    if (pressedTurn != 0) {
      seen.turnBit = pressedTurn.takeLowestOneBit()
      seen.turnRepeatAt = nowMs + TURN_REPEAT_DELAY_MS
      return 0
    }
    if (seen.turnBit == 0) return 0
    if ((buttons and seen.turnBit) == 0) {
      seen.turnBit = 0
      return 0
    }
    if (nowMs < seen.turnRepeatAt) return 0
    seen.turnRepeatAt = nowMs + TURN_REPEAT_INTERVAL_MS
    return seen.turnBit
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

    /** The right thumbstick left or right turns the view, and keeps turning while held. */
    val TURN_BITS = ButtonBits.ButtonThumbRL or ButtonBits.ButtonThumbRR

    /** A push turns once at once; held past this delay it turns again, then at this interval. */
    const val TURN_REPEAT_DELAY_MS = 350L
    const val TURN_REPEAT_INTERVAL_MS = 220L
  }
}

/**
 * What the immersive viewer does with the buttons just pressed (ImmersiveInputSystem.Listener.onButtonsPressed),
 * decided apart from the viewer so that it can be tested:
 * - B or Y goes back to the app, and nothing else happens on that update;
 * - the left thumbstick left or right asks for the previous or the next media, the right thumbstick left or right
 *   turns the view (the way the right thumbstick turns in most headset apps, so that what is behind comes in front
 *   without turning the head, see [snapTurnDegrees]), either stick up or down seeks a video or turns a photo; the
 *   viewer shows all of them on its small feedback line, never by bringing the info panel up;
 * - A, X, grip or menu on a controller, and the menu gesture of a hand, show or hide the info panel; an index pinch
 *   (A or X of a hand) only shows a hidden panel, since a pinch on a panel button must not hide the panel it clicks;
 * - the trigger plays or pauses a video while the panel is hidden (on the panel it clicks a button).
 * Bits that only a controller has (B, Y, the thumbsticks) count as controller bits even when the SDK files them under
 * a hand: after the controllers wake up, the SDK may still take them for hands for a while.
 *
 * A 3D scene ([actionsFor] with scene, design-final 2026-10-27, section 3.3) takes the thumbsticks for itself: the left
 * one held glides the eye (read every frame, see [SceneStick]), the right one does nothing (a scene is frontal, turning
 * it would show the void), neither asks for previous or next, and a click of either one is [Action.RESET]. B, Y, A,
 * X, grip and menu do what they do everywhere; the trigger plays nothing.
 *
 * A flat screen ([actionsFor] with screenGrabbable: a photo of the stereo quad or a video of the flat video screen)
 * leaves the grips to [ScreenGrip], which tells a short press (the info panel, as everywhere) from a hold that grabs
 * the screen. While the screen is held (screenHeld: grabbed or stretched), either thumbstick up takes it farther
 * ([Action.SCREEN_FARTHER]) and down nearer ([Action.SCREEN_NEARER]), and left or right do nothing: neither previous,
 * next nor a turn comes from a hand busy with the screen. Gaurav Mukherjee's idea (gmfun/Immuch360, branch
 * quest/flat-3d), with the mapping FreeKC chose on 29 October.
 */
internal object ImmersiveControls {
  enum class Action {
    CLOSE,
    PREVIOUS,
    NEXT,
    TURN_LEFT,
    TURN_RIGHT,
    STICK_UP,
    STICK_DOWN,
    TOGGLE_PANEL,
    SHOW_PANEL,
    PLAY_PAUSE,
    RESET,
    SCREEN_FARTHER,
    SCREEN_NEARER,
  }

  /** A click of either thumbstick (ButtonBits exposes both, javap of 0.14.0: 0x10000 and 0x20000) */
  val STICK_CLICKS = ButtonBits.ButtonThumbLClick or ButtonBits.ButtonThumbRClick

  /** Either thumbstick pushed up, or down. */
  private val STICKS_UP = ButtonBits.ButtonThumbLU or ButtonBits.ButtonThumbRU
  private val STICKS_DOWN = ButtonBits.ButtonThumbLD or ButtonBits.ButtonThumbRD

  /**
   * The actions for [controllerBits] and [handBits] pressed on the same update, in the order to run them, in a 3D
   * [scene] or on any other media. [screenGrabbable]: the media is on a flat screen, whose grips [ScreenGrip] reads;
   * [screenHeld]: a grip holds that screen now.
   */
  fun actionsFor(
    controllerBits: Int,
    handBits: Int,
    panelVisible: Boolean,
    scene: Boolean = false,
    screenGrabbable: Boolean = false,
    screenHeld: Boolean = false,
  ): List<Action> {
    val controllerOnly =
      ButtonBits.ButtonB or ButtonBits.ButtonY or ControllerEdges.LEFT_STICK or ControllerEdges.RIGHT_STICK or
        STICK_CLICKS
    val controller = controllerBits or (handBits and controllerOnly)
    val hand = handBits and controllerOnly.inv()
    if ((controller and (ButtonBits.ButtonB or ButtonBits.ButtonY)) != 0) return listOf(Action.CLOSE)
    val actions = mutableListOf<Action>()
    val flatScreen = screenGrabbable && !scene
    when {
      scene -> if ((controller and STICK_CLICKS) != 0) actions += Action.RESET
      flatScreen && screenHeld ->
        when {
          (controller and STICKS_UP) != 0 -> actions += Action.SCREEN_FARTHER
          (controller and STICKS_DOWN) != 0 -> actions += Action.SCREEN_NEARER
        }
      (controller and ButtonBits.ButtonThumbLL) != 0 -> actions += Action.PREVIOUS
      (controller and ButtonBits.ButtonThumbLR) != 0 -> actions += Action.NEXT
      (controller and ButtonBits.ButtonThumbRL) != 0 -> actions += Action.TURN_LEFT
      (controller and ButtonBits.ButtonThumbRR) != 0 -> actions += Action.TURN_RIGHT
      (controller and (ButtonBits.ButtonThumbLU or ButtonBits.ButtonThumbRU)) != 0 -> actions += Action.STICK_UP
      (controller and (ButtonBits.ButtonThumbLD or ButtonBits.ButtonThumbRD)) != 0 -> actions += Action.STICK_DOWN
    }
    // On a flat screen a grip is a short press or a hold, which ScreenGrip tells apart once it is released or held
    val grips = if (flatScreen) 0 else ButtonBits.ButtonSqueezeL or ButtonBits.ButtonSqueezeR
    val panelToggle = ButtonBits.ButtonA or ButtonBits.ButtonX or ButtonBits.ButtonMenu or grips
    var visibleAfter = panelVisible
    if ((controller and panelToggle) != 0 || (hand and ButtonBits.ButtonMenu) != 0) {
      actions += Action.TOGGLE_PANEL
      visibleAfter = !panelVisible
    } else if (!panelVisible && (hand and (ButtonBits.ButtonA or ButtonBits.ButtonX)) != 0) {
      actions += Action.SHOW_PANEL
      visibleAfter = true
    }
    // With the panel shown, the trigger clicks its buttons instead; a scene has nothing to play
    if (!scene && !visibleAfter && (controller and (ButtonBits.ButtonTriggerL or ButtonBits.ButtonTriggerR)) != 0) {
      actions += Action.PLAY_PAUSE
    }
    return actions
  }

  /**
   * The yaw in degrees to add to the sphere of the media for [action]: [stepDegrees] one way or the other for a push
   * of the right thumbstick to the left ([Action.TURN_LEFT]) or to the right ([Action.TURN_RIGHT]), 0 for any other
   * action.
   *
   * The view turns the way the stick is pushed, as the snap turn of Meta's LocomotionSystem and of most headset apps
   * does: left turns the view to the left, so the image moves to the right of the user. The viewer turns the sphere
   * rather than the user, hence a positive yaw for a left push. In the coordinates of the Spatial SDK (left handed,
   * +x right, +y up, +z forward), Quaternion(0f, yaw, 0f) with a positive yaw takes what was in front of the user
   * (+z) towards the right (+x): the same view as the LocomotionSystem gives when it turns the view origin by a
   * negative yaw for a left push. [reversed] (the "Reverse thumbstick turn" setting) turns the other way, as
   * builds 17 to 28 did.
   */
  fun snapTurnDegrees(action: Action, stepDegrees: Float, reversed: Boolean): Float {
    val viewTurnsLeft =
      when (action) {
        Action.TURN_LEFT -> true
        Action.TURN_RIGHT -> false
        else -> return 0f
      }
    return if (viewTurnsLeft != reversed) stepDegrees else -stepDegrees
  }
}

/**
 * The left thumbstick held in a 3D scene (design-final 2026-10-27, section 3.3): the Controller component gives its
 * directions only, so the eye glides at one speed (SceneNavigator.GLIDE_SPEED), each axis one way, the other or not at
 * all, a diagonal on both (the navigator keeps it no faster than a straight push).
 */
internal object SceneStick {
  /** The push to the right and forward the buttons held [buttons] make, each -1, 0 or 1 */
  fun of(buttons: Int): Pair<Double, Double> {
    fun axis(plus: Int, minus: Int): Double =
      (if ((buttons and plus) != 0) 1.0 else 0.0) - (if ((buttons and minus) != 0) 1.0 else 0.0)
    return axis(ButtonBits.ButtonThumbLR, ButtonBits.ButtonThumbLL) to
      axis(ButtonBits.ButtonThumbLU, ButtonBits.ButtonThumbLD)
  }
}
