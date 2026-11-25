package app.alextran.immich.immersive

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The transitions between the photos of a flat screen (issue 19) in the immersive viewer, read from the source of
 * ImmersiveViewerActivity as SpatialHoldWiringTest does (the activity needs the whole app to compile). The rule of 21
 * November 2026: nothing may bring the viewer under the display rate. The transition moves at each frame of the
 * headset (onFrame), from the time of the frame (PhotoTransition, SlideshowLookTest), and its frames only set the
 * opacity and the pose of two layers: the photos were drawn before its first frame.
 */
class PhotoTransitionWiringTest {
  private val source by lazy { activitySource().readText() }

  @Test
  fun `the transition moves at each frame of the headset`() {
    assertTrue(bodyOf("override fun onFrame(head: Pose?)").contains("updatePhotoTransition(now)"))
  }

  @Test
  fun `a frame of the transition draws no photo, decodes nothing and makes no bitmap`() {
    val frame = bodyOf("private fun updatePhotoTransition(") + bodyOf("private fun setLayerAlpha(") +
      bodyOf("private fun shiftLayer(") + bodyOf("private fun setLayerLook(") +
      bodyOf("private fun setBackdropAlpha(")
    for (heavy in listOf("drawPhotoLayer", "showOnLayer", "makeBackdrop", "lockHardwareCanvas", "Bitmap.create",
      "decode", "download", "launch", "frost(")) {
      assertFalse("$heavy in a frame of the transition", frame.contains(heavy))
    }
  }

  @Test
  fun `the next photo is drawn before the first frame of its transition`() {
    // The frames wait for the picture of the next photo on its layer, then its time starts
    assertTrue(bodyOf("private fun updatePhotoTransition(").contains("if (!photoLayerDrawn) return"))
  }

  @Test
  fun `the transition is armed by browsing only and taken by the first picture`() {
    assertTrue(bodyOf("private fun applyAdjacent(").contains("armPhotoTransition(next, navigationStep)"))
    assertTrue(bodyOf("private fun applyStereoTexture(").contains("takeArmedTransition()"))
    // Any other opening forgets it with the photo layers
    assertTrue(bodyOf("private fun dropPhotoLayer()").contains("armedTransition = null"))
    assertTrue(bodyOf("private fun dropPhotoLayer()").contains("endPhotoTransition()"))
  }

  /** The body of the function [declaration] begins, up to its closing brace at the indent of the members */
  private fun bodyOf(declaration: String): String {
    val start = source.indexOf(declaration)
    assertTrue("$declaration not found in ImmersiveViewerActivity.kt", start >= 0)
    val body = source.indexOf('{', start + declaration.length)
    val end = source.indexOf("\n  }\n", body).takeIf { it >= 0 } ?: source.length
    return source.substring(body, end)
  }

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
