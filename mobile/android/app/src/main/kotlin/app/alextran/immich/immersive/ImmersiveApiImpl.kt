package app.alextran.immich.immersive

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger

/**
 * Host side of the ImmersiveApi pigeon: device detection, launch of the immersive viewer, and the media Flutter
 * shows in place when the viewer asks for the previous or the next one.
 */
class ImmersiveApiImpl(context: Context) : ImmersiveApi {
  private val appContext = context.applicationContext

  companion object {
    /**
     * Events towards Flutter, attached by MainActivity for the engine of the app UI and detached when that engine goes
     * away, so that a destroyed engine is not kept alive. The viewer is its own activity and only finds Flutter
     * through this. Read and written on the main thread.
     */
    @Volatile
    var events: ImmersiveEvents? = null
      private set

    /** The messenger [events] sends through, to detach only the engine that attached */
    private var eventsMessenger: BinaryMessenger? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    fun attachEvents(messenger: BinaryMessenger) {
      eventsMessenger = messenger
      events = ImmersiveEvents(messenger)
    }

    /** Drops the events only when they still belong to [messenger], so a newer MainActivity keeps its own */
    fun detachEvents(messenger: BinaryMessenger) {
      if (eventsMessenger === messenger) {
        eventsMessenger = null
        events = null
      }
    }

    /** Runs [block] on the main thread, the only thread the Flutter API may be called from. */
    private fun onMainThread(block: () -> Unit) {
      if (Looper.myLooper() == Looper.getMainLooper()) block() else mainHandler.post { block() }
    }

    /**
     * Tells Flutter the viewer of [openingId] closed on the media at [url] (the one shown last, which may be a previous
     * or next one), with the stereo layout and the coverage it showed and the playback position of a video
     * ([positionMs], 0 for a photo), so that the app keeps the corrections for that media and resumes its flat player
     * there. Flutter drops the event of an opening it no longer follows. The result is ignored. Without an engine for
     * the app UI the event is dropped.
     */
    fun notifyClosed(
      openingId: Long,
      url: String,
      stereoLayout: ImmersiveStereoLayout,
      coverage: ImmersiveSphereCoverage,
      positionMs: Long,
    ) {
      onMainThread {
        val current = events
        if (current == null) {
          Log.i(TAG, "no Flutter engine to tell that the immersive viewer closed")
          return@onMainThread
        }
        current.closed(openingId, url, stereoLayout, coverage, positionMs) { result ->
          result.exceptionOrNull()?.let { Log.w(TAG, "Flutter did not get the closed event", it) }
        }
      }
    }

    /**
     * Asks Flutter, under [requestId], for the media [step] places away from the one shown (+1 next, -1 previous) in
     * the viewer of [openingId]. [stereoLayout] and [coverage] are what the viewer shows now, which the app keeps for
     * that media before moving on. [callback] runs on the main thread with true once Flutter found one and showed it
     * through [showAdjacent] with the same [requestId], false when there is none in that direction, Flutter gave up,
     * or Flutter no longer follows that opening, and null when no app engine can answer: none attached, or the
     * message did not reach a Dart handler. An error thrown on the Dart side also gives null, the viewer then tells
     * the user to go back to the app, where the media can still be changed.
     */
    fun requestAdjacent(
      openingId: Long,
      requestId: Long,
      step: Int,
      stereoLayout: ImmersiveStereoLayout,
      coverage: ImmersiveSphereCoverage,
      callback: (Boolean?) -> Unit,
    ) {
      onMainThread {
        val current = events
        if (current == null) {
          Log.i(TAG, "no Flutter engine to ask for the adjacent media")
          callback(null)
          return@onMainThread
        }
        current.requestAdjacent(openingId, requestId, step.toLong(), stereoLayout, coverage) { result ->
          result.exceptionOrNull()?.let { Log.w(TAG, "Flutter did not answer the adjacent media request", it) }
          callback(result.getOrNull())
        }
      }
    }
  }

