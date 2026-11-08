package app.alextran.immich.background

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.ForegroundInfo
import androidx.work.ListenableWorker
import androidx.work.WorkerParameters
import app.alextran.immich.MainActivity
import app.alextran.immich.R
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

private const val TAG = "BackgroundWorker"

class BackgroundWorker(context: Context, params: WorkerParameters) :
  ListenableWorker(context, params), BackgroundWorkerBgHostApi {
  private val ctx: Context = context.applicationContext

  /// The Flutter loader that loads the native Flutter library and resources.
  /// This must be initialized before starting the Flutter engine.
  private var loader: FlutterLoader = FlutterInjector.instance().flutterLoader()

  /// The Flutter engine created specifically for background execution.
  /// This is a separate instance from the main Flutter engine that handles the UI.
  /// It operates in its own isolate and doesn't share memory with the main engine.
  /// Must be properly started, registered, and torn down during background execution.
  private var engine: FlutterEngine? = null

  // Used to call methods on the flutter side
  private var flutterApi: BackgroundWorkerFlutterApi? = null

  /// Result returned when the background task completes. This is used to signal
  /// to the WorkManager that the task has finished, either successfully or with failure.
  private val completionHandler: SettableFuture<Result> = SettableFuture.create()

  private val notificationManager =
    ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

  private var foregroundFuture: ListenableFuture<Void>? = null

  private val mainHandler = Handler(Looper.getMainLooper())

  /// The end of this run in order: the work finished within 5 s of a stop, the engine destroyed only once its Dart has
  /// closed the databases (or at a cap), see BackgroundTeardown
  private val teardown = BackgroundTeardown<Result>(
    slot = engineSlot,
    schedule = { delayMs, action -> mainHandler.postDelayed(action, delayMs) },
    finishWork = ::finishWork,
    destroyEngine = ::destroyEngine,
  )

  /// When startWork began and when the cancel was asked, for the durations of the phases in the log
  private var startedAt = 0L
  private var cancelAskedAt = 0L

  companion object {
    private const val NOTIFICATION_CHANNEL_ID = "immich::background_worker::notif"
    private const val NOTIFICATION_ID = 100
    private val activeWorker = AtomicReference<BackgroundWorker?>(null)

    /// Held from the start of a run until its engine is destroyed, which can be after its work finished
    private val engineSlot = BackgroundEngineSlot()

    /// What must not hold the main thread: the wait for a foreground promotion before a result
    private val offMainThread: ExecutorService = Executors.newCachedThreadPool { runnable ->
      Thread(runnable, "BackgroundWorkerTeardown").apply { isDaemon = true }
    }
  }

  override fun startWork(): ListenableFuture<Result> {
    if (!activeWorker.compareAndSet(null, this)) {
      Log.i(TAG, "Another background worker is running, skipping")
      return Futures.immediateFuture(Result.success())
    }

    if (BackgroundWorkerPreferences(ctx).isLocked() && BackgroundEngineLock.connectEngines > 0) {
      Log.i(TAG, "Foreground engine active, skipping background worker")
      activeWorker.compareAndSet(this, null)
      return Futures.immediateFuture(Result.success())
    }

    // The engine of an earlier run is still alive, its Dart may still be closing the databases: no second engine
    // meanwhile, WorkManager runs this work again later
    if (!teardown.tryStart()) {
      Log.i(TAG, "The previous background engine is still being torn down, retrying later")
      activeWorker.compareAndSet(this, null)
      return Futures.immediateFuture(Result.retry())
    }

    try {
      startedAt = SystemClock.elapsedRealtime()
      Log.i(TAG, "Starting background upload worker")

      if (!loader.initialized()) {
        loader.startInitialization(ctx)
      }

      val notificationChannel = NotificationChannel(
        NOTIFICATION_CHANNEL_ID,
        ctx.getString(R.string.background_worker_notification_channel_name),
        NotificationManager.IMPORTANCE_LOW
      )
      notificationManager.createNotificationChannel(notificationChannel)
      val notificationConfig = BackgroundWorkerPreferences(ctx).getNotificationConfig()
      showNotification(notificationConfig.first, notificationConfig.second)

      loader.ensureInitializationCompleteAsync(ctx, null, mainHandler) {
        phase("Flutter loader ready")
        if (isStopped || teardown.isEnding) {
          return@ensureInitializationCompleteAsync
        }

        engine = FlutterEngine(ctx)
        FlutterEngineCache.getInstance().put(BackgroundWorkerApiImpl.ENGINE_CACHE_KEY, engine!!)

        // Register custom plugins
        MainActivity.registerPlugins(ctx, engine!!)
        flutterApi =
          BackgroundWorkerFlutterApi(binaryMessenger = engine!!.dartExecutor.binaryMessenger)
        BackgroundWorkerBgHostApi.setUp(
          binaryMessenger = engine!!.dartExecutor.binaryMessenger,
          api = this
        )
        teardown.engineStarted()
        phase("engine started")

        engine!!.dartExecutor.executeDartEntrypoint(
          DartExecutor.DartEntrypoint(
            loader.findAppBundlePath(),
            "package:immich_mobile/domain/services/background_worker.service.dart",
            "backgroundSyncNativeEntrypoint"
          )
        )
      }

      return completionHandler
    } catch (error: Throwable) {
      teardown.complete(Result.failure())
      throw error
    }
  }

  /**
   * Called by the Flutter side when it has finished initialization and is ready to receive commands.
   * Routes the appropriate task type (refresh or processing) to the corresponding Flutter method.
   * This method acts as a bridge between the native Android background task system and Flutter.
   */
  override fun onInitialized() {
    phase("Dart initialized")
    // Stopped while Dart was starting: the cancel is on its way, no upload
    if (teardown.isEnding) {
      return
    }
    flutterApi?.onAndroidUpload(maxMinutesArg = 20) { handleHostResult(it) }
  }

  // TODO: Move this to a separate NotificationManager class
  private fun showNotification(title: String, content: String) {
    val notification = NotificationCompat.Builder(applicationContext, NOTIFICATION_CHANNEL_ID)
      .setSmallIcon(R.drawable.notification_icon)
      .setOnlyAlertOnce(true)
      .setOngoing(true)
      .setTicker(title)
      .setContentTitle(title)
      .setContentText(content)
      .build()

    if (isIgnoringBatteryOptimizations()) {
      foregroundFuture = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
        setForegroundAsync(
          ForegroundInfo(
            NOTIFICATION_ID,
            notification,
            FOREGROUND_SERVICE_TYPE_DATA_SYNC
          )
        )
      } else {
        setForegroundAsync(ForegroundInfo(NOTIFICATION_ID, notification))
      }
    } else {
      notificationManager.notify(NOTIFICATION_ID, notification)
    }
  }

  override fun close() {
    mainHandler.postAtFrontOfQueue { stop(Result.failure()) }
  }

  /**
   * Stops the run, on the main thread. Dart is asked to cancel: it waits for its running work, closes the databases and
   * answers. The work is finished on that answer or after 5 s, the engine destroyed on that answer or after 60 s
   * (BackgroundTeardown): destroyed earlier, the isolate of the engine would end with database work in flight.
   */
  private fun stop(result: Result) {
    if (!teardown.cancel(result)) {
      return
    }
    cancelAskedAt = SystemClock.elapsedRealtime()
    phase("cancel asked")
    val api = flutterApi
    if (api == null) {
      teardown.dartAnswered()
      return
    }
    api.cancel { answer ->
      val outcome = if (answer.isSuccess) "confirmed" else "failed (${answer.exceptionOrNull()})"
      phase("Dart cleanup $outcome after the cancel", cancelAskedAt)
      teardown.dartAnswered()
    }
  }

  /**
   * Called when the system has to stop this worker because constraints are
   * no longer met or the system needs resources for more important tasks
   * This is also called when the worker has been explicitly cancelled or replaced
   */
  override fun onStopped() {
    Log.d(TAG, "About to stop BackupWorker")
    close()
  }

  /// The answer of Dart to onAndroidUpload, which comes after its own cleanup
  private fun handleHostResult(result: kotlin.Result<Boolean>) {
    if (teardown.isWorkFinished) {
      return
    }

    result.fold(
      onSuccess = { needsRetry ->
        phase("work ended")
        // The connected worker cannot enqueue itself while it is running, so it retries in place
        if (needsRetry && !tags.contains(BackgroundWorkerApiImpl.RETRY_TAG)) {
          BackgroundWorkerApiImpl.enqueueBackgroundWorkerWhenConnected(ctx)
          teardown.complete(Result.success())
        } else {
          teardown.complete(if (needsRetry) Result.retry() else Result.success())
        }
      },
      onFailure = { _ -> stop(Result.failure()) }
    )
  }

  /**
   * Gives WorkManager the result of this run, once (see BackgroundTeardown). The engine may still be alive. A pending
   * foreground promotion is waited for first, off the main thread since that wait blocks.
   */
  private fun finishWork(result: Result) {
    Log.d(TAG, "About to complete BackupWorker with result: $result")
    notificationManager.cancel(NOTIFICATION_ID)
    activeWorker.compareAndSet(this, null)
    offMainThread.execute {
      waitForForegroundPromotion()
      completionHandler.set(result)
    }
  }

  /** Destroys the engine of this run, once, after the cleanup of its Dart or at the cap (see BackgroundTeardown) */
  private fun destroyEngine() {
    val engine = this.engine ?: return
    this.engine = null
    flutterApi = null
    MainActivity.cancelPlugins(engine)
    engine.destroy()
    val cache = FlutterEngineCache.getInstance()
    if (cache.get(BackgroundWorkerApiImpl.ENGINE_CACHE_KEY) === engine) {
      cache.remove(BackgroundWorkerApiImpl.ENGINE_CACHE_KEY)
    }
    if (cancelAskedAt > 0L) {
      phase("engine destroyed after the cancel", cancelAskedAt)
    } else {
      phase("engine destroyed")
    }
  }

  /**
   * Logs a phase of this run with the time since its start, and since [since] when it is set: how long a step held the
   * main thread at a background start (a TV), how long Dart took to clean up after a cancel
   */
  private fun phase(name: String, since: Long = 0L) {
    val now = SystemClock.elapsedRealtime()
    val took = if (since > 0L) " (took ${now - since} ms)" else ""
    Log.i(TAG, "Phase: $name at ${now - startedAt} ms$took")
  }

  /**
   * Returns `true` if the app is ignoring battery optimizations
   */
  private fun isIgnoringBatteryOptimizations(): Boolean {
    val powerManager = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
    return powerManager.isIgnoringBatteryOptimizations(ctx.packageName)
  }

  /**
   *  Calls to setForegroundAsync() that do not complete before completion of a ListenableWorker will signal an IllegalStateException
   * https://android-review.googlesource.com/c/platform/frameworks/support/+/1262743
   * Wait for a short period of time for the foreground promotion to complete before completing the worker
   */
  private fun waitForForegroundPromotion() {
    val foregroundFuture = this.foregroundFuture
    if (foregroundFuture != null && !foregroundFuture.isCancelled && !foregroundFuture.isDone) {
      try {
        foregroundFuture.get(500, TimeUnit.MILLISECONDS)
      } catch (e: Exception) {
        // ignored, there is nothing to be done
      }
    }
  }
}
