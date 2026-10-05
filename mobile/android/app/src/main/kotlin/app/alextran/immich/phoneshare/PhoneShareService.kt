package app.alextran.immich.phoneshare

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
import java.io.File

/**
 * Keeps "Share this phone on the network" alive while the screen is off or another app is in front: a foreground
 * service of type connectedDevice (the phone serves its gallery to a headset on the Wi-Fi), with an ongoing
 * notification that tells the address and offers Stop. It holds a Wi-Fi lock, so that the Wi-Fi does not doze
 * between two requests of a video, and a partial wake lock, so that the Dart server keeps running.
 *
 * The server itself runs in the Flutter engine of the app: the service only keeps the process awake. It never starts
 * by itself ([START_NOT_STICKY]) and stops with the task of the app (swiped away, the engine and the server are gone
 * too), from its Stop action (Flutter is told, see [PhoneShareApiImpl.notifyStopRequested]), or when Flutter stops
 * the share.
 */
class PhoneShareService : Service() {
  private var wifiLock: WifiManager.WifiLock? = null
  private var wakeLock: PowerManager.WakeLock? = null
  private var texts = PhoneShareNotificationTexts.DEFAULT

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    if (intent?.action == ACTION_STOP) {
      Log.i(TAG, "Stop from the notification")
      PhoneShareApiImpl.notifyStopRequested()
      stopSelf()
      return START_NOT_STICKY
    }
    texts =
      PhoneShareNotificationTexts.of(
        intent?.getStringExtra(EXTRA_TITLE),
        intent?.getStringExtra(EXTRA_TEXT),
        intent?.getStringExtra(EXTRA_STOP_LABEL),
      )
    try {
      createChannel()
      ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(), foregroundType())
    } catch (e: Exception) {
      // Started from the background (Android 12 and later refuse it) or a refused type: the share still runs while
      // the app is in front
      Log.w(TAG, "The phone share cannot run in the foreground", e)
      stopSelf()
      return START_NOT_STICKY
    }
    acquireLocks()
    running = this
    return START_NOT_STICKY
  }

  override fun onTaskRemoved(rootIntent: Intent?) {
    // The app was swiped away: its Flutter engine and the Dart server are gone with it, and Dart cannot delete the
    // copies it served any more
    Log.i(TAG, "Task removed, the phone share stops")
    deleteCopies()
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

  /** Shows [text] in the notification, the address once the network changed */
  internal fun updateText(text: String) {
    texts = texts.withText(text)
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
        .setName(getString(R.string.phone_share_channel))
        .setShowBadge(false)
        .build()
    NotificationManagerCompat.from(this).createNotificationChannel(channel)
  }

  private fun buildNotification(): Notification {
    val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
      PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }
    val stop =
      PendingIntent.getService(
        this,
        1,
        Intent(this, PhoneShareService::class.java).setAction(ACTION_STOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
      )
    return NotificationCompat.Builder(this, CHANNEL_ID)
      .setSmallIcon(R.drawable.notification_icon)
      .setContentTitle(texts.title)
      .setContentText(texts.text)
      .setStyle(NotificationCompat.BigTextStyle().bigText(texts.text))
      .setOngoing(true)
      .setOnlyAlertOnce(true)
      .setSilent(true)
      .setCategory(NotificationCompat.CATEGORY_SERVICE)
      .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
      .setContentIntent(open)
      .addAction(0, texts.stopLabel, stop)
      .build()
  }

  private fun foregroundType(): Int =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0

  private fun acquireLocks() {
    if (wifiLock == null) {
      val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
      val mode =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
          WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
          @Suppress("DEPRECATION")
          WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
      wifiLock =
        wifi?.createWifiLock(mode, LOCK_TAG)?.apply {
          setReferenceCounted(false)
          acquire()
        }
    }
    if (wakeLock == null) {
      val power = getSystemService(Context.POWER_SERVICE) as? PowerManager
      wakeLock =
        power?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, LOCK_TAG)?.apply {
          setReferenceCounted(false)
          // A bound in case the service outlives what should stop it; Flutter stops the share after an hour unused
          acquire(WAKE_LOCK_LIMIT_MS)
        }
    }
  }

  /** Deletes the copies of the media [PhoneShareApiImpl] could not serve in place, off the main thread */
  private fun deleteCopies() {
    val folder = File(cacheDir, COPIES_FOLDER)
    Thread {
      if (folder.exists() && !folder.deleteRecursively()) {
        Log.w(TAG, "Some copies of the phone share were not deleted")
      }
    }.start()
  }

  private fun releaseLocks() {
    wifiLock?.let { if (it.isHeld) it.release() }
    wifiLock = null
    wakeLock?.let { if (it.isHeld) it.release() }
    wakeLock = null
  }

  companion object {
    private const val TAG = "PhoneShareService"
    private const val CHANNEL_ID = "phone_share"
    private const val NOTIFICATION_ID = 3601
    private const val LOCK_TAG = "immuch360:phoneshare"
    private const val WAKE_LOCK_LIMIT_MS = 8L * 60 * 60 * 1000

    /** The cache folder of the copies, the one of [PhoneShareApiImpl] */
    private const val COPIES_FOLDER = "phone_share"

    private const val ACTION_START = "app.alextran.immich.phoneshare.START"
    private const val ACTION_STOP = "app.alextran.immich.phoneshare.STOP"
    private const val EXTRA_TITLE = "app.alextran.immich.phoneshare.TITLE"
    private const val EXTRA_TEXT = "app.alextran.immich.phoneshare.TEXT"
    private const val EXTRA_STOP_LABEL = "app.alextran.immich.phoneshare.STOP_LABEL"

    /** The running service, to update its notification; main thread only */
    @Volatile
    private var running: PhoneShareService? = null

    fun start(context: Context, texts: PhoneShareNotificationTexts) {
      val intent =
        Intent(context, PhoneShareService::class.java)
          .setAction(ACTION_START)
          .putExtra(EXTRA_TITLE, texts.title)
          .putExtra(EXTRA_TEXT, texts.text)
          .putExtra(EXTRA_STOP_LABEL, texts.stopLabel)
      try {
        ContextCompat.startForegroundService(context, intent)
      } catch (e: Exception) {
        // Not allowed from the background, or no such service in this flavour (the Quest build removes it)
        Log.w(TAG, "The phone share service did not start", e)
      }
    }

    fun update(text: String) {
      running?.updateText(text)
    }

    fun stop(context: Context) {
      try {
        context.stopService(Intent(context, PhoneShareService::class.java))
      } catch (e: Exception) {
        Log.w(TAG, "The phone share service did not stop", e)
      }
    }
  }
}
