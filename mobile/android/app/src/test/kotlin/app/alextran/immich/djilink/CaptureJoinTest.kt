package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A mid stream join on the capture of 23 October 2026: the replay starts two seconds after the only key picture, so the
 * stream never gives its own description. The store must fall back on the seed of the profile once the stream shows
 * the H.265 signature, and the assembler must hand over every picture from the first delimiter on. Skipped when the
 * capture is absent, as [CaptureVideoReplayTest].
 */
class CaptureJoinTest {
  private class RecordingSink : DecoderSink {
    val units = mutableListOf<Pair<AccessUnit, ResolvedDescription>>()

    override fun submit(unit: AccessUnit, description: ResolvedDescription) {
      units.add(unit to description)
    }

    override fun reset() = Unit

    override fun status(): DecoderStatus = DecoderStatus()
  }

  @Test
  fun aJoinTwoSecondsAfterTheKeyPictureFallsBackOnTheSeed() {
    val (bytes, index) = CaptureVideoReplayTest.load()
    // Where the key picture is, from a first replay of the whole ring
    var keyNs = 0L
    var lastCounter = 0
    CaptureReplay.replay(bytes, index, onVideoUnit = { unit, _, _, nowNs ->
      if (unit.isKey) {
        keyNs = nowNs
      }
      unit.pictureCounter?.let { lastCounter = it }
    })
    assertTrue(keyNs > 0)

    val joinAt = keyNs + 2_000_000_000L
    val joined = index.filter { it.direction != CaptureDirection.IN || it.monotonicNs >= joinAt }
    val store = ParameterSetStore(MemoryKeyValueStore()).apply { seed = ProfileRegistry.seed20261023 }
    val sink = RecordingSink()
    val pipeline = VideoPipeline(store, sink)
    val counters = mutableListOf<Int>()
    val opening = mutableListOf<Boolean>()
    val result = CaptureReplay.replay(bytes, joined, onVideoUnit = { unit, detector, fresh, nowNs ->
      unit.pictureCounter?.let { counters.add(it) }
      opening.add(unit.startsWithDelimiter)
      pipeline.onUnit(unit, detector, fresh, nowNs)
    })
    // The units before thirty in a row open with the delimiter have no description to be decoded with. The first
    // unit of the join can open with its slice: its delimiter came at the end of the read before the join point.
    var run = 0
    val signatureAt = opening.indexOfFirst { opens ->
      run = if (opens) run + 1 else 0
      run >= CodecDetector.SIGNATURE_UNITS
    }

    // No description in the stream after the key picture: the seed, once thirty pictures showed the signature
    val stats = pipeline.stats(index.last().monotonicNs, result.assembler.unitsTooLarge)
    assertEquals(VideoCodec.H265, stats.codec)
    assertEquals(CodecEvidence.DELIMITER_SIGNATURE, stats.codecEvidence)
    assertEquals(DescriptionSource.PROFILE, stats.descriptionSource)
    assertTrue(signatureAt >= CodecDetector.SIGNATURE_UNITS - 1)
    assertEquals(signatureAt.toLong(), stats.unitsWithoutDescription)
    assertTrue(sink.units.all { it.second.source == DescriptionSource.PROFILE })
    assertEquals(stats.unitsIn - stats.unitsWithoutDescription, sink.units.size.toLong())

    // Every picture from the first delimiter on, none lost, up to the last one of the ring
    assertTrue(counters.isNotEmpty())
    assertTrue(counters.zipWithNext().all { (a, b) -> b == a + 1 })
    assertEquals(lastCounter, counters.last())
    assertEquals(counters.size.toLong(), stats.unitsIn)
    assertTrue(sink.units.all { it.first.startsWithDelimiter && !it.first.isKey })
    assertTrue(opening.drop(1).all { it })
    // Less than one picture is dropped before the first delimiter
    assertTrue(result.assembler.bytesBeforeFirstUnit < 40_000)
  }
}
