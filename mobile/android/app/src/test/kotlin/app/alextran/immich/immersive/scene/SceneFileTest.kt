package app.alextran.immich.immersive.scene

import app.alextran.immich.immersive.StereoPhotoKind
import app.alextran.immich.immersive.VolumetricSceneSpec
import app.alextran.immich.relief.ReliefFixtures
import java.io.File
import java.io.RandomAccessFile
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The tail of a photo that carries a scene (design-final 2026-10-27, sections 3.2 and 8.2), read as the headset reads
 * its cached copy: right, cut short, saved again by another program (no tail), lengthened, with a wrong or uppercase
 * sum; and the packet at the head of the file, which wins over the JSON of the request. The same cases as
 * scene_container_test.dart, on the same fixture.
 */
class SceneFileTest {
  private val tiny = SceneTestFiles.tiny()
  private val glb = SceneTestFiles.tinyGlb()
  private val sum = SceneTestFiles.sha256(glb)

  private fun read(file: ByteArray, length: Long = glb.size.toLong(), sha256: String = sum): SceneTailResult =
    SceneFile.readTail(SceneSource.of(file), length, sha256)

  @Test
  fun `the scene of the fixture is its last SceneLength bytes, checked by its sum`() {
    val result = read(tiny)

    assertTrue(result is SceneTailResult.Read)
    assertArrayEquals(glb, (result as SceneTailResult.Read).glb)
    assertEquals(3740, glb.size)
    assertEquals(SceneTail(offset = tiny.size - 3740L, length = 3740L), SceneFile.tailOf(tiny.size.toLong(), 3740))
  }

  @Test
  fun `a file cut short, or shorter than its scene, has no scene to read`() {
    // Cut in the middle of the glb: its last SceneLength bytes start inside the preview
    assertEquals(SceneTailResult.Failed(SceneFileProblem.NOT_GLTF), read(tiny.copyOf(tiny.size - 100)))
    // Shorter than the scene the packet names
    assertEquals(SceneTailResult.Failed(SceneFileProblem.MISSING), read(tiny.copyOf(3000)))
    assertNull(SceneFile.tailOf(3000, 3740))
    // A length that cannot even hold the header of a glb
    assertEquals(SceneTailResult.Failed(SceneFileProblem.MISSING), read(tiny, length = 11))
    assertEquals(SceneTailResult.Failed(SceneFileProblem.MISSING), read(tiny, length = 0))
  }

  @Test
  fun `a preview saved again by another program lost its scene`() {
    val preview = SceneTestFiles.tinyPreview()

    // Shorter than the scene it lost, as here, or longer (a photo saved again at a higher quality)
    assertEquals(SceneTailResult.Failed(SceneFileProblem.MISSING), read(preview))
    assertEquals(SceneTailResult.Failed(SceneFileProblem.NOT_GLTF), read(preview + preview))
  }

  @Test
  fun `bytes added after the scene move it away from where the packet says`() {
    assertEquals(SceneTailResult.Failed(SceneFileProblem.NOT_GLTF), read(tiny + ByteArray(16)))
  }

  @Test
  fun `a glb of another version or another length is refused before its sum`() {
    val offset = tiny.size - glb.size
    val version = tiny.copyOf().also { it[offset + 4] = 3 }
    assertEquals(SceneTailResult.Failed(SceneFileProblem.WRONG_VERSION), read(version))

    val length = tiny.copyOf().also { it[offset + 8] = (it[offset + 8] + 4).toByte() }
    assertEquals(SceneTailResult.Failed(SceneFileProblem.WRONG_LENGTH), read(length))
  }

  @Test
  fun `a byte changed in the scene, or a sum that is not ours, gives a wrong sum`() {
    val damaged = tiny.copyOf().also { it[it.size - 1] = (it[it.size - 1] + 1).toByte() }
    assertEquals(SceneTailResult.Failed(SceneFileProblem.WRONG_SUM), read(damaged))
    // The sum must be in lowercase hexadecimal, as VolumetricSceneSpec and scene_container.dart require
    assertEquals(SceneTailResult.Failed(SceneFileProblem.WRONG_SUM), read(tiny, sha256 = sum.uppercase()))
    assertEquals(SceneTailResult.Failed(SceneFileProblem.WRONG_SUM), read(tiny, sha256 = "0".repeat(64)))
  }

  @Test
  fun `a sum that is not ours is refused from the header alone, without reading the scene`() {
    var read = 0L
    val source =
      object : SceneSource {
        override val length = tiny.size.toLong()

        override fun read(offset: Long, count: Int): ByteArray {
          read += count
          return tiny.copyOfRange(offset.toInt(), offset.toInt() + count)
        }
      }

    assertEquals(SceneTailResult.Failed(SceneFileProblem.WRONG_SUM), SceneFile.readTail(source, 3740, sum.uppercase()))
    assertEquals(12L, read)
  }

