package app.alextran.immich.immersive

import app.alextran.immich.relief.ReliefStage
import app.alextran.immich.relief.ReliefStop
import com.meta.spatial.core.Vector3
import java.io.File
import kotlin.math.tan
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/** The texture and the quad of a spatial photo (section 5.8 of the design). */
class StereoComposerTest {
  @Test
  fun `no disparity keeps both eyes whole`() {
    assertEquals(StereoComposer.Crop(leftStart = 0, rightStart = 0, width = 3072), StereoComposer.crop(3072, 0))
  }

  @Test
  fun `a positive disparity pushes the scene back`() {
    // s = 200 / 10000 * 3072 / 2 = 30.72, 31 pixels: the left eye keeps its right part, the right eye its left part
    assertEquals(StereoComposer.Crop(leftStart = 62, rightStart = 0, width = 3010), StereoComposer.crop(3072, 200))
  }

  @Test
  fun `a negative disparity brings the scene forward`() {
    // s = 1000 / 10000 * 3072 / 2 = 153.6, 154 pixels
    assertEquals(StereoComposer.Crop(leftStart = 0, rightStart = 308, width = 2764), StereoComposer.crop(3072, -1000))
  }

  @Test
  fun `a disparity past 2000 is clamped`() {
    // As 2000: s = 0.2 * 3072 / 2 = 307.2, 307 pixels
    assertEquals(StereoComposer.Crop(leftStart = 614, rightStart = 0, width = 2458), StereoComposer.crop(3072, 2500))
    assertEquals(StereoComposer.crop(3072, -2000), StereoComposer.crop(3072, -9000))
  }

  @Test
  fun `the texture holds both eyes in their gutters`() {
    assertEquals(2 * (2764 + 8) to 3072 + 8, StereoComposer.textureSize(2764, 3072))
  }

  @Test
  fun `the quad starts at 0_8 of the field of view of the camera, within 35 and 60 degrees`() {
    assertEquals(48f, StereoComposer.initialAngle(60f), 1e-4f)
    assertEquals(48f, StereoComposer.initialAngle(null))
    assertEquals(60f, StereoComposer.initialAngle(120f))
    assertEquals(35f, StereoComposer.initialAngle(30f))
  }

  @Test
  fun `the quad is as wide as its angle at 2 m, as tall as the eyes say`() {
    for ((fov, angle) in listOf(60f to 48f, null to 48f, 120f to 60f)) {
      val start = StereoComposer.initialAngle(fov)
      assertEquals("fov $fov", angle, start, 1e-4f)
      val (width, height) = StereoComposer.quadSize(start, 3072, 3072)
      val expected = (2 * 2.0 * tan(Math.toRadians(angle / 2.0))).toFloat()
      assertEquals("fov $fov", expected, width, 1e-4f)
      // A square eye in its gutters is square
      assertEquals("fov $fov", width, height, 1e-4f)
    }
    // 60 degrees at 2 m: 2.309 m wide
    assertEquals(2.3094f, StereoComposer.quadSize(60f, 3072, 3072).first, 1e-3f)
    // A 4:3 eye after a crop for the disparity: the height follows the eye with its gutters
    val (width, height) = StereoComposer.quadSize(48f, 2764, 2304)
    assertEquals(width * (2304 + 8) / (2764 + 8), height, 1e-4f)
  }

  @Test
  fun `the thumbstick changes the angle by 6 degrees within 30 and 90`() {
    assertEquals(54f, StereoComposer.nextAngle(48f, 1))
    assertEquals(42f, StereoComposer.nextAngle(48f, -1))
    assertEquals(90f, StereoComposer.nextAngle(88f, 1))
    assertEquals(30f, StereoComposer.nextAngle(33f, -1))
  }

  @Test
  fun `fits an eye within the texture limits, its aspect kept`() {
    assertEquals(2560 to 2560, StereoComposer.fitWithin(3072, 3072, 2560, 4088))
    assertEquals(2000 to 1000, StereoComposer.fitWithin(2000, 1000, 2560, 4088))
    assertEquals(2555 to 4088, StereoComposer.fitWithin(3000, 4800, 2560, 4088))
  }

  @Test
  fun `the grey difference of two images`() {
    val black = IntArray(4) { 0xFF000000.toInt() }
    val white = IntArray(4) { 0xFFFFFFFF.toInt() }
    assertEquals(0f, StereoComposer.meanGreyDifference(black, black.copyOf()), 1e-4f)
    assertEquals(255f, StereoComposer.meanGreyDifference(black, white), 1e-3f)
    val half = intArrayOf(0xFFFFFFFF.toInt(), 0xFFFFFFFF.toInt(), 0xFF000000.toInt(), 0xFF000000.toInt())
    assertEquals(127.5f, StereoComposer.meanGreyDifference(black, half), 1e-3f)
  }

