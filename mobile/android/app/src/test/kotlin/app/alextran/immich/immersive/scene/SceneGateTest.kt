package app.alextran.immich.immersive.scene

import app.alextran.immich.immersive.VolumetricSceneSpec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The gate of the scenes in the headset (design-final 2026-10-27, section 3.5, spec 8.3): each cap of each headset,
 * the textures decoded at half on the Quest 2 and Pro, the free memory, the heat and the version, first on the request
 * before the tail is read, then on the glb as read.
 */
class SceneGateTest {
  private val quest3 = SceneGate.capsFor("eureka")
  private val quest2 = SceneGate.capsFor("hollywood")
  private val gib = 1024L * 1024 * 1024

  private fun weight(
    vertices: Int = 58_210,
    triangles: Int = 113_877,
    textures: List<TextureSize>? = listOf(TextureSize(4096, 3072), TextureSize(1024, 768)),
    textureMax: Int = textures?.maxOf { maxOf(it.width, it.height) } ?: 4096,
    fileBytes: Long = 7_000_000,
    formatVersion: Int? = 1,
    sceneFormat: String? = "glb-layers-v1",
  ) = SceneWeight(formatVersion, sceneFormat, fileBytes, vertices, triangles, textureMax, textures)

  private fun check(weight: SceneWeight, caps: SceneCaps = quest3, memory: Long? = 4 * gib, thermal: Int? = 0) =
    SceneGate.check(weight, caps, availableMemory = memory, thermalStatus = thermal)

  private fun heavy(limit: SceneLimit, value: Long, max: Long) =
    SceneVerdict.Refused(SceneRefusal.TOO_HEAVY, limit, value, max)

  private fun opened(verdict: SceneVerdict): SceneVerdict.Open = verdict as SceneVerdict.Open

  @Test
  fun `the Quest 3 and 3S take what the format allows, the Quest 2 and Pro half the geometry`() {
    for (device in listOf("eureka", "panther")) {
      assertEquals(SceneCaps(200_000, 400_000, 4, 4096, null, 64L * 1024 * 1024), SceneGate.capsFor(device))
    }
    for (device in listOf("hollywood", "seacliff")) {
      assertEquals(SceneCaps(100_000, 200_000, 4, 4096, 2048, 64L * 1024 * 1024), SceneGate.capsFor(device))
    }
    // A headset this build does not know is taken as a current one, as the AI relief takes it
    assertEquals(quest3, SceneGate.capsFor("someday"))
    assertEquals(quest3, SceneGate.capsFor(null))
  }

  @Test
  fun `a scene of the design opens on both, its photo decoded at half on the older headsets`() {
    val opened = check(weight()) as SceneVerdict.Open
    assertEquals(listOf(1, 1), opened.sampleSizes)
    assertEquals(4L * (4096 * 3072 + 1024 * 768), opened.decodedBytes)

    val older = check(weight(), quest2) as SceneVerdict.Open
    assertEquals(listOf(2, 1), older.sampleSizes)
    assertEquals(4L * (2048 * 1536 + 1024 * 768), older.decodedBytes)
    // 2048 is not beyond 2048; an odd side rounds up as the decoder does
    val odd = opened(check(weight(textures = listOf(TextureSize(2048, 2048), TextureSize(2049, 15))), quest2))
    assertEquals(listOf(1, 2), odd.sampleSizes)
    assertEquals(4L * (2048 * 2048 + 1025 * 8), odd.decodedBytes)
  }

  @Test
  fun `each cap of the Quest 3, at its value and one beyond`() {
    assertTrue(check(weight(vertices = 200_000, triangles = 400_000)) is SceneVerdict.Open)
    assertEquals(heavy(SceneLimit.TRIANGLES, 400_001, 400_000), check(weight(vertices = 200_000, triangles = 400_001)))
    assertEquals(heavy(SceneLimit.VERTICES, 200_001, 200_000), check(weight(vertices = 200_001, triangles = 400_000)))

    val four = List(4) { TextureSize(1024, 1024) }
    assertTrue(check(weight(textures = four)) is SceneVerdict.Open)
    assertEquals(heavy(SceneLimit.TEXTURES, 5, 4), check(weight(textures = four + TextureSize(16, 16))))

    assertTrue(check(weight(textures = listOf(TextureSize(4096, 4096)))) is SceneVerdict.Open)
    assertEquals(heavy(SceneLimit.TEXTURE_SIDE, 4097, 4096), check(weight(textures = listOf(TextureSize(1024, 4097)))))

    val most = 64L * 1024 * 1024
    assertTrue(check(weight(fileBytes = most)) is SceneVerdict.Open)
    assertEquals(heavy(SceneLimit.FILE, most + 1, most), check(weight(fileBytes = most + 1)))
  }

  @Test
  fun `each cap of the Quest 2 and Pro, at its value and one beyond`() {
    assertTrue(check(weight(vertices = 100_000, triangles = 200_000), quest2) is SceneVerdict.Open)
    assertEquals(
      heavy(SceneLimit.TRIANGLES, 200_001, 200_000),
      check(weight(vertices = 100_000, triangles = 200_001), quest2),
    )
    assertEquals(
      heavy(SceneLimit.VERTICES, 100_001, 100_000),
      check(weight(vertices = 100_001, triangles = 200_000), quest2),
    )
    // The scene of the design (113 877 triangles) opens there; one of 240 000 triangles does not
    assertTrue(check(weight(), quest2) is SceneVerdict.Open)
    assertEquals(
      heavy(SceneLimit.TRIANGLES, 240_000, 200_000),
      check(weight(vertices = 61_000, triangles = 240_000), quest2),
    )
    assertEquals(
      heavy(SceneLimit.TEXTURE_SIDE, 8192, 4096),
      check(weight(textures = listOf(TextureSize(8192, 4096))), quest2),
    )
  }

