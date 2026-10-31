package app.alextran.immich.immersive

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wiring of the watch progress in the immersive viewer, read from the source of ImmersiveViewerActivity (the
 * activity needs the whole app to compile, so the test reads its source as SpatialHoldWiringTest does). WatchReportTest
 * proves the rules; this test keeps the activity on them: where a film reports its position to the app (onPause, before
 * a previous or next media, at its end, before the closed event), that a film plays once and that Play starts it again
 * at its end, the notice of a film that resumes, and the resets of a new video.
 */
class WatchWiringTest {
  private val source by lazy { activitySource().readText() }

  @Test
  fun `onPause reports where the film is before it holds the player`() {
    assertInOrder(bodyOf("override fun onPause()"), "rememberPosition()", "reportProgress()", "holdPlayback()")
  }

  @Test
  fun `a previous or next media is asked for once the film reported where it is`() {
    assertInOrder(bodyOf("private fun navigate("), "reportProgress()", "ImmersiveApiImpl.requestAdjacent(")
  }

  @Test
  fun `the end of a film is reported as its end, the kiosk has its own`() {
    val ended = branchOf("Player.STATE_ENDED ->")
    assertTrue(ended, ended.contains("reportProgress(ended = true)"))
    assertInOrder(ended, "kiosk != null", "runKioskLater(kiosk.onEnded())", "reportProgress(ended = true)")
  }

  @Test
  fun `the closing reports the film first, and nothing goes after the closed event`() {
    assertInOrder(bodyOf("private fun reportClosed()"), "reportProgress()", "closedSent = true")
    assertInOrder(bodyOf("private fun close()"), "reportClosed()", "player?.stop()")
    assertTrue(bodyOf("override fun onStop()").contains("reportClosed()"))
    assertTrue(bodyOf("override fun onDestroy()").contains("reportClosed()"))
    assertTrue(firstStatementOf("private fun reportProgress(").startsWith("if (closedSent) return"))
  }

  @Test
  fun `a film stops looping once its player knows its duration`() {
    assertInOrder(
      branchOf("Player.STATE_READY ->"),
      "WatchReport.loops(",
      "p.repeatMode = Player.REPEAT_MODE_OFF",
    )
  }

  @Test
  fun `Play at the end of a film starts it again from its beginning, never in the kiosk`() {
    val toggle = bodyOf("private fun togglePlayPause()")
    assertInOrder(toggle, "p.playbackState == Player.STATE_ENDED && kiosk == null", "p.seekTo(0L)", "p.play()")
  }

  @Test
  fun `the notice of a film that resumes is said once, as it plays`() {
    assertTrue(bodyOf("private fun showVideo(").contains("pendingStartNotice = media.startNotice"))
    assertInOrder(
      branchOf("Player.STATE_READY ->"),
      "if (firstReady && starting) pendingStartNotice?.let",
      "pendingStartNotice = null",
      "queueNotice(it)",
    )
    assertTrue(bodyOf("private fun showRequest(").contains("pendingStartNotice = null"))
  }

  @Test
  fun `a new video reports only once it played in this opening`() {
    assertTrue(bodyOf("private fun playUrl(").contains("watchPlayed = false"))
    assertTrue(bodyOf("private fun showRequest(").contains("watchPlayed = false"))
    assertInOrder(bodyOf("override fun onIsPlayingChanged("), "if (isPlaying && !watchPlayed)", "watchPlayed = true")
  }

  /** [parts] in [text], each after the one before */
  private fun assertInOrder(text: String, vararg parts: String) {
    var from = 0
    for (part in parts) {
      val at = text.indexOf(part, from)
      assertTrue("\"$part\" not found after \"${parts.takeWhile { it != part }.lastOrNull()}\" in:\n$text", at >= 0)
      from = at + part.length
    }
  }

  /** The body of the function [declaration] begins, braces included */
  private fun bodyOf(declaration: String): String {
    val start = source.indexOf(declaration)
    assertTrue("$declaration not found in ImmersiveViewerActivity.kt", start >= 0)
    return block(source.indexOf('{', start + declaration.length))
  }

  /** The block of the `when` branch [label] (`Player.STATE_ENDED ->`) of the player's listener */
  private fun branchOf(label: String): String {
    val listener = source.indexOf("override fun onPlaybackStateChanged(playbackState: Int)")
    assertTrue("the listener of the player not found", listener >= 0)
    val start = source.indexOf(label, listener)
    assertTrue("$label not found in the listener of the player", start >= 0)
    return block(source.indexOf('{', start + label.length))
  }

  /** From the brace at [open] to the one that closes it: strings and line comments skipped */
  private fun block(open: Int): String {
    assertTrue(open >= 0 && source[open] == '{')
    var depth = 0
    var i = open
    while (i < source.length) {
      when (source[i]) {
        '"' -> {
          i++
          while (i < source.length && source[i] != '"') i += if (source[i] == '\\') 2 else 1
        }
        '/' ->
          if (source.startsWith("//", i)) {
            i = source.indexOf('\n', i).let { if (it < 0) source.length else it }
          }
        '{' -> depth++
        '}' -> {
          depth--
          if (depth == 0) return source.substring(open, i + 1)
        }
      }
      i++
    }
    error("no closing brace for the block at $open")
  }

  /** The first statement in the body of the function [declaration] begins, comments and blank lines skipped */
  private fun firstStatementOf(declaration: String): String =
    bodyOf(declaration)
      .substring(1)
      .lineSequence()
      .map { it.trim() }
      .first { it.isNotEmpty() && !it.startsWith("//") && !it.startsWith("/*") && !it.startsWith("*") }

  /** ImmersiveViewerActivity.kt, found by walking up from the working directory (the app module under Gradle) */
  private fun activitySource(): File {
    val path = "src/main/kotlin/app/alextran/immich/immersive/ImmersiveViewerActivity.kt"
    var dir: File? = File(requireNotNull(System.getProperty("user.dir"))).absoluteFile
    while (dir != null) {
      for (prefix in listOf("", "app/", "android/app/", "mobile/android/app/")) {
        val candidate = File(dir, prefix + path)
        if (candidate.isFile) return candidate
      }
      dir = dir.parentFile
    }
    error("ImmersiveViewerActivity.kt not found")
  }
}
