package app.alextran.immich.core.raw

import app.alextran.immich.core.DualFisheyeCalibration
import app.alextran.immich.core.raw.RawFixtures.view
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** The rawProjection v2 contract (section 3 of the projections design), its validation and the v1 conversion. */
class RawProjectionTest {
  @Test
  fun `example A is a side by side Mei pair in one track`() {
    val a = RawProjection.parse(RawFixtures.A)
    assertEquals(2, a.version)
    assertEquals(RawKind.DUAL_FISHEYE, a.kind)
    assertEquals(RawLayout.SIDE_BY_SIDE, a.layout)
    assertEquals(LensModel.MEI, a.model)
    assertEquals("Insta360 X3", a.camera)
    assertEquals(3840, a.frameWidth)
    assertEquals(1920, a.frameHeight)
    assertEquals(1, a.tracks.size)
    assertEquals(1, a.tracks[0].trackId)
    assertEquals("hvc1.1.6.L153", a.tracks[0].codecs)
    assertEquals(5952.0, a.canvasSquare, 0.0)
    assertEquals(listOf(0.0, 0.0, 0.5, 1.0), a.lenses[0].region.toList())
    assertEquals(listOf(0.5, 0.0, 0.5, 1.0), a.lenses[1].region.toList())
    assertEquals(8933.2, a.lenses[1].cx, 0.0)
    assertEquals(-3.96876335, a.lenses[0].k[2], 0.0)
    assertEquals(-0.00158561, a.lenses[0].p2, 0.0)
    assertEquals(-0.992573, a.lenses[0].viewToLens[8], 0.0)
    assertTrue(!a.isLensLayout)
    assertEquals(1, a.streamCount)
  }

  @Test
  fun `example B puts lens 1 in track 0 and keeps the forward lens as primary stream`() {
    val b = RawProjection.parse(RawFixtures.B)
    assertEquals(RawLayout.TWO_TRACKS, b.layout)
    assertEquals(listOf(1, 2), b.tracks.map { it.trackId })
    assertEquals(listOf(1, 0), b.lenses.map { it.texture })
    assertEquals(listOf(1, 0), b.trackOrder)
    assertEquals(5376.0, b.canvasSquare, 0.0)
    // Lens 1 looks forward (viewToLens is the identity): its texture, track 0, is the one kept for one lens
    assertEquals(0, b.primaryStream())
    assertTrue(b.isLensLayout)
  }

  @Test
  fun `example C is a split pair whose lens 0 is in the second file`() {
    val c = RawProjection.parse(RawFixtures.C)
    assertEquals(RawLayout.TWO_FILES, c.layout)
    assertEquals(listOf(0, 1), c.tracks.map { it.file })
    assertEquals(RawFixtures.C_SECOND_URL, c.secondUrl)
    assertNull(c.secondFallbackUrl)
    assertEquals(listOf(1, 0), c.lenses.map { it.texture })
    // Lens 1 (Studio's forward) is in texture 0, the file that was opened
    assertEquals(0, c.primaryStream())
    assertEquals(1, c.fileOfStream(1))
  }

  @Test
  fun `example D is a Kannala-Brandt pair with five terms and the DJI limits`() {
    val d = RawProjection.parse(RawFixtures.D)
    assertEquals(LensModel.KANNALA_BRANDT, d.model)
    assertEquals(94.0, d.maxThetaDegrees, 0.0)
    assertEquals(87.0, d.blendStartDegrees, 0.0)
    assertEquals(93.0, d.blendEndDegrees, 0.0)
    assertEquals(0.00104408, d.lenses[0].k[4], 0.0)
    assertEquals(-0.00639127, d.lenses[1].k[3], 0.0)
    assertEquals(10, d.tracks[0].bitDepth)
    // The front lens (stream 1) is the one the view opens on
    assertEquals(1, d.primaryStream())
  }

  @Test
  fun `example E and the MAX are EAC pairs with their geometry`() {
    val e = RawProjection.parse(RawFixtures.E)
    assertEquals(RawKind.EAC_GOPRO, e.kind)
    val geometry = e.eac!!
    assertEquals(1920, geometry.face)
    assertEquals(96, geometry.overlap)
    assertEquals(1008, geometry.half)
    assertEquals(2016, geometry.middle)
    assertEquals(3936, geometry.right)
    assertEquals(5952, geometry.trackWidth)
    assertEquals(6, geometry.faces.size)
    assertEquals(listOf(1, 6), e.tracks.map { it.trackId })
    assertEquals(0, e.primaryStream())
    val max = RawProjection.parse(RawFixtures.MAX)
    assertEquals(32, max.eac!!.overlap)
    assertEquals(4096, max.eac!!.trackWidth)
    // The MAX's quarter turn is a reflection of the table frame: accepted
    assertEquals(-1.0, RawProjection.determinant(max.eac!!.viewToCamera), 1e-12)
    assertEquals(0, max.primaryStream())
    // The MAX 2 at 8 bit: 5888 wide, overlap 64
    assertEquals(64, RawProjection.parse(RawFixtures.MAX2_8BIT).eac!!.overlap)
  }