  @Test
  fun `the quad faces the user as the panels do, its eyes the right way round`() {
    // The gaze, and the right of the user in the left handed space of the Spatial SDK (x right, y up, z forward)
    val cases =
      listOf(
        Vector3(0f, 0f, 1f) to Vector3(1f, 0f, 0f),
        Vector3(1f, 0f, 0f) to Vector3(0f, 0f, -1f),
        Vector3(0f, 0f, -1f) to Vector3(-1f, 0f, 0f),
        Vector3(-0.6f, 0f, 0.8f) to Vector3(0.8f, 0f, 0.6f),
      )
    for ((gaze, right) in cases) {
      val rotation = StereoComposer.quadRotation(gaze)
      // u grows along the +x of SceneMesh.singleSidedQuad: to the right of the user, not mirrored
      assertVector("u axis for gaze $gaze", right, rotation * Vector3(1f, 0f, 0f))
      assertVector("up for gaze $gaze", Vector3(0f, 1f, 0f), rotation * Vector3(0f, 1f, 0f))
      // Its +z normal along the gaze: the user sees the other side, which the double sided material shows
      assertVector("normal for gaze $gaze", gaze, rotation * Vector3(0f, 0f, 1f))
    }
  }

  @Test
  fun `the choices on a spatial photo come back for that photo of that opening only`() {
    val choices = StereoPhotoChoices("https://server/photo.heic", 7L, threeD = false, angleDeg = 66f)
    assertEquals(choices, choices.forPhoto("https://server/photo.heic", 7L))
    assertNull(choices.forPhoto("https://server/other.heic", 7L))
    assertNull(choices.forPhoto("https://server/photo.heic", 8L))
    // The 2.5D view of a relief comes back too; any other photo is not in 2.5D
    val mesh = choices.copy(threeD = true, mesh25d = true)
    assertEquals(mesh, mesh.forPhoto("https://server/photo.heic", 7L))
    assertFalse(StereoPhotoChoices("u", 1L, threeD = true, angleDeg = 48f).mesh25d)
  }

  @Test
  fun `the 3D button goes from 3D to 2_5D when the relief has its mesh, then to 2D, then back to 3D`() {
    assertEquals(StereoView.MESH_25D, StereoComposer.nextView(StereoView.THREE_D, meshAvailable = true))
    assertEquals(StereoView.TWO_D, StereoComposer.nextView(StereoView.MESH_25D, meshAvailable = true))
    assertEquals(StereoView.THREE_D, StereoComposer.nextView(StereoView.TWO_D, meshAvailable = true))
    // Any other stereo photo, or a relief whose mesh could not be made: 3D and 2D as before
    assertEquals(StereoView.TWO_D, StereoComposer.nextView(StereoView.THREE_D, meshAvailable = false))
    assertEquals(StereoView.THREE_D, StereoComposer.nextView(StereoView.TWO_D, meshAvailable = false))
    assertEquals(StereoView.TWO_D, StereoComposer.nextView(StereoView.MESH_25D, meshAvailable = false))
  }

  @Test
  fun `the 3D button says what the quad shows, 2_5D experimental included`() {
    assertEquals(StereoComposer.LABEL_3D, StereoComposer.viewLabelKey(StereoView.THREE_D, leftEyeIsOriginal = true))
    assertEquals(StereoComposer.LABEL_25D, StereoComposer.viewLabelKey(StereoView.MESH_25D, leftEyeIsOriginal = true))
    assertEquals(
      StereoComposer.LABEL_2D_ORIGINAL,
      StereoComposer.viewLabelKey(StereoView.TWO_D, leftEyeIsOriginal = true),
    )
    assertEquals(StereoComposer.LABEL_2D, StereoComposer.viewLabelKey(StereoView.TWO_D, leftEyeIsOriginal = false))
    assertEquals("2.5D (experimental)", StereoComposer.label(emptyMap(), StereoComposer.LABEL_25D))
    assertEquals("2,5D (expérimental)", StereoComposer.label(mapOf("ai25d" to "2,5D (expérimental)"), "ai25d"))
  }

  @Test
  fun `a restored angle stays within the bounds of the thumbstick`() {
    val wide = StereoPhotoChoices("u", 1L, threeD = true, angleDeg = 120f)
    assertEquals(90f, wide.forPhoto("u", 1L)?.angleDeg)
    assertEquals(30f, wide.copy(angleDeg = 10f).forPhoto("u", 1L)?.angleDeg)
    assertNull(wide.copy(angleDeg = Float.NaN).forPhoto("u", 1L))
  }

