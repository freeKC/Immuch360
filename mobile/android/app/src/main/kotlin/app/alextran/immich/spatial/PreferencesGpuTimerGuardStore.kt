package app.alextran.immich.spatial

import android.annotation.SuppressLint
import android.content.Context

/** [GpuTimerGuardStore] in the app's own SharedPreferences file of the Spatial 2.5D player */
class PreferencesGpuTimerGuardStore(context: Context) : GpuTimerGuardStore {
  companion object {
    private const val FILE = "immuch360_spatial_gl"
    private const val ARMED = "gpuTimerArmedKey"
    private const val BAD = "gpuTimerBadKeys"

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

  // The armed key must be on disk before the first query: a crash in the driver leaves no time for a later write
  @SuppressLint("ApplySharedPref")
  override fun setArmedKey(key: String?, synchronous: Boolean) {
    val editor = preferences.edit()
    if (key == null) editor.remove(ARMED) else editor.putString(ARMED, key)
    if (synchronous) editor.commit() else editor.apply()
  }

  /** One key per line: the keys hold no line break (see GpuTimerPolicy.driverKey) */
  override fun badKeys(): List<String> =
    preferences.getString(BAD, null)?.split('\n')?.filter { it.isNotEmpty() }.orEmpty()

  @SuppressLint("ApplySharedPref")
  override fun setBadKeys(keys: List<String>) {
    preferences.edit().putString(BAD, keys.joinToString("\n")).commit()
  }
}