  @Test
  fun `the triangles are told before the vertices, the geometry before the textures and the file`() {
    assertEquals(
      heavy(SceneLimit.TRIANGLES, 500_000, 400_000),
      check(
        weight(
          vertices = 300_000,
          triangles = 500_000,
          textures = List(6) { TextureSize(8192, 8192) },
          fileBytes = 1L shl 40,
        )
      ),
    )
  }

  @Test
  fun `the free memory must hold three times the decoded textures`() {
    val textures = listOf(TextureSize(4096, 3072), TextureSize(1024, 768))
    val decoded = 4L * (4096 * 3072 + 1024 * 768)
    assertTrue(check(weight(textures = textures), memory = 3 * decoded) is SceneVerdict.Open)
    assertEquals(
      SceneVerdict.Refused(SceneRefusal.NOT_ENOUGH_MEMORY, null, 3 * decoded - 1, 3 * decoded),
      check(weight(textures = textures), memory = 3 * decoded - 1),
    )
    // At half on the Quest 2, the same memory holds the same photo
    val half = 3 * 4L * (2048 * 1536 + 1024 * 768)
    assertTrue(check(weight(textures = textures), quest2, memory = half) is SceneVerdict.Open)
    // Memory unknown, or the textures not read yet: the gate cannot weigh it, the next check will
    assertTrue(check(weight(textures = textures), memory = null) is SceneVerdict.Open)
    assertTrue(check(weight(textures = null), memory = 1) is SceneVerdict.Open)
  }

  @Test
  fun `a severe heat or worse refuses the scene, a moderate one does not`() {
    assertTrue(check(weight(), thermal = SceneGate.THERMAL_STATUS_SEVERE - 1) is SceneVerdict.Open)
    for (status in SceneGate.THERMAL_STATUS_SEVERE..6) {
      assertEquals(SceneVerdict.Refused(SceneRefusal.TOO_WARM), check(weight(), thermal = status))
    }
    assertTrue(check(weight(), thermal = null) is SceneVerdict.Open)
  }

  @Test
  fun `a newer packet or a newer scene format is a newer version, told before anything else`() {
    val newer = SceneVerdict.Refused(SceneRefusal.NEWER_VERSION)
    assertEquals(newer, check(weight(formatVersion = 2)))
    assertEquals(newer, check(weight(sceneFormat = "glb-layers-v2")))
    assertEquals(newer, check(weight(sceneFormat = "glb-layers-v12", triangles = 10_000_000), thermal = 4, memory = 0))
    // A packet that does not say its version is of version 1, as the Dart side reads it
    assertTrue(check(weight(formatVersion = null)) is SceneVerdict.Open)
    // Another text than a format of ours is not a newer version: the reader then says the scene is not ours
    assertEquals(SceneVerdict.Refused(SceneRefusal.NOT_OURS), check(weight(sceneFormat = "splat")))
    assertEquals(SceneVerdict.Refused(SceneRefusal.NOT_OURS), check(weight(sceneFormat = null)))
  }

  @Test
  fun `heaviness, then memory, then heat`() {
    fun reason(verdict: SceneVerdict) = (verdict as SceneVerdict.Refused).reason
    assertEquals(SceneRefusal.TOO_HEAVY, reason(check(weight(triangles = 500_000), memory = 0, thermal = 4)))
    assertEquals(SceneRefusal.NOT_ENOUGH_MEMORY, reason(check(weight(), memory = 0, thermal = 4)))
  }

  @Test
  fun `the weight of a request is its numbers and the size of the file, that of a glb what it holds`() {
    val spec =
      VolumetricSceneSpec(
        format = "glb-layers-v1",
        sceneLength = 6_712_344,
        sceneSha256 = "0".repeat(64),
        meshes = 2,
        vertices = 58_210,
        triangles = 113_877,
        textureMax = 4096,
        scale = 1.0,
        safe = VolumetricSceneSpec.SafeZone(0.22, 0.13, 0.48, 0.11),
        fovDegrees = 65.4,
        origin = VolumetricSceneSpec.Origin.RECONSTRUCTED_FROM_PHOTO,
        flags = emptyList(),
      )
    assertEquals(
      SceneWeight(1, "glb-layers-v1", 7_400_000, 58_210, 113_877, 4096, null),
      SceneWeight.of(spec, formatVersion = 1, fileBytes = 7_400_000),
    )
    // A request whose texture side is beyond the headset is refused before the tail is read
    assertEquals(
      heavy(SceneLimit.TEXTURE_SIDE, 8192, 4096),
      check(SceneWeight.of(spec.copy(textureMax = 8192), 1, 7_400_000)),
    )

    val scene = GlbReader.read(SceneTestFiles.tinyGlb())
    assertEquals(
      SceneWeight(1, "glb-layers-v1", 6438, 13, 10, 32, listOf(TextureSize(32, 24), TextureSize(16, 16))),
      SceneWeight.of(scene, formatVersion = 1, fileBytes = 6438),
    )
    assertEquals(SceneVerdict.Open(listOf(1, 1), 4L * (32 * 24 + 16 * 16)), check(SceneWeight.of(scene, 1, 6438)))
  }
}
