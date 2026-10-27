package app.alextran.immich.immersive

import app.alextran.immich.relief.ReliefFixtures
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The three kinds of the stereoPair JSON (design-final 2026-10-26, section 4.1), read against the contract the Dart
 * side writes: mobile/test/fixtures/ai_immersive/stereo_pair_contract_v1.json.
 */
class StereoPhotoKindTest {
  private val contract = ReliefFixtures.json("stereo_pair_contract_v1.json")

  private fun requests(group: String): Map<String, String> =
    contract.getValue(group).jsonArray.associate {
      it.jsonObject.getValue("name").jsonPrimitive.content to it.jsonObject.getValue("request").toString()
    }

  @Test
  fun `reads our side by side photo of the contract`() {
    val kind = StereoPhotoKind.parse(requests("sbsPhoto").getValue("ours"))

    assertEquals(
      StereoPhotoKind.Sbs(
        SbsPhotoSpec(
          layout = SbsPhotoSpec.Layout.LEFT_RIGHT,
          eyes = SbsPhotoSpec.Eyes.FULL,
          origin = SbsPhotoSpec.Origin.ESTIMATED_DEPTH,
          leftEye = SbsPhotoSpec.LeftEye.ORIGINAL,
        )
      ),
      kind,
    )
    assertTrue(kind!!.isEstimatedRelief)
    assertTrue(kind.leftEyeIsOriginal)
  }

  @Test
  fun `reads the file of another tool, eyes swapped and half width, and claims nothing about it`() {
    val kind = StereoPhotoKind.parse(requests("sbsPhoto").getValue("another tool, eyes swapped, half width"))

    assertEquals(
      StereoPhotoKind.Sbs(
        SbsPhotoSpec(
          layout = SbsPhotoSpec.Layout.RIGHT_LEFT,
          eyes = SbsPhotoSpec.Eyes.HALF,
          origin = SbsPhotoSpec.Origin.UNKNOWN,
          leftEye = SbsPhotoSpec.LeftEye.UNKNOWN,
        )
      ),
      kind,
    )
    assertFalse(kind!!.isEstimatedRelief)
    assertFalse(kind.leftEyeIsOriginal)
  }

  @Test
  fun `reads both relief requests of the contract`() {
    val requests = requests("depthRelief")
    val server = StereoPhotoKind.parse(requests.getValue("a photo of the server"))
    val share = StereoPhotoKind.parse(requests.getValue("a photo of a share, turned once"))

    val model =
      "/data/user/0/com.aprogsys.immuch360/files/ai-components/models/depth-anything-v2-small/" +
        "depth_anything_v2_small.tflite"
    assertEquals(
      StereoPhotoKind.DepthRelief(
        DepthReliefSpec(
          model = model,
          modelSize = 99530468L,
          modelId = "depth-anything-v2-small@651415f1",
          cacheKey = "448add6b9d133349558e237bd153dccc15b85c23f75231323ec5be4f8ae8a79c",
          parallax = 0.02,
          convergence = 0.5,
          quarterTurns = 0,
        )
      ),
      server,
    )
    assertEquals(1, (share as StereoPhotoKind.DepthRelief).spec.quarterTurns)
    assertEquals("c50073109b15a039ecce095402c90213f4d7be326a366f2831c189182d0fe668", share.spec.cacheKey)
    // The headset makes the right eye, the left one stays the photo
    assertTrue(share.isEstimatedRelief)
    assertTrue(share.leftEyeIsOriginal)
  }

