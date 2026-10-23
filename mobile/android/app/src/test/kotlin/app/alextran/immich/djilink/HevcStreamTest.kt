package app.alextran.immich.djilink

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Our own H.265 reader: start codes, the NAL header, emulation prevention, the SPS fields and the SEI headers */
class HevcStreamTest {
  @Test
  fun startCodesOfThreeAndFourBytesAreFound() {
    val bytes = byteArrayOf(0, 0, 0, 1, 0x46, 0x01, 0x30, 0, 0, 1, 0x02, 0x01, 0xAF.toByte(), 0x11)
    val nals = AnnexB.split(bytes)
    assertEquals(2, nals.size)
    assertEquals(4, nals[0].offset)
    assertEquals(7, nals[0].end)
    assertEquals(HevcNal.ACCESS_UNIT_DELIMITER, HevcNal.type(bytes[nals[0].offset].toInt()))
    assertEquals(1, HevcNal.type(bytes[nals[1].offset].toInt()))
  }

  @Test
  fun theZeroByteOfAFourByteStartCodeIsNotPartOfThePreviousUnit() {
    val bytes = HevcSamples.annexB(HevcSamples.DELIMITER, HevcSamples.slice(body = 3))
    val nals = AnnexB.split(bytes)
    assertEquals(3, nals[0].size)
  }

  @Test
  fun theTwoByteHeaderIsRead() {
    assertEquals(HevcNal.VPS, HevcNal.type(0x40))
    assertEquals(HevcNal.SPS, HevcNal.type(0x42))
    assertEquals(HevcNal.PPS, HevcNal.type(0x44))
    assertEquals(HevcNal.SUFFIX_SEI, HevcNal.type(0x50))
    assertEquals(20, HevcNal.type(0x28))
    assertTrue(HevcNal.isLayerZeroHeader(0x40, 0x01))
    assertFalse("forbidden bit", HevcNal.isLayerZeroHeader(0xC0, 0x01))
    assertFalse("layer id not zero", HevcNal.isLayerZeroHeader(0x41, 0x01))
    assertFalse("temporal id plus one of zero", HevcNal.isLayerZeroHeader(0x40, 0x00))
    assertTrue(HevcNal.isIntraRandomAccess(19))
    assertTrue(HevcNal.isIntraRandomAccess(21))
    assertFalse(HevcNal.isIntraRandomAccess(1))
  }

  @Test
  fun theFirstSliceFlagIsTheFirstBitAfterTheHeader() {
    val first = HevcSamples.slice(first = true)
    val other = HevcSamples.slice(first = false)
    assertTrue((first[2].toInt() and 0x80) != 0)
    assertFalse((other[2].toInt() and 0x80) != 0)
  }

  @Test
  fun emulationPreventionBytesAreRemoved() {
    val escaped = byteArrayOf(0x11, 0, 0, 3, 1, 0, 0, 3, 0, 0x22)
    assertArrayEquals(byteArrayOf(0x11, 0, 0, 1, 0, 0, 0, 0x22), AnnexB.unescape(escaped, 0, escaped.size))
  }

  @Test
  fun theSeedSpsGivesTheStreamOfTheCapture() {
    val sps = HevcSpsReader.parse(HevcSamples.SPS, 0, HevcSamples.SPS.size)
    assertNotNull(sps)
    sps!!
    assertEquals(1, sps.profileIdc)
    assertEquals("Main", sps.profileName)
    assertTrue(sps.highTier)
    assertEquals(150, sps.levelIdc)
    assertEquals("5.0", sps.levelName)
    assertEquals(1, sps.chromaFormatIdc)
    assertEquals(1920, sps.width)
    assertEquals(1080, sps.height)
    assertTrue(sps.conformanceWindowZero)
    assertEquals(8, sps.bitDepthLuma)
    assertEquals(8, sps.bitDepthChroma)
  }

  @Test
  fun aTruncatedSpsIsRefusedWithoutAnException() {
    for (cut in 2 until HevcSamples.SPS.size - 1) {
      // Every prefix too short to reach the bit depths is refused
      val parsed = HevcSpsReader.parse(HevcSamples.SPS.copyOf(cut), 0, cut)
      if (cut < 20) {
        assertNull("cut at $cut", parsed)
      }
    }
    assertNull(HevcSpsReader.parse(HevcSamples.VPS, 0, HevcSamples.VPS.size))
  }

  @Test
  fun anSeiPayloadTypeAbove255UsesTheExtensionByte() {
    val sei = byteArrayOf(0x50, 0x01, 0xFF.toByte(), 0x01, 0x02, 0x0A, 0x0B, 0x80.toByte())
    val messages = SeiReader.messages(sei, 0, sei.size)
    assertEquals(1, messages.size)
    assertEquals(256, messages[0].payloadType)
    assertEquals(2, messages[0].payloadSize)
    assertEquals(0x0A, messages[0].payloadByte(0))
  }

  @Test
  fun thePictureCounterIsReadFromTheSuffixSei() {
    val bytes = HevcSamples.picture(counter = 2247)
    assertEquals(2247, SeiPictureCounter.read(bytes, AnnexB.split(bytes)))
    val without = HevcSamples.annexB(HevcSamples.DELIMITER, HevcSamples.slice())
    assertNull(SeiPictureCounter.read(without, AnnexB.split(without)))
  }

  @Test
  fun aStreamDescriptionKeepsItsThreeSetsBehindStartCodes() {
    val description = ProfileRegistry.seed20261023!!
    val configuration = description.configuration()
    assertEquals("the 102 bytes of the capture, start codes included", 102, configuration.size)
    assertArrayEquals(HevcSamples.START, configuration.copyOf(4))
  }
}
