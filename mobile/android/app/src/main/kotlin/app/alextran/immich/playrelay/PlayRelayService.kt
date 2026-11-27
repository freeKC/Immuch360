package app.alextran.immich.playrelay

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
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
import app.alextran.immich.phoneshare.PhoneShareNotificationTexts

/**
 * Keeps "Play on…" sending from the phone while its screen is off (release 53): while the phone serves one of its own
 * photos or videos to a linked TV, headset or computer from its relay (lib/providers/play_on_screen/
 * phone_relay.provider.dart), a foreground service of type connectedDevice runs, with an ongoing notification
 * "Sending to (screen)" that offers Stop. It holds a Wi-Fi lock, so that the Wi-Fi does not doze between two requests
 * of a video, and a partial wake lock, so that the Dart relay keeps running.
 *
 * The relay itself runs in the Flutter engine of the app: the service only keeps the process awake. It never starts by
 * itself ([START_NOT_STICKY]), and stops when Flutter has no lease left, from its Stop action (Flutter is told, see
 * [PlayRelayChannel.notifyStopRequested]), or with the task of the app (swiped away: the relay is gone too).
 *
 * The Quest flavour removes the service from its manifest (the headset is a screen, it does not send): there, [start]
 * and [stop] do nothing rather than ask Android for a service it does not know.
 */
class PlayRelayService : Service() {
  private var wifiLock: WifiManager.WifiLock? = null
  private var wakeLock: PowerManager.WakeLock? = null
  private var texts = DEFAULT_TEXTS
  private var channelName = DEFAULT_CHANNEL_NAME

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    if (intent?.action == ACTION_STOP) {
      Log.i(TAG, "Stop from the notification")
      PlayRelayChannel.notifyStopRequested()
      stopSelf()
      return START_NOT_STICKY
    }
    texts =
      PhoneShareNotificationTexts.of(
        intent?.getStringExtra(EXTRA_TITLE) ?: DEFAULT_TEXTS.title,
        intent?.getStringExtra(EXTRA_TEXT) ?: DEFAULT_TEXTS.text,
        intent?.getStringExtra(EXTRA_STOP_LABEL) ?: DEFAULT_TEXTS.stopLabel,
      )
    channelName = intent?.getStringExtra(EXTRA_CHANNEL)?.trim()?.takeIf { it.isNotEmpty() }?.take(80) ?: channelName
    try {
      createChannel()
      ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(), foregroundType())
    } catch (e: Exception) {
      // Started from the background (Android 12 and later refuse it) or a refused type: the relay still sends while
      // the app is in front
      Log.w(TAG, "The relay cannot run in the foreground", e)
      stopSelf()
      return START_NOT_STICKY
    }
    acquireLocks()
    return START_NOT_STICKY
  }

  override fun onTaskRemoved(rootIntent: Intent?) {
    // The app was swiped away: its Flutter engine and the Dart relay are gone with it
    Log.i(TAG, "Task removed, the relay stops")
    stopSelf()
    super.onTaskRemoved(rootIntent)
  }

  override fun onDestroy() {
    releaseLocks()
    super.onDestroy()
  }

  private fun createChannel() {
    val channel =
      NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
        .setName(channelName)
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
        Intent(this, PlayRelayService::class.java).setAction(ACTION_STOP),
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
          // A bound in case the service outlives what should stop it; a lease of the relay lives 12 hours at most
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

  companion object {
    private const val TAG = "PlayRelayService"
    private const val CHANNEL_ID = "play_relay"
    private const val NOTIFICATION_ID = 3605
    private const val LOCK_TAG = "immuch360:playrelay"
    private const val WAKE_LOCK_LIMIT_MS = 12L * 60 * 60 * 1000
    private const val DEFAULT_CHANNEL_NAME = "Sending to a screen"
    private val DEFAULT_TEXTS = PhoneShareNotificationTexts("Sending to a screen", "Immuch360", "Stop")

    private const val ACTION_START = "app.alextran.immich.playrelay.START"
    private const val ACTION_STOP = "app.alextran.immich.playrelay.STOP"
    private const val EXTRA_TITLE = "app.alextran.immich.playrelay.TITLE"
    private const val EXTRA_TEXT = "app.alextran.immich.playrelay.TEXT"
    private const val EXTRA_STOP_LABEL = "app.alextran.immich.playrelay.STOP_LABEL"
    private const val EXTRA_CHANNEL = "app.alextran.immich.playrelay.CHANNEL"

    /** Whether the manifest of this build declares the service; read once, it does not change while the app runs */
    @Volatile
    private var declared: Boolean? = null

    fun start(context: Context, title: String?, text: String?, stopLabel: String?, channel: String?) {
      if (!isDeclared(context)) {
        Log.i(TAG, "No relay service in this build, the relay sends while the app is in front")
        return
      }
      val intent =
        Intent(context, PlayRelayService::class.java)
          .setAction(ACTION_START)
          .putExtra(EXTRA_TITLE, title)
          .putExtra(EXTRA_TEXT, text)
          .putExtra(EXTRA_STOP_LABEL, stopLabel)
          .putExtra(EXTRA_CHANNEL, channel)
      try {
        ContextCompat.startForegroundService(context, intent)
      } catch (e: Exception) {
        // Not allowed from the background (Android 12 and later)
        Log.w(TAG, "The relay service did not start", e)
      }
    }

    fun stop(context: Context) {
      if (!isDeclared(context)) {
        return
      }
      try {
        context.stopService(Intent(context, PlayRelayService::class.java))
      } catch (e: Exception) {
        Log.w(TAG, "The relay service did not stop", e)
      }
    }

    /** False in the Quest build, whose manifest removes the service */
    private fun isDeclared(context: Context): Boolean = declared ?: lookUpDeclared(context).also { declared = it }

    private fun lookUpDeclared(context: Context): Boolean {
      val component = ComponentName(context, PlayRelayService::class.java)
      return try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
          context.packageManager.getServiceInfo(component, PackageManager.ComponentInfoFlags.of(0))
        } else {
          @Suppress("DEPRECATION")
          context.packageManager.getServiceInfo(component, 0)
        }
        true
      } catch (e: PackageManager.NameNotFoundException) {
        false
      }
    }
  }
}