  @Test
  fun `a relief request names its mode for 2_5D only, and stereo is the rest`() {
    val requests = requests("depthRelief")
    val server = StereoPhotoKind.parse(requests.getValue("a photo of the server")) as StereoPhotoKind.DepthRelief
    val text = requests.getValue("a photo of the server, first shown in 2.5D")
    val mesh = StereoPhotoKind.parse(text) as StereoPhotoKind.DepthRelief

    assertEquals(ReliefViewMode.STEREO, server.spec.mode)
    assertEquals(ReliefViewMode.MESH_25D, mesh.spec.mode)
    // The same photo, the same map: only the first view changes
    assertEquals(server.spec.copy(mode = ReliefViewMode.MESH_25D), mesh.spec)
    for (other in listOf("\"volumetric\"", "\"stereo\"", "2", "null")) {
      val read = StereoPhotoKind.parse(text.replace("\"mesh25d\"", other)) as StereoPhotoKind.DepthRelief
      assertEquals(other, ReliefViewMode.STEREO, read.spec.mode)
    }
  }

  @Test
  fun `the cache keys of the requests are those of the contract`() {
    val keys = contract.getValue("cacheKeys").jsonArray.map { it.jsonObject.getValue("key").jsonPrimitive.content }
    val read =
      requests("depthRelief").values.map { (StereoPhotoKind.parse(it) as StereoPhotoKind.DepthRelief).spec.cacheKey }
    // The request in 2.5D is the photo of the server again
    assertEquals(keys, read.distinct())
    assertEquals(3, read.size)
  }

  @Test
  fun `refuses every request the contract lists as unknown to version 1`() {
    for (request in contract.getValue("unknown").jsonArray) {
      assertNull("$request", StereoPhotoKind.parse(request.toString()))
    }
  }

  @Test
  fun `an Apple spatial pair is read as before`() {
    val sample =
      """{"kind":"heicStereoPair","version":1,"primaryItemId":37,"leftItemId":37,"rightItemId":74,""" +
        """"pitmIdOffset":129,"pitmIdBytes":2,"width":3072,"height":3072,"disparityAdjustment":-1000}"""

    val kind = StereoPhotoKind.parse(sample)

    assertEquals(StereoPhotoKind.HeicPair(StereoPairSpec.parse(sample)!!), kind)
    assertFalse(kind!!.isEstimatedRelief)
    assertFalse(kind.leftEyeIsOriginal)
  }

  @Test
  fun `a later origin or left eye is read as unknown, as the Dart side does`() {
    val ours = requests("sbsPhoto").getValue("ours")
    val kind =
      StereoPhotoKind.parse(ours.replace("estimatedDepth", "volumetric").replace("\"original\"", "\"generated\""))

    assertEquals(SbsPhotoSpec.Origin.UNKNOWN, (kind as StereoPhotoKind.Sbs).spec.origin)
    assertEquals(SbsPhotoSpec.LeftEye.UNKNOWN, kind.spec.leftEye)
    assertFalse(kind.isEstimatedRelief)
  }

  @Test
  fun `a damaged request is none`() {
    val ours = requests("sbsPhoto").getValue("ours")
    val relief = requests("depthRelief").getValue("a photo of the server")
    for (text in
      listOf(
        null,
        "",
        "not json",
        "[1]",
        """{"version":1}""",
        ours.replace("\"version\":1", "\"version\":\"1\""),
        ours.replace("\"layout\":\"leftRight\",", ""),
        ours.replace("\"eyes\":\"full\"", "\"eyes\":2"),
        relief.replace("99530468", "\"99530468\""),
        relief.replace("99530468", "0"),
        relief.replace("\"quarterTurns\":0", "\"quarterTurns\":0.5"),
        relief.replace("\"parallax\":0.02", "\"parallax\":\"0.02\""),
        // The key names a file of the cache: anything but 64 hexadecimal digits would leave its folder
        relief.replace("448add6b9d133349558e237bd153dccc15b85c23f75231323ec5be4f8ae8a79c", "../../files/x"),
      )) {
      assertNull("$text", StereoPhotoKind.parse(text))
    }
  }

  @Test
  fun `the contract file is the one of the Dart tests`() {
    // Both groups the viewer reads are there, so that an empty file cannot pass the tests above
    assertEquals(2, (contract.getValue("sbsPhoto").jsonArray).size)
    assertEquals(3, (contract.getValue("depthRelief").jsonArray).size)
    assertTrue(contract.getValue("unknown").jsonArray.all { it is JsonObject })
  }
}
