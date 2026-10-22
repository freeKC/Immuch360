package app.alextran.immich.djilink

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbManager
import android.os.BatteryManager
import android.os.Build
import android.provider.Settings
import app.alextran.immich.BuildConfig
import java.io.File

/**
 * What this device can do about a USB accessory, read on the device itself.
 *
 * Whether a headset can be the accessory end of Android Open Accessory at all is the first open question of this
 * work, and it is answered by the device and not by a document. So the page reads it here: the two USB features, the
 * accessory device node, the optional accessory library, the build, whether adb is on (an adb session holds the USB
 * gadget), whether the DJI application is installed (only one application at a time can hold the accessory), and the
 * current the port is giving us.
 */
data class UsbEnvironmentReport(
  val deviceManufacturer: String,
  val deviceModel: String,
  val buildFingerprint: String,
  val androidRelease: String,
  val sdkInt: Int,
  val appVersion: String,
  val flavour: String,
  val hasAccessoryFeature: Boolean,
  val hasHostFeature: Boolean,
  val accessoryNodeExists: Boolean,
  val accessoryNodeWritable: Boolean,
  val futureUsbLibraryPresent: Boolean,
  val adbEnabled: Boolean,
  val usbStateKnown: Boolean,
  val usbConnected: Boolean,
  val usbConfigured: Boolean,
  val usbAccessoryMode: Boolean,
  val usbAdbFunction: Boolean,
  val djiApplicationInstalled: Boolean,
  val chargeCurrentMicroAmps: Int?,
  val accessoriesListed: Int,
) {
  /** No accessory feature means no cable path on this device, whatever else is true */
  val transportPossible: Boolean get() = hasAccessoryFeature || accessoryNodeExists
}

object UsbEnvironment {
  /**
   * The sticky broadcast of the USB gadget state, with its boolean extras (connected, configured, accessory, adb).
   * The platform does not publish a constant for it, so the name is written out here once.
   */
  const val USB_STATE_ACTION = "android.hardware.usb.action.USB_STATE"

  /** The device node the accessory driver gives, one application at a time */
  const val ACCESSORY_NODE = "/dev/usb_accessory"

  /** The optional library of the old support API; the framework API needs none of it */
  const val FUTURE_USB_LIBRARY = "com.android.future.usb.accessory"

  /** The DJI controller application; named only to say whether it is installed */
  const val DJI_APPLICATION = "dji.go.v5"

  fun read(context: Context): UsbEnvironmentReport {
    val packages = context.packageManager
    val usb = context.getSystemService(Context.USB_SERVICE) as? UsbManager
    val node = File(ACCESSORY_NODE)
    val state = stickyUsbState(context)
    return UsbEnvironmentReport(
      deviceManufacturer = Build.MANUFACTURER ?: "",
      deviceModel = Build.MODEL ?: "",
      buildFingerprint = Build.FINGERPRINT ?: "",
      androidRelease = Build.VERSION.RELEASE ?: "",
      sdkInt = Build.VERSION.SDK_INT,
      appVersion = BuildConfig.VERSION_NAME,
      flavour = BuildConfig.FLAVOR,
      hasAccessoryFeature = packages.hasSystemFeature(PackageManager.FEATURE_USB_ACCESSORY),
      hasHostFeature = packages.hasSystemFeature(PackageManager.FEATURE_USB_HOST),
      accessoryNodeExists = node.exists(),
      accessoryNodeWritable = node.canWrite(),
      futureUsbLibraryPresent = runCatching {
        packages.systemSharedLibraryNames?.contains(FUTURE_USB_LIBRARY) == true
      }.getOrDefault(false),
      adbEnabled = runCatching {
        Settings.Global.getInt(context.contentResolver, Settings.Global.ADB_ENABLED, 0) == 1
      }.getOrDefault(false),
      usbStateKnown = state != null,
      usbConnected = state?.getBooleanExtra("connected", false) == true,
      usbConfigured = state?.getBooleanExtra("configured", false) == true,
      usbAccessoryMode = state?.getBooleanExtra("accessory", false) == true,
      usbAdbFunction = state?.getBooleanExtra("adb", false) == true,
      djiApplicationInstalled = runCatching {
        packages.getPackageInfo(DJI_APPLICATION, 0)
        true
      }.getOrDefault(false),
      chargeCurrentMicroAmps = chargeCurrent(context),
      accessoriesListed = runCatching { usb?.accessoryList?.size ?: 0 }.getOrDefault(0),
    )
  }

  /** The sticky broadcast of the USB gadget state, which says whether the port switched to accessory mode */
  private fun stickyUsbState(context: Context): Intent? = runCatching {
    context.registerReceiver(null, IntentFilter(USB_STATE_ACTION))
  }.getOrNull()

  private fun chargeCurrent(context: Context): Int? = runCatching {
    val battery = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager ?: return@runCatching null
    val current = battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
    if (current == Int.MIN_VALUE) null else current
  }.getOrNull()
}
