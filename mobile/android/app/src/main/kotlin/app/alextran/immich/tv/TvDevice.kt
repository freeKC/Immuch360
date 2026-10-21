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

/**
 * Whether the device is short of memory for the large pictures of the TV layout (the sharp texture of a 360° photo,
 * 134 MB): what the system tells of the device class (ActivityManager.isLowRamDevice, which makers set mostly on 1 GB
 * devices), or [LOW_RAM_TOTAL_BYTES] of memory or less, as most TVs and boxes have without the flag. Not the memory
 * pressure of the moment.
 */
internal fun isLowRamDevice(context: Context): Boolean {
  val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
  val memory = ActivityManager.MemoryInfo().also(activityManager::getMemoryInfo)
  return isLowRamDevice(activityManager.isLowRamDevice, memory.totalMem)
}

/** Pure part of [isLowRamDevice], unit tested: [totalMemBytes] as MemoryInfo.totalMem tells it, 0 when unknown */
internal fun isLowRamDevice(lowRamFlag: Boolean, totalMemBytes: Long): Boolean =
  lowRamFlag || totalMemBytes in 1..LOW_RAM_TOTAL_BYTES

/**
 * The memory of a 3 GB device as the system tells it (about 2.8 to 3.1 GB once the kernel and the GPU took their
 * part), below a 4 GB one (3.6 GB and more)
 */
internal const val LOW_RAM_TOTAL_BYTES = 3_400_000_000L