  @Test
  fun `defaults apply to absent limits and radius angle`() {
    val noLimits =
      RawFixtures.B.replace("\"maxTheta\":100.0,\"blendStart\":85.0,\"blendEnd\":95.0,", "")
    val b = RawProjection.parse(noLimits)
    assertEquals(RawProjection.DEFAULT_MAX_THETA, b.maxThetaDegrees, 0.0)
    assertEquals(RawProjection.DEFAULT_BLEND_START, b.blendStartDegrees, 0.0)
    assertEquals(RawProjection.DEFAULT_BLEND_END, b.blendEndDegrees, 0.0)
    val equidistant =
      RawFixtures.B.replace("\"model\":\"mei\"", "\"model\":\"equidistant\"")
        .replace("\"fx\":4180.0,\"fy\":4180.0,", "\"radius\":2600.0,")
    val parsed = RawProjection.parse(equidistant)
    assertEquals(LensModel.EQUIDISTANT, parsed.model)
    assertEquals(100.0, parsed.lenses[0].radiusTheta, 0.0)
  }

  @Test
  fun `unknown keys are ignored`() {
    val extra =
      RawFixtures.D.replace("{\"version\":2,", "{\"version\":2,\"serial\":\"95SXN6500213WL\",\"future\":[1,2],")
    assertEquals(RawProjection.parse(RawFixtures.D).summary(), RawProjection.parse(extra).summary())
  }

  @Test
  fun `every rule of section 3 point 4 refuses the JSON`() {
    val b = RawFixtures.B
    val identity = "[1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0]"
    val secondTrack =
      """,
           {"file":0,"videoTrack":1,"trackId":2,"width":3840,"height":3840,"codec":"hvc1","codecs":"hvc1.1.6.L183",""" +
        """"bitDepth":8}"""
    val lens1 = RawFixtures.A.indexOf(",\n  {\"texture\":0,\"region\":[0.5")
    val eacTrack1 = "\"width\":5952,\"height\":1920,\"codec\":\"hvc1\",\"codecs\":\"hvc1.2.4.L153\",\"bitDepth\":10}]"
    val lastFace = ",\n  {\"texture\":1,\"slot\":2,\"forward\":[0,1,0],\"right\":[0,0,1],\"down\":[-1,0,0]}"
    val refused =
      mapOf(
        "not json" to "not json",
        "array" to "[]",
        "version 3" to b.replace("\"version\":2", "\"version\":3"),
        "unknown kind" to b.replace("dualFisheye", "cubemap"),
        "unknown layout" to b.replace("twoTracks", "threeTracks"),
        "one track for twoTracks" to b.replace(secondTrack, ""),
        "file 2" to RawFixtures.C.replace("{\"file\":1,", "{\"file\":2,"),
        "second file without secondUrl" to
          RawFixtures.C.replace("\"secondUrl\":\"${RawFixtures.C_SECOND_URL}\"", "\"secondUrl\":null"),
        "twoFiles in one file" to RawFixtures.C.replace("{\"file\":1,", "{\"file\":0,"),
        "same track IDs" to b.replace("\"trackId\":2", "\"trackId\":1"),
        "no track ID" to b.replace("\"trackId\":2", "\"trackId\":null"),
        "eacGoPro side by side" to RawFixtures.E.replace("twoTracks", "sideBySide"),
        "one lens" to RawFixtures.A.replace(RawFixtures.A.substring(lens1, RawFixtures.A.lastIndexOf("]}")), ""),
        "texture out of range" to
          RawFixtures.A.replace("\"texture\":0,\"region\":[0.5", "\"texture\":1,\"region\":[0.5"),
        "region outside" to RawFixtures.A.replace("[0.5,0.0,0.5,1.0]", "[0.6,0.0,0.5,1.0]"),
        "no canvas square" to RawFixtures.A.replace("\"canvasSquare\":5952.0", "\"canvasSquare\":0"),
        "Mei without fx" to b.replace("\"fx\":4180.0,\"fy\":4180.0,\"xi\":1.95", "\"xi\":1.95"),
        "Mei with xi < 0" to b.replace("\"xi\":1.95", "\"xi\":-0.1"),
        "Kannala-Brandt without fy" to RawFixtures.D.replace("\"fy\":1046.16796875,", ""),
        "equidistant without radius" to b.replace("\"model\":\"mei\"", "\"model\":\"equidistant\""),
        "viewToLens of 8 numbers" to b.replace(identity, "[1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0]"),
        "viewToLens a mirror" to b.replace(identity, "[-1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0]"),
        "viewToLens scaled" to b.replace(identity, "[1.1,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0]"),
        "blend start after end" to b.replace("\"blendStart\":85.0", "\"blendStart\":96.0"),
        "blend end after max" to b.replace("\"blendEnd\":95.0", "\"blendEnd\":101.0"),
        "max above 180" to b.replace("\"maxTheta\":100.0", "\"maxTheta\":181.0"),
        "blend start 0" to b.replace("\"blendStart\":85.0", "\"blendStart\":0.0"),
        "EAC face 0" to RawFixtures.E.replace("\"face\":1920", "\"face\":0"),
        "EAC middle" to RawFixtures.E.replace("\"middle\":2016", "\"middle\":2000"),
        "EAC right" to RawFixtures.E.replace("\"right\":3936", "\"right\":3900"),
        "EAC track width" to RawFixtures.E.replace(eacTrack1, eacTrack1.replace("5952", "5888")),
        "EAC five faces" to RawFixtures.E.replace(lastFace, ""),
        "EAC slot twice" to RawFixtures.E.replace("{\"texture\":1,\"slot\":2", "{\"texture\":1,\"slot\":1"),
        "EAC face not orthonormal" to
          RawFixtures.E.replace("\"forward\":[0,0,1],\"right\":[1,0,0]", "\"forward\":[0,0,1],\"right\":[1,0,1]"),
        "no frame size" to b.replace("\"frameWidth\":7680,", ""),
      )
    for ((name, json) in refused) {
      if (json == RawFixtures.A || json == RawFixtures.B || json == RawFixtures.C || json == RawFixtures.D ||
        json == RawFixtures.E
      ) {
        throw AssertionError("the case '$name' did not change the fixture")
      }
      assertThrows(name, IllegalArgumentException::class.java) { RawProjection.parse(json) }
    }
  }

