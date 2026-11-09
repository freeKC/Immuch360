package app.alextran.immich.spatial

import android.app.ApplicationExitInfo
import org.junit.Assert.assertEquals
import org.junit.Test

/** How the end of the process that armed the GPU timers is read from its ApplicationExitInfo */
class PreferencesGpuTimerGuardStoreTest {
  private fun endOf(reason: Int, status: Int = 0) = PreferencesGpuTimerGuardStore.endOf(reason, status)

  @Test
  fun `a Java or native crash, or the signal of a native crash, is a crash`() {
    assertEquals(ArmedProcessEnd.CRASH, endOf(ApplicationExitInfo.REASON_CRASH_NATIVE, 11))
    assertEquals(ArmedProcessEnd.CRASH, endOf(ApplicationExitInfo.REASON_CRASH))
    for (signal in listOf(4, 6, 7, 8, 11)) {
      assertEquals("signal $signal", ArmedProcessEnd.CRASH, endOf(ApplicationExitInfo.REASON_SIGNALED, signal))
    }
  }

  @Test
  fun `the user, the low memory killer and an update are not the driver's`() {
    // A swipe from the recent apps is SIGKILL on many devices, a force stop REASON_USER_REQUESTED
    assertEquals(ArmedProcessEnd.OTHER, endOf(ApplicationExitInfo.REASON_SIGNALED, 9))
    assertEquals(ArmedProcessEnd.OTHER, endOf(ApplicationExitInfo.REASON_USER_REQUESTED))
    assertEquals(ArmedProcessEnd.OTHER, endOf(ApplicationExitInfo.REASON_LOW_MEMORY))
    assertEquals(ArmedProcessEnd.OTHER, endOf(ApplicationExitInfo.REASON_EXIT_SELF))
    assertEquals(ArmedProcessEnd.OTHER, endOf(ApplicationExitInfo.REASON_ANR))
    assertEquals(ArmedProcessEnd.OTHER, endOf(ApplicationExitInfo.REASON_OTHER))
  }

  @Test
  fun `an end Android does not know stays unknown, counted as a crash by the guard`() {
    assertEquals(ArmedProcessEnd.UNKNOWN, endOf(ApplicationExitInfo.REASON_UNKNOWN))
  }
}
