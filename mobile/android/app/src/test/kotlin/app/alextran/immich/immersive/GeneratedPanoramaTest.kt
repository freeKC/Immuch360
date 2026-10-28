package app.alextran.immich.immersive

import app.alextran.immich.relief.ReliefFixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the sphere of the immersive viewer reads at the head of a photo (design-final 2026-10-27, section 5, lot P4):
 * our packet of a panorama generated beyond the edges of a photo, or of its 3D version, read against the samples the
 * Dart side writes (mobile/test/fixtures/ai_immersive/xmp_v1_panorama_sample.xmp and
 * xmp_v1_stereo_panorama_sample.xmp); the yaw the sphere opens at, so that the photo is where the user looks; and the
 * passing text on every path of the sphere.
 */
class GeneratedPanoramaTest {
  private val panoramaPacket = ReliefFixtures.file("xmp_v1_panorama_sample.xmp").readText()
  private val stereoPacket = ReliefFixtures.file("xmp_v1_stereo_panorama_sample.xmp").readText()

  /** [packet] inside the head of a JPEG, after a little of its start, as the computers write it */
  private fun jpegHead(packet: String): ByteArray =
    byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE1.toByte(), 0x10, 0x00) +
      "http://ns.adobe.com/xap/1.0/\u0000".toByteArray(Charsets.ISO_8859_1) +
      packet.toByteArray(Charsets.UTF_8) +
      ByteArray(2048) { 0x55 }

  private fun withField(packet: String, field: String, value: String): String =
    packet.replace(Regex("Immuch360:$field=\"[^\"]*\""), "Immuch360:$field=\"$value\"")

  @Test
  fun `reads the panorama of the samples, generated, its photo and its flags`() {
    val head = GeneratedPanorama.readHead(jpegHead(panoramaPacket))!!

    assertEquals(1, head.formatVersion)
    assertEquals("Panorama360", head.kind)
    assertEquals("GeneratedContent", head.origin)
    assertTrue(head.isGenerated)
    assertFalse(head.isEstimatedRelief)
    assertEquals(PhotoRegion(yaw = 0.0, pitch = 0.0, hfov = 65.4, vfov = 50.6), head.region)
    assertEquals(listOf("fovGuessed"), head.flags)
  }

  @Test
  fun `reads the 3D version of the panorama, generated too, its photo copied from the panorama`() {
    val head = GeneratedPanorama.readHead(jpegHead(stereoPacket))!!

    assertEquals("StereoPanorama360", head.kind)
    assertTrue(head.isGenerated)
    assertFalse(head.isEstimatedRelief)
    assertEquals(PhotoRegion(yaw = 0.0, pitch = 0.0, hfov = 65.4, vfov = 50.6), head.region)
    assertEquals(emptyList<String>(), head.flags)
  }

  @Test
  fun `the 3D version of a 360 photo of the user is a relief estimated by AI, nothing generated`() {
    val packet =
      withField(stereoPacket, "Origin", "EstimatedDepth").replace(Regex("\\s*Immuch360:Relief=\"[^\"]*\""), "")
    val head = GeneratedPanorama.readHead(jpegHead(packet))!!

    assertFalse(head.isGenerated)
    assertTrue(head.isEstimatedRelief)
  }

  @Test
  fun `a photo without our packet, our packet of another kind, or another namespace say nothing`() {
    assertNull(GeneratedPanorama.readHead(ByteArray(4096) { 0x20 }))
    assertNull(GeneratedPanorama.readHead(jpegHead(withField(panoramaPacket, "Kind", "VolumetricScene"))))
    val otherNamespace = panoramaPacket.replace("http://ns.aprogsys.com/immuch360/1.0/", "http://example.com/other/")
    assertNull(GeneratedPanorama.readHead(jpegHead(otherNamespace)))
    // The scene sample is ours, of another kind
    val scene = ReliefFixtures.file("xmp_v1_scene_sample.xmp").readText()
    assertNull(GeneratedPanorama.readHead(jpegHead(scene)))
  }

  @Test
  fun `a packet past the head that is read is not seen`() {
    val far = ByteArray(GeneratedPanorama.HEAD_BYTES) { 0x20 } + panoramaPacket.toByteArray(Charsets.UTF_8)

    assertNull(GeneratedPanorama.readHead(far))
  }

  @Test
  fun `a newer packet still says generated, its photo is not used`() {
    val head = GeneratedPanorama.readHead(jpegHead(withField(panoramaPacket, "FormatVersion", "2")))!!

    assertTrue(head.isGenerated)
    assertEquals(2, head.formatVersion)
    assertNull(head.readableRegion)
    assertEquals(PhotoRegion(yaw = 0.0, pitch = 0.0, hfov = 65.4, vfov = 50.6), head.region)
  }

  @Test
  fun `a photo region that cannot be right is left out, the rest is read`() {
    for ((field, value) in listOf("PhotoHfov" to "0", "PhotoVfov" to "180", "PhotoPitch" to "95", "PhotoYaw" to "x")) {
      val head = GeneratedPanorama.readHead(jpegHead(withField(panoramaPacket, field, value)))!!
      assertTrue("$field=$value", head.isGenerated)
      assertNull("$field=$value", head.region)
    }
    // A yaw outside -180..180 is the same direction
    val turned = GeneratedPanorama.readHead(jpegHead(withField(panoramaPacket, "PhotoYaw", "270")))!!
    assertEquals(-90.0, turned.region!!.yaw, 1e-12)
  }

  @Test
  fun `the panorama the M3 measure wrote is read the same way, its values without decimals`() {
    // As finish.py of M3 wrote its ten panoramas (6144 x 3072), the GPano tags after ours
    val packet =
      """<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        |<rdf:Description rdf:about="" xmlns:GPano="http://ns.google.com/photos/1.0/panorama/"
        |    xmlns:Immuch360="http://ns.aprogsys.com/immuch360/1.0/"
        |    Immuch360:FormatVersion="1" Immuch360:Kind="Panorama360" Immuch360:Origin="GeneratedContent"
        |    Immuch360:Pipeline="pano-m3-base_q4_1536_s20" Immuch360:PhotoYaw="0" Immuch360:PhotoPitch="0"
        |    Immuch360:PhotoHfov="65.00" Immuch360:PhotoVfov="46.02" Immuch360:SourceCoverage="0.0440"
        |    GPano:ProjectionType="equirectangular" GPano:FullPanoWidthPixels="6144"/>
        |</rdf:RDF></x:xmpmeta>"""
        .trimMargin()
    val head = GeneratedPanorama.readHead(jpegHead(packet))!!

    assertTrue(head.isGenerated)
    assertEquals(PhotoRegion(yaw = 0.0, pitch = 0.0, hfov = 65.0, vfov = 46.02), head.region)
    assertEquals(emptyList<String>(), head.flags)
  }

  @Test
  fun `the sphere opens with the photo where the user looks`() {
    val photo = PhotoRegion(yaw = 0.0, pitch = 0.0, hfov = 65.4, vfov = 50.6)

    // Looking ahead (+z of the Spatial SDK): the sphere at its starting rotation, the centre column ahead
    assertEquals(0f, GeneratedPanorama.openingYaw(gazeYawDegrees = 0.0, region = photo, skyboxYawDegrees = 0f), 1e-6f)
    // Looking to the right (a positive yaw takes +z towards +x): the sphere turns as far, the photo comes along
    assertEquals(90f, GeneratedPanorama.openingYaw(90.0, photo, 0f), 1e-6f)
    assertEquals(-135f, GeneratedPanorama.openingYaw(-135.0, photo, 0f), 1e-6f)
    // A photo 40° right of the centre column of its panorama: the sphere turns 40° the other way to bring it ahead
    val right = photo.copy(yaw = 40.0)
    assertEquals(-40f, GeneratedPanorama.openingYaw(0.0, right, 0f), 1e-6f)
    assertEquals(20f, GeneratedPanorama.openingYaw(60.0, right, 0f), 1e-6f)
    // The starting rotation of every sphere (SKYBOX_YAW_DEGREES, checked in the headset by MQ) is kept under it
    assertEquals(-170f, GeneratedPanorama.openingYaw(150.0, right, 80f), 1e-6f)
  }

  @Test
  fun `where the photo lies in the world once the sphere opens is the gaze, whatever the gaze`() {
    val photo = PhotoRegion(yaw = -25.0, pitch = 10.0, hfov = 50.0, vfov = 40.0)
    for (gaze in listOf(-179.0, -90.0, -10.0, 0.0, 33.0, 90.0, 179.0)) {
      val sphereYaw = GeneratedPanorama.openingYaw(gaze, photo, 0f)
      // A point at longitude l of the panorama lies at the world yaw l + sphereYaw (the frame of PanoramaOutline)
      val world = GeneratedPanorama.normalizeDegrees(photo.yaw + sphereYaw)
      assertEquals("gaze $gaze", GeneratedPanorama.normalizeDegrees(gaze), world, 1e-4)
    }
  }

  @Test
  fun `the yaw of the gaze is 0 along +z of the Spatial SDK and positive towards +x`() {
    assertEquals(0.0, GeneratedPanorama.gazeYawDegrees(0.0, 1.0), 1e-12)
    assertEquals(90.0, GeneratedPanorama.gazeYawDegrees(1.0, 0.0), 1e-12)
    assertEquals(-90.0, GeneratedPanorama.gazeYawDegrees(-1.0, 0.0), 1e-12)
    assertEquals(180.0, kotlin.math.abs(GeneratedPanorama.gazeYawDegrees(0.0, -1.0)), 1e-12)
    // Looking straight up or down: no horizontal gaze, the starting rotation
    assertEquals(0.0, GeneratedPanorama.gazeYawDegrees(0.0, 0.0), 1e-12)
  }

  @Test
  fun `the text passes on every path of the sphere, whole, front half, top and bottom, side by side`() {
    val generated = GeneratedPanorama.readHead(jpegHead(panoramaPacket))
    val labels = mapOf(GeneratedPanorama.LABEL_NOTICE to "Généré par IA au delà des bords de la photo")
    for (layout in ImmersiveStereoLayout.values()) {
      for (coverage in ImmersiveSphereCoverage.values()) {
        assertEquals(
          "$layout $coverage",
          "Généré par IA au delà des bords de la photo",
          GeneratedPanorama.noticeOnSphere(generated, labels, layout, coverage),
        )
        assertEquals(
          "$layout $coverage, English without a label",
          "Generated by AI beyond the photo's edges",
          GeneratedPanorama.noticeOnSphere(generated, emptyMap(), layout, coverage),
        )
        assertNull("$layout $coverage", GeneratedPanorama.noticeOnSphere(null, labels, layout, coverage))
      }
    }
  }

  @Test
  fun `the 3D version of a 360 photo says its relief was estimated, an ordinary 360 photo says nothing`() {
    val packet =
      withField(stereoPacket, "Origin", "EstimatedDepth").replace(Regex("\\s*Immuch360:Relief=\"[^\"]*\""), "")
    val estimated = GeneratedPanorama.readHead(jpegHead(packet))

    assertEquals(
      "Relief estimated by AI",
      GeneratedPanorama.noticeOnSphere(
        estimated,
        emptyMap(),
        ImmersiveStereoLayout.TOP_BOTTOM,
        ImmersiveSphereCoverage.FULL,
      ),
    )
    // Another kind of ours on a sphere (a 3D photo viewed as 360°) makes no such claim here
    val sbs = ReliefFixtures.file("xmp_v1_sample.xmp").readText()
    assertNull(
      GeneratedPanorama.noticeOnSphere(
        GeneratedPanorama.readHead(jpegHead(sbs)),
        emptyMap(),
        ImmersiveStereoLayout.MONO,
        ImmersiveSphereCoverage.FULL,
      )
    )
  }

  @Test
  fun `the panel keeps the sentence, then the flags of the file it knows`() {
    val labels =
      mapOf(
        GeneratedPanorama.LABEL_NOTICE to "Generated (fr)",
        GeneratedPanorama.LABEL_FLAG_PREFIX + "seam" to "Raccord visible",
      )
    val flags = withField(panoramaPacket, "QualityFlags", "seam,mostlyInvented,later")
    val seam = GeneratedPanorama.readHead(jpegHead(flags))

    assertEquals(
      listOf("Generated (fr)", "Raccord visible", "Most of this panorama is invented"),
      GeneratedPanorama.detailLines(seam, labels),
    )
    assertEquals(
      listOf("Generated by AI beyond the photo's edges", "Field of view guessed: shapes may be off"),
      GeneratedPanorama.detailLines(GeneratedPanorama.readHead(jpegHead(panoramaPacket)), emptyMap()),
    )
    assertEquals(emptyList<String>(), GeneratedPanorama.detailLines(null, labels))
  }
}
