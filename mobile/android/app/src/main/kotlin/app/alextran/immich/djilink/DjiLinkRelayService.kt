package app.alextran.immich.djilink

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

/** The texts of the notification, from Flutter (i18n/en.json), as the phone share passes its own */
data class DjiLinkRelayTexts(
  val title: String,
  val text: String,
  val stopLabel: String,
  val channelName: String,
) {
  fun withText(next: String): DjiLinkRelayTexts = copy(text = next)
}

/**
 * Keeps "Send to a headset" alive while the phone sits in its holder with the screen locked: a foreground service of
 * type connectedDevice (the phone sends what its cable receives to a headset on the Wi-Fi, the type the phone share
 * already uses), with a notification that says so and offers Stop. It holds a partial wake lock, bounded to 8 hours,
 * so that the USB reading, the decoder and the relay go on, and a low latency Wi-Fi lock. Android honours the low
 * latency lock only for an app in front with the screen on (AOSP, Wi-Fi low latency mode): the page keeps the screen on
 * while it sends, by default.
 *
 * The relay itself lives in [DjiLinkController]: the service only keeps the process awake. It never starts by itself
 * ([START_NOT_STICKY]); Stop in the notification stops the relay and tells Flutter, which stops the announcement; the
 * app swiped away stops everything; a service Android refuses to run in the foreground stops the relay too. The Quest
 * flavour removes the service from its manifest (the headset receives, it does not send): there, [start] and [stop] do
 * nothing.
 *
 * Nothing here talks to the remote: the service holds no transport, no accessory manager and no USB service.
 */
class DjiLinkRelayService : Service() {
  private var wifiLock: WifiManager.WifiLock? = null
  private var wakeLock: PowerManager.WakeLock? = null
  private var texts = DjiLinkRelayTexts("Immuch360", "", "Stop", "Immuch360")

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    if (intent?.action == ACTION_STOP) {
      Log.i(TAG, "Stop from the notification")
      DjiLinkController.existing()?.stopRelayFromNotification()
      stopSelf()
      return START_NOT_STICKY
    }
    texts = DjiLinkRelayTexts(
      title = intent?.getStringExtra(EXTRA_TITLE) ?: texts.title,
      text = intent?.getStringExtra(EXTRA_TEXT) ?: texts.text,
      stopLabel = intent?.getStringExtra(EXTRA_STOP_LABEL) ?: texts.stopLabel,
      channelName = intent?.getStringExtra(EXTRA_CHANNEL) ?: texts.channelName,
    )
    try {
      createChannel()
      ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(), foregroundType())
    } catch (e: Exception) {
      // Started from the background (Android 12 and later refuse it) or a refused type: a relay left listening with no
      // notification and no Stop could be frozen with the process, so it stops, and the page's switch goes off
      Log.w(TAG, "The relay cannot run in the foreground", e)
      DjiLinkController.existing()?.relayServiceRefused()
      stopSelf()
      return START_NOT_STICKY
    }
    acquireLocks()
    running = this
    return START_NOT_STICKY
  }

  override fun onTaskRemoved(rootIntent: Intent?) {
    Log.i(TAG, "Task removed, the relay stops")
    DjiLinkController.existing()?.onTaskRemoved()
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
    val channel = NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
      .setName(texts.channelName)
      .setShowBadge(false)
      .build()
    NotificationManagerCompat.from(this).createNotificationChannel(channel)
  }

  private fun buildNotification(): Notification {
    val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
      PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }
    val stop = PendingIntent.getService(
      this,
      1,
      Intent(this, DjiLinkRelayService::class.java).setAction(ACTION_STOP),
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
      val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        WifiManager.WIFI_MODE_FULL_LOW_LATENCY
      } else {
        @Suppress("DEPRECATION")
        WifiManager.WIFI_MODE_FULL_HIGH_PERF
      }
      wifiLock = runCatching {
        wifi?.createWifiLock(mode, LOCK_TAG)?.apply {
          setReferenceCounted(false)
          acquire()
        }
      }.getOrNull()
    }
    if (wakeLock == null) {
      val power = getSystemService(Context.POWER_SERVICE) as? PowerManager
      wakeLock = runCatching {
        power?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, LOCK_TAG)?.apply {
          setReferenceCounted(false)
          acquire(WAKE_LOCK_LIMIT_MS)
        }
      }.getOrNull()
    }
    wifiLockHeld = wifiLock?.isHeld == true
  }

  private fun releaseLocks() {
    wifiLock?.let { if (it.isHeld) it.release() }
    wifiLock = null
    wakeLock?.let { if (it.isHeld) it.release() }
    wakeLock = null
    wifiLockHeld = false
  }

  companion object {
    private const val TAG = "DjiLinkRelayService"
    private const val CHANNEL_ID = "dji_link_relay"
    private const val NOTIFICATION_ID = 3602
    private const val LOCK_TAG = "immuch360:djirelay"
    private const val WAKE_LOCK_LIMIT_MS = 8L * 60 * 60 * 1000

    private const val ACTION_START = "app.alextran.immich.djilink.relay.START"
    private const val ACTION_STOP = "app.alextran.immich.djilink.relay.STOP"
    private const val EXTRA_TITLE = "app.alextran.immich.djilink.relay.TITLE"
    private const val EXTRA_TEXT = "app.alextran.immich.djilink.relay.TEXT"
    private const val EXTRA_STOP_LABEL = "app.alextran.immich.djilink.relay.STOP_LABEL"
    private const val EXTRA_CHANNEL = "app.alextran.immich.djilink.relay.CHANNEL"

    @Volatile
    private var running: DjiLinkRelayService? = null

    /** Whether the low latency Wi-Fi lock is held, for the page */
    @Volatile
    var wifiLockHeld = false
      private set

    @Volatile
    private var declared: Boolean? = null

    /**
     * From the page, while the app is in front, as Android 12 and later require. False when Android refused to start
     * it; a build without the service (the Quest's, which does not send) answers true, there being nothing to start.
     */
    fun start(context: Context, texts: DjiLinkRelayTexts): Boolean {
      if (!isDeclared(context)) {
        Log.i(TAG, "No relay service in this build, the relay runs while the app is in front")
        return true
      }
      val intent = Intent(context, DjiLinkRelayService::class.java)
        .setAction(ACTION_START)
        .putExtra(EXTRA_TITLE, texts.title)
        .putExtra(EXTRA_TEXT, texts.text)
        .putExtra(EXTRA_STOP_LABEL, texts.stopLabel)
        .putExtra(EXTRA_CHANNEL, texts.channelName)
      return try {
        ContextCompat.startForegroundService(context, intent)
        true
      } catch (e: Exception) {
        Log.w(TAG, "The relay service did not start", e)
        false
      }
    }

    fun update(text: String) {
      running?.updateText(text)
    }

    fun stop(context: Context) {
      if (!isDeclared(context)) {
        return
      }
      try {
        context.stopService(Intent(context, DjiLinkRelayService::class.java))
      } catch (e: Exception) {
        Log.w(TAG, "The relay service did not stop", e)
      }
    }

    /** False in the Quest build, whose manifest removes the service */
    private fun isDeclared(context: Context): Boolean = declared ?: lookUpDeclared(context).also { declared = it }

    private fun lookUpDeclared(context: Context): Boolean {
      val component = ComponentName(context, DjiLinkRelayService::class.java)
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
