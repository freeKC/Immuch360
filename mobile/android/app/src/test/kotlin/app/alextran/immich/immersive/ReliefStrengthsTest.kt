package app.alextran.immich.immersive

import app.alextran.immich.relief.ReliefFixtures
import app.alextran.immich.relief.ReliefV1
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The relief strengths of the button "Relief: Normal" of the viewer (issue 19, point 4) against the requests the app
 * sends (stereo_pair_contract_v1.json, written from ReliefStrength in Dart): the same parallax under the same name.
 */
class ReliefStrengthsTest {
  private val pairs = ReliefFixtures.json("stereo_pair_contract_v1.json")

  private fun request(name: String): DepthReliefSpec =
    (StereoPhotoKind.parse(
      pairs.getValue("depthRelief").jsonArray
        .first { it.jsonObject.getValue("name").jsonPrimitive.content == name }
        .jsonObject
        .getValue("request")
        .toString()
    ) as StereoPhotoKind.DepthRelief)
      .spec

  @Test
  fun `the strengths of the contract are those of the button, Normal the parallax of every earlier version`() {
    val strong = request("a photo of the server, Strong relief").parallax
    val subtle = request("a photo of the server, Subtle relief").parallax
    assertEquals(ReliefStrengthChoice.STRONG, ReliefStrengthChoice.ofParallax(strong))
    assertEquals(ReliefStrengthChoice.SUBTLE, ReliefStrengthChoice.ofParallax(subtle))
    val normal = request("a photo of the server").parallax
    assertEquals(ReliefStrengthChoice.NORMAL, ReliefStrengthChoice.ofParallax(normal))
    assertEquals(ReliefV1.PARALLAX, ReliefStrengthChoice.NORMAL.parallax, 0.0)
    assertNull(ReliefStrengthChoice.ofParallax(0.06))
  }

  @Test
  fun `the names are those the app keeps in its settings, and the button cycles Subtle, Normal, Strong`() {
    assertEquals(listOf("subtle", "normal", "strong"), ReliefStrengthChoice.entries.map { it.wire })
    assertEquals(ReliefStrengthChoice.NORMAL, ReliefStrengthChoice.SUBTLE.next)
    assertEquals(ReliefStrengthChoice.STRONG, ReliefStrengthChoice.NORMAL.next)
    assertEquals(ReliefStrengthChoice.SUBTLE, ReliefStrengthChoice.STRONG.next)
    assertEquals("aiReliefStrength_strong", ReliefStrengthChoice.STRONG.labelKey)
  }

  @Test
  fun `the button reads its English label when the app sent none`() {
    val label = StereoComposer.label(emptyMap(), ReliefStrengthChoice.LABEL_INFO)
    val name = StereoComposer.label(emptyMap(), ReliefStrengthChoice.STRONG.labelKey)
    assertEquals("Relief: Strong", label.replace(ReliefStrengthChoice.STRENGTH, name))
  }
}
