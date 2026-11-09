package app.alextran.immich.core

import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The tombstones of these tests are written with the field numbers of AOSP's debuggerd/proto/tombstone.proto */
class TombstoneReaderTest {
  /** A small protobuf writer */
  private class Proto {
    private val out = ByteArrayOutputStream()

    fun varint(number: Int, value: Long) = apply {
      key(number, 0)
      raw(value)
    }

    fun fixed64(number: Int, value: Long) = apply {
      key(number, 1)
      repeat(8) { out.write((value ushr (8 * it)).toInt() and 0xFF) }
    }

    fun fixed32(number: Int, value: Int) = apply {
      key(number, 5)
      repeat(4) { out.write((value ushr (8 * it)) and 0xFF) }
    }

    fun bytes(number: Int, value: ByteArray) = apply {
      key(number, 2)
      raw(value.size.toLong())
      out.write(value)
    }

    fun string(number: Int, value: String) = bytes(number, value.toByteArray())

    fun message(number: Int, value: Proto) = bytes(number, value.toByteArray())

    /** A group of proto2, which tombstone.proto never has: one varint inside */
    fun group(number: Int) = apply {
      key(number, 3)
      key(1, 0)
      raw(7)
      key(number, 4)
    }

    /** [depth] groups of proto2 one inside the other, closed when [closed] */
    fun nestedGroups(number: Int, depth: Int, closed: Boolean = true) = apply {
      repeat(depth) { key(number, 3) }
      if (closed) {
        repeat(depth) { key(number, 4) }
      }
    }

    /** One unknown field of each wire type */
    fun unknownFields() = varint(90, 300).fixed64(91, -1L).string(92, "unknown").fixed32(93, 7).group(94)

    fun toByteArray(): ByteArray = out.toByteArray()

    private fun key(number: Int, type: Int) = raw((number.toLong() shl 3) or type.toLong())

    private fun raw(value: Long) {
      var rest = value
      while (rest and 0x7FL.inv() != 0L) {
        out.write(((rest and 0x7F) or 0x80).toInt())
        rest = rest ushr 7
      }
      out.write(rest.toInt())
    }
  }

  private val app = "/data/app/~~Xy12Zw==/com.aprogsys.immuch360-Ab34Cd==/base.apk"

  private fun frame(
    relPc: Long,
    file: String,
    function: String = "",
    offset: Long = 0,
    mapOffset: Long = 0,
    buildId: String = "",
  ): Proto {
    val frame = Proto().varint(1, relPc).varint(2, 0x7a00000000L + relPc).varint(3, 0x7fc0001000L)
    if (function.isNotEmpty()) frame.string(4, function).varint(5, offset)
    frame.string(6, file)
    if (mapOffset != 0L) frame.varint(7, mapOffset)
    if (buildId.isNotEmpty()) frame.string(8, buildId)
    return frame
  }

  /** A thread with registers and a memory dump, which the reader must never show */
  private fun thread(id: Int, name: String, frames: List<Proto>): Proto {
    val thread = Proto().varint(1, id.toLong()).string(2, name)
    thread.message(3, Proto().string(1, "x0").varint(2, 0x5EC12E70L))
    frames.forEach { thread.message(4, it) }
    thread.message(5, Proto().string(1, "x0").string(2, "[anon:scudo]").varint(3, 0x5EC12E70L).string(4, "SECRET-HEAP"))
    return thread
  }

  private fun signal(number: Int, name: String, code: Int, codeName: String, faultAddress: Long? = null): Proto {
    val signal = Proto().varint(1, number.toLong()).string(2, name).varint(3, code.toLong()).string(4, codeName)
    if (faultAddress != null) signal.varint(8, 1).varint(9, faultAddress)
    return signal
  }

