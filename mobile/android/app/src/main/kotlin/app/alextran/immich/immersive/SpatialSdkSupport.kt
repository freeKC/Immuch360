package app.alextran.immich.immersive

import android.os.Build

/**
 * Whether the Meta Spatial SDK loads on this headset, asked before any of its activities starts (the immersive viewer,
 * the flight view of a DJI drone).
 *
 * libMetaSpatialSDK.so of the SDK 0.14.0 needs `backtrace`, which bionic has from Android 13 (API 33, symbol version
 * LIBC_T). A Quest left on an older Horizon OS (v74 is Android 12L, API 32) fails in VrActivity.loadLibrary with
 * "dlopen failed: cannot locate symbol "backtrace"", an UnsatisfiedLinkError in onCreate that ends the whole app (Meta
 * signature 934bfc, a Quest 2 on Horizon OS 74, build 3030043). Such a headset gets a message instead, to update it.
 */
object SpatialSdkSupport {
  /** The SDK version whose library gave [MIN_SDK] (SpatialSdkSupportTest compares it with the version catalogue) */
  const val SDK_VERSION_CHECKED = "0.14.0"

  /** The oldest Android whose libc has every symbol libMetaSpatialSDK.so asks for */
  const val MIN_SDK = 33

  /** The error code [ImmersiveApiImpl.open] refuses with on such a headset, read by Flutter for its message */
  const val TOO_OLD_ERROR = "horizon_os_too_old"

  fun loads(sdkInt: Int): Boolean = sdkInt >= MIN_SDK

  /** True on a device whose Android loads the SDK */
  val here: Boolean
    get() = loads(Build.VERSION.SDK_INT)
}
