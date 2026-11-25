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

  @Test
  fun `the blurred background keeps the copy of the photo before until the middle`() {
    // Review of 25 November: makeBackdrop cleared backdropDrawn while the copy waited, and placeBackdrop hid the
    // background at the start of each transition instead of fading it out
    val make = bodyOf("private fun makeBackdrop(")
    val waits = make.indexOf("if (backdropWaitsForMiddle) {")
    assertTrue("makeBackdrop keeps the next copy apart while it waits", waits >= 0)
    val waitBranch = make.substring(waits, make.indexOf("} else {", waits))
    assertTrue(waitBranch.contains("pendingBackdropBitmap = small"))
    assertFalse("the copy shown stays drawn while the next one waits", waitBranch.contains("backdropDrawn"))
    assertFalse(waitBranch.contains("backdropBitmap = "))
    assertTrue("backdropDrawn is cleared only outside the wait",
      make.indexOf("backdropDrawn = false") > waits)
    // The copy before can still be drawn (a new Surface), and the next one goes in at the middle or at the end
    assertFalse(bodyOf("private fun drawBackdrop()").contains("backdropWaitsForMiddle"))
    assertTrue(bodyOf("private fun updatePhotoTransition(").contains("if (frame.atMiddle) swapInBackdrop()"))
    assertTrue(bodyOf("private fun endPhotoTransition()").contains("if (backdropWaitsForMiddle) swapInBackdrop()"))
    assertTrue(bodyOf("private fun swapInBackdrop()").contains("backdropBitmap = pending"))
    assertTrue(bodyOf("private fun forgetBackdrop()").contains("pendingBackdropBitmap = null"))
  }

  @Test
  fun `a later picture of the photo waits for the end of its transition`() {
    // Review of 25 November: the original of a server photo, after its preview, came during the transition and was
    // drawn on the layer of 4096 x 2048 in the middle of the fade, on the main thread
    val apply = bodyOf("private fun applyStereoTexture(")
    val later = apply.indexOf("laterPicture = LaterPicture(")
    assertTrue(later >= 0)
    assertTrue(apply.contains("photoTransition != null && media === transitionRequest"))
    assertTrue("deferred before any drawing", later < apply.indexOf("showOnLayer(stereo)"))
    assertTrue("deferred before the backdrop copy", later < apply.indexOf("makeBackdrop(media, stereo)"))
    assertTrue(bodyOf("private fun beginPhotoTransition(").contains("transitionRequest = request"))
    val end = bodyOf("private fun endPhotoTransition()")
    assertTrue(end.contains("transitionRequest = null"))
    assertTrue("applied from the main loop after the end",
      end.contains("mainHandler.post { applyLaterPicture(later) }"))
    val applyLater = bodyOf("private fun applyLaterPicture(")
    assertTrue("dropped once the viewer moved on", applyLater.contains("request !== later.media"))
    assertTrue(applyLater.contains("later.stereo.bitmap.recycle()"))
  }

  @Test
  fun `the twin photo layer is made only while a transition is chosen`() {
    val make = bodyOf("private fun makePhotoLayers()")
    assertTrue(make.contains("lookOf(it).transition != SlideshowTransition.NONE"))
    assertTrue(make.contains("layer !== shownLayer && !twinWanted"))
    assertTrue(bodyOf("private fun showOnLayer(").contains("makePhotoLayers()"))
    assertTrue(bodyOf("private fun cycleTransition()").contains("makePhotoLayers()"))
  }

  @Test
  fun `a slide moves both photos by one distance from both widths`() {
    val update = bodyOf("private fun updatePhotoTransition(")
    assertTrue(update.contains("PhotoTransition.slideDistance(incomingWidth, outgoingWidth)"))
    assertTrue(update.contains("shiftLayer(incoming, frame.incomingShift * distance)"))
    assertTrue(update.contains("shiftLayer(outgoing, frame.outgoingShift * distance)"))
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
