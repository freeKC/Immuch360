package app.alextran.immich.core

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TombstoneSummaryTest {
  /** A protobuf message written field by field, as debuggerd writes a tombstone */
  private class Proto {
    private val out = ByteArrayOutputStream()

    fun varint(field: Int, value: Long) = apply {
      tag(field, 0)
      writeVarint(value)
    }

    fun string(field: Int, value: String) = bytes(field, value.toByteArray(Charsets.UTF_8))

    fun message(field: Int, message: Proto) = bytes(field, message.toByteArray())

    fun fixed64(field: Int, value: Long) = apply {
      tag(field, 1)
      for (shift in 0 until 64 step 8) out.write((value ushr shift).toInt() and 0xff)
    }

    fun fixed32(field: Int, value: Int) = apply {
      tag(field, 5)
      for (shift in 0 until 32 step 8) out.write((value ushr shift) and 0xff)
    }

    fun bytes(field: Int, value: ByteArray) = apply {
      tag(field, 2)
      writeVarint(value.size.toLong())
      out.write(value)
    }

    fun toByteArray(): ByteArray = out.toByteArray()

    private fun tag(field: Int, type: Int) = writeVarint(((field shl 3) or type).toLong())

    private fun writeVarint(value: Long) {
      var rest = value
      while (rest and 0x7fL.inv() != 0L) {
        out.write(((rest and 0x7f) or 0x80).toInt())
        rest = rest ushr 7
      }
      out.write(rest.toInt())
    }
  }

  private val apk = "/data/app/~~simLStPT4k_R1zi1lqmTEw==/com.aprogsys.immuch360-c5Rtg-YsWr4yxblbV3pruQ==/" +
    "split_config.arm64_v8a.apk"
  private val libappBuildId = "fb72c445f89c39a3fe453cb9d530f050"

  private fun frame(relPc: Long, file: String, function: String = "", offset: Long = 0, buildId: String = "") =
    Proto().apply {
      varint(1, relPc)
      varint(2, relPc + 0x7000000000)
      varint(3, 0x7ff0001000)
      if (function.isNotEmpty()) string(4, function)
      if (offset != 0L) varint(5, offset)
      string(6, file)
      if (buildId.isNotEmpty()) string(8, buildId)
    }

  /** The frames of Play's P1 (3c402e, OnePlus 13, build 3030038), as the tombstone stores them */
  private fun p1Frames(): List<Proto> =
    listOf(
      frame(
        0x332398,
        "/apex/com.android.art/lib64/libart.so",
        "_ZN3art35InvokeVirtualOrInterfaceWithVarArgsIP10_jmethodIDEENS_6JValueERKNS_33ScopedObjectAccess" +
          "AlreadyRunnableEP8_jobjectT_St9__va_list",
        152,
      ),
      frame(
        0x6a33ec,
        "/apex/com.android.art/lib64/libart.so",
        "_ZN3art3JNIILb0EE17CallObjectMethodVEP7_JNIEnvP8_jobjectP10_jmethodIDSt9__va_list",
        184,
      ),
      frame(
        0xef18,
        "$apk!libdartjni.so",
        "globalEnv_CallObjectMethod",
        224,
        "f76a329ad8396079b3dde08f1cbf4d110340c9fe",
      ),
      frame(0x28f09c8, apk, buildId = libappBuildId),
      frame(0x1db1c1c, apk, buildId = libappBuildId),
      frame(0x1db7038, apk, buildId = libappBuildId),
      frame(0x275abe8, apk, buildId = libappBuildId),
      frame(0x1d2c9e0, apk, buildId = libappBuildId),
      frame(0x1d2c890, apk, buildId = libappBuildId),
      frame(0x16df8, "/system/lib64/libutils.so", "_ZN7android6Looper8pollOnceEiPiS1_PPv", 1200),
    )

  private fun thread(id: Int, name: String, frames: List<Proto>) =
    Proto().apply {
      varint(1, id.toLong())
      string(2, name)
      // A register: skipped, its value never reaches the text
      message(3, Proto().string(1, "x0").varint(2, 0x7a7a7a7a7a))
      frames.forEach { message(4, it) }
      string(7, "a backtrace note")
    }

  private fun threadEntry(tid: Int, thread: Proto) = Proto().varint(1, tid.toLong()).message(2, thread)

  private fun signal(
    number: Int,
    name: String,
    code: Int,
    codeName: String,
    faultAddress: Long? = null,
  ) =
    Proto().apply {
      varint(1, number.toLong())
      string(2, name)
      // An int32 below zero is written on ten bytes, as protobuf does
      varint(3, code.toLong())
      string(4, codeName)
      if (faultAddress != null) {
        varint(8, 1)
        // proto3 leaves out a field at its default value: a fault address of 0 is not written
        if (faultAddress != 0L) varint(9, faultAddress)
      }
    }

  /** P1 as a tombstone: SIGSEGV with a fault address of 0 on the main thread, another thread listed first */
  private fun p1Tombstone(): ByteArray =
    Proto()
      .varint(1, 1)
      .string(2, "OnePlus/OP5D55L1/OP5D55L1:16/BP2A.250605.015/U.1:user/release-keys")
      .string(4, "2026-11-07 19:02:11.123456789+0100")
      .varint(5, 23215)
      .varint(6, 23215)
      .varint(7, 10321)
      .string(9, "com.aprogsys.immuch360")
      .message(10, signal(11, "SIGSEGV", 1, "SEGV_MAPERR", faultAddress = 0))
      .message(15, Proto().string(1, "null pointer dereference"))
      .message(16, threadEntry(23290, thread(23290, "RenderThread", listOf(frame(0x1234, "/system/lib64/libhwui.so")))))
      .message(16, threadEntry(23215, thread(23215, "main", p1Frames())))
      .message(17, Proto().varint(1, 0x7000000000).string(7, "/system/lib64/libc.so").string(8, "c0ffee"))
      .message(18, Proto().string(1, "main").string(2, "a log line that must not show"))
      .toByteArray()

  @Test
  fun `a SIGSEGV in a JNI call of package jni gives its signal, its thread, its first frames and the F2 tag`() {
    val summary = TombstoneSummary.parse(p1Tombstone())

    assertNotNull(summary)
    summary!!
    assertEquals(11, summary.signal)
    assertEquals("SIGSEGV", summary.signalName)
    assertEquals(1, summary.code)
    assertEquals("SEGV_MAPERR", summary.codeName)
    assertEquals(0L, summary.faultAddress)
    assertEquals(23215, summary.threadId)
    assertEquals("main", summary.threadName)
    assertEquals(10, summary.frames.size)
    assertEquals(libappBuildId, summary.libappBuildId)
    assertEquals(TombstoneSummary.F2_TAG, summary.family)

    val text = TombstoneSummary.read(ByteArrayInputStream(p1Tombstone()))
    val lines = text.lines()
    assertEquals("signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault address 0x0", lines[0])
    assertEquals("Thread main (tid 23215):", lines[1])
    assertTrue(lines[2], lines[2].startsWith("  #00 libart.so _ZN3art35InvokeVirtualOrInterfaceWithVarArgs"))
    assertTrue(lines[2], lines[2].endsWith("+152"))
    assertTrue(lines[3], lines[3].startsWith("  #01 libart.so _ZN3art3JNIILb0EE17CallObjectMethodV"))
    assertEquals("  #02 libdartjni.so globalEnv_CallObjectMethod+224", lines[4])
    assertEquals("  #03 split_config.arm64_v8a.apk rel_pc 0x28f09c8", lines[5])
    assertEquals("  #05 split_config.arm64_v8a.apk rel_pc 0x1db7038", lines[7])
    assertEquals("  #07 split_config.arm64_v8a.apk rel_pc 0x1d2c9e0", lines[9])
    assertEquals("  ... 2 more frames", lines[10])
    assertEquals("libapp.so build id $libappBuildId", lines[11])
    assertEquals(TombstoneSummary.F2_TAG, lines[12])
    assertEquals(13, lines.size)
    // No path of the device, no register, no log line
    assertFalse(text, text.contains("/data/app"))
    assertFalse(text, text.contains("7a7a7a7a7a"))
    assertFalse(text, text.contains("log line"))
    assertFalse(text, text.contains("RenderThread"))
  }

  @Test
  fun `a native crash without a JNI call of package jni gets no tag`() {
    val tombstone =
      Proto()
        .varint(6, 4242)
        .message(10, signal(6, "SIGABRT", -6, "SI_TKILL"))
        .string(14, "spz: unsupported version 3")
        .message(
          16,
          threadEntry(
            4242,
            thread(
              4242,
              "DefaultDispatch",
              listOf(
                frame(0x5f3c4, "/apex/com.android.runtime/lib64/bionic/libc.so", "abort", 164),
                frame(0x1a2b0, "/data/app/x/base.apk!libsplat.so", "spz_load", 88),
                frame(0x9f00, "/data/app/x/base.apk!libdartjni.so", "Java_com_github_dart_1lang_jni_PortProxy", 12),
              ),
            ),
          ),
        )
        .toByteArray()

    val summary = TombstoneSummary.parse(tombstone)!!
    assertNull(summary.family)
    assertNull(summary.faultAddress)
    assertNull(summary.libappBuildId)
    val text = TombstoneSummary.describe(summary)
    assertTrue(text, text.startsWith("signal 6 (SIGABRT), code -6 (SI_TKILL), no fault address\n"))
    assertTrue(text, text.contains("  #01 libsplat.so spz_load+88"))
    assertFalse(text, text.contains("[F2"))
  }

  @Test
  fun `the family tag is F2 for P1 and nothing for another crash or for bytes that are no tombstone`() {
    assertEquals(TombstoneSummary.F2_TAG, TombstoneSummary.familyTag(p1Tombstone()))
    val abort =
      Proto()
        .varint(6, 9)
        .message(10, signal(6, "SIGABRT", -6, "SI_TKILL"))
        .message(16, threadEntry(9, thread(9, "main", listOf(frame(0x5f3c4, "/system/lib64/libc.so", "abort", 164)))))
        .toByteArray()
    assertNull(TombstoneSummary.familyTag(abort))
    assertNull(TombstoneSummary.familyTag(ByteArray(0)))
    assertNull(TombstoneSummary.familyTag(p1Tombstone().copyOf(40)))
    assertNull(TombstoneSummary.familyTag("not a tombstone".toByteArray()))
  }

  @Test
  fun `a tombstone cut short, empty or damaged is unreadable and never throws`() {
    val whole = p1Tombstone()
    assertEquals(TombstoneSummary.UNREADABLE, TombstoneSummary.read(ByteArrayInputStream(whole.copyOf(40))))
    assertEquals(TombstoneSummary.UNREADABLE, TombstoneSummary.read(ByteArrayInputStream(ByteArray(0))))
    assertEquals(
      TombstoneSummary.UNREADABLE,
      TombstoneSummary.read(ByteArrayInputStream(ByteArray(64) { 0xff.toByte() })),
    )
    val failing =
      object : InputStream() {
        override fun read(): Int = throw IOException("trace gone")
      }
    assertEquals(TombstoneSummary.UNREADABLE, TombstoneSummary.read(failing))
    // Every cut before the end of the crashing thread is unreadable, none throws
    val crashingThreadEnd = whole.size - mappingsAndLogsSize()
    for (cut in 0 until crashingThreadEnd) {
      val text = TombstoneSummary.read(ByteArrayInputStream(whole.copyOf(cut)))
      assertEquals("cut at $cut", TombstoneSummary.UNREADABLE, text)
    }
  }

  @Test
  fun `a tombstone cut in its memory maps keeps the crash read before`() {
    val whole = p1Tombstone()
    val cut = whole.copyOf(whole.size - mappingsAndLogsSize() + 5)
    val text = TombstoneSummary.read(ByteArrayInputStream(cut))
    assertTrue(text, text.startsWith("signal 11 (SIGSEGV)"))
    assertTrue(text, text.endsWith(TombstoneSummary.F2_TAG))
  }

  @Test
  fun `fields of every wire type the reader does not know are skipped`() {
    val tombstone =
      Proto()
        .fixed64(30, 0x1122334455667788)
        .fixed32(31, 0x55667788)
        .varint(6, 7)
        .message(10, signal(11, "SIGSEGV", 2, "SEGV_ACCERR", faultAddress = 0x7b4c000010).fixed32(40, 1))
        .bytes(32, byteArrayOf(1, 2, 3))
        .message(16, threadEntry(7, thread(7, "1.ui", listOf(frame(0x10, "/data/app/x/base.apk!libapp.so")))))
        .varint(33, 99)
        .toByteArray()

    val text = TombstoneSummary.read(ByteArrayInputStream(tombstone))
    assertEquals(
      listOf(
        "signal 11 (SIGSEGV), code 2 (SEGV_ACCERR), fault address 0x7b4c000010",
        "Thread 1.ui (tid 7):",
        "  #00 libapp.so rel_pc 0x10",
      ),
      text.lines(),
    )
  }

  @Test
  fun `the native crash text of AppHealth ends with the family tag of a JNI call of package jni, and only then`() {
    // What the Logs page shows of a native crash: the text of TombstoneReader, then the F2 tag on a line of its own
    val p1 = AppHealth.nativeCrashText(p1Tombstone())
    assertEquals(TombstoneReader.read(p1Tombstone()) + "\n" + TombstoneSummary.F2_TAG, p1)
    assertTrue(p1, p1.contains("libdartjni.so"))

    val abort =
      Proto()
        .varint(6, 9)
        .message(10, signal(6, "SIGABRT", -6, "SI_TKILL"))
        .message(16, threadEntry(9, thread(9, "main", listOf(frame(0x5f3c4, "/system/lib64/libc.so", "abort", 164)))))
        .toByteArray()
    val text = AppHealth.nativeCrashText(abort)
    assertEquals(TombstoneReader.read(abort), text)
    assertFalse(text, text.contains("[F2"))

    // Bytes that are no tombstone: the sentence of an unreadable one, and no tag
    val noise = "not a tombstone".toByteArray()
    val unreadable = AppHealth.nativeCrashText(noise)
    assertFalse(unreadable, unreadable.contains("[F2"))
    assertEquals(TombstoneReader.read(noise) ?: "The tombstone of the crash could not be read.", unreadable)
  }

  /** The size of the memory map and log buffer fields at the end of [p1Tombstone] */
  private fun mappingsAndLogsSize(): Int =
    Proto()
      .message(17, Proto().varint(1, 0x7000000000).string(7, "/system/lib64/libc.so").string(8, "c0ffee"))
      .message(18, Proto().string(1, "main").string(2, "a log line that must not show"))
      .toByteArray()
      .size
}
