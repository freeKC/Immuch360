package app.alextran.immich.spatial

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import app.alextran.immich.immersive.isHorizonOsDevice
import io.flutter.plugin.common.BinaryMessenger

private const val TAG = "SpatialVideoApi"

/** OpenGL ES 3.0, as reported by ConfigurationInfo.reqGlEsVersion (major version in the upper 16 bits) */
private const val GL_ES_3_0 = 0x30000

class SpatialVideoApiImpl(private val context: Context) : SpatialVideoApi {
  companion object {
    /**
     * Events towards Flutter, attached by MainActivity for the engine of the app UI and detached when that engine goes
     * away, so that a destroyed engine is not kept alive. The player activity runs on its own and only finds Flutter
     * through this. Read and written on the main thread.
     */
    @Volatile
    var events: SpatialVideoEvents? = null
      private set

    /** The messenger [events] sends through, to detach only the engine that attached */
    private var eventsMessenger: BinaryMessenger? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    fun attachEvents(messenger: BinaryMessenger) {
      eventsMessenger = messenger
      events = SpatialVideoEvents(messenger)
    }

    /** Drops the events only when they still belong to [messenger], so a newer MainActivity keeps its own */
    fun detachEvents(messenger: BinaryMessenger) {
      if (eventsMessenger === messenger) {
        eventsMessenger = null
        events = null
      }
    }

    /**
     * Tells Flutter the player closed, on the main thread as the Flutter API requires. [projection] is the one shown
     * last, with the coverage the user may have changed. The result is ignored. Without an engine for the app UI the
     * event is dropped: a new engine has no Spatial session to end.
     */
    fun notifyClosed(
      positionMs: Long,
      wasPlaying: Boolean,
      layout: SpatialStereoLayout,
      projection: SpatialProjection,
    ) {
      val send = Runnable {
        val current = events
        if (current == null) {
          Log.i(TAG, "No Flutter engine to tell that the player closed")
          return@Runnable
        }
        current.closed(positionMs, wasPlaying, layout, projection) { result ->
          result.exceptionOrNull()?.let { Log.w(TAG, "Flutter did not get the closed event", it) }
        }
      }
      if (Looper.myLooper() == Looper.getMainLooper()) {
        send.run()
      } else {
        mainHandler.post(send)
      }
    }
  }

  override fun capabilities(): SpatialCapabilities {
    val packageManager = context.packageManager
    val frontCamera = packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_FRONT)
    val cameraPermissionGranted =
      ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
    val glEsVersion =
      context.getSystemService(ActivityManager::class.java)?.deviceConfigurationInfo?.reqGlEsVersion ?: 0
    val reason = when {
      isHorizonOsDevice() -> "Not available on Meta Quest"
      glEsVersion < GL_ES_3_0 -> "OpenGL ES 3.0 is required, the device reports 0x${Integer.toHexString(glEsVersion)}"
      else -> null
    }
    return SpatialCapabilities(
      supported = reason == null,
      frontCamera = frontCamera,
      cameraPermissionGranted = cameraPermissionGranted,
      reason = reason,
    )
  }

  override fun open(request: SpatialOpenRequest) {
    val intent = SpatialVideoActivity.intent(context, request)
    if (context !is Activity) {
      intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    context.startActivity(intent)
  }
}
