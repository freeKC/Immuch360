package app.alextran.immich.core

import android.app.ActivityManager
import android.app.ActivityManager.RunningAppProcessInfo
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.annotation.RequiresApi
import app.alextran.immich.BuildConfig
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
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
 * - why the process ended the last times (Android 11 and later), read at the start of every process ([collectExits],
 *   from ImmichApp), whatever started it: the app, a background worker. Each end worth a word is reported once, with
 *   the build that ran (version code and flavour), whether the app was in the foreground, its last known state, and
 *   what Android kept of it: the threads of an ANR ([AnrTraces]), the tombstone of a native crash on Android 12 and
 *   later ([TombstoneReader]), the stack of a Java crash ([JavaCrashRecorder]). A report is written to a file
 *   ([PendingReports]) before the end counts as read, and the file is deleted once Flutter has written the report to
 *   its log: a death in between repeats a report at the next start rather than losing it.
 *
 * Other parts of the app report through [report] too: the 360° player, a video it cannot play.
 *
 * Flutter takes the reports on [CHANNEL]: "takeReports" gives those made so far, then each new one comes as "report",
 * a map of its kind ("stall", "exit" or "video") and its text, with the "id" of its file for the ends; Flutter answers
 * "reportsWritten" with those ids once the reports are in its log. "setState" gives the state of the app (its page,
 * foreground or background), which Android returns with the end of the process ([stateSummary]).
 */
object AppHealth {
  private const val TAG = "AppHealth"
  const val CHANNEL = "immuch360/app_health"
  const val CHECK_INTERVAL_MS = 500L
  const val STALL_MS = 3_000L
  private const val MAX_PENDING = 20
  private const val MAX_STACK_FRAMES = 30
  /** The reports of ends kept until Flutter has written them ([PendingReports]), and the size of each */
  const val MAX_PENDING_FILES = 20
  const val MAX_REPORT_BYTES = 32 * 1024

  /** What ActivityManager.setProcessStateSummary keeps */
  const val MAX_STATE_BYTES = 128
  private const val MAX_TRACE_BYTES = 4 shl 20
  private const val PREFERENCES = "immuch360_app_health"
  private const val LAST_EXIT = "lastExitTimestamp"
  private const val FOLDER = "app_health"
  private const val PENDING_FOLDER = "pending"

  // RunningAppProcessInfo.IMPORTANCE_TOP_SLEEPING, deprecated since Android 9 but still what an end can say
  private const val IMPORTANCE_TOP_SLEEPING = 325

  private val main by lazy { Handler(Looper.getMainLooper()) }

  // The files of the reports and the state summary, off the main thread, in order
  private val files by lazy {
    Executors.newSingleThreadExecutor { Thread(it, "Immuch360 health").apply { isDaemon = true } }
  }
  private val pending = ArrayList<Map<String, String>>()
  private var channel: MethodChannel? = null
  private var flutterTookReports = false
  private val exitsCollected = AtomicBoolean(false)
  private var watchdog: Watchdog? = null

  // The state of the app Flutter gave last (setState)
  @Volatile private var appState = ""
  private val BUILD_IN_SUMMARY = Regex("""\d+ [A-Za-z0-9]+""")

  /** The folder of the health files of the app: filesDir/app_health */
  fun folder(context: Context): File = File(context.filesDir, FOLDER)

