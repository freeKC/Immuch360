package app.alextran.immich.tv

import android.content.res.Configuration
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Which devices get the remote control layout by themselves: Android TV and Google TV, never a Meta Quest */
class TvDeviceTest {
  @Test
  fun leanbackAloneIsATelevision() {
    assertTrue(isTelevision(hasLeanback = true, uiModeType = Configuration.UI_MODE_TYPE_NORMAL, isHorizonOs = false))
  }

  @Test
  fun televisionUiModeAloneIsATelevision() {
    assertTrue(
      isTelevision(hasLeanback = false, uiModeType = Configuration.UI_MODE_TYPE_TELEVISION, isHorizonOs = false)
    )
  }

  @Test
  fun neitherIsNotATelevision() {
    assertFalse(isTelevision(hasLeanback = false, uiModeType = Configuration.UI_MODE_TYPE_NORMAL, isHorizonOs = false))
    assertFalse(isTelevision(hasLeanback = false, uiModeType = Configuration.UI_MODE_TYPE_DESK, isHorizonOs = false))
  }

  @Test
  fun horizonOsIsNeverATelevision() {
    assertFalse(isTelevision(hasLeanback = true, uiModeType = Configuration.UI_MODE_TYPE_TELEVISION, isHorizonOs = true))
    assertFalse(isTelevision(hasLeanback = true, uiModeType = Configuration.UI_MODE_TYPE_NORMAL, isHorizonOs = true))
    assertFalse(isTelevision(hasLeanback = false, uiModeType = Configuration.UI_MODE_TYPE_VR_HEADSET, isHorizonOs = true))
  }

  @Test
  fun lowRamIsTheFlagOrThreeGigabytesOrLess() {
    val gib = 1024L * 1024L * 1024L
    // A 2 GB TV without the flag, as most are, and a 3 GB one
    assertTrue(isLowRamDevice(lowRamFlag = false, totalMemBytes = 1_900_000_000L))
    assertTrue(isLowRamDevice(lowRamFlag = false, totalMemBytes = 2_900_000_000L))
    // A 4 GB box tells about 3.7 GB
    assertFalse(isLowRamDevice(lowRamFlag = false, totalMemBytes = 3_700_000_000L))
    assertFalse(isLowRamDevice(lowRamFlag = false, totalMemBytes = 8 * gib))
    assertTrue(isLowRamDevice(lowRamFlag = true, totalMemBytes = 8 * gib))
    assertFalse("unknown", isLowRamDevice(lowRamFlag = false, totalMemBytes = 0))
  }
}
