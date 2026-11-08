package app.alextran.immich.spatial

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wiring of [GpuFrameTimer] in the Spatial 2.5D renderer, read from the source of SpatialRenderer.kt (the
 * renderer needs a GL context, so the test reads its source as SpatialHoldWiringTest reads the immersive viewer).
 * GpuFrameTimerTest proves the timer; this test keeps the renderer on it: build 25 crashed in libGLES_mali.so under
 * the glGetQueryObjectuiv of the renderer's own timer code (Play cluster 7b656f, 27 October 2026).
 */
class SpatialRendererTimerWiringTest {
  private val source by lazy { spatialSource("SpatialRenderer.kt").readText() }

  @Test
  fun `no query call is left in the renderer`() {
    val calls = QUERY_CALL.findAll(source).map { it.value }.toList()
    assertTrue("the queries go through GpuFrameTimer and GlesTimerGl: $calls", calls.isEmpty())
    val constants = listOf("GL_TIME_ELAPSED_EXT", "GL_GPU_DISJOINT_EXT").filter { source.contains(it) }
    assertTrue("the constants of the extension live in GlesTimerGl: $constants", constants.isEmpty())
  }

  @Test
  fun `GlesTimerGl is the only file of the spatial player that calls the query functions`() {
    val callers = spatialSource("SpatialRenderer.kt").parentFile
      .listFiles { file -> file.name.endsWith(".kt") }
      .orEmpty()
      .filter { file -> QUERY_CALL.containsMatchIn(file.readText()) }
      .map { it.name }
    assertEquals(listOf("GlesTimerGl.kt"), callers)
  }

  @Test
  fun `settleBeforeDelete comes right before each target release of the frame paths`() {
    val releases = mapOf(
      "private fun updateGeometry(" to "releaseEyeTargets()",
      "private fun ensureDisparityTargets(" to "releaseDisparityTargets()",
    )
    for ((declaration, release) in releases) {
      val statements = statementsOf(declaration)
      val indices = statements.indices.filter { statements[it] == release }
      assertTrue("$release not found in $declaration", indices.isNotEmpty())
      for (index in indices) {
        assertEquals("before $release in $declaration", "timer.settleBeforeDelete()", statements[index - 1])
      }
    }
    assertEquals(2, statementsOf("private fun ensureDisparityTargets(").count { it == "releaseDisparityTargets()" })
  }

  @Test
  fun `forgetGlObjects forgets the timer`() {
    assertTrue("timer.forget()" in statementsOf("private fun forgetGlObjects("))
  }

  @Test
  fun `releaseGlObjects releases the timer first`() {
    assertEquals("timer.release()", statementsOf("private fun releaseGlObjects(").first())
  }

  @Test
  fun `onSurfaceChanged voids the pending queries`() {
    assertTrue("timer.voidPending()" in statementsOf("override fun onSurfaceChanged("))
  }

  @Test
  fun `release disarms the guard even without a current context`() {
    assertTrue("timer.onPaused()" in statementsOf("fun release("))
  }

  @Test
  fun `the CPU timing runs when the GPU timer does not`() {
    val frame = statementsOf("private fun drawFrame(")
    assertTrue(frame.any { it.startsWith("val cpuTiming = !timer.active &&") })
    assertTrue("timer.collect(timingSink)" in frame)
  }

  /**
   * The statements, one per trimmed line, in the body of the function [declaration] begins: from its first brace to
   * the matching one, comments and blank lines skipped
   */
  private fun statementsOf(declaration: String): List<String> {
    val start = source.indexOf(declaration)
    assertTrue("$declaration not found in SpatialRenderer.kt", start >= 0)
    val open = source.indexOf('{', start)
    var depth = 0
    var end = open
    while (end < source.length) {
      when (source[end]) {
        '{' -> depth++
        '}' -> if (--depth == 0) break
      }
      end++
    }
    return source
      .substring(open + 1, end)
      .lineSequence()
      .map { it.trim() }
      .filter { it.isNotEmpty() && !it.startsWith("//") && !it.startsWith("/*") && !it.startsWith("*") }
      .toList()
  }

  /** A file of the spatial package, found by walking up from the working directory (the app module under Gradle) */
  private fun spatialSource(name: String): File {
    val path = "src/main/kotlin/app/alextran/immich/spatial/$name"
    var dir: File? = File(requireNotNull(System.getProperty("user.dir"))).absoluteFile
    while (dir != null) {
      for (prefix in listOf("", "app/", "android/app/", "mobile/android/app/")) {
        val candidate = File(dir, prefix + path)
        if (candidate.isFile) return candidate
      }
      dir = dir.parentFile
    }
    error("$name not found")
  }

  private companion object {
    /** A call of a query function of GLES30, by name and opening parenthesis: comments and log text do not count */
    val QUERY_CALL = Regex("""\bgl(GetQueryObject\w*|BeginQuery|EndQuery|GenQueries|DeleteQueries|IsQuery)\s*\(""")
  }
}
