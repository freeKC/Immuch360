package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** One file per tap: a second export with nothing new writes nothing (p2/design-final-2026-10-24.md, section 6) */
class ExportMemoryTest {
  private val saved = CaptureExport.Result(ok = true, bytes = 4096, binPath = "Download/Immuch360/dji-link/a.bin")

  @Test
  fun theSameBytesAnswerTheLastExportRepeated() {
    val memory = ExportMemory(5_000)
    val key = listOf(4096L, 4L, 0L, 900L)
    assertNull(memory.repeated(key, 4096, 0))
    memory.remember(key, saved, 0)
    val again = memory.repeated(key, 4096, 60_000)!!
    assertTrue(again.repeated)
    assertEquals(saved.binPath, again.binPath)
    // New bytes: a new file
    assertNull(memory.repeated(listOf(8192L, 6L, 0L, 1200L), 8192, 60_000))
  }

  @Test
  fun aHeaderOnlyExportIsRepeatedOnlyForAFewSeconds() {
    val memory = ExportMemory(5_000)
    val empty = listOf(0L, 0L, 0L, 0L)
    memory.remember(empty, CaptureExport.Result(ok = true, bytes = 0, headerOnly = true), 0)
    assertTrue(memory.repeated(empty, 0, 4_999)!!.repeated)
    assertNull(memory.repeated(empty, 0, 5_000))
  }

  @Test
  fun aFailedExportIsTriedAgain() {
    val memory = ExportMemory(5_000)
    val key = listOf(4096L, 4L, 0L, 0L)
    memory.remember(key, CaptureExport.Result(ok = false, bytes = 0, error = "full"), 0)
    assertNull(memory.repeated(key, 4096, 100))
    memory.clear()
    assertNull(memory.repeated(key, 4096, 100))
  }
}
