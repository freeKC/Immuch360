package app.alextran.immich.immersive

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wiring of [SpatialHold] in the immersive viewer, read from the source of ImmersiveViewerActivity (the activity
 * needs the whole app to compile, so the test reads its source as StereoComposerTest reads en.json). SpatialHoldTest
 * proves the mechanism; this test keeps the activity on it: every object of the scene the viewer keeps is held by
 * `sceneHold.ref()`, and onSpatialShutdown lets them all go before anything else. Build 33 brought the photo layer of
 * the flat screens as a plain field, whose late call in onDestroy crashed the process once the SDK had cleared
 * EntityContext, and the 2D window of the app went with it (30 October 2026).
 */
class SpatialHoldWiringTest {
  private val source by lazy { activitySource().readText() }

  @Test
  fun `no object of the scene is a plain field of the viewer`() {
    val plain = PLAIN_SCENE_FIELD.findAll(source).map { it.value }.toList()
    assertTrue(
      "declare them by sceneHold.ref(), so that they read null once the SDK shut the scene down: $plain",
      plain.isEmpty(),
    )
  }

  @Test
  fun `the photo layer of the crash of build 33 is held by the hold`() {
    assertTrue(Regex("""var\s+photoLayerEntity\s*:\s*Entity\?\s+by\s+sceneHold\.ref\(\)""").containsMatchIn(source))
  }

  @Test
  fun `onSpatialShutdown lets the objects of the scene go before anything else`() {
    assertEquals("sceneHold.shutDown()", firstStatementOf("override fun onSpatialShutdown()"))
  }

  @Test
  fun `the lazy creators of the scene make nothing once it is down`() {
    // Each makes its object when its reference reads null, which it always does once the scene is down: a late caller
    // would run Entity.create on the cleared EntityContext and throw the NotImplementedError of the headset
    val unguarded = LAZY_CREATORS.filterNot { firstStatementOf(it).startsWith("if (sceneHold.isDown)") }
    assertTrue("return first once the scene is down in: $unguarded", unguarded.isEmpty())
  }

  /** The first statement in the body of the function [declaration] begins, comments and blank lines skipped */
  private fun firstStatementOf(declaration: String): String {
    val start = source.indexOf(declaration)
    assertTrue("$declaration not found in ImmersiveViewerActivity.kt", start >= 0)
    val body = source.indexOf('{', start + declaration.length)
    return source
      .substring(body + 1)
      .lineSequence()
      .map { it.trim() }
      .first { it.isNotEmpty() && !it.startsWith("//") && !it.startsWith("/*") && !it.startsWith("*") }
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

  private companion object {
    /** The types of the objects of the scene: entities, panels, materials, textures, meshes, Surfaces of layers */
    val SCENE_TYPES =
      listOf("Entity", "PanelSceneObject", "SceneMaterial", "SceneTexture", "SceneMesh", "TriangleMesh", "Surface")

    /** The functions that make an object of the scene at their first call: kiosk panel, photo layer, flat video */
    val LAZY_CREATORS =
      listOf("private fun ensureKioskPanel()", "private fun showOnLayer(", "private fun ensureFlatVideoEntity()")

    /** A nullable property of a scene type that starts at null and is not delegated: kept as is after the shutdown */
    val PLAIN_SCENE_FIELD =
      Regex("""var\s+\w+\s*:\s*(?:[\w.]+\.)?(${SCENE_TYPES.joinToString("|")})\?\s*=\s*null""")
  }
}
