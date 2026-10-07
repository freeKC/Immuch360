package app.alextran.immich.spherical

import android.os.SystemClock
import android.view.Choreographer
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import kotlin.math.min

/** Where an arrow of the remote asks the 360° view to look */
internal enum class LookDirection {
  LEFT,
  RIGHT,
  UP,
  DOWN,
}

/**
 * The pure part of [RemoteLook], unit tested: how fast the view turns while an arrow is held, and where the synthetic
 * finger goes for it. The spherical view of Media3 turns by one degree per [PX_PER_DEGREE] pixels of drag, and the
 * scene follows the finger like with any drag on it: looking right moves the finger left, looking up moves it down.
 */
internal object RemoteLookMath {
  /** Pixels of drag per degree of turn in Media3's SphericalGLSurfaceView (its PX_PER_DEGREES) */
  const val PX_PER_DEGREE = 25f

  /** Up and down turn a little slower than left and right, as in the 360° photo viewer of Flutter */
  const val PITCH_FACTOR = 0.75f

  /**
   * Degrees per second once an arrow has been held for [heldSeconds]: a short press nudges the view by a few degrees,
   * holding accelerates up to a third of a turn per second. The ramp of the 360° photo viewer (remoteTurnSpeed in
   * Dart) without its field of view factor: the field of view of the Media3 view is fixed, 90 degrees.
   */
  fun speed(heldSeconds: Float): Float = min(40f + 160f * heldSeconds.coerceAtLeast(0f), 120f)

  /** How far the finger moves for [direction] during a frame of [frameSeconds], held for [heldSeconds] */
  fun pixels(direction: LookDirection, heldSeconds: Float, frameSeconds: Float): Float {
    val degrees = speed(heldSeconds) * frameSeconds.coerceAtLeast(0f)
    val factor = if (direction == LookDirection.UP || direction == LookDirection.DOWN) PITCH_FACTOR else 1f
    return degrees * factor * PX_PER_DEGREE
  }

  /** The horizontal move of the finger for [direction], in screen pixels per pixel of drag */
  fun fingerX(direction: LookDirection): Float =
    when (direction) {
      LookDirection.LEFT -> 1f
      LookDirection.RIGHT -> -1f
      else -> 0f
    }

  /** The vertical move of the finger for [direction]; the y axis of the screen points down */
  fun fingerY(direction: LookDirection): Float =
    when (direction) {
      LookDirection.UP -> 1f
      LookDirection.DOWN -> -1f
      else -> 0f
    }

  /**
   * The length of the first move, right after the finger goes down: just beyond [touchSlop], so that the gesture
   * detector of the view takes a drag at once, and never a tap (which toggles the controls) or a long press.
   */
  fun firstMove(touchSlop: Int): Float = touchSlop.coerceAtLeast(0) + 1f

  /** The direction of an arrow key of a remote, a keyboard or a game pad, null for any other key */
  fun directionOf(keyCode: Int): LookDirection? =
    when (keyCode) {
      KeyEvent.KEYCODE_DPAD_LEFT -> LookDirection.LEFT
      KeyEvent.KEYCODE_DPAD_RIGHT -> LookDirection.RIGHT
      KeyEvent.KEYCODE_DPAD_UP -> LookDirection.UP
      KeyEvent.KEYCODE_DPAD_DOWN -> LookDirection.DOWN
      else -> null
    }

  /** The OK key of a remote, Enter on a keyboard, A on a game pad */
  fun isOkKey(keyCode: Int): Boolean =
    keyCode == KeyEvent.KEYCODE_DPAD_CENTER ||
      keyCode == KeyEvent.KEYCODE_ENTER ||
      keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER ||
      keyCode == KeyEvent.KEYCODE_BUTTON_A
}

/**
 * Turns the spherical view of Media3 with the arrows of a remote control. The view has no API to turn it, so this
 * drags a synthetic finger across it, through public API only: the finger goes down at the centre and at once moves
 * beyond the touch slop (a drag, never a tap), then moves a little more at every frame while an arrow is held, faster
 * the longer it is held, and goes up when the last arrow is released. Two arrows held at once turn the view
 * diagonally. The events go to the spherical view alone: PlayerView would show or hide the controls for a touch.
 */
internal class RemoteLook(private val view: View) : Choreographer.FrameCallback {
  /** The arrows held, with when each went down (System.nanoTime, the clock of the frames) */
  private val held = LinkedHashMap<LookDirection, Long>()
  private var dragging = false
  private var downTime = 0L
  private var x = 0f
  private var y = 0f
  private var lastFrameNanos = 0L

  fun isHeld(direction: LookDirection): Boolean = direction in held

  /** [direction] went down: the view starts turning that way, together with the arrows already held */
  fun start(direction: LookDirection) {
    if (direction in held) return
    held[direction] = System.nanoTime()
    if (!dragging) beginDrag(direction)
  }

  /** [direction] went up: the view stops turning that way, and the finger lifts once no arrow is held */
  fun stop(direction: LookDirection) {
    if (held.remove(direction) == null) return
    if (held.isEmpty()) endDrag(MotionEvent.ACTION_UP)
  }

  /**
   * Ends the turn at once, without waiting for the keys: the activity stops, the window loses the focus (the key
   * releases go elsewhere then), a real finger touches the screen, or the controls show.
   */
  fun cancel() {
    held.clear()
    endDrag(MotionEvent.ACTION_CANCEL)
  }

  override fun doFrame(frameTimeNanos: Long) {
    if (!dragging) return
    if (lastFrameNanos != 0L) {
      val frameSeconds = (frameTimeNanos - lastFrameNanos) / 1e9f
      for ((direction, since) in held) {
        val pixels = RemoteLookMath.pixels(direction, (frameTimeNanos - since) / 1e9f, frameSeconds)
        x += RemoteLookMath.fingerX(direction) * pixels
        y += RemoteLookMath.fingerY(direction) * pixels
      }
      dispatch(MotionEvent.ACTION_MOVE)
    }
    lastFrameNanos = frameTimeNanos
    Choreographer.getInstance().postFrameCallback(this)
  }

  private fun beginDrag(first: LookDirection) {
    dragging = true
    downTime = SystemClock.uptimeMillis()
    x = view.width / 2f
    y = view.height / 2f
    dispatch(MotionEvent.ACTION_DOWN)
    val slop = RemoteLookMath.firstMove(ViewConfiguration.get(view.context).scaledTouchSlop)
    x += RemoteLookMath.fingerX(first) * slop
    y += RemoteLookMath.fingerY(first) * slop
    dispatch(MotionEvent.ACTION_MOVE)
    lastFrameNanos = 0L
    Choreographer.getInstance().postFrameCallback(this)
  }

  private fun endDrag(action: Int) {
    if (!dragging) return
    dragging = false
    Choreographer.getInstance().removeFrameCallback(this)
    dispatch(action)
  }

  private fun dispatch(action: Int) {
    val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, x, y, 0)
    event.source = InputDevice.SOURCE_TOUCHSCREEN
    view.dispatchTouchEvent(event)
    event.recycle()
  }
}