  private fun assertVector(message: String, expected: Vector3, actual: Vector3) {
    assertEquals("$message x", expected.x, actual.x, 1e-4f)
    assertEquals("$message y", expected.y, actual.y, 1e-4f)
    assertEquals("$message z", expected.z, actual.z, 1e-4f)
  }

  @Test
  fun `an estimated relief is never wider than 60 degrees`() {
    // At 60 degrees the 2 percent of relief-v1 make 1.25 degrees, at 90 they would make 1.8
    assertEquals(60f, StereoComposer.maxAngle(estimatedRelief = true))
    assertEquals(90f, StereoComposer.maxAngle(estimatedRelief = false))
    assertEquals(60f, StereoComposer.nextAngle(54f, 1, StereoComposer.maxAngle(estimatedRelief = true)))
    assertEquals(60f, StereoComposer.nextAngle(60f, 1, StereoComposer.maxAngle(estimatedRelief = true)))
    assertEquals(54f, StereoComposer.nextAngle(60f, -1, StereoComposer.maxAngle(estimatedRelief = true)))
    // A file of another tool, a spatial photo: up to 90 as before
    assertEquals(66f, StereoComposer.nextAngle(60f, 1, StereoComposer.maxAngle(estimatedRelief = false)))
    // A choice kept over a recreation stays within the cap of its photo
    val wide = StereoPhotoChoices("u", 1L, threeD = true, angleDeg = 84f)
    assertEquals(60f, wide.forPhoto("u", 1L, StereoComposer.maxAngle(estimatedRelief = true))?.angleDeg)
    assertEquals(84f, wide.forPhoto("u", 1L)?.angleDeg)
  }

  @Test
  fun `the 2D button names the original when the left eye is the photo itself`() {
    assertEquals(StereoComposer.LABEL_2D_ORIGINAL, StereoComposer.twoDLabelKey(leftEyeIsOriginal = true))
    assertEquals(StereoComposer.LABEL_2D, StereoComposer.twoDLabelKey(leftEyeIsOriginal = false))
    assertEquals("2D (original)", StereoComposer.label(emptyMap(), StereoComposer.LABEL_2D_ORIGINAL))
    assertEquals("2D (left eye)", StereoComposer.label(emptyMap(), StereoComposer.LABEL_2D))
    assertEquals("2D (original)", StereoComposer.label(mapOf("ai2dOriginal" to " "), "ai2dOriginal"))
    val french = mapOf("ai2dOriginal" to "2D (photo d'origine)")
    assertEquals("2D (photo d'origine)", StereoComposer.label(french, "ai2dOriginal"))
  }

  @Test
  fun `the honesty label and the navigation of 3D photos have their own English texts`() {
    assertEquals("Relief estimated by AI", StereoComposer.label(emptyMap(), StereoComposer.LABEL_RELIEF_ESTIMATED))
    assertEquals(
      "Previous and next are not available for 3D photos yet",
      StereoComposer.label(emptyMap(), StereoComposer.LABEL_NO_NAVIGATION_3D),
    )
    // The Apple spatial photos keep theirs
    assertEquals(
      "Previous and next are not available for spatial photos yet",
      StereoComposer.label(emptyMap(), StereoComposer.LABEL_NO_NAVIGATION),
    )
  }

  @Test
  fun `labels fall back to English`() {
    assertEquals("3D", StereoComposer.label(emptyMap(), StereoComposer.LABEL_3D))
    assertEquals("2D (œil gauche)", StereoComposer.label(mapOf("spatial2d" to "2D (œil gauche)"), "spatial2d"))
    assertEquals(
      "The second eye could not be decoded: shown in 2D",
      StereoComposer.label(mapOf("spatialSecondEyeFailed" to " "), StereoComposer.LABEL_SECOND_EYE_FAILED),
    )
  }
  @Test
  fun `each stage of a relief has its label`() {
    assertEquals(StereoComposer.LABEL_RELIEF_PREPARING, StereoComposer.reliefStageLabelKey(ReliefStage.PREPARING))
    assertEquals(StereoComposer.LABEL_RELIEF_ESTIMATING, StereoComposer.reliefStageLabelKey(ReliefStage.ESTIMATING))
    assertEquals(StereoComposer.LABEL_RELIEF_BUILDING, StereoComposer.reliefStageLabelKey(ReliefStage.BUILDING))
    assertEquals("Estimating the relief (AI)", StereoComposer.label(emptyMap(), StereoComposer.LABEL_RELIEF_ESTIMATING))
    assertEquals("Stop relief", StereoComposer.label(emptyMap(), StereoComposer.LABEL_RELIEF_STOP))
  }

