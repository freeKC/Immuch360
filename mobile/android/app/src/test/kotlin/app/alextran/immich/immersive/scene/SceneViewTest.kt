package app.alextran.immich.immersive.scene

import app.alextran.immich.immersive.VolumetricSceneSpec
import app.alextran.immich.immersive.VolumetricSceneSpec.SafeZone
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pure parts of the scene viewer of the Quest (design-final 2026-10-27, sections 3.2 to 3.7): the opening of a
 * cached file from its head to the sample sizes of its textures, in the order the viewer goes (the packet, the gate on
 * the request, the tail, the glb, the gate on the glb), on the fixture of C0; the texts of the panel and of the passing
 * notices; the arrays handed to the triangles of the Spatial SDK; the darkening; the options a measuring session may
 * push to the headset.
 */
class SceneViewTest {
  private val tiny = SceneTestFiles.tiny()
  private val glb = SceneTestFiles.tinyGlb()
  private val quest3 = SceneGate.CURRENT_HEADSETS

  private fun open(
    file: ByteArray = tiny,
    request: VolumetricSceneSpec? = null,
    caps: SceneCaps = quest3,
    memory: Long? = 8L shl 30,
    thermal: Int? = 0,
  ): SceneOpening = SceneOpener.open(SceneSource.of(file), request, caps, { memory }, { thermal })

  private fun stopOf(opening: SceneOpening): SceneStop = (opening as SceneOpening.Stopped).stop

  private fun refusalOf(opening: SceneOpening): SceneVerdict.Refused =
    (stopOf(opening) as SceneStop.Refused).verdict

  /** The preview of the fixture with each of [fields] written as given, then [tail] */
  private fun fileWith(tail: ByteArray, vararg fields: Pair<String, String>): ByteArray {
    var text = String(SceneTestFiles.tinyPreview(), Charsets.ISO_8859_1)
    for ((name, value) in fields) {
      val pattern = Regex("Immuch360:$name=\"[^\"]*\"")
      check(pattern.containsMatchIn(text)) { "no $name in the packet" }
      text = pattern.replace(text, "Immuch360:$name=\"$value\"")
    }
    return text.toByteArray(Charsets.ISO_8859_1) + tail
  }

  // Opening

  @Test
  fun `the fixture opens from its head, its two meshes read and its textures decoded whole`() {
    val opening = open() as SceneOpening.Ready

    assertEquals(SceneFile.readHead(SceneSource.of(tiny))!!.spec, opening.spec)
    assertEquals(2, opening.scene.meshes.size)
    assertEquals(listOf(1, 1), opening.open.sampleSizes)
    assertEquals(4L * (32 * 24 + 16 * 16), opening.open.decodedBytes)
    assertEquals(0.05, opening.hiddenFraction!!, 1e-12)
  }

  @Test
  fun `the head wins over the JSON, which opens a file without our packet`() {
    val head = SceneFile.readHead(SceneSource.of(tiny))!!.spec!!
    val wrongJson = head.copy(sceneLength = 12, sceneSha256 = "0".repeat(64))
    assertTrue(open(request = wrongJson) is SceneOpening.Ready)

    // A JPEG without our packet: the JSON alone finds the scene
    val bare = SceneTestFiles.minimalJpeg() + glb
    assertTrue(open(file = bare, request = head) is SceneOpening.Ready)
    assertEquals(SceneStop.Unreadable(SceneFileProblem.MISSING), stopOf(open(file = bare, request = null)))
  }

  @Test
  fun `a newer packet, or one of another kind, is refused from the head before anything is weighed`() {
    assertEquals(SceneRefusal.NEWER_VERSION, refusalOf(open(file = fileWith(glb, "FormatVersion" to "2"))).reason)
    assertEquals(SceneRefusal.NOT_OURS, refusalOf(open(file = fileWith(glb, "Kind" to "Panorama360"))).reason)
  }

  @Test
  fun `a packet that misses a field, or a tail gone, says the scene data is missing`() {
    val missing = SceneStop.Unreadable(SceneFileProblem.MISSING)
    assertEquals(missing, stopOf(open(file = fileWith(glb, "SceneLength" to ""))))
    assertEquals(missing, stopOf(open(file = SceneTestFiles.tinyPreview())))
    val changed = glb.copyOf().also { it[it.size - 9] = (it[it.size - 9] + 1).toByte() }
    val wrongSum = stopOf(open(file = SceneTestFiles.tinyPreview() + changed))
    assertEquals(SceneStop.Unreadable(SceneFileProblem.WRONG_SUM), wrongSum)
  }

