package app.alextran.immich.core

/**
 * What the Logs page keeps of the trace of an ANR (ApplicationExitInfo.getTraceInputStream of a REASON_ANR end, the
 * dump of the threads Android made when the app stopped answering): the Subject line, which says what timed out, the
 * main thread with its native frames (Flutter runs Dart on it since 3.29: libapp.so and libflutter.so frames), then
 * each other thread whose stack holds a frame of the app or of what it runs (the Flutter engine threads, OkHttp,
 * WorkManager), at most [MAX_LINES] lines in all. The threads of the system (daemons, binder, JIT) are left out, and
 * so are the URLs and the folders of the installed app.
 */
object AnrTraces {
  const val MAX_LINES = 200
  const val MAX_MAIN_LINES = 100

  private val APP_FRAMES =
    listOf(
      "app.alextran.immich",
      "io.flutter",
      "libapp.so",
      "libflutter.so",
      "okhttp3",
      "com.example.ok_http",
      "androidx.work",
    )

  /** The extract of [trace], or null when it holds neither a Subject line nor a thread */
  fun extract(trace: String): String? {
    val lines = trace.lines()
    val subject = lines.firstOrNull { it.startsWith("Subject:") }
    val blocks = threadBlocks(lines)
    val main = blocks.firstOrNull { it.first().startsWith("\"main\"") }
    val others = blocks.filter { block -> block !== main && block.any { line -> APP_FRAMES.any { line.contains(it) } } }
    if (subject == null && main == null && others.isEmpty()) {
      return null
    }
    val out = ArrayList<String>()
    subject?.let { out.add(it) }
    main?.let {
      if (out.isNotEmpty()) out.add("")
      out.addAll(it.take(MAX_MAIN_LINES))
      if (it.size > MAX_MAIN_LINES) out.add("  (${it.size - MAX_MAIN_LINES} more lines)")
    }
    for (block in others) {
      out.add("")
      out.addAll(block)
    }
    val cut = out.size - (MAX_LINES - 1)
    val kept = if (out.size > MAX_LINES) out.take(MAX_LINES - 1) + "(cut: $cut more lines)" else out
    return kept.joinToString("\n") { CrashText.withoutAppFolders(CrashText.withoutUrls(it)) }
  }

  /** The thread blocks of a trace: from a line that opens with a quoted thread name to the next blank line */
  private fun threadBlocks(lines: List<String>): List<List<String>> {
    val blocks = ArrayList<List<String>>()
    var current: ArrayList<String>? = null
    for (line in lines) {
      when {
        line.startsWith("\"") -> current = arrayListOf(line).also { blocks.add(it) }
        line.isBlank() -> current = null
        else -> current?.add(line)
      }
    }
    return blocks
  }
}
