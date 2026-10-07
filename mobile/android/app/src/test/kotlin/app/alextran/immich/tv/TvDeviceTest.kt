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
}