  @Test
  fun `the request is weighed before the tail is read, on the caps of the headset and its heat`() {
    val heavy = refusalOf(open(caps = quest3.copy(maxTriangles = 9)))
    assertEquals(SceneVerdict.Refused(SceneRefusal.TOO_HEAVY, SceneLimit.TRIANGLES, 10, 9), heavy)
    assertEquals(SceneRefusal.TOO_WARM, refusalOf(open(thermal = SceneGate.THERMAL_STATUS_SEVERE)).reason)
    assertEquals(SceneLimit.FILE, refusalOf(open(caps = quest3.copy(maxFileBytes = tiny.size - 1L))).limit)
    // Weighed on the request, the tail is never read: a tail gone still says the scene is too heavy
    val heavyWithoutTail = refusalOf(open(file = SceneTestFiles.tinyPreview(), caps = quest3.copy(maxTriangles = 9)))
    assertEquals(SceneRefusal.TOO_HEAVY, heavyWithoutTail.reason)
  }

  @Test
  fun `the glb read is weighed again, its textures against the free memory`() {
    val decoded = 4L * (32 * 24 + 16 * 16)
    val refused = refusalOf(open(memory = 3 * decoded - 1))
    assertEquals(SceneRefusal.NOT_ENOUGH_MEMORY, refused.reason)
    assertTrue(open(memory = 3 * decoded) is SceneOpening.Ready)
    // Unknown memory or heat: opened, as the gate reads them
    assertTrue(open(memory = null, thermal = null) is SceneOpening.Ready)
  }

  @Test
  fun `a glb of a newer format behind a head of ours says made by a newer version`() {
    val newer = SceneTestFiles.tinyGlbWith(listOf("extras", "immuch360", "format"), JsonPrimitive("glb-layers-v2"))
    assertEquals(glb.size, newer.size)
    val file = fileWith(newer, "SceneSha256" to SceneTestFiles.sha256(newer))

    assertEquals(SceneStop.NotScene(GlbProblem.NEWER_FORMAT), stopOf(open(file = file)))
  }

  @Test
  fun `a glb that is not of our subset behind a head of ours says it is not a scene of ours`() {
    val other = SceneTestFiles.tinyGlbWith(listOf("asset", "version"), JsonPrimitive("3.0"))
    assertEquals(glb.size, other.size)
    val file = fileWith(other, "SceneSha256" to SceneTestFiles.sha256(other))

    assertEquals(SceneStop.NotScene(GlbProblem.NOT_OURS), stopOf(open(file = file)))
  }

  @Test
  fun `an older headset decodes a texture beyond 2048 px at half`() {
    val caps = SceneGate.OLDER_HEADSETS.copy(halveTexturesAbove = 24)
    val opening = open(caps = caps) as SceneOpening.Ready

    assertEquals(listOf(2, 1), opening.open.sampleSizes)
  }

  // Texts

  private val english = emptyMap<String, String>()

  @Test
  fun `each stop says why the photo stays flat, in English without a translation`() {
    fun text(stop: SceneStop) = SceneTexts.stopText(english, stop)
    assertEquals(
      "This scene is too heavy for this headset (400001 triangles, at most 400000)",
      text(SceneStop.Refused(SceneVerdict.Refused(SceneRefusal.TOO_HEAVY, SceneLimit.TRIANGLES, 400_001, 400_000))),
    )
    for (limit in listOf(SceneLimit.VERTICES, SceneLimit.TEXTURES, SceneLimit.TEXTURE_SIDE, SceneLimit.FILE)) {
      assertEquals(
        "This scene is too heavy for this headset",
        text(SceneStop.Refused(SceneVerdict.Refused(SceneRefusal.TOO_HEAVY, limit, 9, 8))),
      )
    }
    assertEquals(
      "Made by a newer version of Immuch360: shown flat",
      text(SceneStop.Refused(SceneVerdict.Refused(SceneRefusal.NEWER_VERSION))),
    )
    assertEquals("Made by a newer version of Immuch360: shown flat", text(SceneStop.NotScene(GlbProblem.NEWER_FORMAT)))
    assertEquals("Not a scene made by Immuch360", text(SceneStop.Refused(SceneVerdict.Refused(SceneRefusal.NOT_OURS))))
    assertEquals("Not a scene made by Immuch360", text(SceneStop.NotScene(GlbProblem.NOT_OURS)))
    assertEquals(
      "Not enough free memory",
      text(SceneStop.Refused(SceneVerdict.Refused(SceneRefusal.NOT_ENOUGH_MEMORY))),
    )
    assertEquals("Headset too warm", text(SceneStop.Refused(SceneVerdict.Refused(SceneRefusal.TOO_WARM))))
    for (problem in SceneFileProblem.entries) {
      assertEquals("The 3D scene data is missing from this file", text(SceneStop.Unreadable(problem)))
    }
    assertEquals("The 3D scene could not be shown: out of memory", text(SceneStop.Failed("out of memory")))
  }

