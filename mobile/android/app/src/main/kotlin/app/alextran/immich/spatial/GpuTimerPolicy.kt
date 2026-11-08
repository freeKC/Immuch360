package app.alextran.immich.spatial

import java.util.Locale

/**
 * Whether the Spatial 2.5D renderer may time its frames on the GPU with GL_EXT_disjoint_timer_query, and why. When
 * it may not, the renderer times one frame in a few on the CPU around glFinish. [reason] is shown in the log line of
 * each GL context and in the debug overlay.
 */
enum class GpuTimerVerdict(val allowed: Boolean, val reason: String) {
  ALLOWED(true, "on"),
  TURNED_OFF(false, "turned off"),
  CRASHED_BEFORE(false, "off after a crash on this driver"),
  NO_EXTENSION(false, "no timer extension"),
  ARM_MALI(false, "ARM Mali"),
  VIRTUAL_GPU(false, "virtual GPU"),
}

/**
 * Decides once per GL context whether the GPU timer queries may run. Pure Kotlin: the strings come from glGetString.
 *
 * The queries are off on every ARM GPU (Mali and Immortalis, every driver release): build 25 crashed in
 * libGLES_mali.so under glGetQueryObjectuiv on a Mali-G57 (Play cluster 7b656f, 27 October 2026), and Filament turns
 * them off on Mali after memory corruptions and crashes (its bugs b/233754398 and b/273759031). Filament turns them
 * back on for Mali-G drivers from release r46; this rule does not, because the release of the crashed driver is
 * unknown and the CPU timing is enough for the adaptive quality. Virtual GPUs (virgl, virtio) are off too: Filament
 * reports that their results are often 0.
 */
object GpuTimerPolicy {
  const val TIMER_EXTENSION = "GL_EXT_disjoint_timer_query"

  /** Longest driver key kept by the crash guard */
  const val MAX_DRIVER_KEY_LENGTH = 200

  private val WHITESPACE = Regex("\\s+")
  private val NOT_ALPHANUMERIC = Regex("[^A-Za-z0-9]+")
  private val CONTROL = Regex("\\p{Cntrl}")

  /**
   * The verdict, in this order: not [wanted], a crash with the timers on this driver before ([crashedBefore], see
   * [GpuTimerCrashGuard]), the extension missing from [extensions], an ARM GPU, a virtual GPU, otherwise allowed.
   */
  fun decide(
    vendor: String?,
    renderer: String?,
    extensions: String?,
    crashedBefore: Boolean,
    wanted: Boolean,
  ): GpuTimerVerdict = when {
    !wanted -> GpuTimerVerdict.TURNED_OFF
    crashedBefore -> GpuTimerVerdict.CRASHED_BEFORE
    !hasExtension(extensions, TIMER_EXTENSION) -> GpuTimerVerdict.NO_EXTENSION
    isArm(vendor, renderer) -> GpuTimerVerdict.ARM_MALI
    isVirtual(renderer) -> GpuTimerVerdict.VIRTUAL_GPU
    else -> GpuTimerVerdict.ALLOWED
  }

  /** True when the space separated list [extensions] holds the exact token [name] */
  fun hasExtension(extensions: String?, name: String): Boolean =
    extensions != null && name.isNotEmpty() && extensions.split(WHITESPACE).contains(name)

  /**
   * The key of a driver for the crash guard: the renderer and GL_VERSION, which carries the driver release (on Mali,
   * for example "OpenGL ES 3.2 v1.r26p0-01eac0"). A driver update makes a new key.
   */
  fun driverKey(renderer: String?, version: String?): String {
    val key = "${renderer?.trim().orEmpty()} | ${version?.trim().orEmpty()}"
    return key.replace(CONTROL, " ").take(MAX_DRIVER_KEY_LENGTH)
  }

  /** Vendor ARM (as a word), or a renderer that names a Mali or an Immortalis GPU, in any case */
  private fun isArm(vendor: String?, renderer: String?): Boolean {
    val armVendor = vendor != null && vendor.split(NOT_ALPHANUMERIC).any { it.equals("ARM", ignoreCase = true) }
    val name = renderer?.lowercase(Locale.ROOT).orEmpty()
    return armVendor || name.contains("mali") || name.contains("immortalis")
  }

  private fun isVirtual(renderer: String?): Boolean {
    val name = renderer?.lowercase(Locale.ROOT).orEmpty()
    return name.contains("virgl") || name.contains("virtio")
  }
}
