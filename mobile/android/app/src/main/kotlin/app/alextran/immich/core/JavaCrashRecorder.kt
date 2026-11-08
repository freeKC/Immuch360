package app.alextran.immich.core

import java.io.File

/**
 * The stack of a Java or Kotlin crash, for the Logs page at the next start. Android records the end of the process
 * (ApplicationExitInfo.REASON_CRASH, its description "crash") but no text for it, unlike an ANR or a native crash:
 * this handler of uncaught exceptions, put in front of Android's own as the process starts, writes the thread and the
 * stack with its causes (URLs removed, at most [MAX_BYTES] bytes) to [FILE_NAME], then always hands the exception to
 * the handler that was there, which ends the process as before. At the next start [AppHealth] gives that stack to
 * the REASON_CRASH end that came within [MATCH_WINDOW_MS] after it.
 *
 * The frames carry the names of the shrunk build (R8): the build in the header of the report says which mapping.txt
 * retraces them (the symbols artifact of the release workflow, or the proguard.map of the phone bundle).
 */
object JavaCrashRecorder {
  const val FILE_NAME = "java-crash.txt"
  const val MAX_BYTES = 64 * 1024
  const val MATCH_WINDOW_MS = 30_000L
  private const val TIME = "time "

  @Volatile private var installed = false

  /** Puts the recorder in front of the default handler, writing to [folder]; first thing of the process */
  @Synchronized
  fun install(folder: File) {
    if (installed) {
      return
    }
    installed = true
    Thread.setDefaultUncaughtExceptionHandler(handler(folder, Thread.getDefaultUncaughtExceptionHandler()))
  }

  /** The handler that records to [folder], then hands every exception to [previous], whatever happens before */
  fun handler(
    folder: File,
    previous: Thread.UncaughtExceptionHandler?,
    now: () -> Long = System::currentTimeMillis,
  ): Thread.UncaughtExceptionHandler =
    Thread.UncaughtExceptionHandler { thread, error ->
      try {
        write(folder, thread.name, error, now())
      } catch (_: Throwable) {
        // Nothing of the recorder may stand between the crash and the handler of Android
      } finally {
        previous?.uncaughtException(thread, error)
      }
    }

  /** Writes [error], thrown on the thread [threadName] at [timeMs], to [FILE_NAME] in [folder] */
  fun write(folder: File, threadName: String, error: Throwable, timeMs: Long) {
    folder.mkdirs()
    val stack = CrashText.withoutUrls(error.stackTraceToString())
    val text = "$TIME$timeMs\n${CrashText.withoutUrls(threadName)}\n$stack"
    File(folder, FILE_NAME).writeText(CrashText.cutUtf8(text, MAX_BYTES))
  }

  /**
   * The crash recorded in [folder] for an end of the process at [exitTimestamp]: the thread and the stack, when it was
   * written at most [MATCH_WINDOW_MS] before; the file is then deleted, as when it is too old for that end (the ends
   * come in the order of their time). A crash recorded after [exitTimestamp] is kept for a later end.
   */
  fun take(folder: File, exitTimestamp: Long): String? {
    val file = File(folder, FILE_NAME)
    if (!file.isFile) {
      return null
    }
    val parts =
      try {
        file.readText().split('\n', limit = 3)
      } catch (_: Exception) {
        return null
      }
    val time = parts[0].removePrefix(TIME).toLongOrNull()
    if (time == null || time < exitTimestamp - MATCH_WINDOW_MS) {
      file.delete()
      return null
    }
    if (time > exitTimestamp) {
      return null
    }
    file.delete()
    return "Java crash on the thread \"${parts.getOrElse(1) { "" }}\":\n${parts.getOrElse(2) { "" }.trimEnd()}"
  }

  /** Deletes a crash recorded in [folder] before [timestamp]: no end after it can be its own */
  fun discardBefore(folder: File, timestamp: Long) {
    val file = File(folder, FILE_NAME)
    val time =
      try {
        file.takeIf { it.isFile }?.useLines { it.firstOrNull() }?.removePrefix(TIME)?.toLongOrNull()
      } catch (_: Exception) {
        null
      }
    if (time != null && time < timestamp) {
      file.delete()
    }
  }
}