  @Test
  fun `a translated text keeps the numbers in their places`() {
    val labels = mapOf(SceneTexts.LABEL_TOO_HEAVY to "Trop lourde ({triangles} triangles, {max} au plus)")
    val stop = SceneStop.Refused(SceneVerdict.Refused(SceneRefusal.TOO_HEAVY, SceneLimit.TRIANGLES, 10, 9))

    assertEquals("Trop lourde (10 triangles, 9 au plus)", SceneTexts.stopText(labels, stop))
    // A blank translation falls back to English
    assertEquals(
      "Not enough free memory",
      SceneTexts.stopText(
        mapOf(SceneTexts.LABEL_NO_MEMORY to " "),
        SceneStop.Refused(SceneVerdict.Refused(SceneRefusal.NOT_ENOUGH_MEMORY)),
      ),
    )
  }

  @Test
  fun `the room to move is the mean reach on the floor, in centimetres or metres`() {
    assertEquals("18 cm", SceneTexts.sizeText(SceneTexts.reachOf(SafeZone(0.15, 0.09, 0.3, 0.075))))
    assertEquals("Room to move: about 18 cm each way", SceneTexts.zoneText(english, SafeZone(0.15, 0.09, 0.3, 0.075)))
    assertEquals("1.2 m", SceneTexts.sizeText(1.24))
    assertEquals("1 m", SceneTexts.sizeText(0.996))
    assertEquals("0 cm", SceneTexts.sizeText(0.0))
  }

  @Test
  fun `the panel says the honesty sentence, the room, the hidden part filled and the flags of the file`() {
    val spec = SceneFile.readHead(SceneSource.of(tiny))!!.spec!!
    val flags = listOf("hiddenAreas", "fovGuessed", "wideGamut", "x")
    val lines = SceneTexts.detailLines(english, spec.copy(flags = flags), 0.05)

    assertEquals(
      listOf(
        "Reconstructed from one photo, explore within its limits",
        "Room to move: about 18 cm each way",
        "Hidden areas filled: 5%",
        "Field of view guessed: shapes may be off",
      ),
      lines,
    )
    // Without the hidden part, its flag says it; a part under 1 % is not worth a line
    val flagged = SceneTexts.detailLines(english, spec, null)
    assertEquals("Large hidden areas were filled in", flagged.last())
    assertEquals(SceneTexts.detailLines(english, spec, null), SceneTexts.detailLines(english, spec, 0.004))
    // Every flag a scene may carry has its line, but the one about other apps
    val all = listOf("lowRelief", "dark", "sky", "smallZone")
    assertEquals(
      listOf(
        "Little depth found: the relief may be weak",
        "Dark photo: the relief may be wrong",
        "Much of the photo is sky: it stays far away",
        "Barely any movement is possible here: the 3D photo may suit this picture better.",
      ),
      SceneTexts.detailLines(english, spec.copy(flags = all), null).drop(2),
    )
  }

  @Test
  fun `the labels of the panel and of the notices have their English texts`() {
    assertEquals("Reset", SceneTexts.label(english, SceneTexts.LABEL_RESET))
    assertEquals("Photo (2D)", SceneTexts.label(english, SceneTexts.LABEL_PHOTO_2D))
    assertEquals("3D scene", SceneTexts.label(english, SceneTexts.LABEL_SCENE_3D))
    assertEquals("Preparing the 3D scene", SceneTexts.label(english, SceneTexts.LABEL_PREPARING))
    assertEquals(
      "Edge of the reconstructed area. Reset is in the panel.",
      SceneTexts.label(english, SceneTexts.LABEL_EDGE),
    )
    assertTrue(SceneTexts.label(english, SceneTexts.LABEL_HINT).startsWith("Left thumbstick: glide"))
    assertEquals("Explore", SceneTexts.label(mapOf(SceneTexts.LABEL_RESET to "Explore"), SceneTexts.LABEL_RESET))
  }

  // Meshes

