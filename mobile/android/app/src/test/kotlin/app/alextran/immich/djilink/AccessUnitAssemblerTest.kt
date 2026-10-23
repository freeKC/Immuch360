package app.alextran.immich.djilink

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Access units at the NAL level, with the fragmentation the RC-N3 shows on 23 October 2026 */
class AccessUnitAssemblerTest {
  private val assembler = AccessUnitAssembler()
  private var clock = 0L

  private fun offer(bytes: ByteArray): List<AccessUnit> {
    clock += 1_000_000
    return assembler.offer(bytes, clock)
  }

  /** Cuts [bytes] into fragments of [size] bytes, the last one shorter, as the remote does */
  private fun fragments(bytes: ByteArray, size: Int): List<ByteArray> =
    (bytes.indices step size).map { bytes.copyOfRange(it, minOf(bytes.size, it + size)) }

  @Test
  fun theTrailingDelimiterClosesAPictureAtOnceAndOpensTheNextUnit() {
    // Picture 1 in two fragments, the second ending with the delimiter of picture 2, as on the wire
    val first = HevcSamples.annexB(HevcSamples.DELIMITER, HevcSamples.slice(body = 90))
    val second = HevcSamples.annexB(HevcSamples.suffixSei(7), HevcSamples.DELIMITER)
    assertTrue(offer(first).isEmpty())
    val units = offer(second)
    assertEquals(1, units.size)
    val unit = units[0]
    assertEquals(listOf(35, 1, 40), unit.nalTypes.toList())
    assertTrue(unit.startsWithDelimiter)
    assertEquals(AccessUnitClose.BOUNDARY, unit.closedBy)
    assertEquals(7, unit.pictureCounter)
    // The delimiter of picture 2 opens the next unit
    val third = HevcSamples.annexB(HevcSamples.slice(body = 20), HevcSamples.suffixSei(8), HevcSamples.DELIMITER)
    val next = offer(third)
    assertEquals(1, next.size)
    assertEquals(listOf(35, 1, 40), next[0].nalTypes.toList())
    assertEquals(8, next[0].pictureCounter)
    assertEquals(0L, assembler.counters.bytesBeforeFirstUnit)
  }

  @Test
  fun aSuffixSeiThatOpensAFragmentStaysWithItsPicture() {
    // The slice filled whole fragments, so the suffix SEI of the same picture opens the next fragment with a start code
    offer(HevcSamples.annexB(HevcSamples.DELIMITER, HevcSamples.slice(body = 200)))
    val units = offer(HevcSamples.annexB(HevcSamples.suffixSei(3), HevcSamples.suffixSei(3), HevcSamples.DELIMITER))
    assertEquals(1, units.size)
    assertEquals(listOf(35, 1, 40, 40), units[0].nalTypes.toList())
  }

  @Test
  fun theParameterSetsJoinTheKeyPicture() {
    offer(HevcSamples.picture(counter = 1) + HevcSamples.annexB(HevcSamples.DELIMITER))
    // The parameter sets come in an envelope of their own, then the key picture in the next ones
    assertTrue(offer(HevcSamples.annexB(HevcSamples.VPS, HevcSamples.SPS, HevcSamples.PPS)).isEmpty())
    val units = offer(HevcSamples.annexB(HevcSamples.slice(type = 20, body = 60), HevcSamples.suffixSei(1), HevcSamples.DELIMITER))
    val key = units.last()
    assertEquals(listOf(35, 32, 33, 34, 20, 40), key.nalTypes.toList())
    assertTrue(key.isKey)
    assertTrue(key.hasParameterSets)
  }

  @Test
  fun bytesBeforeTheFirstBoundaryAreDroppedAndCounted() {
    // The stream is joined in the middle of a picture: the end of a slice, then the next picture's delimiter
    val middle = ByteArray(30) { 0x33 }
    assertTrue(offer(middle).isEmpty())
    assertTrue(offer(HevcSamples.annexB(HevcSamples.DELIMITER, HevcSamples.slice())).isEmpty())
    val units = offer(HevcSamples.annexB(HevcSamples.suffixSei(4), HevcSamples.DELIMITER))
    assertEquals(1, units.size)
    assertTrue(units[0].startsWithDelimiter)
    // Every byte of the middle of the picture is dropped but the two that could still begin a start code
    assertTrue(assembler.counters.bytesBeforeFirstUnit >= 28)
  }

  @Test
  fun withoutADelimiterAShortFragmentClosesTheUnit() {
    // A product that sends no delimiter: a picture is full fragments then a shorter one
    val picture = HevcSamples.annexB(HevcSamples.slice(body = 450), HevcSamples.suffixSei(1))
    val parts = fragments(picture, 200)
    var units = emptyList<AccessUnit>()
    for (part in parts) {
      units = units + offer(part)
    }
    assertEquals(1, units.size)
    assertEquals(AccessUnitClose.SHORT_FRAGMENT, units[0].closedBy)
    assertArrayEquals(picture, units[0].bytes)
    assertEquals(1L, assembler.counters.closedByShortFragment)
  }

  @Test
  fun aUnitAboveTheBoundIsDroppedAndTheNextBoundaryStartsAgain() {
    val small = AccessUnitAssembler(maxUnitBytes = 1000)
    var units = small.offer(HevcSamples.annexB(HevcSamples.DELIMITER, HevcSamples.slice(body = 300)), 1)
    // Fragments no shorter than the largest seen, so that the short fragment fallback stays out of it
    repeat(4) { units = units + small.offer(ByteArray(400) { 0x44 }, 2) }
    assertTrue(units.isEmpty())
    assertEquals(1L, small.counters.unitsTooLarge)
    units = small.offer(HevcSamples.picture(counter = 9) + HevcSamples.annexB(HevcSamples.DELIMITER), 3)
    assertEquals(1, units.size)
    assertEquals(9, units[0].pictureCounter)
  }

  @Test
  fun aResetClearsTheUnitUnderWayOnANewStreamOrAGap() {
    offer(HevcSamples.annexB(HevcSamples.DELIMITER, HevcSamples.slice(body = 100)))
    assembler.reset()
    assertTrue(assembler.counters.bytesDroppedAtReset > 0)
    val units = offer(HevcSamples.picture(counter = 2, body = 10) + HevcSamples.annexB(HevcSamples.DELIMITER))
    assertEquals(1, units.size)
    assertEquals(2, units[0].pictureCounter)
    // Nothing of the stream before the reset is glued to the unit after it
    assertTrue(units[0].size < 40)
  }

  @Test
  fun aStartCodeSplitAcrossTwoFragmentsIsFound() {
    val picture = HevcSamples.picture(counter = 5)
    val trailing = HevcSamples.annexB(HevcSamples.DELIMITER)
    val all = picture + trailing
    // Cut inside the start code of the trailing delimiter
    val cut = picture.size + 2
    assertTrue(offer(all.copyOf(cut)).isEmpty())
    val units = offer(all.copyOfRange(cut, all.size))
    assertEquals(1, units.size)
    assertArrayEquals(picture, units[0].bytes)
  }

  @Test
  fun everyUnitCarriesItsArrivalTimes() {
    val first = HevcSamples.annexB(HevcSamples.DELIMITER, HevcSamples.slice(body = 90))
    offer(first)
    val firstFragmentNs = clock
    offer(ByteArray(first.size) { 0x22 })
    val units = offer(HevcSamples.annexB(HevcSamples.suffixSei(1), HevcSamples.DELIMITER))
    assertEquals(firstFragmentNs, units[0].firstArrivalNs)
    assertEquals(clock, units[0].lastArrivalNs)
  }
}
