package app.alextran.immich.core

import java.util.Locale

/**
 * The tombstone Android keeps of a native crash, read for the Logs page. From Android 12,
 * ApplicationExitInfo.getTraceInputStream of a REASON_CRASH_NATIVE end gives it in the protobuf form of AOSP's
 * debuggerd (system/core/debuggerd/proto/tombstone.proto). This reads what crashed and where, and only that: the
 * signal with its code and fault address, the causes debuggerd found, the abort message (URLs removed), the crashing
 * thread with its first [MAX_FRAMES] frames and their build IDs (the folders of the installed app removed), and the
 * names of the other threads. The registers, the memory dumps, the memory maps, the open files and the log buffers are
 * skipped unread: no memory content of the app leaves the reader.
 *
 * A small protobuf wire reader: varints, length delimited fields, fixed 32 and 64 bit values; the fields it does not
 * know are skipped (groups too, [MAX_GROUP_DEPTH] deep at most), and it stops at the first malformed or truncated field
 * with what it read so far. It never throws, not even an Error (out of memory, a stack overflow): it runs on the thread
 * that reads why the app ended, where an uncaught Error would end the app at each start.
 *
 * The frames of the Dart code are offsets in libapp.so ("base.apk (offset 0x...)" or "base.apk!libapp.so"): the
 * symbols of the build that the release workflow keeps name them (llvm-symbolizer --obj=libapp.so 0x<pc>), found by
 * the build ID of the frame in their manifest.json.
 */
object TombstoneReader {
  const val MAX_INPUT_BYTES = 4 shl 20
  const val MAX_FRAMES = 40
  const val MAX_OTHER_THREADS = 30
  private const val MAX_FUNCTION_NAME = 200
  private const val MAX_ABORT_MESSAGE = 1000

  // Groups inside groups skipped at most: deeper is malformed, rather than a StackOverflowError of the reader
  private const val MAX_GROUP_DEPTH = 32

  // Architecture of tombstone.proto: the 64 bit ones print their pc on 16 digits, as debuggerd does
  private val ARCH_64 = setOf(1, 3, 4)

  /** The text of the tombstone [bytes] (at most [MAX_INPUT_BYTES] are read), or null when nothing could be read */
  fun read(bytes: ByteArray): String? {
    val tombstone = Tombstone()
    try {
      parseTombstone(Input(bytes, 0, minOf(bytes.size, MAX_INPUT_BYTES)), tombstone)
    } catch (_: Throwable) {
      // Truncated, or not a tombstone (Malformed), or anything else: what was read so far, never a crash of the app
    }
    return try {
      format(tombstone)
    } catch (_: Throwable) {
      null
    }
  }

  private class Signal {
    var number = 0
    var name = ""
    var code = 0
    var codeName = ""
    var hasFaultAddress = false
    var faultAddress = 0L
  }

  private class Frame {
    var relPc = 0L
    var functionName = ""
    var functionOffset = 0L
    var fileName = ""
    var fileMapOffset = 0L
    var buildId = ""
  }

  private class ThreadInfo {
    var id = 0
    var name = ""
    val frames = ArrayList<Frame>()
    var framesLeftOut = 0
  }

  private class Tombstone {
    var arch = 0
    var tid = 0
    var signal: Signal? = null
    var abortMessage = ""
    val causes = ArrayList<String>()
    val threads = ArrayList<ThreadInfo>()
  }

