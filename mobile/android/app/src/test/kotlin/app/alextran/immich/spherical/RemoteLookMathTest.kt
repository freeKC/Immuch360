package app.alextran.immich.spherical

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** How the arrows of a remote turn the native 360° video: the speed ramp, the pixels of drag, the directions */
class RemoteLookMathTest {
  @Test
  fun aShortPressNudgesAndHoldingAccelerates() {
    assertEquals(40f, RemoteLookMath.speed(0f), 0.001f)
    assertEquals(80f, RemoteLookMath.speed(0.25f), 0.001f)
    assertEquals(120f, RemoteLookMath.speed(0.5f), 0.001f)
    assertEquals(120f, RemoteLookMath.speed(10f), 0.001f)
    // A frame may start a little before the key went down
    assertEquals(40f, RemoteLookMath.speed(-0.01f), 0.001f)
  }

  @Test
  fun twentyFivePixelsPerDegree() {
    // 120 degrees per second for a 60 Hz frame: 2 degrees, 50 pixels
    assertEquals(50f, RemoteLookMath.pixels(LookDirection.RIGHT, 2f, 1f / 60f), 0.01f)
    assertEquals(50f, RemoteLookMath.pixels(LookDirection.LEFT, 2f, 1f / 60f), 0.01f)
    // Up and down at three quarters of that
    assertEquals(37.5f, RemoteLookMath.pixels(LookDirection.UP, 2f, 1f / 60f), 0.01f)
    assertEquals(37.5f, RemoteLookMath.pixels(LookDirection.DOWN, 2f, 1f / 60f), 0.01f)
    // The first frame of a press: 40 degrees per second
    assertEquals(40f * 25f / 60f, RemoteLookMath.pixels(LookDirection.RIGHT, 0f, 1f / 60f), 0.01f)
    assertEquals(0f, RemoteLookMath.pixels(LookDirection.RIGHT, 1f, -0.5f), 0f)
  }

  @Test
  fun theSceneFollowsTheFinger() {
    // Looking right drags the scene to the left, looking up drags it down (the y axis of the screen points down)
    assertEquals(-1f, RemoteLookMath.fingerX(LookDirection.RIGHT), 0f)
    assertEquals(1f, RemoteLookMath.fingerX(LookDirection.LEFT), 0f)
    assertEquals(0f, RemoteLookMath.fingerX(LookDirection.UP), 0f)
    assertEquals(0f, RemoteLookMath.fingerX(LookDirection.DOWN), 0f)
    assertEquals(1f, RemoteLookMath.fingerY(LookDirection.UP), 0f)
    assertEquals(-1f, RemoteLookMath.fingerY(LookDirection.DOWN), 0f)
    assertEquals(0f, RemoteLookMath.fingerY(LookDirection.LEFT), 0f)
    assertEquals(0f, RemoteLookMath.fingerY(LookDirection.RIGHT), 0f)
  }

  @Test
  fun theFirstMoveIsBeyondTheTouchSlop() {
    assertTrue(RemoteLookMath.firstMove(21) > 21f)
    assertTrue(RemoteLookMath.firstMove(8) > 8f)
    assertTrue(RemoteLookMath.firstMove(0) > 0f)
    assertTrue(RemoteLookMath.firstMove(-3) > 0f)
  }

  @Test
  fun theArrowsAndOk() {
    assertEquals(LookDirection.LEFT, RemoteLookMath.directionOf(KeyEvent.KEYCODE_DPAD_LEFT))
    assertEquals(LookDirection.RIGHT, RemoteLookMath.directionOf(KeyEvent.KEYCODE_DPAD_RIGHT))
    assertEquals(LookDirection.UP, RemoteLookMath.directionOf(KeyEvent.KEYCODE_DPAD_UP))
    assertEquals(LookDirection.DOWN, RemoteLookMath.directionOf(KeyEvent.KEYCODE_DPAD_DOWN))
    assertNull(RemoteLookMath.directionOf(KeyEvent.KEYCODE_DPAD_CENTER))
    assertNull(RemoteLookMath.directionOf(KeyEvent.KEYCODE_MEDIA_FAST_FORWARD))
    assertNull(RemoteLookMath.directionOf(KeyEvent.KEYCODE_BACK))

    assertTrue(RemoteLookMath.isOkKey(KeyEvent.KEYCODE_DPAD_CENTER))
    assertTrue(RemoteLookMath.isOkKey(KeyEvent.KEYCODE_ENTER))
    assertTrue(RemoteLookMath.isOkKey(KeyEvent.KEYCODE_NUMPAD_ENTER))
    assertTrue(RemoteLookMath.isOkKey(KeyEvent.KEYCODE_BUTTON_A))
    assertFalse(RemoteLookMath.isOkKey(KeyEvent.KEYCODE_BACK))
    assertFalse(RemoteLookMath.isOkKey(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
    assertFalse(RemoteLookMath.isOkKey(KeyEvent.KEYCODE_DPAD_LEFT))
  }
}
