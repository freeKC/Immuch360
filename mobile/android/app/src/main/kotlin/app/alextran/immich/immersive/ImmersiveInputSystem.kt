package app.alextran.immich.immersive

import android.util.Log
import com.meta.spatial.core.Pose
import com.meta.spatial.core.Query
import com.meta.spatial.core.SystemBase
import com.meta.spatial.toolkit.AvatarAttachment
import com.meta.spatial.toolkit.Controller
import com.meta.spatial.toolkit.ControllerType
import com.meta.spatial.toolkit.Transform

/**
 * Polls the controllers every frame, like the ControllerListenerSystem of Meta's SplatSample, and
 * reports the buttons just pressed plus the head pose. With hand tracking, A and X mean index
 * pinches, so hand buttons are reported separately.
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
        val down = controller.buttonState and controller.changedButtons
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
}
