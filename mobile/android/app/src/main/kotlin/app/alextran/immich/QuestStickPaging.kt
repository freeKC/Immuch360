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
 * While the viewer asks for it ("setPaging"), a mostly horizontal scroll is taken from Flutter and a push sends one
 * "page" call, 1 for right and -1 for left (see [StickPushDetector]). Made on a Meta Quest only (see [attach]).
 */
internal class QuestStickPaging(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
  private val channel = MethodChannel(messenger, CHANNEL)
  private val pushes = StickPushDetector()
  private var enabled = false

  init {
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "setPaging" -> {
        enabled = call.arguments as? Boolean ?: false
        pushes.reset()
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  fun dispose() {
    channel.setMethodCallHandler(null)
    enabled = false
  }

  /** True when [event] was a sideways scroll of the stick that the asset viewer takes. */
  fun onGenericMotion(event: MotionEvent): Boolean {
    if (!enabled || event.actionMasked != MotionEvent.ACTION_SCROLL) return false
    val horizontal = event.getAxisValue(MotionEvent.AXIS_HSCROLL)
    val push = pushes.onScroll(horizontal, event.getAxisValue(MotionEvent.AXIS_VSCROLL), event.eventTime)
    if (push.step != 0) {
      Log.i(TAG, "thumbstick page ${push.step} (scroll $horizontal, source ${event.source})")
      channel.invokeMethod("page", push.step)
    }
    return push != StickPush.IGNORE
  }

  companion object {
    private const val CHANNEL = "immuch360/quest_stick"
    private const val TAG = "Immuch360"

    /**
     * The paging channel of [messenger] on a Meta Quest ([horizonOs], see isHorizonOsDevice), null on any other
     * device: a phone, a tablet or a TV keeps every scroll event as it comes, and nothing there answers "setPaging",
     * which the asset viewer only sends on Horizon OS.
     */
    fun attach(messenger: BinaryMessenger, horizonOs: Boolean): QuestStickPaging? =
      if (horizonOs) QuestStickPaging(messenger) else null
  }
}

/** What a scroll of the thumbstick does: [step] pages away from the asset on screen, 0 for none. */
internal enum class StickPush(val step: Int) {
  /** Not a sideways scroll: left to Flutter. */
  IGNORE(0),

  /** Taken without paging: the push already paged, or the scroll is too small to count. */
  HOLD(0),
  PREVIOUS(-1),
  NEXT(1),
}

/**
 * Tells the pushes of the thumbstick apart in the scroll events it sends, pure so that it can be tested: a scroll
 * mostly vertical, or none, is left to the page; a sideways one is taken. The first one at least [DEADZONE] wide pages
 * once, the left or the right way; the scrolls that follow it the same way are the same push until none came for
 * [REARM_MS]. A push the other way pages at once. The smaller scrolls (the stick coming back to the middle, or resting
 * a little off it) are taken too, without paging, and do not keep a push going.
 */
internal class StickPushDetector {
  /** The way of the push going on, 1 right or -1 left, 0 for none. */
  private var direction = 0

  /** When its last scroll at least [DEADZONE] wide came, in the uptime milliseconds of the events. */
  private var lastAt = 0L

  fun onScroll(horizontal: Float, vertical: Float, timeMs: Long): StickPush {
    if (horizontal == 0f || abs(horizontal) < abs(vertical)) return StickPush.IGNORE
    if (abs(horizontal) < DEADZONE) return StickPush.HOLD
    val way = if (horizontal > 0f) 1 else -1
    val held = way == direction && timeMs - lastAt <= REARM_MS
    direction = way
    lastAt = timeMs
    return when {
      held -> StickPush.HOLD
      way > 0 -> StickPush.NEXT
      else -> StickPush.PREVIOUS
    }
  }

  /** Forgets the push going on: the next sideways scroll pages. */
  fun reset() {
    direction = 0
  }

  companion object {
    /**
     * The smallest sideways scroll that pages, small enough for any push of the stick: the value of each push that
     * pages is in its log line, for the check on the headset.
     */
    const val DEADZONE = 0.05f

    /** A pause in the scrolls this long ends a push: a stick pushed and held sends them far closer together. */
    const val REARM_MS = 300L
  }
}