  override fun isHorizonOs(): Boolean = isHorizonOsDevice()

  /**
   * [headers] stays in the pigeon signature but is ignored: HttpClientManager already adds the user's custom
   * headers (and the session cookie) to every OkHttp and Cronet request, adding them again would duplicate them.
   * [stereoLayout] is the 3D layout Flutter guessed from the media size, [stereoLabels] the translated labels of
   * the 3D control and of the field of view control ("coverage", "coverage_full", "coverage_half"). [coverage] is
   * how much of the sphere the media covers: all of it, or the front half for a VR180 media. [startPositionMs] is
   * where a video starts, so that the immersive view carries on from the flat player. [openingId] identifies this
   * opening: the viewer sends it back with every event, so that Flutter can tell the events of the viewer it follows
   * from those of an earlier one. While the viewer is in front, a new open from the app replaces its media in place
   * as a fresh opening, with its own id (the activity is single task and gets the intent in onNewIntent). Previous
   * and next never come this way, see [showAdjacent]. [fallbackUrl] is the server's transcoded stream of a video,
   * played once instead of [url] when the headset cannot decode the original or when it fails. [rawProjection] is the
   * JSON calibration of a raw dual fisheye video, which the viewer stitches on the headset; null for an
   * equirectangular media and for a raw photo, which Flutter stitched already.
   */
  override fun open(
    url: String,
    headers: Map<String, String>,
    isVideo: Boolean,
    title: String,
    stereoLayout: ImmersiveStereoLayout,
    stereoLabels: Map<String, String>,
    coverage: ImmersiveSphereCoverage,
    startPositionMs: Long,
    openingId: Long,
    fallbackUrl: String?,
    rawProjection: String?,
  ) {
    if (!isHorizonOsDevice()) {
      throw FlutterError("unsupported", "The immersive viewer needs a Meta Quest headset", null)
    }
    Log.i(
      TAG,
      "open immersive viewer, opening $openingId, video=$isVideo, 3D layout=$stereoLayout, coverage=$coverage, " +
        "start=$startPositionMs ms, fallback=${fallbackUrl != null}, raw=${rawProjection != null}",
    )
    appContext.startActivity(
      ImmersiveViewerActivity.intent(
        appContext,
        url,
        isVideo,
        title,
        stereoLayout,
        stereoLabels,
        coverage,
        startPositionMs,
        openingId,
        fallbackUrl,
        rawProjection,
      ),
    )
  }

  /**
   * Answers ImmersiveEvents.requestAdjacent: shows the media in place in the viewer that asked, if it still waits for
   * [requestId], and never starts the viewer. The answer must be known before returning, which the main thread gives:
   * Pigeon calls a host API there (no task queue), the thread the viewer lives on. Called from another thread, the
   * media is refused rather than shown from the wrong thread. [fallbackUrl] is the transcoded stream of a video and
   * [rawProjection] the calibration of a raw dual fisheye video, as for [open].
   */
  override fun showAdjacent(
    requestId: Long,
    url: String,
    isVideo: Boolean,
    title: String,
    stereoLayout: ImmersiveStereoLayout,
    coverage: ImmersiveSphereCoverage,
    fallbackUrl: String?,
    rawProjection: String?,
  ): Boolean {
    if (Looper.myLooper() != Looper.getMainLooper()) {
      Log.e(TAG, "showAdjacent called off the main thread, request $requestId refused")
      return false
    }
    Log.i(
      TAG,
      "adjacent media for request $requestId, video=$isVideo, 3D layout=$stereoLayout, coverage=$coverage, " +
        "fallback=${fallbackUrl != null}, raw=${rawProjection != null}",
    )
    return ImmersiveViewerActivity.showAdjacent(
      requestId,
      url,
      isVideo,
      title,
      stereoLayout,
      coverage,
      fallbackUrl,
      rawProjection,
    )
  }
}