  private val dartFrames =
    listOf(
      frame(0xef18, "$app!libdartjni.so", "globalEnv_CallObjectMethod", 224, 0x58d0000, "f76a329ad8396079b3dde08f1cbf4d110340c9fe"),
      frame(0x190041c, app, mapOffset = 0x3988000, buildId = "3f3463a721a991e5367f9a2331cac0d4"),
    )

  /** The fields of the crash of M6 before its threads */
  private fun segvHead(): Proto =
    Proto()
      .varint(1, 1)
      .string(2, "oculus/eureka/eureka:14/UP1A/1:user/release-keys")
      .varint(5, 8800)
      .varint(6, 8905)
      .message(10, signal(11, "SIGSEGV", 1, "SEGV_MAPERR", 0x18))
      .message(15, Proto().string(1, "null pointer dereference"))

  /** The crash of M6 (SIGSEGV in a JNI call of package:ok_http) on the thread 8905 of three */
  private fun segv(): Proto =
    segvHead()
      .message(16, Proto().varint(1, 8800).message(2, thread(8800, "main", listOf(frame(0x9c4b4, "libc.so")))))
      .message(16, Proto().varint(1, 8905).message(2, thread(8905, "DartWorker", dartFrames)))
      .message(16, Proto().varint(1, 8910).message(2, thread(8910, "1.raster", emptyList())))
      .message(17, Proto().varint(1, 0x7a00000000L).string(7, "$app!libapp.so"))

  @Test
  fun `a SIGSEGV gives its signal, its cause and the crashing thread picked by its tid`() {
    val text = TombstoneReader.read(segv().toByteArray())!!

    assertEquals(
      listOf(
        "Signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault address 0x18",
        "Cause: null pointer dereference",
        "Crashing thread 8905 \"DartWorker\":",
        "  #00 pc 000000000000ef18  base.apk!libdartjni.so (offset 0x58d0000) (globalEnv_CallObjectMethod+224) " +
          "(BuildId: f76a329ad8396079b3dde08f1cbf4d110340c9fe)",
        "  #01 pc 000000000190041c  base.apk (offset 0x3988000) (BuildId: 3f3463a721a991e5367f9a2331cac0d4)",
        "Other threads (2): main, 1.raster",
      ).joinToString("\n"),
      text,
    )
  }

  @Test
  fun `the folders of the app, the registers, the memory and the maps never reach the text`() {
    val text = TombstoneReader.read(segv().toByteArray())!!

    assertFalse(text, text.contains("/data/app"))
    assertFalse(text, text.contains("SECRET"))
    assertFalse(text, text.contains("scudo"))
    assertFalse(text, text.contains("5ec12e70", ignoreCase = true))
    assertFalse(text, text.contains(0x5EC12E70L.toString()))
    // The absolute pc and the stack pointer of a frame are left out too: the offset in the library is enough
    assertFalse(text, text.contains("7a0000ef18"))
    assertFalse(text, text.contains("7fc0001000"))
  }

  @Test
  fun `a SIGABRT gives the abort message of the engine, URLs removed`() {
    val abort =
      "[FATAL:flutter/shell/platform/android/android_image_generator.cc] Check failed: fml::jni::CheckException(env)."
    val tombstone =
      Proto()
        .varint(1, 1)
        .varint(6, 13109)
        .message(10, signal(6, "SIGABRT", -1, "SI_QUEUE"))
        .string(14, "$abort Last image https://photos.example.org/api/assets/1/original?key=secret")
        .message(16, Proto().varint(1, 13109).message(2, thread(13109, "1.io", listOf(frame(0xcd818, "libc.so")))))

    val text = TombstoneReader.read(tombstone.toByteArray())!!

    assertTrue(text, text.startsWith("Signal 6 (SIGABRT), code -1 (SI_QUEUE)\nAbort message: $abort Last image (a URL)\n"))
    assertFalse(text, text.contains("fault address"))
    assertFalse(text, text.contains("photos.example.org"))
    assertTrue(text, text.contains("Crashing thread 13109 \"1.io\":\n  #00 pc 00000000000cd818  libc.so"))
  }

