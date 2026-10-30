package app.alextran.immich.immersive

import app.alextran.immich.relief.ReliefFixtures
import kotlinx.serialization.json.jsonArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The bigScreen JSON of an ordinary photo or video opened with "View on a big screen", read against the contract the
 * Dart side writes: mobile/test/fixtures/ai_immersive/big_screen_contract_v1.json. "View on a big screen" is an idea of
 * Gaurav Mukherjee (gmfun/Immuch360, branch quest/flat-3d, commit 502779b0b).
 */
class BigScreenSpecTest {
  private val contract = ReliefFixtures.json("big_screen_contract_v1.json")

  @Test
  fun `the request of the contract puts a photo on the big screen and a video on the flat video screen`() {
    val text = contract.getValue("bigScreen").toString()

    assertTrue(BigScreenSpec.isRequest(text))
    assertEquals(StereoPhotoKind.BigScreen, StereoPhotoKind.parse(text))
    // An ordinary photo: no relief claimed, no "2D (original)"
    assertFalse(StereoPhotoKind.BigScreen.isEstimatedRelief)
    assertFalse(StereoPhotoKind.BigScreen.leftEyeIsOriginal)
  }

  @Test
  fun `refuses what a reader of version 1 does not know`() {
    val unknown = contract.getValue("unknown").jsonArray
    assertTrue(unknown.size >= 4)
    for (request in unknown) {
      val text = request.toString()
      assertFalse(text, BigScreenSpec.isRequest(text))
      assertNotEquals(text, StereoPhotoKind.BigScreen, StereoPhotoKind.parse(text))
    }
  }

  @Test
  fun `no JSON, or not JSON at all, is no big screen request`() {
    assertFalse(BigScreenSpec.isRequest(null))
    assertFalse(BigScreenSpec.isRequest(""))
    assertFalse(BigScreenSpec.isRequest("bigScreen"))
    assertFalse(BigScreenSpec.isRequest("""{"kind":"flat3d","version":1,"format":"sbs"}"""))
  }

  @Test
  fun `a photo on the big screen goes on the compositor layer with the sharp setting, and on the mesh without`() {
    assertTrue(FlatScreenLayer.showsOnLayer(StereoPhotoKind.BigScreen, sharp = true))
    assertFalse(FlatScreenLayer.showsOnLayer(StereoPhotoKind.BigScreen, sharp = false))
  }
}
