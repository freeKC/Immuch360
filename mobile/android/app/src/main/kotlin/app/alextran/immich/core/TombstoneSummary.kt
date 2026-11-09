package app.alextran.immich.core

import java.io.ByteArrayOutputStream
import java.io.InputStream

/**
 * A short text of a native crash out of its tombstone, which ApplicationExitInfo.getTraceInputStream() gives for
 * REASON_CRASH_NATIVE from Android 12 on: a protobuf message of AOSP's debuggerd/proto/tombstone.proto. The text
 * names the signal and its code, the fault address, the crashing thread with its first [MAX_FRAMES] frames, and the
 * build id of libapp.so (the Dart code, whose relative pcs the symbols of that build turn into Dart functions). It
 * tags the crash families the app knows: [F2_TAG] when a frame is a JNI call of package:jni (libdartjni.so,
 * globalEnv_Call...), the crashes of package:ok_http of November 2026. Function names are those the tombstone holds
 * (C++ names may be mangled).
 *
 * Registers, memory dumps, memory maps, open files and log buffers are skipped, and files are named by their base
 * name only: no content of the app's memory and no path of the device goes into the text. Pure Kotlin, without the
 * protobuf library: the JVM tests read it as the app does.
 *
 * AppHealth, which reads why the app ended, reads the whole tombstone with TombstoneReader; its native crash text
 * (AppHealth.nativeCrashText) ends with the family line of [familyTag] on the same bytes.
 */
object TombstoneSummary {
  const val MAX_FRAMES = 8
  /** A tombstone is read up to this size; what follows (memory maps, logs) is not needed */
  const val MAX_BYTES = 4 * 1024 * 1024
  const val UNREADABLE = "tombstone unreadable"
  const val F2_TAG = "[F2: JNI call of package:ok_http]"

  /** A frame of a backtrace, as BacktraceFrame of tombstone.proto has it */
  data class Frame(
    val relPc: Long,
    val functionName: String,
    val functionOffset: Long,
    val fileName: String,
    val buildId: String,
  ) {
    /** The base name of the file, without the folder nor the APK that holds it ("base.apk!libapp.so") */
    val library: String
      get() = fileName.substringAfterLast('/').substringAfterLast('!')

    override fun toString(): String =
      if (functionName.isNotEmpty()) {
        "$library $functionName+$functionOffset"
      } else {
        "$library rel_pc 0x${java.lang.Long.toHexString(relPc)}"
      }
  }

  /** What the text tells of a tombstone */
  data class Summary(
    val signal: Int,
    val signalName: String,
    val code: Int,
    val codeName: String,
    /** Null when the signal has no fault address */
    val faultAddress: Long?,
    val threadId: Int,
    val threadName: String,
    /** Every frame of the crashing thread, innermost first */
    val frames: List<Frame>,
    val libappBuildId: String?,
  ) {
    /** The tag of a known crash family, or null */
    val family: String?
      get() = if (frames.any { isJniCall(it) }) F2_TAG else null
  }

  /** A frame of package:jni calling Java: the call whose receiver the crashes of family F2 had lost */
  fun isJniCall(frame: Frame): Boolean =
    frame.library == "libdartjni.so" && frame.functionName.startsWith("globalEnv_Call")

  /**
   * A frame of the Dart code: in libapp.so, or in an APK of the app without a library name nor a function name. The
   * Play traces of November 2026 show the frames of libapp.so that way ("split_config.arm64_v8a.apk" and the build id
   * of libapp.so) while the other libraries of the same APK come with their name ("split_config.arm64_v8a.apk!lib...")
   */
  fun isDartCode(frame: Frame): Boolean =
    frame.library == "libapp.so" ||
      (frame.library.endsWith(".apk") && frame.functionName.isEmpty())

  /** The tag of the crash family of the tombstone [bytes] ([F2_TAG]), null for none or when unreadable; never throws */
  fun familyTag(bytes: ByteArray): String? =
    try {
      parse(bytes.copyOf(minOf(bytes.size, MAX_BYTES)))?.family
    } catch (_: Exception) {
      null
    }

  /** The text of the tombstone in [input], or [UNREADABLE]; never throws */
  fun read(input: InputStream): String =
    try {
      val bytes = readAtMost(input, MAX_BYTES)
      parse(bytes)?.let { describe(it) } ?: UNREADABLE
    } catch (_: Exception) {
      UNREADABLE
    }

