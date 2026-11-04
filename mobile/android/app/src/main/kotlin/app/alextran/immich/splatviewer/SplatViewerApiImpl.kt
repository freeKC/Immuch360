package app.alextran.immich.splatviewer

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.util.Log
import android.webkit.WebView
import io.flutter.plugin.common.BinaryMessenger

private const val TAG = "SplatViewerApi"

/** Opens and closes SplatViewerActivity for Flutter, and tells Flutter how it closed (SplatViewerEvents) */
class SplatViewerApiImpl(private val context: Context) : SplatViewerApi {
  companion object {
    /** Events towards the engine of the app UI, attached by MainActivity, as for the 360° player */
    @Volatile
    private var events: SplatViewerEvents? = null
    private var eventsMessenger: BinaryMessenger? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun attachEvents(messenger: BinaryMessenger) {
      eventsMessenger = messenger
      events = SplatViewerEvents(messenger)
    }

    fun detachEvents(messenger: BinaryMessenger) {
      if (eventsMessenger === messenger) {
        eventsMessenger = null
        events = null
      }
    }

    /** Tells Flutter the viewer of the viewing [viewing] closed, on the main thread; dropped without an engine */
    fun notifyClosed(reason: String, viewing: Long) {
      val send = Runnable {
        val current = events
        if (current == null) {
          Log.i(TAG, "No Flutter engine to tell that the splat viewer closed")
          return@Runnable
        }
        current.closed(reason, viewing) { result ->
          result.exceptionOrNull()?.let { Log.w(TAG, "Flutter did not get the closed event", it) }
        }
      }
      if (Looper.myLooper() == Looper.getMainLooper()) send.run() else mainHandler.post(send)
    }
  }

  override fun open(pageUrl: String, title: String, viewing: Long) {
    val intent = SplatViewerActivity.intent(context, pageUrl, title, viewing)
    if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    context.startActivity(intent)
  }

  override fun close() {
    mainHandler.post { SplatViewerActivity.current?.finishWith("user") }
  }

  override fun webViewMajorVersion(): Long =
    SplatViewerRules.majorOf(WebView.getCurrentWebViewPackage()?.versionName).toLong()

  override fun freeBytes(folder: String): Long =
    try {
      StatFs(folder).availableBytes
    } catch (e: IllegalArgumentException) {
      Log.w(TAG, "No free space for $folder", e)
      -1L
    }
}
