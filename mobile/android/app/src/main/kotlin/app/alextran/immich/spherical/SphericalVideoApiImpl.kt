package app.alextran.immich.spherical

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger

private const val TAG = "SphericalVideoApi"

class SphericalVideoApiImpl(private val context: Context) : SphericalVideoApi {
  companion object {
    /**
     * Events towards Flutter, attached by MainActivity for the engine of the app UI and detached when that engine goes
     * away, so that a destroyed engine is not kept alive. The player activity runs on its own and only finds Flutter
     * through this. Read and written on the main thread.
     */
    @Volatile
    var events: SphericalVideoEvents? = null
      private set

    /** The messenger [events] sends through, to detach only the engine that attached */
    private var eventsMessenger: BinaryMessenger? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    fun attachEvents(messenger: BinaryMessenger) {
      eventsMessenger = messenger
      events = SphericalVideoEvents(messenger)
    }

    /** Drops the events only when they still belong to [messenger], so a newer MainActivity keeps its own */
    fun detachEvents(messenger: BinaryMessenger) {
      if (eventsMessenger === messenger) {
        eventsMessenger = null
        events = null
      }
    }

    /**
     * Tells Flutter the player closed, with the stereo layout and the coverage it showed last, on the main thread as
     * the Flutter API requires. The result is ignored. Without an engine for the app UI the event is dropped.
     */
    fun notifyClosed(stereoLayout: StereoLayout, coverage: SphereCoverage) {
      val send = Runnable {
        val current = events
        if (current == null) {
          Log.i(TAG, "No Flutter engine to tell that the player closed")
          return@Runnable
        }
        current.closed(stereoLayout, coverage) { result ->
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

  override fun open(
    url: String,
    headers: Map<String, String>,
    title: String,
    closeLabel: String?,
    errorMessage: String?,
    stereoLayout: StereoLayout,
    stereoLabels: Map<String, String>,
    coverage: SphereCoverage,
  ) {
    val intent = SphericalVideoActivity.intent(
      context,
      url,
      headers,
      title,
      closeLabel,
      errorMessage,
      stereoLayout,
      stereoLabels,
      coverage,
    )
    if (context !is Activity) {
      intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    context.startActivity(intent)
  }
}