  @Test
  fun `a version 1 JSON becomes side by side with the build 17 rotations`() {
    val v1 = RawProjection.parse(RawFixtures.X3_V1)
    val calibration = DualFisheyeCalibration.parse(RawFixtures.X3_V1)
    assertEquals(1, v1.version)
    assertEquals(RawLayout.SIDE_BY_SIDE, v1.layout)
    assertEquals(LensModel.MEI, v1.model)
    assertEquals(5760, v1.frameWidth)
    assertEquals(5952.0, v1.canvasSquare, 0.0)
    assertEquals(listOf(0.0, 0.0, 0.5, 1.0), v1.lenses[0].region.toList())
    assertEquals(listOf(0.5, 0.0, 0.5, 1.0), v1.lenses[1].region.toList())
    for (lens in 0..1) {
      val expected = calibration.viewToLens(lens)
      for (i in 0 until 9) {
        assertEquals("viewToLens $lens[$i]", expected[i].toDouble(), v1.lenses[lens].viewToLens[i], 1e-6)
      }
    }
  }

  @Test
  fun `a version 1 JSON draws the same frame pixels as build 17`() {
    val v1 = RawProjection.parse(RawFixtures.X3_V1)
    val calibration = DualFisheyeCalibration.parse(RawFixtures.X3_V1)
    var compared = 0
    for (lon in -180 until 180 step 15) {
      for (lat in -75..75 step 15) {
        val direction = view(lon.toDouble(), lat.toDouble())
        for (lens in 0..1) {
          val sample = v1.lensSample(lens, direction) ?: continue
          val expected = calibration.canvasPixel(lens, direction)
          assertEquals("x of lens $lens at $lon, $lat", expected.x, sample.canvasX, 0.01)
          assertEquals("y of lens $lens at $lon, $lat", expected.y, sample.canvasY, 0.01)
          // Build 17 sampled the frame at canvas * (W / 2 / S, H / S): the same fraction of the frame
          assertEquals(expected.x / 2 / 5952.0, sample.textureX, 1e-6)
          assertEquals(expected.y / 5952.0, sample.textureY, 1e-6)
          compared++
        }
      }
    }
    assertTrue("compared $compared directions", compared > 200)
  }

  @Test
  fun `a version 1 JSON that build 17 refused is refused`() {
    assertThrows(IllegalArgumentException::class.java) {
      RawProjection.parse(RawFixtures.X3_V1.replace("\"mei\"", "\"kannalaBrandt\""))
    }
  }

  @Test
  fun `the summary names the layout and the tracks without a URL`() {
    val summary = RawProjection.parse(RawFixtures.C).summary()
    assertTrue(summary, summary.contains("twoFiles") && summary.contains("2880x2880"))
    assertTrue(summary, !summary.contains("http"))
  }
}