  @Test
  fun `unknown fields of every wire type are skipped`() {
    val frame = frame(0x190041c, app, mapOffset = 0x3988000).unknownFields()
    val thread = Proto().unknownFields().varint(1, 7).string(2, "main").message(4, frame)
    val tombstone =
      Proto()
        .unknownFields()
        .varint(1, 1)
        .varint(6, 7)
        .message(10, signal(11, "SIGSEGV", 2, "SEGV_ACCERR", 0xdead).unknownFields())
        .message(16, Proto().varint(1, 7).message(2, thread).unknownFields())
        .unknownFields()

    assertEquals(
      "Signal 11 (SIGSEGV), code 2 (SEGV_ACCERR), fault address 0xdead\n" +
        "Crashing thread 7 \"main\":\n" +
        "  #00 pc 000000000190041c  base.apk (offset 0x3988000)",
      TombstoneReader.read(tombstone.toByteArray()),
    )
  }

  @Test
  fun `groups nested a few deep are skipped, deeper ones stop the reading without a stack overflow`() {
    val tombstone =
      Proto()
        .varint(1, 1)
        .varint(6, 7)
        .message(10, signal(11, "SIGSEGV", 1, "SEGV_MAPERR", 0x18))
        .nestedGroups(94, 3)
        .message(16, Proto().varint(1, 7).message(2, thread(7, "main", listOf(frame(0x9c4b4, "libc.so")))))

    val text = TombstoneReader.read(tombstone.toByteArray())!!

    assertTrue(text, text.endsWith("Crashing thread 7 \"main\":\n  #00 pc 000000000009c4b4  libc.so"))

    // A hundred thousand groups opened: once read recursively, a StackOverflowError on the thread that reads the ends
    val deep = segvHead().nestedGroups(94, 100_000, closed = false).toByteArray()
    assertEquals(
      "Signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault address 0x18\nCause: null pointer dereference",
      TombstoneReader.read(deep),
    )
  }

  @Test
  fun `a truncated tombstone gives what was read, and never throws`() {
    val bytes = segv().toByteArray()
    for (length in 0..bytes.size) {
      TombstoneReader.read(bytes.copyOf(length))
    }
    // Cut inside the first thread: the signal, the cause and what was read of that thread
    val text = TombstoneReader.read(bytes.copyOf(segvHead().toByteArray().size + 30))!!
    assertTrue(text, text.startsWith("Signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault address 0x18\nCause: "))
    assertNull(TombstoneReader.read(ByteArray(0)))
    assertNull(TombstoneReader.read("not a tombstone at all".toByteArray()))
  }

  @Test
  fun `the crashing thread shows its first 40 frames`() {
    val frames = (0 until 41).map { frame(0x1000L + it, "libapp.so") }
    val tombstone =
      Proto()
        .varint(1, 1)
        .varint(6, 1)
        .message(10, signal(11, "SIGSEGV", 1, "SEGV_MAPERR", 0))
        .message(16, Proto().varint(1, 1).message(2, thread(1, "main", frames)))

    val text = TombstoneReader.read(tombstone.toByteArray())!!

    assertTrue(text, text.contains("  #39 pc 0000000000001027  libapp.so\n  (1 more frame)"))
    assertFalse(text, text.contains("#40"))
  }

  @Test
  fun `a 32 bit tombstone prints its pc on 8 digits`() {
    val tombstone =
      Proto()
        .varint(6, 3)
        .message(10, signal(11, "SIGSEGV", 1, "SEGV_MAPERR", 4))
        .message(16, Proto().varint(1, 3).message(2, thread(3, "sqlite", listOf(frame(0x2b10c, "libsqlite3.so")))))

    val text = TombstoneReader.read(tombstone.toByteArray())!!

    assertTrue(text, text.contains("  #00 pc 0002b10c  libsqlite3.so"))
  }
}
