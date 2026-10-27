package app.alextran.immich.immersive

import android.app.ActivityManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.PowerManager
import android.os.Process
import android.util.Log
import app.alextran.immich.relief.DepthEstimators
import app.alextran.immich.relief.DepthPathMemory
import app.alextran.immich.relief.DepthPathStore
import app.alextran.immich.relief.ReliefCache
import app.alextran.immich.relief.ReliefEye
import app.alextran.immich.relief.ReliefJob
import app.alextran.immich.relief.ReliefPhoto
import app.alextran.immich.relief.ReliefWorker

// The Android side of the AI relief of the immersive view (design-final 2026-10-26, sections 3.4 and 3.6), for
// relief/ReliefJob.kt, which is plain JVM code: its thread, a HandlerThread at background priority whose XNNPACK
// threads inherit that priority; the photo and its right eye as bitmaps; the GPU decision of the headset in the
// preferences of the app; the heat and the memory of the headset. The depth engine is DepthEstimators of the flavour:
// LiteRT in the quest flavour, none in the phone flavour, whose relief then says "Not in this version of the app".

/** The thread of the relief, at background priority so that the scene keeps its frames */
internal class ReliefThread : ReliefWorker {
  private val thread = HandlerThread("ImmuchRelief", Process.THREAD_PRIORITY_BACKGROUND).apply { start() }
  private val handler = Handler(thread.looper)

  override fun post(task: Runnable) {
    handler.post(task)
  }

  override fun postDelayed(task: Runnable, delayMs: Long) {
    handler.postDelayed(task, delayMs)
  }

  override fun cancel(task: Runnable) {
    handler.removeCallbacks(task)
  }

  override fun quit() {
    thread.quitSafely()
  }
}

/** The photo of a relief: an upright, opaque ARGB_8888 software bitmap (ImmersiveMedia.decodeForRelief) */
internal class BitmapReliefPhoto(val bitmap: Bitmap) : ReliefPhoto {
  override val width = bitmap.width
  override val height = bitmap.height

  override fun read(y: Int, out: IntArray) {
    bitmap.getPixels(out, 0, width, 0, y, width, 1)
  }

  override fun release() {
    bitmap.recycle()
  }
}

/** The right eye of a relief, a new ARGB_8888 bitmap of the size of the photo */
internal class BitmapReliefEye(width: Int, height: Int) : ReliefEye {
  val bitmap: Bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)

  override fun write(y: Int, row: IntArray) {
    bitmap.setPixels(row, 0, bitmap.width, 0, y, bitmap.width, 1)
  }

  override fun release() {
    bitmap.recycle()
  }
}

/** The path the GPU parity check chose, in the preferences file of the relief */
private class PreferencesPathStore(private val preferences: SharedPreferences) : DepthPathStore {
  override fun read(key: String): String? = preferences.getString(key, null)

  override fun write(key: String, value: String?) {
    preferences.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
  }
}

/**
 * The thermal status of the headset while the viewer has a relief job: read before a relief starts, and each change
 * sent to [onStatus] on the main thread (the pattern of djilink/DjiLinkController.kt). Android 10 and later; before,
 * the status reads as none.
 */
internal class ThermalWatch(context: Context, private val onStatus: (Int) -> Unit) {
  private val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
  private var listener: Any? = null

  fun current(): Int {
    val power = power ?: return 0
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return 0
    return runCatching { power.currentThermalStatus }.getOrDefault(0)
  }

  fun start() {
    val power = power ?: return
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || listener != null) return
    val watcher = PowerManager.OnThermalStatusChangedListener { status -> onStatus(status) }
    if (runCatching { power.addThermalStatusListener(watcher) }.isSuccess) listener = watcher
  }

  fun stop() {
    val power = power ?: return
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
    (listener as? PowerManager.OnThermalStatusChangedListener)?.let { watcher ->
      runCatching { power.removeThermalStatusListener(watcher) }
    }
    listener = null
  }
}

internal object ReliefHost {
  /** The memory Android sees, a little under the memory of the device (the part the kernel keeps) */
  fun totalMemoryBytes(context: Context): Long {
    val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return 0L
    return ActivityManager.MemoryInfo().also { manager.getMemoryInfo(it) }.totalMem
  }

  /**
   * The relief job of a viewer: the engine of the flavour, the GPU decision kept for this system build, the relief
   * cache in the cache directory of the app, answers posted to [main], the heat read by [thermal]
   */
  fun newJob(context: Context, main: Handler, thermal: ThermalWatch): ReliefJob {
    val preferences = context.getSharedPreferences(DepthPathMemory.PREFERENCES, Context.MODE_PRIVATE)
    val memory = DepthPathMemory(PreferencesPathStore(preferences), Build.FINGERPRINT.orEmpty(), DepthEstimators.engine)
    val totalMemory = totalMemoryBytes(context)
    Log.i(TAG, "relief: engine ${DepthEstimators.engine}, ${totalMemory / 1048576} MB of memory seen")
    return ReliefJob(
      engine = DepthEstimators,
      memory = memory,
      cache = ReliefCache.inCacheDir(context.cacheDir) { Log.w(TAG, it) },
      worker = ReliefThread(),
      main = { main.post(it) },
      thermalStatus = thermal::current,
      totalMemoryBytes = totalMemory,
      log = { Log.i(TAG, it) },
    )
  }
}
