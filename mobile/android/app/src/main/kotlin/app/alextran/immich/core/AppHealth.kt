package app.alextran.immich.core

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * What the app tells its Logs page about its own health, which only logcat (or nothing) kept before, out of reach of
 * a TV user:
 * - the stalls of the main thread, where Flutter runs Dart since 3.29: while the app is in the foreground ([watch]),
 *   a watchdog thread posts to the main looper every [CHECK_INTERVAL_MS]. A post that waits [STALL_MS] or more is a
 *   stall: the watchdog records the stack of the main thread and the memory at that moment, and reports the stall
 *   with its length once the main thread is back. A stall of 5 s is what Android shows as "not responding".
 * - why the process ended the last times (Android 11 and later): an ANR with the main thread of its trace, a crash,
 *   the low memory killer. Each end is reported once.
 *
 * Flutter takes the reports on [CHANNEL]: "takeReports" gives those made so far, then each new one comes as "report",
 * a map of its kind ("stall" or "exit") and its text.
 */
object AppHealth {
  private const val TAG = "AppHealth"
  const val CHANNEL = "immuch360/app_health"
  const val CHECK_INTERVAL_MS = 500L
  const val STALL_MS = 3_000L
  private const val MAX_PENDING = 20
  private const val MAX_STACK_FRAMES = 30
  private const val MAX_TRACE_LINES = 60
  private const val PREFERENCES = "immuch360_app_health"
  private const val LAST_EXIT = "lastExitTimestamp"

  private val main by lazy { Handler(Looper.getMainLooper()) }
  private val pending = ArrayList<Map<String, String>>()
  private var channel: MethodChannel? = null
  private var flutterTookReports = false
  private var exitsRead = false
  private var watchdog: Watchdog? = null

  /** Listens to Flutter on [messenger], and reads the ends of the process once (main thread) */
  fun attach(context: Context, messenger: BinaryMessenger) {
    channel =
      MethodChannel(messenger, CHANNEL).also {
        it.setMethodCallHandler { call, result ->
          if (call.method == "takeReports") {
            flutterTookReports = true
            val reports = ArrayList(pending)
            pending.clear()
            result.success(reports)
          } else {
            result.notImplemented()
          }
        }
      }
    if (!exitsRead) {
      exitsRead = true
      val appContext = context.applicationContext
      Thread({ readExits(appContext) }, "Immuch360 exits").start()
    }
  }

  fun detach() {
    channel?.setMethodCallHandler(null)
    channel = null
    flutterTookReports = false
  }

  /** Watches the main thread while [on]: the app is in the foreground (main thread) */
  fun watch(context: Context, on: Boolean) {
    if (on) {
      val current = watchdog ?: Watchdog(context.applicationContext).also { watchdog = it }
      current.resumeWatching()
    } else {
      watchdog?.pauseWatching()
    }
  }

  private fun report(kind: String, text: String) {
    Log.w(TAG, text)
    main.post {
      val report = mapOf("kind" to kind, "text" to text)
      val current = channel
      if (current != null && flutterTookReports) {
        current.invokeMethod("report", report)
      } else {
        if (pending.size >= MAX_PENDING) pending.removeAt(0)
        pending.add(report)
      }
    }
  }

