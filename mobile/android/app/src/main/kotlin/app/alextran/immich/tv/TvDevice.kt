package app.alextran.immich.tv

import android.app.ActivityManager
import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import app.alextran.immich.immersive.isHorizonOsDevice

/**
 * True on Android TV and Google TV: the leanback feature, or the television UI mode of boxes that do not declare it.
 * Never on a Meta Quest.
 */
internal fun isTelevision(context: Context): Boolean =
  isTelevision(
    hasLeanback = context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK),
    uiModeType = (context.getSystemService(Context.UI_MODE_SERVICE) as UiModeManager).currentModeType,
    isHorizonOs = isHorizonOsDevice(),
  )

/**
 * Pure part, unit tested. The leanback feature is the check Google documents; the UI mode catches the uncertified
 * boxes and projectors that run a TV launcher without declaring it.
 */
internal fun isTelevision(hasLeanback: Boolean, uiModeType: Int, isHorizonOs: Boolean): Boolean =
  !isHorizonOs && (hasLeanback || uiModeType == Configuration.UI_MODE_TYPE_TELEVISION)

/** What the system tells of the device class, not the memory pressure of the moment */
internal fun isLowRamDevice(context: Context): Boolean =
  (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).isLowRamDevice
