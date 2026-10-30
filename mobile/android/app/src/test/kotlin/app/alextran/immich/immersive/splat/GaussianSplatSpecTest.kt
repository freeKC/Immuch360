package app.alextran.immich.immersive.splat

import app.alextran.immich.immersive.FlatScreenLayer
import app.alextran.immich.immersive.FlatScreenMedia
import app.alextran.immich.immersive.StereoPhotoKind
import app.alextran.immich.relief.ReliefFixtures
import kotlinx.serialization.json.jsonArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The gaussianSplat JSON of a splat file of another tool, read against the contract the Dart side writes:
 * mobile/test/fixtures/ai_immersive/gaussian_splat_contract_v1.json (lot S5).
 */
class GaussianSplatSpecTest {
  private val contract = ReliefFixtures.json("gaussian_splat_contract_v1.json")

  @Test
  fun `the requests of the contract read as splats`() {
    val spz = StereoPhotoKind.parse(contract.getValue("gaussianSplat").toString()) as StereoPhotoKind.GaussianSplat
    assertEquals(
      GaussianSplatSpec(SplatFormat.SPZ, 3, 452451, 0, 6824362, 50000, null, "gsplat-cactus.spz"),
      spz.spec,
    )
    val ply = StereoPhotoKind.parse(contract.getValue("ply").toString()) as StereoPhotoKind.GaussianSplat
    assertEquals(SplatFormat.PLY, ply.spec.format)
    assertEquals(150000, ply.spec.maxGaussians)
    assertEquals("make_splat_fixtures.py", ply.spec.tool)
    // A splat claims no relief and no original eye
    assertFalse(spz.isEstimatedRelief)
    assertFalse(spz.leftEyeIsOriginal)
  }

  @Test
  fun `refuses what a reader of version 1 does not know`() {
    val unknown = contract.getValue("unknown").jsonArray
    assertTrue(unknown.size >= 7)
    for (request in unknown) {
      assertFalse(request.toString(), StereoPhotoKind.parse(request.toString()) is StereoPhotoKind.GaussianSplat)
    }
  }

  @Test
  fun `a splat is neither a movable flat screen nor a photo of the layer, and holds no navigation`() {
    val json = contract.getValue("gaussianSplat").toString()
    val media = FlatScreenMedia(isVideo = false, rawProjection = null, stereoPairJson = json, sharpFlatScreens = true)
    assertTrue(media.isSplat)
    assertTrue(media.isStereoPhoto)
    assertFalse(media.isMovableScreen)
    assertFalse(media.photoOnLayer)
    assertFalse(media.isBigScreen)
    assertFalse(media.isFlat3d)
    assertFalse(FlatScreenLayer.showsOnLayer(media.stereoKind, sharp = true))
    // A video never carries one
    val video = FlatScreenMedia(isVideo = true, rawProjection = null, stereoPairJson = json)
    assertFalse(video.isSplat)
    assertNull(video.stereoKind)
  }
}