  @Test
  fun `the cached file is read by ranges, as the bytes in memory`() {
    val file = File.createTempFile("immersive_original_", "_scene3D.jpg")
    try {
      file.writeBytes(tiny)
      RandomAccessFile(file, "r").use { access ->
        val source = SceneSource.of(access)
        assertEquals(tiny.size.toLong(), source.length)
        val result = SceneFile.readTail(source, glb.size.toLong(), sum)
        assertArrayEquals(glb, (result as SceneTailResult.Read).glb)
        assertEquals(VolumetricSceneSpec.FORMAT, SceneFile.readHead(source)?.sceneFormat)
      }
    } finally {
      file.delete()
    }
  }

  @Test
  fun `the packet at the head of the fixture gives the request of the stereoPair contract for this file`() {
    val head = SceneFile.readHead(SceneSource.of(tiny))!!

    assertEquals(1, head.formatVersion)
    assertEquals("VolumetricScene", head.kind)
    assertEquals("glb-layers-v1", head.sceneFormat)
    assertEquals(
      VolumetricSceneSpec(
        format = "glb-layers-v1",
        sceneLength = 3740,
        sceneSha256 = sum,
        meshes = 2,
        vertices = 13,
        triangles = 10,
        textureMax = 32,
        scale = 1.0,
        safe = VolumetricSceneSpec.SafeZone(lateral = 0.15, vertical = 0.09, forward = 0.3, backward = 0.075),
        fovDegrees = 60.0,
        origin = VolumetricSceneSpec.Origin.RECONSTRUCTED_FROM_PHOTO,
        flags = listOf("hiddenAreas"),
      ),
      head.spec,
    )
  }

  @Test
  fun `the packet of the scene sample reads as the volumetricScene request of the contract`() {
    val sample = ReliefFixtures.file("xmp_v1_scene_sample.xmp").readBytes()
    val contract = ReliefFixtures.json("stereo_pair_contract_v1.json")
    val design =
      contract.getValue("volumetricScene").jsonArray.first {
        it.jsonObject.getValue("name").jsonPrimitive.content.contains("design")
      }
    val request =
      StereoPhotoKind.parse(design.jsonObject.getValue("request").toString()) as StereoPhotoKind.VolumetricScene

    assertEquals(request.spec, SceneFile.readHead(SceneSource.of(sample))!!.spec)
  }

  @Test
  fun `the head wins over the JSON of the request, which serves only a file without our packet`() {
    val head = SceneFile.readHead(SceneSource.of(tiny))!!
    val json = head.spec!!.copy(sceneLength = 99, safe = VolumetricSceneSpec.SafeZone(1.0, 1.0, 1.0, 1.0))

    assertEquals(head.spec, SceneFile.specOf(head, json))
    assertEquals(json, SceneFile.specOf(null, json))
    // A head of ours that names a scene this build cannot read gives no request, whatever the JSON says
    val newer = SceneFile.readHead(SceneSource.of(SceneTestFiles.previewWith("SceneFormat", "glb-layers-v2")))!!
    assertEquals("glb-layers-v2", newer.sceneFormat)
    assertNull(newer.spec)
    assertNull(SceneFile.specOf(newer, json))
  }

  @Test
  fun `a packet without a field the request needs, or with a value that cannot be right, gives no request`() {
    for ((name, value) in
      listOf("SceneLength" to "", "SceneLength" to "-3", "SceneSha256" to "ABC", "SafeLateral" to "wide",
        "FieldOfView" to "200", "SceneMeshes" to "2.5")) {
      val head = SceneFile.readHead(SceneSource.of(SceneTestFiles.previewWith(name, value)))!!
      assertNull("$name=$value", head.spec)
    }
    // A newer packet keeps what it says of itself for the gate
    val newer = SceneFile.readHead(SceneSource.of(SceneTestFiles.previewWith("FormatVersion", "2")))!!
    assertEquals(2, newer.formatVersion)
    assertNull(newer.spec)
    // Another kind of ours in the head is no scene either
    assertNull(SceneFile.readHead(SceneSource.of(SceneTestFiles.previewWith("Kind", "Panorama360")))!!.spec)
  }

  @Test
  fun `entities are decoded, and a head without our packet reads as none`() {
    val head = SceneFile.readHead(SceneSource.of(SceneTestFiles.previewWith("QualityFlags", "hiddenAreas&#x2C;sky")))!!
    assertEquals(listOf("hiddenAreas", "sky"), head.spec!!.flags)

    assertNull(SceneFile.readHead(SceneSource.of(ByteArray(64))))
    assertNull(SceneFile.readHead(SceneSource.of(ByteArray(0))))
  }

  @Test
  fun `only the head is searched for the packet`() {
    // The packet pushed beyond the first 128 KiB of the file is not read: the Dart side reads no further
    val far = ByteArray(SceneFile.HEAD_BYTES) + SceneTestFiles.tinyPreview()

    assertNull(SceneFile.readHead(SceneSource.of(far)))
  }
}