  /** Listens to Flutter on [messenger] (main thread) */
  fun attach(context: Context, messenger: BinaryMessenger) {
    val appContext = context.applicationContext
    channel =
      MethodChannel(messenger, CHANNEL).also {
        it.setMethodCallHandler { call, result ->
          when (call.method) {
            "takeReports" -> {
              flutterTookReports = true
              val reports = ArrayList(pending)
              pending.clear()
              result.success(reports)
            }
            "reportsWritten" -> {
              val ids = (call.arguments as? List<*>)?.filterIsInstance<String>().orEmpty()
              files.execute { PendingReports.delete(File(folder(appContext), PENDING_FOLDER), ids) }
              result.success(null)
            }
            "setState" -> {
              setState(appContext, call.arguments as? String ?: "")
              result.success(null)
            }
            else -> result.notImplemented()
          }
        }
      }
    // ImmichApp has started the reading already; this covers a process whose Application did not
    collectExits(appContext)
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

  /**
   * Sends [text] to the Logs page as a report of [kind] ("stall", "exit", or "video" for a video the 360° player
   * cannot play), kept until Flutter takes it; also to logcat. Any thread.
   */
  fun report(kind: String, text: String) {
    Log.w(TAG, text)
    main.post { post(mapOf("kind" to kind, "text" to text)) }
  }

  /** Hands [report] to Flutter when it listens, or keeps it until it does (main thread) */
  private fun post(report: Map<String, String>) {
    val current = channel
    if (current != null && flutterTookReports) {
      current.invokeMethod("report", report)
    } else {
      if (pending.size >= MAX_PENDING) pending.removeAt(0)
      pending.add(report)
    }
  }

  /**
   * Reads why the process ended the last times, once per process, on a thread of its own: at the start of every
   * process (ImmichApp.onCreate), so that the ends of a process started in the background are read too. The reports
   * of the files left by earlier processes, which Flutter did not write yet, come with them.
   */
  fun collectExits(context: Context) {
    if (!exitsCollected.compareAndSet(false, true)) {
      return
    }
    val appContext = context.applicationContext
    files.execute {
      try {
        collect(appContext)
      } catch (error: Exception) {
        Log.w(TAG, "Cannot read why the app ended last time", error)
      }
    }
  }

  private fun collect(context: Context) {
    val healthFolder = folder(context)
    val pendingFolder = File(healthFolder, PENDING_FOLDER)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      // The build of this process, which Android gives back with its end
      writeStateSummary(context)
      // Whether the system tells the low memory killer apart (REASON_LOW_MEMORY), or reports its kills as signals
      Log.i(TAG, "Low memory kill reports supported: ${ActivityManager.isLowMemoryKillReportSupported()}")
      writeNewExits(context, healthFolder, pendingFolder)
    }
    val reports = PendingReports.load(pendingFolder)
    if (reports.isNotEmpty()) {
      main.post { reports.forEach { (id, text) -> post(mapOf("kind" to "exit", "text" to text, "id" to id)) } }
    }
  }

  @RequiresApi(Build.VERSION_CODES.R)
  private fun writeNewExits(context: Context, healthFolder: File, pendingFolder: File) {
    val activityManager = context.getSystemService(ActivityManager::class.java) ?: return
    val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    val lastSeen = preferences.getLong(LAST_EXIT, 0L)
    // 0: every end the system keeps (16 per package in AOSP), a crash among background starts included
    val exits =
      activityManager.getHistoricalProcessExitReasons(context.packageName, 0, 0)
        .filter { it.timestamp > lastSeen }
        .sortedBy { it.timestamp }
    var read = lastSeen
    for (exit in exits) {
      if (isWorthReporting(exit.reason)) {
        val text = describe(exit, healthFolder)
        Log.w(TAG, text)
        if (!PendingReports.write(pendingFolder, PendingReports.id(exit.timestamp, exit.pid), text)) {
          // No room: this end and the next ones are read again at the next start
          Log.w(TAG, "Cannot keep the report of an end in $pendingFolder")
          break
        }
      }
      read = exit.timestamp
    }
    if (read > lastSeen) {
      preferences.edit().putLong(LAST_EXIT, read).commit()
    }
    exits.lastOrNull()?.let {
      JavaCrashRecorder.discardBefore(healthFolder, it.timestamp - JavaCrashRecorder.MATCH_WINDOW_MS)
    }
  }

  @RequiresApi(Build.VERSION_CODES.R)
  private fun describe(exit: ApplicationExitInfo, healthFolder: File): String {
    val summary = readStateSummary(exit.processStateSummary)
    return describeExit(
      reason = reasonName(exit.reason, exit.status),
      timestamp = exit.timestamp,
      description = exit.description,
      pssKb = exit.pss,
      rssKb = exit.rss,
      importance = exit.importance,
      build = summary.build ?: "build not recorded, now ${currentBuild()}",
      state = summary.state,
      details = details(exit, healthFolder),
    )
  }

