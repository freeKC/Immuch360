package app.alextran.immich.pairing

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import com.google.zxing.client.android.Intents
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanIntentResult
import com.journeyapps.barcodescanner.ScanOptions

/**
 * The scanner of "Connect a TV or computer" (sign in with your phone): ZXing Android Embedded, which needs no Google
 * Play services (the F-Droid build excludes them). The camera permission is asked first through the Activity Result
 * API, so that a refusal comes back to Flutter as such rather than as a closed scanner. What the code says goes to
 * Flutter only: never to the log.
 */
class QrScanApiImpl(private val activity: ComponentActivity) : QrScanApi {
  private var pending: ((Result<QrScanResult>) -> Unit)? = null
  private var sequence = 0

  override fun scan(prompt: String, cancelLabel: String, callback: (Result<QrScanResult>) -> Unit) {
    if (pending != null) {
      callback(Result.success(QrScanResult(QrScanStatus.FAILED)))
      return
    }
    if (!activity.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)) {
      callback(Result.success(QrScanResult(QrScanStatus.NO_CAMERA)))
      return
    }
    pending = callback
    if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
      launch(prompt)
      return
    }
    // Registered at the call rather than with the activity: register() without a lifecycle owner may come at any time
    lateinit var permission: ActivityResultLauncher<String>
    permission = activity.activityResultRegistry.register(
      "immuch360-qr-permission-${sequence++}",
      ActivityResultContracts.RequestPermission(),
    ) { granted ->
      permission.unregister()
      if (granted) launch(prompt) else finish(QrScanResult(QrScanStatus.PERMISSION_DENIED))
    }
    permission.launch(Manifest.permission.CAMERA)
  }

  private fun launch(prompt: String) {
    lateinit var scanner: ActivityResultLauncher<ScanOptions>
    scanner = activity.activityResultRegistry.register("immuch360-qr-scan-${sequence++}", ScanContract()) { result ->
      scanner.unregister()
      finish(resultOf(result))
    }
    try {
      scanner.launch(
        ScanOptions()
          .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
          .setPrompt(prompt)
          .setBeepEnabled(false)
          .setBarcodeImageEnabled(false)
          .setOrientationLocked(false),
      )
    } catch (e: Exception) {
      scanner.unregister()
      finish(QrScanResult(QrScanStatus.FAILED))
    }
  }

  private fun finish(result: QrScanResult) {
    val callback = pending ?: return
    pending = null
    callback(Result.success(result))
  }

  companion object {
    /** The Pigeon result of what the scanner of ZXing gave */
    fun resultOf(result: ScanIntentResult): QrScanResult = resultOf(
      contents = result.contents,
      // Set by ZXing's CaptureActivity when it closed for want of the camera permission
      missingCameraPermission = result.originalIntent?.hasExtra(Intents.Scan.MISSING_CAMERA_PERMISSION) == true,
    )

    fun resultOf(contents: String?, missingCameraPermission: Boolean): QrScanResult = when {
      contents != null -> QrScanResult(QrScanStatus.SCANNED, contents)
      missingCameraPermission -> QrScanResult(QrScanStatus.PERMISSION_DENIED)
      else -> QrScanResult(QrScanStatus.CANCELLED)
    }
  }
}