  private fun readExits(context: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
      return
    }
    try {
      val activityManager = context.getSystemService(ActivityManager::class.java) ?: return
      val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
      val lastSeen = preferences.getLong(LAST_EXIT, 0L)
      val exits = activityManager.getHistoricalProcessExitReasons(context.packageName, 0, 5)
        .filter { it.timestamp > lastSeen }
        .sortedBy { it.timestamp }
      exits.maxOfOrNull { it.timestamp }?.let { preferences.edit().putLong(LAST_EXIT, it).apply() }
      for (exit in exits.filter { isWorthReporting(it.reason) }) {
        val trace =
          if (exit.reason == ApplicationExitInfo.REASON_ANR) {
            try {
              exit.traceInputStream?.bufferedReader()?.use { mainThreadOfTrace(it.readText()) }
            } catch (error: Exception) {
              "trace unreadable: ${error.message}"
            }
          } else {
            null
          }
        report(
          "exit",
          describeExit(
            reason = reasonName(exit.reason),
            timestamp = exit.timestamp,
            description = exit.description,
            pssKb = exit.pss,
            rssKb = exit.rss,
            trace = trace,
          ),
        )
      }
    } catch (error: Exception) {
      Log.w(TAG, "Cannot read why the app ended last time", error)
    }
  }

  /** The ends of the process worth a word: not those the user or the app chose, nor an update */
  fun isWorthReporting(reason: Int): Boolean =
    reason == ApplicationExitInfo.REASON_ANR ||
      reason == ApplicationExitInfo.REASON_CRASH ||
      reason == ApplicationExitInfo.REASON_CRASH_NATIVE ||
      reason == ApplicationExitInfo.REASON_LOW_MEMORY ||
      reason == ApplicationExitInfo.REASON_SIGNALED ||
      reason == ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE ||
      reason == ApplicationExitInfo.REASON_INITIALIZATION_FAILURE ||
      reason == ApplicationExitInfo.REASON_DEPENDENCY_DIED

  private fun reasonName(reason: Int): String =
    when (reason) {
      ApplicationExitInfo.REASON_ANR -> "not responding (ANR)"
      ApplicationExitInfo.REASON_CRASH -> "crash"
      ApplicationExitInfo.REASON_CRASH_NATIVE -> "native crash"
      ApplicationExitInfo.REASON_LOW_MEMORY -> "killed for low memory"
      ApplicationExitInfo.REASON_SIGNALED -> "killed by a signal (often the low memory killer)"
      ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "killed for excessive resource use"
      ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "failed to start"
      ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "a process it depends on died"
      else -> "reason $reason"
    }

  /** The text of an end of the process, sizes in kB as ApplicationExitInfo gives them */
  fun describeExit(
    reason: String,
    timestamp: Long,
    description: String?,
    pssKb: Long,
    rssKb: Long,
    trace: String?,
  ): String {
    val date = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.ROOT).format(Date(timestamp))
    val memory = if (pssKb > 0 || rssKb > 0) ", memory PSS ${pssKb / 1024} MB, RSS ${rssKb / 1024} MB" else ""
    val details = description?.takeIf { it.isNotBlank() }?.let { " ($it)" } ?: ""
    val traceText = trace?.let { "\nMain thread at the ANR:\n$it" } ?: ""
    return "The app ended on $date: $reason$details$memory$traceText"
  }

  /**
   * The main thread of an ANR trace: from its header line ("main" prio=...) to the next blank line, at most
   * [MAX_TRACE_LINES] lines; null when the trace has none
   */
  fun mainThreadOfTrace(trace: String): String? {
    val lines = trace.lines()
    val start = lines.indexOfFirst { it.startsWith("\"main\"") }
    if (start < 0) {
      return null
    }
    val end = (start until lines.size).firstOrNull { lines[it].isBlank() } ?: lines.size
    return lines.subList(start, minOf(end, start + MAX_TRACE_LINES)).joinToString("\n")
  }

  /** The text of a stall of the main thread */
  fun describeStall(lengthMs: Long, stack: List<String>, memory: String): String {
    val nativeOnly = stack.firstOrNull()?.contains("nativePollOnce") == true
    val where =
      if (nativeOnly) "busy in native code (Dart or the Flutter engine), no Java frame" else "in Java code"
    val seconds = String.format(Locale.ROOT, "%.1f", lengthMs / 1000.0)
    return "The main thread did not answer for $seconds s, $where. $memory\nMain thread:\n" +
      stack.take(MAX_STACK_FRAMES).joinToString("\n") { "  at $it" }
  }

  private fun memoryNow(context: Context): String {
    val activityManager = context.getSystemService(ActivityManager::class.java)
    val info = ActivityManager.MemoryInfo().also { activityManager?.getMemoryInfo(it) }
    val runtime = Runtime.getRuntime()
    val javaUsed = (runtime.totalMemory() - runtime.freeMemory()) shr 20
    return "Memory: ${info.availMem shr 20} MB free of ${info.totalMem shr 20} MB" +
      " (low: ${info.lowMemory}, threshold ${info.threshold shr 20} MB)," +
      " Java heap $javaUsed of ${runtime.maxMemory() shr 20} MB, native heap ${Debug.getNativeHeapAllocatedSize() shr 20} MB."
  }

  /** Posts to the main looper and times the answer, see [AppHealth] */
  private class Watchdog(private val context: Context) : Thread("Immuch360 watchdog") {
    private val lock = ReentrantLock()
    private val resumed = lock.newCondition()
    private var watching = false
    private val answeredAt = AtomicLong(0L)

    init {
      isDaemon = true
      start()
    }

    fun resumeWatching() =
      lock.withLock {
        watching = true
        resumed.signalAll()
      }

    fun pauseWatching() = lock.withLock { watching = false }

    override fun run() {
      try {
        watchLoop()
      } catch (_: InterruptedException) {
        // The process goes away
      }
    }

    private fun watchLoop() {
      while (true) {
        lock.withLock {
          while (!watching) resumed.await()
        }
        val postedAt = SystemClock.uptimeMillis()
        answeredAt.set(0L)
        main.post { answeredAt.set(SystemClock.uptimeMillis()) }
        var stack: List<String>? = null
        var memory = ""
        while (answeredAt.get() == 0L) {
          sleep(100)
          val waited = SystemClock.uptimeMillis() - postedAt
          if (stack == null && waited >= STALL_MS && !Debug.isDebuggerConnected()) {
            stack = Looper.getMainLooper().thread.stackTrace.map { it.toString() }
            memory = memoryNow(context)
          }
        }
        val length = answeredAt.get() - postedAt
        // A pause of the watching (the app went to the background) is not a stall
        if (stack != null && length >= STALL_MS && lock.withLock { watching }) {
          report("stall", describeStall(length, stack, memory))
        }
        sleep((CHECK_INTERVAL_MS - length).coerceAtLeast(0L) + 1)
      }
    }
  }
}
