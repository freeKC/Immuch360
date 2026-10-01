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
 */
internal class ImmersiveInputSystem(private val listener: Listener) : SystemBase() {
  interface Listener {
    fun onButtonsPressed(controllerBits: Int, handBits: Int)

    fun onFrame(head: Pose?)
  }

  private val headQuery =
    Query.where { has(AvatarAttachment.id) }
      .filter { isLocal() and by(AvatarAttachment.typeData).isEqualTo("head") }

  override fun execute() {
    var controllerBits = 0
    var handBits = 0
    try {
      val controllers = Query.where { has(Controller.id) }.eval().filter { it.isLocal() }
      for (entity in controllers) {
        val controller = entity.getComponent<Controller>()
        if (!controller.isActive) continue
        val before = controller.buttonState xor controller.changedButtons
        var down = controller.buttonState and controller.changedButtons
        down = firstDirectionOnly(down, before, LEFT_STICK)
        down = firstDirectionOnly(down, before, RIGHT_STICK)
        if (down == 0) continue
        when (controller.type) {
          ControllerType.CONTROLLER -> controllerBits = controllerBits or down
          ControllerType.HAND -> handBits = handBits or down
          else -> Unit
        }
      }
    } catch (e: Exception) {
      Log.e(TAG, "controller polling failed", e)
    }
    if (controllerBits != 0 || handBits != 0) listener.onButtonsPressed(controllerBits, handBits)

    val head =
      try {
        headQuery.eval().firstOrNull()?.getComponent<Transform>()?.transform
      } catch (e: Exception) {
        Log.e(TAG, "head query failed", e)
        null
      }
    listener.onFrame(head)
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

  private companion object {
    /** Direction bits of each thumbstick. */
    val LEFT_STICK =
      ButtonBits.ButtonThumbLL or ButtonBits.ButtonThumbLR or ButtonBits.ButtonThumbLU or ButtonBits.ButtonThumbLD
    val RIGHT_STICK =
      ButtonBits.ButtonThumbRL or ButtonBits.ButtonThumbRR or ButtonBits.ButtonThumbRU or ButtonBits.ButtonThumbRD
  }
}
