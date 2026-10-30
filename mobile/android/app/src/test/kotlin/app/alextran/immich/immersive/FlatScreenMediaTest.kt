package app.alextran.immich.immersive

import app.alextran.immich.relief.ReliefFixtures
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the viewer makes of each request: where the media shows, whether its flat screen moves with the grips, whether
 * its photo goes on the photo layer, and the widths its screen takes. The requests are those of the contracts the Dart
 * side writes (mobile/test/fixtures/ai_immersive/).
 */
class FlatScreenMediaTest {
  private val pairs = ReliefFixtures.json("stereo_pair_contract_v1.json")

  private fun request(group: String, name: String): String =
    pairs.getValue(group).jsonArray
      .first { it.jsonObject.getValue("name").jsonPrimitive.content == name }
      .jsonObject
      .getValue("request")
      .toString()

  private val heic =
    """{"kind":"heicStereoPair","version":1,"primaryItemId":37,"leftItemId":37,"rightItemId":74,""" +
      """"pitmIdOffset":129,"pitmIdBytes":2,"width":3072,"height":3072,"rotation":0,""" +
      """"disparityAdjustment":-1000,"horizontalFovDeg":59.98}"""
  private val sbsEstimated = request("sbsPhoto", "ours")
  private val sbsOther = request("sbsPhoto", "another tool, eyes swapped, half width")
  private val relief = request("depthRelief", "a photo of the server")
  private val scene = request("volumetricScene", "a scene of the design")
  private val flat3d = """{"kind":"flat3d","version":1,"format":"sbs"}"""
  private val bigScreen = ReliefFixtures.json("big_screen_contract_v1.json").getValue("bigScreen").toString()
  private val unreadable = """{"kind":"mvHevc","version":1}"""
  private val raw = """{"kind":"dualFisheye"}"""

  private fun photo(json: String?, sharp: Boolean = true) = FlatScreenMedia(false, null, json, sharp)

  private fun video(json: String?, rawProjection: String? = null) = FlatScreenMedia(true, rawProjection, json)

  @Test
  fun `a photo of two eyes goes on the stereo quad, movable, on the layer, within 30 to 90 degrees`() {
    for (json in listOf(heic, sbsOther, flat3d)) {
      val media = photo(json)
      assertTrue(json, media.isStereoPhoto)
      assertTrue(json, media.isMovableScreen)
      assertTrue(json, media.photoOnLayer)
      assertTrue(json, media.holdsTwoEyes)
      assertFalse(json, media.isFlatVideo)
      assertFalse(json, media.isBigScreen)
      assertEquals(json, 30f..90f, media.angleBounds)
    }
    assertTrue(photo(flat3d).isFlat3d)
    assertFalse(photo(heic).isFlat3d)
    assertTrue(photo(heic).stereoKind is StereoPhotoKind.HeicPair)
  }

  @Test
  fun `an estimated side by side photo stays within 60 degrees`() {
    val media = photo(sbsEstimated)
    assertTrue(media.isMovableScreen)
    assertTrue(media.holdsTwoEyes)
    assertEquals(30f..60f, media.angleBounds)
  }

  @Test
  fun `an ordinary photo on the big screen is one picture, movable, on the layer, within 15 to 110 degrees`() {
    val media = photo(bigScreen)
    assertTrue(media.isStereoPhoto)
    assertTrue(media.isBigScreen)
    assertTrue(media.isMovableScreen)
    assertTrue(media.photoOnLayer)
    assertFalse(media.holdsTwoEyes)
    assertFalse(media.isFlat3d)
    assertEquals(15f..110f, media.angleBounds)
  }

  @Test
  fun `a photo whose JSON does not read shows flat as one picture, movable`() {
    val media = photo(unreadable)
    assertTrue(media.isStereoPhoto)
    assertNull(media.stereoKind)
    assertTrue(media.isMovableScreen)
    assertTrue(media.photoOnLayer)
    assertFalse(media.holdsTwoEyes)
    assertEquals(15f..110f, media.angleBounds)
  }

  @Test
  fun `a relief made in the headset and a scene stay where they were placed, on the mesh`() {
    val made = photo(relief)
    assertFalse(made.isMovableScreen)
    assertFalse(made.photoOnLayer)
    assertTrue(made.holdsTwoEyes)
    assertEquals(30f..60f, made.angleBounds)
    val shown = photo(scene)
    assertFalse(shown.isMovableScreen)
    assertFalse(shown.photoOnLayer)
    assertEquals(30f..90f, shown.angleBounds)
  }

  @Test
  fun `with Sharper flat screens off no photo goes on the layer, the screen still moves`() {
    for (json in listOf(heic, sbsOther, flat3d, bigScreen, unreadable)) {
      val media = photo(json, sharp = false)
      assertFalse(json, media.photoOnLayer)
      assertTrue(json, media.isMovableScreen)
    }
  }

  @Test
  fun `a flat 3D video and a video on the big screen play on the flat video screen, movable, 15 to 110 degrees`() {
    val flat = video(flat3d)
    assertNotNull(flat.flatVideo)
    assertTrue(flat.isFlatVideo)
    assertTrue(flat.isFlat3d)
    assertFalse(flat.isBigScreen)
    assertTrue(flat.isMovableScreen)
    assertFalse(flat.photoOnLayer)
    assertEquals(15f..110f, flat.angleBounds)
    val big = video(bigScreen)
    assertNull(big.flatVideo)
    assertTrue(big.isBigScreenVideo)
    assertTrue(big.isFlatVideo)
    assertTrue(big.isBigScreen)
    assertFalse(big.isFlat3d)
    assertTrue(big.isMovableScreen)
    assertFalse(big.isStereoPhoto)
    assertEquals(15f..110f, big.angleBounds)
  }

  @Test
  fun `a 360 media and a raw 360 video are no flat screen`() {
    for (media in listOf(photo(null), video(null), video(flat3d, rawProjection = raw), video(bigScreen, raw))) {
      assertFalse(media.isMovableScreen)
      assertFalse(media.isFlatVideo)
      assertFalse(media.isBigScreen)
      assertFalse(media.isFlat3d)
      assertFalse(media.photoOnLayer)
    }
    assertTrue(video(flat3d, rawProjection = raw).isRawVideo)
    assertFalse(photo(null).isStereoPhoto)
    assertFalse(photo(null).isRawVideo)
  }
}