  private fun format(tombstone: Tombstone): String? {
    val signal = tombstone.signal
    if (signal == null && tombstone.threads.isEmpty() && tombstone.abortMessage.isEmpty()) {
      return null
    }
    val lines = ArrayList<String>()
    if (signal != null) {
      val name = signal.name.takeIf { it.isNotEmpty() }?.let { " ($it)" } ?: ""
      val codeName = signal.codeName.takeIf { it.isNotEmpty() }?.let { " ($it)" } ?: ""
      val fault = if (signal.hasFaultAddress) ", fault address 0x${hex(signal.faultAddress)}" else ""
      lines.add("Signal ${signal.number}$name, code ${signal.code}$codeName$fault")
    }
    tombstone.causes.forEach { lines.add("Cause: ${clean(it)}") }
    if (tombstone.abortMessage.isNotEmpty()) {
      lines.add("Abort message: ${clean(tombstone.abortMessage).take(MAX_ABORT_MESSAGE)}")
    }
    val crashing = tombstone.threads.firstOrNull { it.id == tombstone.tid } ?: tombstone.threads.firstOrNull()
    if (crashing != null) {
      lines.add("Crashing thread ${crashing.id} \"${crashing.name}\":")
      val width = if (tombstone.arch in ARCH_64) 16 else 8
      crashing.frames.forEachIndexed { index, frame -> lines.add("  " + frameLine(index, frame, width)) }
      if (crashing.framesLeftOut > 0) {
        lines.add("  (${crashing.framesLeftOut} more frame${if (crashing.framesLeftOut == 1) "" else "s"})")
      }
    }
    val others = tombstone.threads.filter { it !== crashing }
    if (others.isNotEmpty()) {
      val names = others.take(MAX_OTHER_THREADS).joinToString(", ") { it.name.ifEmpty { "tid ${it.id}" } }
      val more = if (others.size > MAX_OTHER_THREADS) " and ${others.size - MAX_OTHER_THREADS} more" else ""
      lines.add("Other threads (${others.size}): $names$more")
    }
    return lines.joinToString("\n")
  }

  /** A frame as debuggerd writes it: #04 pc 000000000190041c  base.apk (offset 0x3988000) (BuildId: 3f3463a7...) */
  private fun frameLine(index: Int, frame: Frame, width: Int): String {
    val pc = hex(frame.relPc).padStart(width, '0')
    val text = StringBuilder(String.format(Locale.ROOT, "#%02d pc %s  %s", index, pc, clean(frame.fileName)))
    if (frame.fileMapOffset != 0L) {
      text.append(" (offset 0x").append(hex(frame.fileMapOffset)).append(')')
    }
    if (frame.functionName.isNotEmpty()) {
      val name = frame.functionName
      text.append(" (").append(if (name.length > MAX_FUNCTION_NAME) "${name.take(MAX_FUNCTION_NAME)}..." else name)
      text.append('+').append(frame.functionOffset).append(')')
    }
    if (frame.buildId.isNotEmpty()) {
      text.append(" (BuildId: ").append(frame.buildId).append(')')
    }
    return text.toString()
  }

  private fun clean(text: String): String = CrashText.withoutAppFolders(CrashText.withoutUrls(text))

  /** [value] in hexadecimal, as an unsigned 64 bit number */
  private fun hex(value: Long): String = java.lang.Long.toHexString(value)

  // The fields of tombstone.proto read here; every other one is skipped

  private fun parseTombstone(input: Input, tombstone: Tombstone) {
    forEachField(input) { number, value, sub ->
      when {
        number == 1 && sub == null -> tombstone.arch = value.toInt()
        number == 6 && sub == null -> tombstone.tid = value.toInt()
        number == 10 && sub != null -> parseSignal(sub, Signal().also { tombstone.signal = it })
        number == 14 && sub != null -> tombstone.abortMessage = sub.string()
        number == 15 && sub != null -> parseCause(sub, tombstone.causes)
        number == 16 && sub != null -> parseThreadEntry(sub, tombstone.threads)
      }
    }
  }

  private fun parseSignal(input: Input, signal: Signal) {
    forEachField(input) { number, value, sub ->
      when {
        number == 1 && sub == null -> signal.number = value.toInt()
        number == 2 && sub != null -> signal.name = sub.string()
        number == 3 && sub == null -> signal.code = value.toInt()
        number == 4 && sub != null -> signal.codeName = sub.string()
        number == 8 && sub == null -> signal.hasFaultAddress = value != 0L
        number == 9 && sub == null -> signal.faultAddress = value
      }
    }
  }

  private fun parseCause(input: Input, causes: MutableList<String>) {
    forEachField(input) { number, _, sub ->
      if (number == 1 && sub != null) {
        causes.add(sub.string())
      }
    }
  }

  /** An entry of the map of threads: the thread id (key, 1), the thread (value, 2) */
  private fun parseThreadEntry(input: Input, threads: MutableList<ThreadInfo>) {
    var key = 0
    var thread: ThreadInfo? = null
    forEachField(input) { number, value, sub ->
      if (number == 1 && sub == null) {
        key = value.toInt()
        thread?.let { if (it.id == 0) it.id = key }
      } else if (number == 2 && sub != null) {
        val current = ThreadInfo().also { it.id = key }
        thread = current
        threads.add(current)
        parseThread(sub, current)
      }
    }
  }

