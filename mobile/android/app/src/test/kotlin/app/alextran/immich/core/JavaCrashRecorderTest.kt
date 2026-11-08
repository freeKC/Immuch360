package app.alextran.immich.core

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class JavaCrashRecorderTest {
  @get:Rule val temporary = TemporaryFolder()

  @Test
  fun `writes the thread and the stack with its causes, URLs removed, then hands the exception on`() {
    val folder = temporary.newFolder("app_health")
    var handed: Throwable? = null
    val handler = JavaCrashRecorder.handler(folder, { _, error -> handed = error }, now = { 1_731_090_000_000L })
    // The crash of M3: OkHttp refused the relative Location of a redirect
    val cause =
      IllegalArgumentException(
        "Expected URL scheme 'http' or 'https' but no scheme was found for /api/i... at https://photos.example.org/a?k=1",
      )
    val error = IllegalStateException("The redirect failed", cause)

    handler.uncaughtException(Thread("OkHttp Dispatcher"), error)

    assertSame(error, handed)
    val text = File(folder, JavaCrashRecorder.FILE_NAME).readText()
    assertTrue(text, text.startsWith("time 1731090000000\nOkHttp Dispatcher\njava.lang.IllegalStateException: The redirect"))
    assertTrue(text, text.contains("\tat app.alextran.immich.core.JavaCrashRecorderTest"))
    assertTrue(text, text.contains("Caused by: java.lang.IllegalArgumentException: Expected URL scheme 'http'"))
    assertTrue(text, text.contains("found for /api/i... at (a URL)"))
    assertFalse(text, text.contains("photos.example.org"))
  }

  @Test
  fun `always hands the exception on, also when it cannot write`() {
    // A file where the folder should be: nothing can be written in it
    val notAFolder = temporary.newFile("app_health")
    var handed = 0
    val handler = JavaCrashRecorder.handler(notAFolder, { _, _ -> handed++ })

    handler.uncaughtException(Thread.currentThread(), IllegalStateException("boom"))

    assertEquals(1, handed)
    // Without a handler before it, nothing is thrown either
    JavaCrashRecorder.handler(notAFolder, null).uncaughtException(Thread.currentThread(), IllegalStateException("boom"))
  }

  @Test
  fun `keeps at most 64 KB, whole characters`() {
    val folder = temporary.newFolder()

    JavaCrashRecorder.write(folder, "main", RuntimeException("é".repeat(100_000)), 1L)

    val file = File(folder, JavaCrashRecorder.FILE_NAME)
    assertTrue("${file.length()}", file.length() <= JavaCrashRecorder.MAX_BYTES)
    assertTrue("${file.length()}", file.length() > JavaCrashRecorder.MAX_BYTES - 4)
    assertFalse(file.readText().contains('\uFFFD'))
  }
}