  @Test
  fun `a photo left flat says why, but for the Stop relief of the user`() {
    assertNull(StereoComposer.reliefStopText(emptyMap(), ReliefStop.STOPPED, ""))
    assertEquals(
      "Headset too warm, relief stopped",
      StereoComposer.reliefStopText(emptyMap(), ReliefStop.TOO_WARM, ""),
    )
    assertEquals(
      "Not in this version of the app",
      StereoComposer.reliefStopText(emptyMap(), ReliefStop.NOT_IN_THIS_VERSION, ""),
    )
    assertEquals("Not enough memory", StereoComposer.reliefStopText(emptyMap(), ReliefStop.NOT_ENOUGH_MEMORY, ""))
    assertEquals(
      "The AI components are not installed",
      StereoComposer.reliefStopText(emptyMap(), ReliefStop.MODEL_MISSING, ""),
    )
    assertEquals("An AI component is damaged", StereoComposer.reliefStopText(emptyMap(), ReliefStop.MODEL_DAMAGED, ""))
    // Every reason but the stop of the user has its own label
    val keys = ReliefStop.entries.mapNotNull { StereoComposer.reliefStopLabelKey(it) }
    assertEquals(ReliefStop.entries.size - 1, keys.toSet().size)
  }

  @Test
  fun `a failed relief says its reason in the translated sentence`() {
    assertEquals(
      "The relief failed: the pass failed on CPU",
      StereoComposer.reliefStopText(emptyMap(), ReliefStop.FAILED, "the pass failed on CPU"),
    )
    val french = mapOf(StereoComposer.LABEL_RELIEF_FAILED to "Le relief a échoué : {reason}")
    assertEquals(
      "Le relief a échoué : the pass failed on CPU",
      StereoComposer.reliefStopText(french, ReliefStop.FAILED, "the pass failed on CPU"),
    )
  }

  @Test
  fun `the English texts of the relief and of the flat 3D media are those of en_json`() {
    // The translation keys Flutter sends them under (lib/domain/models/ai_immersive/immersive_viewer_labels.dart)
    val translated =
      mapOf(
        StereoComposer.LABEL_2D_ORIGINAL to "ai_immersive_2d_original",
        StereoComposer.LABEL_25D to "ai_immersive_mode_25d",
        StereoComposer.LABEL_RELIEF_ESTIMATED to "ai_immersive_relief_estimated",
        StereoComposer.LABEL_NO_NAVIGATION_3D to "ai_immersive_no_navigation",
        StereoComposer.LABEL_RELIEF_PREPARING to "ai_immersive_state_preparing",
        StereoComposer.LABEL_RELIEF_ESTIMATING to "ai_immersive_relief_estimating",
        StereoComposer.LABEL_RELIEF_BUILDING to "ai_immersive_relief_building",
        StereoComposer.LABEL_RELIEF_STOP to "ai_immersive_relief_stop",
        StereoComposer.LABEL_RELIEF_TOO_WARM to "ai_immersive_relief_too_warm",
        StereoComposer.LABEL_RELIEF_FAILED to "ai_immersive_relief_failed",
        StereoComposer.LABEL_RELIEF_NOT_IN_VERSION to "ai_immersive_unavailable_build",
        StereoComposer.LABEL_RELIEF_NO_MEMORY to "ai_immersive_unavailable_memory",
        StereoComposer.LABEL_RELIEF_MISSING to "ai_immersive_unavailable_missing",
        StereoComposer.LABEL_RELIEF_DAMAGED to "ai_immersive_unavailable_damaged",
        StereoComposer.LABEL_FLAT3D_NOTICE to "immersive_flat_3d_notice",
        StereoComposer.LABEL_FLAT3D_NO_NAVIGATION to "immersive_flat_3d_no_navigation",
      )
    val english = Json.parseToJsonElement(englishFile().readText()).jsonObject
    for ((key, translation) in translated) {
      assertEquals(key, english.getValue(translation).jsonPrimitive.content, StereoComposer.label(emptyMap(), key))
    }
  }

  /** i18n/en.json of the repository, found by walking up from the working directory */
  private fun englishFile(): File {
    var dir: File? = File(requireNotNull(System.getProperty("user.dir"))).absoluteFile
    while (dir != null) {
      val candidate = File(dir, "i18n/en.json")
      if (candidate.isFile) return candidate
      dir = dir.parentFile
    }
    error("i18n/en.json not found")
  }
}