  private fun parseThread(input: Input, thread: ThreadInfo) {
    forEachField(input) { number, value, sub ->
      when {
        number == 1 && sub == null -> thread.id = value.toInt()
        number == 2 && sub != null -> thread.name = sub.string()
        // current_backtrace; 3 (registers) and 5 (memory_dump) are never read
        number == 4 && sub != null ->
          if (thread.frames.size < MAX_FRAMES) {
            parseFrame(sub, Frame().also { thread.frames.add(it) })
          } else {
            thread.framesLeftOut++
          }
      }
    }
  }

  private fun parseFrame(input: Input, frame: Frame) {
    forEachField(input) { number, value, sub ->
      when {
        number == 1 && sub == null -> frame.relPc = value
        number == 4 && sub != null -> frame.functionName = sub.string()
        number == 5 && sub == null -> frame.functionOffset = value
        number == 6 && sub != null -> frame.fileName = sub.string()
        number == 7 && sub == null -> frame.fileMapOffset = value
        number == 8 && sub != null -> frame.buildId = sub.string()
      }
    }
  }

  // The protobuf wire format

  private class Malformed : RuntimeException()

  private class Input(val bytes: ByteArray, var at: Int, val end: Int) {
    fun string(): String = String(bytes, at, end - at, Charsets.UTF_8)
  }

  /**
   * Calls [onField] with the number of each field of the message in [input] and its value: a number for the varint
   * and fixed fields (sub null), the bytes of a length delimited field as an input of their own (value its length).
   * A length delimited field cut by the end of the input is handed as far as it goes, then the reading stops.
   */
  private inline fun forEachField(input: Input, onField: (number: Int, value: Long, sub: Input?) -> Unit) {
    while (input.at < input.end) {
      val key = varint(input)
      val number = (key ushr 3).toInt()
      when ((key and 7L).toInt()) {
        0 -> onField(number, varint(input), null)
        1 -> onField(number, fixed(input, 8), null)
        5 -> onField(number, fixed(input, 4), null)
        2 -> {
          val length = varint(input)
          if (length < 0) {
            throw Malformed()
          }
          val start = input.at
          val available = input.end - start
          val cut = length > available
          val stop = if (cut) input.end else start + length.toInt()
          input.at = stop
          onField(number, length, Input(input.bytes, start, stop))
          if (cut) {
            throw Malformed()
          }
        }
        // A group (proto2 only, not in tombstone.proto): skipped whole
        3 -> skipGroup(input, number, 1)
        // The end of a group that did not start, or the wire types 6 and 7, which do not exist
        else -> throw Malformed()
      }
    }
  }

  private fun skipGroup(input: Input, group: Int, depth: Int) {
    if (depth > MAX_GROUP_DEPTH) {
      throw Malformed()
    }
    while (true) {
      val key = varint(input)
      val number = (key ushr 3).toInt()
      when ((key and 7L).toInt()) {
        0 -> varint(input)
        1 -> fixed(input, 8)
        5 -> fixed(input, 4)
        2 -> {
          val length = varint(input)
          if (length < 0 || length > input.end - input.at) {
            throw Malformed()
          }
          input.at += length.toInt()
        }
        3 -> skipGroup(input, number, depth + 1)
        4 -> if (number == group) return else throw Malformed()
        else -> throw Malformed()
      }
    }
  }

  private fun varint(input: Input): Long {
    var result = 0L
    var shift = 0
    while (shift < 64) {
      if (input.at >= input.end) {
        throw Malformed()
      }
      val byte = input.bytes[input.at++].toInt()
      result = result or ((byte and 0x7F).toLong() shl shift)
      if (byte and 0x80 == 0) {
        return result
      }
      shift += 7
    }
    throw Malformed()
  }

  private fun fixed(input: Input, size: Int): Long {
    if (input.end - input.at < size) {
      input.at = input.end
      throw Malformed()
    }
    var result = 0L
    for (i in 0 until size) {
      result = result or ((input.bytes[input.at + i].toLong() and 0xFF) shl (8 * i))
    }
    input.at += size
    return result
  }
}
