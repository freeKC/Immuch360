package app.alextran.immich.filmdownload

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import app.alextran.immich.R

/**
 * Keeps "Download" of a Plex film running while the screen is off or another app is in front: a foreground service of
 * type dataSync with an ongoing notification that tells the film, its progress and the time left, and offers Pause and
 * Cancel. It holds a Wi-Fi lock, so that the Wi-Fi does not doze under a long copy, and a partial wake lock, so that
 * the Dart copy keeps running.
 *
 * The copy itself runs in the Flutter engine of the app, through the pinned client of the server with the token in its
 * header: the service never sees an address or the token. It never starts by itself ([START_NOT_STICKY]); it stops
 * when Flutter has no copy running any more, from its actions (Flutter is told, see [FilmDownloadApiImpl]), with the
 * task of the app (swiped away: the engine and the copy are gone too, and the copy goes on at the next start), or when
 * Android ends the time of a dataSync service (Android 15 and later).
 */
class FilmDownloadService : Service() {
  private var wifiLock: WifiManager.WifiLock? = null
  private var wakeLock: PowerManager.WakeLock? = null
  private var notice: Notice = Notice.DEFAULT

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    when (intent?.action) {
      ACTION_PAUSE -> {
        Log.i(TAG, "Pause from the notification")
        FilmDownloadApiImpl.notifyPauseRequested()
        return START_NOT_STICKY
      }
      ACTION_CANCEL -> {
        Log.i(TAG, "Cancel from the notification")
        FilmDownloadApiImpl.notifyCancelRequested()
        return START_NOT_STICKY
      }
    }
    pending?.let { notice = it }
    try {
      createChannel()
      ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(), foregroundType())
    } catch (e: Exception) {
      // Started from the background (Android 12 and later refuse it) or a refused type: the copy still runs while the
      // app is in front
      Log.w(TAG, "The film download cannot run in the foreground", e)
      stopSelf()
      return START_NOT_STICKY
    }
    acquireLocks()
    running = this
    return START_NOT_STICKY
  }

  override fun onTimeout(startId: Int, fgsType: Int) {
    // Android 15 and later give a dataSync service six hours a day: the copy goes on while the app runs, and from where
    // it stopped at its next start
    Log.w(TAG, "Android ended the time of the film download service")
    stopSelf()
  }

  override fun onTaskRemoved(rootIntent: Intent?) {
    Log.i(TAG, "Task removed, the film download service stops")
    stopSelf()
    super.onTaskRemoved(rootIntent)
  }

  override fun onDestroy() {
    if (running === this) {
      running = null
    }
    releaseLocks()
    super.onDestroy()
  }

  internal fun show(next: Notice) {
    notice = next
    try {
      NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, buildNotification())
    } catch (e: SecurityException) {
      // Notifications refused (Android 13 and later): the service keeps running without them
      Log.i(TAG, "The notification cannot be updated: ${e.message}")
    }
  }

  private fun createChannel() {
    val channel =
      NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
        .setName(notice.channelName)
        .setShowBadge(false)
        .build()
    NotificationManagerCompat.from(this).createNotificationChannel(channel)
  }

  private fun buildNotification(): Notification {
    val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
      PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }
    val pause =
      PendingIntent.getService(
        this,
        1,
        Intent(this, FilmDownloadService::class.java).setAction(ACTION_PAUSE),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
      )
    val cancel =
      PendingIntent.getService(
        this,
        2,
        Intent(this, FilmDownloadService::class.java).setAction(ACTION_CANCEL),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
      )
    val indeterminate = notice.progress < 0
    return NotificationCompat.Builder(this, CHANNEL_ID)
      .setSmallIcon(R.drawable.notification_icon)
      .setContentTitle(notice.title)
      .setContentText(notice.text)
      .setProgress(PROGRESS_MAX, if (indeterminate) 0 else notice.progress.coerceIn(0, PROGRESS_MAX), indeterminate)
      .setOngoing(true)
      .setOnlyAlertOnce(true)
      .setSilent(true)
      .setCategory(NotificationCompat.CATEGORY_PROGRESS)
      .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
      .setContentIntent(open)
      .addAction(0, notice.pauseLabel, pause)
      .addAction(0, notice.cancelLabel, cancel)
      .build()
  }

  private fun foregroundType(): Int =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0

  private fun acquireLocks() {
    if (wifiLock == null) {
      val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
      @Suppress("DEPRECATION")
      wifiLock =
        wifi?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, LOCK_TAG)?.apply {
          setReferenceCounted(false)
          acquire()
        }
    }
    if (wakeLock == null) {
      val power = getSystemService(Context.POWER_SERVICE) as? PowerManager
      wakeLock =
        power?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, LOCK_TAG)?.apply {
          setReferenceCounted(false)
          // A bound in case the service outlives the copy; Flutter stops it once no copy runs
          acquire(WAKE_LOCK_LIMIT_MS)
        }
    }
  }

  private fun releaseLocks() {
    wifiLock?.let { if (it.isHeld) it.release() }
    wifiLock = null
    wakeLock?.let { if (it.isHeld) it.release() }
    wakeLock = null
  }

  /** The texts of the notification, cut to what a notification shows; English when Flutter sent none */
  data class Notice(
    val channelName: String,
    val title: String,
    val text: String,
    val progress: Int,
    val pauseLabel: String,
    val cancelLabel: String,
  ) {
    companion object {
      private const val MAX_LENGTH = 200
      private val CONTROL = Regex("[\\u0000-\\u001f\\u007f]+")

      val DEFAULT = Notice("Film downloads", "Downloading a film", "Immuch360", -1, "Pause", "Cancel")

      fun of(notice: FilmDownloadNotice): Notice =
        Notice(
          channelName = clean(notice.channelName, DEFAULT.channelName),
          title = clean(notice.title, DEFAULT.title),
          text = clean(notice.text, DEFAULT.text),
          progress = notice.progress.toInt(),
          pauseLabel = clean(notice.pauseLabel, DEFAULT.pauseLabel),
          cancelLabel = clean(notice.cancelLabel, DEFAULT.cancelLabel),
        )

      private fun clean(value: String?, fallback: String): String {
        val trimmed = value?.replace(CONTROL, " ")?.trim()
        if (trimmed.isNullOrEmpty()) {
          return fallback
        }
        return if (trimmed.length > MAX_LENGTH) trimmed.take(MAX_LENGTH - 1).trimEnd() + "…" else trimmed
      }
    }
  }

  companion object {
    private const val TAG = "FilmDownloadService"
    private const val CHANNEL_ID = "film_download"
    private const val NOTIFICATION_ID = 3602
    private const val PROGRESS_MAX = 1000
    private const val LOCK_TAG = "immuch360:filmdownload"
    private const val WAKE_LOCK_LIMIT_MS = 12L * 60 * 60 * 1000

    private const val ACTION_START = "app.alextran.immich.filmdownload.START"
    private const val ACTION_PAUSE = "app.alextran.immich.filmdownload.PAUSE"
    private const val ACTION_CANCEL = "app.alextran.immich.filmdownload.CANCEL"

    /** The running service, to update its notification; main thread only */
    @Volatile private var running: FilmDownloadService? = null

    /** The texts of the next start, read by [onStartCommand] */
    @Volatile private var pending: Notice? = null

    fun start(context: Context, notice: Notice) {
      val current = running
      if (current != null) {
        current.show(notice)
        return
      }
      pending = notice
      try {
        ContextCompat.startForegroundService(
          context,
          Intent(context, FilmDownloadService::class.java).setAction(ACTION_START),
        )
      } catch (e: Exception) {
        // Not allowed from the background (Android 12 and later): the copy runs while the app is in front
        Log.w(TAG, "The film download service did not start", e)
      }
    }

    fun update(notice: Notice) {
      running?.show(notice)
    }

    fun stop(context: Context) {
      if (running == null) {
        return
      }
      try {
        context.stopService(Intent(context, FilmDownloadService::class.java))
      } catch (e: Exception) {
        Log.w(TAG, "The film download service did not stop", e)
      }
    }
  }
}
