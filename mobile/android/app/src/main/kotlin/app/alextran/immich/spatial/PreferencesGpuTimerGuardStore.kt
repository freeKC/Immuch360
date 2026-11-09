package app.alextran.immich.spatial

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Process
import androidx.annotation.RequiresApi

/** [GpuTimerGuardStore] in the app's own SharedPreferences file of the Spatial 2.5D player */
class PreferencesGpuTimerGuardStore(context: Context) : GpuTimerGuardStore {
  companion object {
    private const val FILE = "immuch360_spatial_gl"
    private const val ARMED = "gpuTimerArmedKey"
    private const val ARMED_PID = "gpuTimerArmedPid"
    private const val ARMED_AT = "gpuTimerArmedAt"
    private const val BAD = "gpuTimerBadKeys"

    // The signals of a native crash as Linux numbers them on the Android ABIs: SIGILL, SIGABRT, SIGBUS, SIGFPE, SIGSEGV
    private val CRASH_SIGNALS = setOf(4, 6, 7, 8, 11)

    /**
     * How a process ended, out of the reason and the status of its ApplicationExitInfo: a crash (Java or native, or a
     * process ended by the signal of a native crash), [ArmedProcessEnd.UNKNOWN] when Android does not know, otherwise
     * another end (the user, the low memory killer, an update)
     */
    fun endOf(reason: Int, status: Int): ArmedProcessEnd =
      when (reason) {
        ApplicationExitInfo.REASON_CRASH, ApplicationExitInfo.REASON_CRASH_NATIVE -> ArmedProcessEnd.CRASH
        ApplicationExitInfo.REASON_SIGNALED ->
          if (status in CRASH_SIGNALS) ArmedProcessEnd.CRASH else ArmedProcessEnd.OTHER
        ApplicationExitInfo.REASON_UNKNOWN -> ArmedProcessEnd.UNKNOWN
        else -> ArmedProcessEnd.OTHER
      }

    @Volatile private var shared: GpuTimerCrashGuard? = null

    /** The guard of the process, so that the check of the previous process runs once */
    fun guard(context: Context): GpuTimerCrashGuard =
      shared ?: synchronized(this) {
        shared ?: GpuTimerCrashGuard(PreferencesGpuTimerGuardStore(context)).also { shared = it }
      }
  }

  private val appContext = context.applicationContext

  // Opened at the first use, on the GL thread, rather than in the activity's onCreate
  private val preferences by lazy { appContext.getSharedPreferences(FILE, Context.MODE_PRIVATE) }

  override fun armedKey(): String? = preferences.getString(ARMED, null)

  // The armed key must be on disk before the first query: a crash in the driver leaves no time for a later write. The
  // process and the time go with it, so that the next process finds how this one ended (armedProcessEnd)
  @SuppressLint("ApplySharedPref")
  override fun setArmedKey(key: String?, synchronous: Boolean) {
    val editor = preferences.edit()
    if (key == null) {
      editor.remove(ARMED).remove(ARMED_PID).remove(ARMED_AT)
    } else {
      editor.putString(ARMED, key).putInt(ARMED_PID, Process.myPid()).putLong(ARMED_AT, System.currentTimeMillis())
    }
    if (synchronous) editor.commit() else editor.apply()
  }

  /** The first end Android kept of the process that armed the key, after it armed it (Android 11 and later) */
  override fun armedProcessEnd(): ArmedProcessEnd =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) armedProcessExit() else ArmedProcessEnd.UNKNOWN

  @RequiresApi(Build.VERSION_CODES.R)
  private fun armedProcessExit(): ArmedProcessEnd {
    val pid = preferences.getInt(ARMED_PID, 0)
    if (pid == 0) return ArmedProcessEnd.UNKNOWN
    val armedAt = preferences.getLong(ARMED_AT, 0L)
    return try {
      val manager = appContext.getSystemService(ActivityManager::class.java) ?: return ArmedProcessEnd.UNKNOWN
      val exit = manager.getHistoricalProcessExitReasons(appContext.packageName, pid, 0)
        .filter { it.timestamp >= armedAt }
        .minByOrNull { it.timestamp }
        ?: return ArmedProcessEnd.UNKNOWN
      endOf(exit.reason, exit.status)
    } catch (_: RuntimeException) {
      ArmedProcessEnd.UNKNOWN
    }
  }

  /** One key per line: the keys hold no line break (see GpuTimerPolicy.driverKey) */
  override fun badKeys(): List<String> =
    preferences.getString(BAD, null)?.split('\n')?.filter { it.isNotEmpty() }.orEmpty()

  @SuppressLint("ApplySharedPref")
  override fun setBadKeys(keys: List<String>) {
    preferences.edit().putString(BAD, keys.joinToString("\n")).commit()
  }
}