  /**
   * The summary of the tombstone in [bytes], null when its signal or its crashing thread cannot be read. A tombstone
   * cut short keeps what was read before the cut: the signal and the threads come before the memory maps and the
   * logs in the order protobuf writes the fields.
   */
  fun parse(bytes: ByteArray): Summary? {
    var tid = -1
    var signal: Signal? = null
    val threads = HashMap<Int, ThreadInfo>()
    var libappMapping: String? = null
    val wire = Wire(bytes, 0, bytes.size)
    try {
      while (!wire.atEnd()) {
        val tag = wire.varint()
        val field = (tag ushr 3).toInt()
        val type = (tag and 7L).toInt()
        when {
          field == TOMBSTONE_TID && type == VARINT -> tid = wire.varint().toInt()
          field == TOMBSTONE_SIGNAL && type == LENGTH -> signal = readSignal(wire.message())
          field == TOMBSTONE_THREADS && type == LENGTH -> readThreadEntry(wire.message())?.let { threads[it.id] = it }
          field == TOMBSTONE_MAPPINGS && type == LENGTH && libappMapping == null ->
            libappMapping = readLibappMapping(wire.message())
          else -> wire.skip(type)
        }
      }
    } catch (_: Unreadable) {
      // Cut short or damaged: what was read before stays
    }
    val crashed = threads[tid] ?: return null
    val info = signal ?: return null
    val libappFrame = crashed.frames.firstOrNull { isDartCode(it) && it.buildId.isNotEmpty() }
    return Summary(
      signal = info.number,
      signalName = info.name,
      code = info.code,
      codeName = info.codeName,
      faultAddress = if (info.hasFaultAddress) info.faultAddress else null,
      threadId = crashed.id,
      threadName = crashed.name,
      frames = crashed.frames,
      libappBuildId = libappFrame?.buildId ?: libappMapping,
    )
  }

  /** The text of [summary], several lines, the first one from the signal on */
  fun describe(summary: Summary): String {
    val signal = buildString {
      append("signal ${summary.signal}")
      if (summary.signalName.isNotEmpty()) append(" (${summary.signalName})")
      append(", code ${summary.code}")
      if (summary.codeName.isNotEmpty()) append(" (${summary.codeName})")
      append(", ")
      append(summary.faultAddress?.let { "fault address 0x${java.lang.Long.toHexString(it)}" } ?: "no fault address")
    }
    val name = summary.threadName.ifEmpty { "without a name" }
    val lines = mutableListOf(signal, "Thread $name (tid ${summary.threadId}):")
    summary.frames.take(MAX_FRAMES).forEachIndexed { index, frame ->
      lines.add("  #${index.toString().padStart(2, '0')} $frame")
    }
    if (summary.frames.size > MAX_FRAMES) lines.add("  ... ${summary.frames.size - MAX_FRAMES} more frames")
    summary.libappBuildId?.let { lines.add("libapp.so build id $it") }
    summary.family?.let { lines.add(it) }
    return lines.joinToString("\n")
  }

  private class Signal(
    val number: Int,
    val name: String,
    val code: Int,
    val codeName: String,
    val hasFaultAddress: Boolean,
    val faultAddress: Long,
  )

  private class ThreadInfo(val id: Int, val name: String, val frames: List<Frame>)

  private fun readSignal(wire: Wire): Signal {
    var number = 0
    var name = ""
    var code = 0
    var codeName = ""
    var hasFaultAddress = false
    var faultAddress = 0L
    while (!wire.atEnd()) {
      val tag = wire.varint()
      val field = (tag ushr 3).toInt()
      val type = (tag and 7L).toInt()
      when {
        field == SIGNAL_NUMBER && type == VARINT -> number = wire.varint().toInt()
        field == SIGNAL_NAME && type == LENGTH -> name = wire.string()
        field == SIGNAL_CODE && type == VARINT -> code = wire.varint().toInt()
        field == SIGNAL_CODE_NAME && type == LENGTH -> codeName = wire.string()
        field == SIGNAL_HAS_FAULT_ADDRESS && type == VARINT -> hasFaultAddress = wire.varint() != 0L
        field == SIGNAL_FAULT_ADDRESS && type == VARINT -> faultAddress = wire.varint()
        else -> wire.skip(type)
      }
    }
    return Signal(number, name, code, codeName, hasFaultAddress, faultAddress)
  }

  /** An entry of the map of threads: its key (the tid) and its Thread */
  private fun readThreadEntry(wire: Wire): ThreadInfo? {
    var key: Int? = null
    var thread: ThreadInfo? = null
    while (!wire.atEnd()) {
      val tag = wire.varint()
      val field = (tag ushr 3).toInt()
      val type = (tag and 7L).toInt()
      when {
        field == ENTRY_KEY && type == VARINT -> key = wire.varint().toInt()
        field == ENTRY_VALUE && type == LENGTH -> thread = readThread(wire.message())
        else -> wire.skip(type)
      }
    }
    val value = thread ?: return null
    return ThreadInfo(key ?: value.id, value.name, value.frames)
  }

  private fun readThread(wire: Wire): ThreadInfo {
    var id = 0
    var name = ""
    val frames = ArrayList<Frame>()
    while (!wire.atEnd()) {
      val tag = wire.varint()
      val field = (tag ushr 3).toInt()
      val type = (tag and 7L).toInt()
      when {
        field == THREAD_ID && type == VARINT -> id = wire.varint().toInt()
        field == THREAD_NAME && type == LENGTH -> name = wire.string()
        field == THREAD_BACKTRACE && type == LENGTH -> frames.add(readFrame(wire.message()))
        else -> wire.skip(type)
      }
    }
    return ThreadInfo(id, name, frames)
  }

