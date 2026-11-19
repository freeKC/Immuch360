package app.alextran.immich.immersive

import app.alextran.immich.relief.ReliefFixtures
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The flat3d JSON of a flat 3D photo or video told by its file name, read against the contract the Dart side writes:
 * mobile/test/fixtures/ai_immersive/flat3d_contract_v1.json.
 */
class FlatStereoSpecTest {
  private val contract = ReliefFixtures.json("flat3d_contract_v1.json")

  @Test
  fun `reads every request of the contract, a photo of the quad as a video of the flat screen`() {
    val cases = contract.getValue("flat3d").jsonArray.map { it.jsonObject }
    assertEquals(5, cases.size)
    for (case in cases) {
      val request = case.getValue("request").jsonObject
      val text = request.toString()
      val format = FlatFormat.parse(case.getValue("format").jsonPrimitive.content)
      val name = case.getValue("name").jsonPrimitive.content
      val full = request["full"]?.jsonPrimitive?.content == "true"

      assertEquals(name, FlatStereoSpec(format!!, full), FlatStereoSpec.parse(text))
      val kind = StereoPhotoKind.parse(text)
      assertEquals(name, StereoPhotoKind.Flat(FlatStereoSpec(format, full)), kind)
      // Another tool's file: the quad claims nothing about how it was made
      assertFalse(name, kind!!.isEstimatedRelief)
      assertFalse(name, kind.leftEyeIsOriginal)
    }
    val formats = cases.map { FlatFormat.parse(it.getValue("format").jsonPrimitive.content) }
    assertEquals(FlatFormat.entries.toSet(), formats.toSet())
  }

  @Test
  fun `refuses what a reader of version 1 does not know, the photo staying flat and the video on the sphere`() {
    val unknown = contract.getValue("unknown").jsonArray
    assertTrue(unknown.size >= 5)
    for (request in unknown) {
      val text = request.toString()
      assertNull(text, FlatStereoSpec.parse(text))
      assertFalse(text, StereoPhotoKind.parse(text) is StereoPhotoKind.Flat)
    }
  }

  @Test
  fun `full is read for side by side eyes only, and a request without it squeezes as before`() {
    val full = FlatStereoSpec.parse("""{"kind":"flat3d","version":1,"format":"sbs","full":true}""")
    assertEquals(FlatStereoSpec(FlatFormat.SBS, fullSaid = true), full)
    assertEquals(
      FlatStereoSpec(FlatFormat.SBS),
      FlatStereoSpec.parse("""{"kind":"flat3d","version":1,"format":"sbs","full":"yes"}"""),
    )
    assertEquals(
      FlatStereoSpec(FlatFormat.TB),
      FlatStereoSpec.parse("""{"kind":"flat3d","version":1,"format":"tb","full":true}"""),
    )
  }

  @Test
  fun `no JSON, or not JSON at all, is no flat 3D media`() {
    assertNull(FlatStereoSpec.parse(null))
    assertNull(FlatStereoSpec.parse(""))
    assertNull(FlatStereoSpec.parse("sbs"))
  }

  @Test
  fun `the other kinds of the stereo quad stay what they were`() {
    val sbs =
      """{"kind":"sbsPhoto","version":1,"layout":"leftRight","eyes":"full","origin":"unknown","leftEye":"unknown"}"""

    assertNull(FlatStereoSpec.parse(sbs))
    assertTrue(StereoPhotoKind.parse(sbs) is StereoPhotoKind.Sbs)
  }
}
