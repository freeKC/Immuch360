package app.alextran.immich.filmdownload

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger

/**
 * Host side of the FilmDownloadApi pigeon: the foreground service of "Download" for the Plex films (see
 * [FilmDownloadService]) and the free room of the volume of the copies. The copy itself runs in Dart.
 */
class FilmDownloadApiImpl(context: Context) : FilmDownloadApi {
  private val appContext = context.applicationContext

  override fun startKeepAlive(notice: FilmDownloadNotice) {
    FilmDownloadService.start(appContext, FilmDownloadService.Notice.of(notice))
  }

  override fun updateKeepAlive(notice: FilmDownloadNotice) {
    FilmDownloadService.update(FilmDownloadService.Notice.of(notice))
  }

  override fun stopKeepAlive() {
    FilmDownloadService.stop(appContext)
  }

  override fun showEnd(notice: FilmDownloadEndNotice) {
    FilmDownloadService.showEnd(appContext, notice)
  }

  override fun cancelEnd(filmId: String) {
    FilmDownloadService.cancelEnd(appContext, filmId)
  }

  override fun freeBytes(path: String): Long? =
    try {
      StatFs(path).availableBytes
    } catch (e: IllegalArgumentException) {
      Log.i(TAG, "No free room known for the folder of the films: ${e.message}")
      null
    }

  companion object {
    private const val TAG = "FilmDownloadApi"
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Events towards Flutter, attached by MainActivity for the engine of the app UI and detached when that engine goes
     * away, as for the phone share. Read and written on the main thread.
     */
    @Volatile private var events: FilmDownloadEvents? = null

    /** The messenger [events] sends through, to detach only the engine that attached */
    private var eventsMessenger: BinaryMessenger? = null

    fun attachEvents(messenger: BinaryMessenger) {
      eventsMessenger = messenger
      events = FilmDownloadEvents(messenger)
    }

    /** Drops the events only when they still belong to [messenger], so a newer MainActivity keeps its own */
    fun detachEvents(messenger: BinaryMessenger) {
      if (eventsMessenger === messenger) {
        eventsMessenger = null
        events = null
      }
    }

    fun notifyPauseRequested() = tell("pause") { it.pauseRequested(::logFailure) }

    fun notifyCancelRequested() = tell("cancel") { it.cancelRequested(::logFailure) }

    private fun tell(what: String, send: (FilmDownloadEvents) -> Unit) {
      mainHandler.post {
        val current = events
        if (current == null) {
          Log.i(TAG, "no Flutter engine to tell the $what of a film download")
          return@post
        }
        send(current)
      }
    }

    private fun logFailure(result: Result<Unit>) {
      result.exceptionOrNull()?.let { Log.w(TAG, "Flutter did not get the action of the notification", it) }
    }
  }
}