  private fun readFrame(wire: Wire): Frame {
    var relPc = 0L
    var functionName = ""
    var functionOffset = 0L
    var fileName = ""
    var buildId = ""
    while (!wire.atEnd()) {
      val tag = wire.varint()
      val field = (tag ushr 3).toInt()
      val type = (tag and 7L).toInt()
      when {
        field == FRAME_REL_PC && type == VARINT -> relPc = wire.varint()
        field == FRAME_FUNCTION_NAME && type == LENGTH -> functionName = wire.string()
        field == FRAME_FUNCTION_OFFSET && type == VARINT -> functionOffset = wire.varint()
        field == FRAME_FILE_NAME && type == LENGTH -> fileName = wire.string()
        field == FRAME_BUILD_ID && type == LENGTH -> buildId = wire.string()
        else -> wire.skip(type)
      }
    }
    return Frame(relPc, functionName, functionOffset, fileName, buildId)
  }

  /** The build id of a memory mapping of libapp.so, null for any other mapping */
  private fun readLibappMapping(wire: Wire): String? {
    var name = ""
    var buildId = ""
    while (!wire.atEnd()) {
      val tag = wire.varint()
      val field = (tag ushr 3).toInt()
      val type = (tag and 7L).toInt()
      when {
        field == MAPPING_NAME && type == LENGTH -> name = wire.string()
        field == MAPPING_BUILD_ID && type == LENGTH -> buildId = wire.string()
        else -> wire.skip(type)
      }
    }
    return if (name.substringAfterLast('/').substringAfterLast('!') == "libapp.so" && buildId.isNotEmpty()) {
      buildId
    } else {
      null
    }
  }

  private fun readAtMost(input: InputStream, limit: Int): ByteArray {
    val out = ByteArrayOutputStream()
    val buffer = ByteArray(64 * 1024)
    while (out.size() < limit) {
      val read = input.read(buffer, 0, minOf(buffer.size, limit - out.size()))
      if (read < 0) break
      out.write(buffer, 0, read)
    }
    return out.toByteArray()
  }

  /** A tombstone cut short or damaged */
  private class Unreadable : Exception()

  /** The protobuf wire format over [bytes] from [position] to [end] */
  private class Wire(private val bytes: ByteArray, private var position: Int, private val end: Int) {
    fun atEnd(): Boolean = position >= end

    fun varint(): Long {
      var result = 0L
      var shift = 0
      while (shift < 64) {
        if (position >= end) throw Unreadable()
        val byte = bytes[position++].toInt()
        result = result or ((byte and 0x7f).toLong() shl shift)
        if (byte and 0x80 == 0) return result
        shift += 7
      }
      throw Unreadable()
    }

    /** A length delimited field read as a message of its own */
    fun message(): Wire {
      val length = varint()
      if (length < 0 || length > end - position) throw Unreadable()
      val start = position
      position += length.toInt()
      return Wire(bytes, start, position)
    }

    fun string(): String {
      val field = message()
      return String(bytes, field.position, field.end - field.position, Charsets.UTF_8)
    }

    fun skip(type: Int) {
      when (type) {
        VARINT -> varint()
        FIXED64 -> advance(8)
        LENGTH -> message()
        FIXED32 -> advance(4)
        else -> throw Unreadable()
      }
    }

    private fun advance(count: Int) {
      if (count > end - position) throw Unreadable()
      position += count
    }
  }

  // Wire types of protobuf
  private const val VARINT = 0
  private const val FIXED64 = 1
  private const val LENGTH = 2
  private const val FIXED32 = 5

  // Field numbers of AOSP system/core debuggerd/proto/tombstone.proto (main, read on 8 November 2026)
  private const val TOMBSTONE_TID = 6
  private const val TOMBSTONE_SIGNAL = 10
  private const val TOMBSTONE_THREADS = 16
  private const val TOMBSTONE_MAPPINGS = 17
  private const val ENTRY_KEY = 1
  private const val ENTRY_VALUE = 2
  private const val SIGNAL_NUMBER = 1
  private const val SIGNAL_NAME = 2
  private const val SIGNAL_CODE = 3
  private const val SIGNAL_CODE_NAME = 4
  private const val SIGNAL_HAS_FAULT_ADDRESS = 8
  private const val SIGNAL_FAULT_ADDRESS = 9
  private const val THREAD_ID = 1
  private const val THREAD_NAME = 2
  private const val THREAD_BACKTRACE = 4
  private const val FRAME_REL_PC = 1
  private const val FRAME_FUNCTION_NAME = 4
  private const val FRAME_FUNCTION_OFFSET = 5
  private const val FRAME_FILE_NAME = 6
  private const val FRAME_BUILD_ID = 8
  private const val MAPPING_NAME = 7
  private const val MAPPING_BUILD_ID = 8
}
