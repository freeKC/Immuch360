package app.alextran.immich.immersive.splat

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wiring of the splats that the Quest 3 of 31 October 2026 asked for, read from the sources of SplatStage, the
 * splat module of the quest flavour and ImmersiveViewerActivity (they need the Spatial SDK to compile, so the test
 * reads them as WatchWiringTest does). SplatModuleFrameTest, SplatModuleFormatTest and SplatPreparerTest prove the
 * rules; this test keeps the stage and the viewer on them: every pose reaches the module converted, once, through
 * one function; the file is checked once more before the entity; "Loading the splat" while the module loads; the
 * renderer checked once the splat shows; a splat that cannot show keeps the panel in sight.
 */
class SplatWiringTest {
  private val stage by lazy { source("src/main/kotlin/app/alextran/immich/immersive/splat/SplatStage.kt") }
  private val quest by lazy { source("src/quest/kotlin/app/alextran/immich/immersive/splat/SplatEngines.kt") }
  private val activity by lazy { source("src/main/kotlin/app/alextran/immich/immersive/ImmersiveViewerActivity.kt") }
  private val preparer by lazy { source("src/main/kotlin/app/alextran/immich/immersive/splat/SplatPreparer.kt") }

  @Test
  fun `every pose reaches the module through modulePose, once`() {
    // The three entry points: the entity as it is made, a later Transform, the system of the module
    val start = bodyOf(stage, "private fun start(")
    assertInOrder(
      start,
      "val given = modulePose(splat, pose)",
      "engine.create(Uri.fromFile(splat.prepared.file), given)",
    )
    val move = bodyOf(stage, "private fun move(")
    assertInOrder(move, "val given = modulePose(splat, pose)", "when (splat.options.move)")
    assertEquals(3, Regex("Transform\\(given\\)").findAll(move).count())
    assertEquals(2, Regex("engine\\.moveBySystem\\(systems, entity, given\\)").findAll(move).count())
    // No Transform of the splat built anywhere else from a pose of the SDK, and nothing converted twice
    assertEquals(3, Regex("Transform\\(").findAll(stage).count())
    assertEquals(2, Regex("modulePose\\(splat, pose\\)").findAll(stage).count())
    assertEquals(1, Regex("SplatModuleFrame\\.toModule\\(").findAll(stage).count())
    assertTrue(bodyOf(stage, "private fun modulePose(").contains("SplatModuleFrame.toModule(valuesOf(pose))"))
    // The module of the quest flavour takes the pose as it is given: no conversion of its own
    assertFalse(quest.contains("SplatModuleFrame.toModule("))
    assertTrue(quest.contains("Transform(pose)"))
    assertTrue(quest.contains("system.updateSplatTransform(entity.id, pose, Vector3(1f))"))
  }

  @Test
  fun `a splat opens in the orientation chosen for its file, else the one its gaussians say, else the default`() {
    assertInOrder(
      bodyOf(stage, "fun show(\n    prepared: SplatPreparation.Ready"),
      "val upright = memory.chosen(spec.name, prepared.sourceBytes) ?: prepared.upright ?: SplatUpright.DEFAULT",
      "Current(prepared, spec, options, upright)",
    )
  }

  @Test
  fun `the centre of the file is taken as the module shows it before it is turned`() {
    val local = bodyOf(stage, "private fun localOf(")
    assertInOrder(local, "SplatModuleFrame.filePoint(bounds.center)", "rotation.times(", "SplatPlacement.localPosition(")
  }

  @Test
  fun `the file is checked once more before the entity, and refused rather than handed over`() {
    val start = bodyOf(stage, "private fun start(")
    assertInOrder(
      start,
      "SplatModuleFormat.check(splat.prepared.file, expected)",
      "if (unreadable != null)",
      "session.drop()",
      "listener.onSplatRefused(SplatRefusal.MODULE_CANNOT_READ, unreadable)",
      "return",
      "engine.create(",
    )
  }

  @Test
  fun `the preparation checks the whole of the file it gives, off the main thread, and the stage its head`() {
    // SplatPreparer runs on Dispatchers.IO: it reads the whole file (SplatModuleFormat.checkWhole); the stage, on the
    // main thread just before the entity, reads its head again
    assertTrue(bodyOf(preparer, "private fun guarded(").contains("SplatModuleFormat.checkWhole(ready.file, gaussians)"))
    assertFalse(preparer.contains("SplatModuleFormat.check("))
    assertTrue(bodyOf(stage, "private fun start(").contains("SplatModuleFormat.check(splat.prepared.file, expected)"))
    assertFalse(stage.contains("checkWhole"))
  }

  @Test
  fun `the user reads Loading the splat while the module loads it, and the renderer is checked once it shows`() {
    assertInOrder(bodyOf(stage, "private fun start("), "if (!session.made(entity))", "listener.onSplatLoading()")
    assertInOrder(
      bodyOf(stage, "private fun reveal("),
      "entity.setComponent(Visible(true))",
      "listener.onSplatShown()",
      "checkRenderer(splat, entity)",
    )
    assertInOrder(
      bodyOf(stage, "private fun checkRenderer("),
      "if (session.isDown || current !== splat || session.handle !== entity) return@postDelayed",
      "engine.rendererReady(systems)",
      "if (ready == false) listener.onSplatRefused(SplatRefusal.NO_RENDERER",
    )
    assertInOrder(
      bodyOf(activity, "override fun onSplatLoading()"),
      "if (!media.isSplat || closing || sceneHold.isDown) return",
      "cancelInfoHide()",
      "SplatTexts.LABEL_LOADING",
    )
  }

  @Test
  fun `a splat that cannot show says why and keeps the panel and its Back in sight`() {
    assertInOrder(
      bodyOf(activity, "override fun onSplatRefused("),
      "if (!media.isSplat || closing || sceneHold.isDown) return",
      "splatStopped(media, SplatTexts.refusalText(media.stereoLabels, SplatVerdict.Refused(refusal)))",
    )
    val stopped = bodyOf(activity, "private fun splatStopped(")
    assertInOrder(
      stopped,
      "splatDetails = listOf(text)",
      "showPassing(text)",
      "cancelInfoHide()",
      "if (!infoVisible) setInfoVisible(true, reposition = true)",
    )
    assertFalse(stopped.contains("scheduleInfoHide"))
    // While it is prepared and loaded, the panel stays: no hide is scheduled before the splat shows
    assertTrue(bodyOf(activity, "private fun showSplat(").contains("cancelInfoHide()"))
    assertFalse(bodyOf(activity, "private fun showSplat(").contains("scheduleInfoHide"))
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

  /** The body of the function [declaration] begins in [source], braces included */
  private fun bodyOf(source: String, declaration: String): String {
    val start = source.indexOf(declaration)
    assertTrue("$declaration not found", start >= 0)
    return block(source, source.indexOf('{', start + declaration.length))
  }

  /** From the brace at [open] to the one that closes it: strings and line comments skipped */
  private fun block(source: String, open: Int): String {
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

  /** A source of the app module, found by walking up from the working directory (the app module under Gradle) */
  private fun source(path: String): String {
    var dir: File? = File(requireNotNull(System.getProperty("user.dir"))).absoluteFile
    while (dir != null) {
      for (candidate in listOf(File(dir, path), File(dir, "mobile/android/app/$path"), File(dir, "android/app/$path"))) {
        if (candidate.isFile) return candidate.readText()
      }
      dir = dir.parentFile
    }
    error("$path not found above ${System.getProperty("user.dir")}")
  }
}
