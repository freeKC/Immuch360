package app.alextran.immich

import android.util.Log
import android.view.MotionEvent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs

/**
 * The thumbstick of a Meta Quest controller, which Horizon OS sends a 2D app as scroll events (AXIS_HSCROLL and
 * AXIS_VSCROLL) while the ray points at its window. Flutter turns them into pointer scrolls that the scrollables of the
 * page compete for, and the asset viewer does not reliably get them: a sideways push reaches it from here instead.
 * While the viewer asks for it ("setPaging"), a mostly horizontal scroll is taken from Flutter and sent as one "page"
 * call, 1 for right and -1 for left; the next one counts once the stick has been still for [REARM_MS].
 */
internal class QuestStickPaging(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
  private val channel = MethodChannel(messenger, CHANNEL)
  private var enabled = false
  private var used = false
  private var lastScrollAt = 0L

  init {
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "setPaging" -> {
        enabled = call.arguments as? Boolean ?: false
        used = false
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  fun dispose() {
    channel.setMethodCallHandler(null)
    enabled = false
  }

  /** True when [event] was a sideways push of the stick that the asset viewer takes. */
  fun onGenericMotion(event: MotionEvent): Boolean {
    if (!enabled || event.actionMasked != MotionEvent.ACTION_SCROLL) return false
    val horizontal = event.getAxisValue(MotionEvent.AXIS_HSCROLL)
    val vertical = event.getAxisValue(MotionEvent.AXIS_VSCROLL)
    if (horizontal == 0f || abs(horizontal) < abs(vertical)) return false
    val now = event.eventTime
    if (now - lastScrollAt > REARM_MS) used = false
    lastScrollAt = now
    if (!used) {
      used = true
      val step = if (horizontal > 0) 1 else -1
      Log.i(TAG, "thumbstick page $step (scroll $horizontal, source ${event.source})")
      channel.invokeMethod("page", step)
    }
    return true
  }

  private companion object {
    const val CHANNEL = "immuch360/quest_stick"
    const val TAG = "Immuch360"
    const val REARM_MS = 300L
  }
}