  @Test
  fun `the arrays of a mesh are written for the Spatial SDK, whole at the start`() {
    val scene = GlbReader.read(glb)
    val plane = SceneNavigator.photoPlane(scene.meshes)!!
    for (mesh in scene.meshes) {
      val buffers = SceneMeshBuffers(mesh)
      val positions = buffers.write(0.0, plane)
      val n = mesh.vertexCount

      assertArrayEquals(SdkFrame.positions(mesh.positions, FloatArray(3 * n)), positions, 0f)
      assertArrayEquals(SdkFrame.indices(mesh.indices), buffers.indices)
      assertArrayEquals(mesh.uvs, buffers.uvs, 0f)
      assertEquals(3 * n, buffers.normals.size)
      assertTrue((0 until n).all { buffers.normals[3 * it + 2] == -1f && buffers.normals[3 * it] == 0f })
      assertArrayEquals(IntArray(n) { SceneShade.WHITE }, buffers.colours)
    }
  }

  @Test
  fun `flattened, a mesh slides on its rays to the photo plane before its z is turned`() {
    val scene = GlbReader.read(glb)
    val plane = SceneNavigator.photoPlane(scene.meshes)!!
    for (mesh in scene.meshes) {
      val buffers = SceneMeshBuffers(mesh)
      val flat = SceneNavigator.flatten(mesh, 1.0, plane, FloatArray(3 * mesh.vertexCount))
      val expected = SdkFrame.positions(flat, FloatArray(flat.size))

      assertArrayEquals(expected, buffers.write(1.0, plane), 1e-6f)
      // The same array each time, rewritten in place
      assertTrue(buffers.write(0.5, plane) === buffers.write(0.0, plane))
    }
    // Without a photo layer nothing flattens
    val mesh = scene.meshes.first()
    assertArrayEquals(
      SdkFrame.positions(mesh.positions, FloatArray(mesh.positions.size)),
      SceneMeshBuffers(mesh).write(1.0, null),
      0f,
    )
  }

  // Darkening and options

  @Test
  fun `the scene darkens by a grey that keeps the alpha, made again by steps`() {
    assertEquals(1.0, SceneShade.brightness(0.0), 0.0)
    assertEquals(0.05, SceneShade.brightness(0.95), 1e-12)
    assertEquals(SceneShade.WHITE, SceneShade.grey(0.0))
    assertEquals(0xFF0D0D0D.toInt(), SceneShade.grey(0.95))
    val buffers = SceneMeshBuffers(GlbReader.read(glb).meshes.first())
    assertTrue(buffers.shade(0.95).all { it == 0xFF0D0D0D.toInt() })

    assertFalse(SceneShade.needsUpdate(0.0, 0.019))
    assertTrue(SceneShade.needsUpdate(0.0, 0.02))
    assertTrue(SceneShade.needsUpdate(0.94, SceneNavigator.DARKEN_MAX))
    assertTrue(SceneShade.needsUpdate(0.01, 0.0))
    assertFalse(SceneShade.needsUpdate(0.0, 0.0))
  }

  @Test
  fun `a measuring session may push the darkening and the sides it tries, the defaults otherwise`() {
    val defaults = SceneViewerOptions()
    assertEquals(SceneDarkening.ALBEDO, defaults.darkening)
    assertTrue(defaults.doubleSided)
    assertEquals(defaults, SceneViewerOptions.parse(null))
    assertEquals(defaults, SceneViewerOptions.parse("# nothing\nother=1\ndarken=paint\nsides=both"))
    assertEquals(
      SceneViewerOptions(SceneDarkening.VERTEX_COLOURS, doubleSided = false),
      SceneViewerOptions.parse("darken = vertex\r\nsides=single\n"),
    )
    assertEquals(
      SceneViewerOptions(SceneDarkening.ALBEDO, true),
      SceneViewerOptions.parse("darken=albedo\nsides=double"),
    )
  }

  @Test
  fun `the hidden part of the head is read with the request`() {
    assertEquals(0.05, SceneFile.readHead(SceneSource.of(tiny))!!.hiddenFraction!!, 1e-12)
    for (value in listOf("much", "-0.1", "1.5")) {
      val head = SceneFile.readHead(SceneSource.of(SceneTestFiles.previewWith("HiddenFraction", value)))!!
      assertNull(value, head.hiddenFraction)
    }
    // A packet this build does not read says nothing of it either
    assertNull(SceneFile.readHead(SceneSource.of(SceneTestFiles.previewWith("FormatVersion", "2")))!!.hiddenFraction)
  }
}
