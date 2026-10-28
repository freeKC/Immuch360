package app.alextran.immich.immersive.scene

import app.alextran.immich.immersive.VolumetricSceneSpec
import app.alextran.immich.relief.ReliefFixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The contract between the writer of the computers and the readers of the Quest (design-final 2026-10-27, section 10.1
 * point 8; lot S1): tiny_scene3D_dart.jpg is a scene written by the scene engine of the Dart side
 * (lib/desktop/ai/scene, made again and compared byte for byte by test/desktop/ai/scene/scene_fixture_test.dart), and
 * the readers of lot S2 take it as they take the fixture of the Python script: the packet at its head, the tail it
 * sums, the two layers told by their image, the zone, the weight the gate opens on a Quest 3.
 */
class SceneCrossContractTest {
  private val bytes: ByteArray by lazy { ReliefFixtures.file("tiny_scene3D_dart.jpg").readBytes() }

  private fun head(): SceneHead = SceneFile.readHead(SceneSource.of(bytes))!!

  private fun spec(): VolumetricSceneSpec = head().spec!!

  private fun scene(): GlbScene {
    val spec = spec()
    val tail = SceneFile.readTail(SceneSource.of(bytes), spec.sceneLength, spec.sceneSha256)
    assertTrue("the tail reads: $tail", tail is SceneTailResult.Read)
    return GlbReader.read((tail as SceneTailResult.Read).glb)
  }

  @Test
  fun `the packet at its head is a scene of ours, of version 1, with its request`() {
    val head = head()

    assertEquals(1, head.formatVersion)
    assertEquals("VolumetricScene", head.kind)
    assertEquals(VolumetricSceneSpec.FORMAT, head.sceneFormat)
    assertNull(SceneGate.checkHead(head))
    val spec = spec()
    assertEquals(VolumetricSceneSpec.Origin.RECONSTRUCTED_FROM_PHOTO, spec.origin)
    assertEquals(2, spec.meshes)
    assertTrue(spec.flags.contains("hiddenAreas"))
    assertTrue(spec.safe.lateral in 0.10..0.50)
    assertEquals(SceneFile.specOf(head, null), spec)
  }

  @Test
  fun `its tail is the glb the packet sums, and the reader takes its two layers by their image`() {
    val spec = spec()
    val scene = scene()

    assertEquals(spec.meshes, scene.meshes.size)
    assertEquals(spec.vertices, scene.vertices)
    assertEquals(spec.triangles, scene.triangles)
    assertEquals(spec.textureMax, scene.textures.maxOf { maxOf(it.width, it.height) })
    assertEquals(VolumetricSceneSpec.FORMAT, scene.format)
    assertEquals(spec.safe, scene.safe)
    assertEquals(spec.scale, scene.scale!!, 0.0)
    assertEquals(spec.fovDegrees, scene.fovDegrees!!, 0.0)
    assertEquals("Immuch360 Desktop 3.4.0 scene-v1", scene.generator)
    val (photo, background) = scene.meshes
    assertEquals(SceneLayer.PHOTO, photo.layer)
    assertEquals(0, photo.texture)
    assertEquals(SceneLayer.BACKGROUND, background.layer)
    assertEquals(1, background.texture)
    // The photo texture is the photo, the background the filled map: both 48 x 32 here
    assertEquals(listOf(48 to 32, 48 to 32), scene.textures.map { it.width to it.height })
  }

  @Test
  fun `every vertex in front of the camera, every triangle turned towards it, every uv on its texture`() {
    for (mesh in scene().meshes) {
      for (vertex in 0 until mesh.vertexCount) {
        assertTrue(mesh.positions[3 * vertex + 2] < 0f)
        assertTrue(mesh.uvs[2 * vertex] in 0f..1f && mesh.uvs[2 * vertex + 1] in 0f..1f)
      }
      for (t in mesh.indices.indices step 3) {
        // Projected on the plane of the photo (x right, y up), counter clockwise: the front face of glTF
        fun x(i: Int) = mesh.positions[3 * mesh.indices[t + i]] / -mesh.positions[3 * mesh.indices[t + i] + 2]
        fun y(i: Int) = mesh.positions[3 * mesh.indices[t + i] + 1] / -mesh.positions[3 * mesh.indices[t + i] + 2]
        val area = (x(1) - x(0)) * (y(2) - y(0)) - (x(2) - x(0)) * (y(1) - y(0))
        assertTrue("triangle ${t / 3} of a ${mesh.layer} mesh", area > 0f)
      }
    }
  }

  @Test
  fun `the gate weighs it as its packet says and opens it on a Quest 3, the navigator finds its plane`() {
    val head = head()
    val scene = scene()
    val read = SceneWeight.of(scene, head.formatVersion, bytes.size.toLong())
    val said = SceneWeight.of(spec(), head.formatVersion, bytes.size.toLong())

    assertEquals(said.vertices, read.vertices)
    assertEquals(said.triangles, read.triangles)
    assertEquals(said.textureMax, read.textureMax)
    assertTrue(SceneGate.check(read, SceneGate.capsFor("eureka"), null, null) is SceneVerdict.Open)
    val plane = SceneNavigator.photoPlane(scene.meshes)
    assertNotNull(plane)
    assertTrue(plane!! > 0)
  }
}