  /** What Android kept of the end [exit]: the threads of an ANR, the tombstone of a native crash, the Java stack */
  @RequiresApi(Build.VERSION_CODES.R)
  private fun details(exit: ApplicationExitInfo, healthFolder: File): String? =
    when (exit.reason) {
      ApplicationExitInfo.REASON_ANR ->
        readTrace(exit)?.let { AnrTraces.extract(String(it, Charsets.UTF_8)) }?.let { "Threads at the ANR:\n$it" }
          ?: "No trace of the ANR kept by the system."
      ApplicationExitInfo.REASON_CRASH_NATIVE ->
        // The tombstone from Android 12; the system keeps a few for all apps, a newer crash can replace it
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
          null
        } else {
          readTrace(exit)?.let { TombstoneReader.read(it) ?: "The tombstone of the crash could not be read." }
            ?: "No tombstone kept by the system."
        }
      ApplicationExitInfo.REASON_CRASH ->
        JavaCrashRecorder.take(healthFolder, exit.timestamp) ?: "No Java stack recorded for this crash."
      else -> null
    }

  @RequiresApi(Build.VERSION_CODES.R)
  private fun readTrace(exit: ApplicationExitInfo): ByteArray? =
    try {
      exit.traceInputStream?.use { readAtMost(it, MAX_TRACE_BYTES) }
    } catch (error: Exception) {
      Log.w(TAG, "Cannot read the trace of an end", error)
      null
    }

  private fun readAtMost(stream: InputStream, limit: Int): ByteArray {
    val out = ByteArrayOutputStream()
    val buffer = ByteArray(64 * 1024)
    while (out.size() < limit) {
      val read = stream.read(buffer, 0, minOf(buffer.size, limit - out.size()))
      if (read < 0) {
        break
      }
      out.write(buffer, 0, read)
    }
    return out.toByteArray()
  }

  /** The version code and the flavour of this build: "3030042 quest" */
  fun currentBuild(): String = "${BuildConfig.VERSION_CODE} ${BuildConfig.FLAVOR}"

  /**
   * The state of the app, a few words without a name, a path nor an address (its page, foreground or background),
   * which Android keeps with the process and gives back with its end (Android 11 and later)
   */
  private fun setState(context: Context, state: String) {
    if (state == appState) {
      return
    }
    appState = state
    files.execute { writeStateSummary(context) }
  }

  private fun writeStateSummary(context: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
      return
    }
    try {
      val summary = stateSummary(currentBuild(), appState)
      context.getSystemService(ActivityManager::class.java)?.setProcessStateSummary(summary)
    } catch (error: Exception) {
      Log.w(TAG, "Cannot keep the state of the app", error)
    }
  }

  /** The state summary of a process of the build [build] in the state [state]: "3030042 quest|state", 128 bytes */
  fun stateSummary(build: String, state: String): ByteArray =
    CrashText.cutUtf8("$build|$state", MAX_STATE_BYTES).toByteArray(Charsets.UTF_8)

  class StateSummary(val build: String?, val state: String?)

  /** The build and the state of a summary of [stateSummary]; no build for another summary, or none */
  fun readStateSummary(bytes: ByteArray?): StateSummary {
    val text = bytes?.toString(Charsets.UTF_8)?.takeIf { it.isNotBlank() } ?: return StateSummary(null, null)
    val bar = text.indexOf('|')
    val build = if (bar > 0) text.substring(0, bar) else null
    if (build == null || !BUILD_IN_SUMMARY.matches(build)) {
      return StateSummary(null, text)
    }
    return StateSummary(build, text.substring(bar + 1).takeIf { it.isNotBlank() })
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

  /**
   * The words for an end of [reason], with its [status] (ApplicationExitInfo.getStatus: the signal of an end by a
   * signal). A signal 6 is an abort the process asked for itself (SIGABRT, a native library giving up, as the splat
   * module does on a file it cannot read), not the low memory killer, whose signal is 9 (SIGKILL)
   */
  fun reasonName(reason: Int, status: Int = 0): String =
    when (reason) {
      ApplicationExitInfo.REASON_ANR -> "not responding (ANR)"
      ApplicationExitInfo.REASON_CRASH -> "crash"
      ApplicationExitInfo.REASON_CRASH_NATIVE -> "native crash"
      ApplicationExitInfo.REASON_LOW_MEMORY -> "killed for low memory"
      ApplicationExitInfo.REASON_SIGNALED -> signalName(status)
      ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "killed for excessive resource use"
      ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "failed to start"
      ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "a process it depends on died"
      else -> "reason $reason"
    }

  /** An end by the signal [signal] */
  fun signalName(signal: Int): String =
    when (signal) {
      SIGABRT -> "a native abort (signal 6, SIGABRT): a native library stopped the app"
      SIGKILL -> "killed by signal 9 (SIGKILL, often the low memory killer)"
      SIGSEGV -> "a native crash (signal 11, SIGSEGV)"
      0 -> "killed by a signal"
      else -> "killed by signal $signal"
    }

  private const val SIGABRT = 6
  private const val SIGKILL = 9
  private const val SIGSEGV = 11

  /**
   * Where the app stood when it ended, from ApplicationExitInfo.getImportance: in the foreground, visible, in the
   * background; null when Android did not say
   */
  fun importanceName(importance: Int): String? =
    when (importance) {
      0 -> null
      RunningAppProcessInfo.IMPORTANCE_FOREGROUND -> "in the foreground"
      RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE -> "running a foreground service"
      RunningAppProcessInfo.IMPORTANCE_VISIBLE -> "visible"
      RunningAppProcessInfo.IMPORTANCE_PERCEPTIBLE -> "in the background, perceptible"
      RunningAppProcessInfo.IMPORTANCE_SERVICE -> "in the background, running a service"
      IMPORTANCE_TOP_SLEEPING -> "in the foreground, screen off"
      RunningAppProcessInfo.IMPORTANCE_CANT_SAVE_STATE -> "in the background"
      RunningAppProcessInfo.IMPORTANCE_CACHED -> "in the background, cached"
      RunningAppProcessInfo.IMPORTANCE_GONE -> "gone"
      else -> "importance $importance"
    }

  /**
   * The text of an end of the process: when, why, where the app stood ([importance]), the memory (sizes in kB as
   * ApplicationExitInfo gives them), the [build] that ran, then its last known [state] and the [details] Android kept;
   * at most [MAX_REPORT_BYTES] bytes
   */
  fun describeExit(
    reason: String,
    timestamp: Long,
    description: String?,
    pssKb: Long,
    rssKb: Long,
    importance: Int = 0,
    build: String? = null,
    state: String? = null,
    details: String? = null,
  ): String {
    val date = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.ROOT).format(Date(timestamp))
    val descriptionText = description?.takeIf { it.isNotBlank() }?.let { " (${CrashText.withoutUrls(it)})" } ?: ""
    val where = importanceName(importance)?.let { ", $it" } ?: ""
    val memory = if (pssKb > 0 || rssKb > 0) ", memory PSS ${pssKb / 1024} MB, RSS ${rssKb / 1024} MB" else ""
    val buildText = build?.let { " [Immuch360 $it]" } ?: ""
    val stateText = state?.takeIf { it.isNotBlank() }?.let { "\nLast known state: $it" } ?: ""
    val detailsText = details?.let { "\n$it" } ?: ""
    val text = "The app ended on $date: $reason$descriptionText$where$memory$buildText$stateText$detailsText"
    return CrashText.cutUtf8(text, MAX_REPORT_BYTES)
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

/**
 * The reports of the ends of the process, one file each in filesDir/app_health/pending named <time>-<pid>.txt, kept
 * from the moment the end is read until Flutter has written the report to its log (AppHealth, "reportsWritten"): a
 * death in between gives the report again at the next start instead of losing it. At most
 * [AppHealth.MAX_PENDING_FILES] files of [AppHealth.MAX_REPORT_BYTES] bytes, the oldest dropped.
 */
object PendingReports {
  private val ID = Regex("""\d+-\d+\.txt""")

  /** The id of the report of the end of the process [pid] at [timestamp] */
  fun id(timestamp: Long, pid: Int): String = "$timestamp-$pid.txt"

  /** Writes [text] as the report [id] in [folder], whole or not at all; false when it could not */
  fun write(folder: File, id: String, text: String, maxFiles: Int = AppHealth.MAX_PENDING_FILES): Boolean =
    try {
      folder.mkdirs()
      val temporary = File(folder, "$id.tmp")
      temporary.writeText(CrashText.cutUtf8(text, AppHealth.MAX_REPORT_BYTES))
      val written = temporary.renameTo(File(folder, id))
      if (!written) {
        temporary.delete()
      }
      ids(folder).dropLast(maxFiles).forEach { File(folder, it).delete() }
      written
    } catch (_: Exception) {
      false
    }

  /** The reports kept in [folder], the oldest first: their ids and texts */
  fun load(folder: File): List<Pair<String, String>> {
    folder.listFiles { file -> file.name.endsWith(".tmp") }?.forEach { it.delete() }
    return ids(folder).mapNotNull { id ->
      try {
        id to File(folder, id).readText()
      } catch (_: Exception) {
        null
      }
    }
  }

  /** Deletes the reports [ids] of [folder], which Flutter has written; a name that is not an id is left alone */
  fun delete(folder: File, ids: List<String>) {
    ids.filter { ID.matches(it) }.forEach { File(folder, it).delete() }
  }

  private fun ids(folder: File): List<String> =
    (folder.list() ?: emptyArray())
      .filter { ID.matches(it) }
      .sortedWith(compareBy<String>({ it.substringBefore('-').toLongOrNull() ?: 0L }, { it }))
}
