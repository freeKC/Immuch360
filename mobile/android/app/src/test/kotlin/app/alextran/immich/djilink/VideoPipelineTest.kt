package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The glue between the router and the decoder, with a sink of the test's own */
class VideoPipelineTest {
  private class RecordingSink : DecoderSink {
    val units = mutableListOf<Pair<AccessUnit, ResolvedDescription>>()
    val kept = mutableListOf<Pair<AccessUnit, ResolvedDescription>>()
    var resets = 0
    var status = DecoderStatus()

    override fun submit(unit: AccessUnit, description: ResolvedDescription) {
      units.add(unit to description)
    }

    override fun keepKey(unit: AccessUnit, description: ResolvedDescription) {
      kept.add(unit to description)
    }

    override fun reset() {
      resets += 1
    }

    override fun status(): DecoderStatus = status
  }

  private val preferences = MemoryKeyValueStore()
  private val store = ParameterSetStore(preferences).apply { seed = ProfileRegistry.seed20261023 }
  private val sink = RecordingSink()
  private val pipeline = VideoPipeline(store, sink)
  private val detector = CodecDetector()
  private var clock = 0L

  private fun feed(unit: AccessUnit) {
    clock += 33_000_000
    pipeline.onUnit(unit, detector, detector.offer(unit), clock)
  }

  @Test
  fun aKeyUnitKeptByThePhoneGoesToTheSinkToKeepAndCountsNowhere() {
    val key = HevcSamples.unitOf(
      HevcSamples.DELIMITER,
      HevcSamples.VPS,
      HevcSamples.SPS,
      HevcSamples.PPS,
      HevcSamples.slice(type = 20),
      HevcSamples.suffixSei(7),
    )
    // As on the headset: the phone's parameter sets settle the codec and the description first
    val sets = ProfileRegistry.seed20261023!!
    detector.offer(RelayWire.annexBUnit(sets.configuration(), clock))
    store.onRelayedDescription(sets, DescriptionSource.SESSION)
    pipeline.onPrimer(key, detector)
    assertTrue(sink.kept.single().first === key)
    assertEquals(DescriptionSource.SESSION, sink.kept.single().second.source)
    assertTrue(sink.units.isEmpty())
    val stats = pipeline.stats(clock, 0)
    assertEquals(0L, stats.unitsIn)
    assertEquals(0L, stats.keyPictures)
    assertEquals(0L, stats.pictureCounters)
    // A unit that is not a key picture is never kept
    val p = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(8))
    pipeline.onPrimer(p, detector)
    assertEquals(1, sink.kept.size)
  }

  @Test
  fun nothingIsDecodedBeforeAStreamDescriptionCanBeHad() {
    feed(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(1)))
    assertTrue(sink.units.isEmpty())
    val stats = pipeline.stats(clock, 0)
    assertEquals(VideoState.WAITING_FOR_DESCRIPTION, stats.state)
    assertEquals(1L, stats.unitsWithoutDescription)
    assertEquals(1L, stats.unitsIn)
  }

  @Test
  fun theSeedIsUsedOnceTheStreamShowsTheH265Signature() {
    repeat(CodecDetector.SIGNATURE_UNITS) {
      feed(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(it + 1)))
    }
    assertEquals(1, sink.units.size)
    assertEquals(DescriptionSource.PROFILE, sink.units.single().second.source)
    assertEquals(DescriptionSource.PROFILE, pipeline.stats(clock, 0).descriptionSource)
    assertEquals(VideoCodec.H265, pipeline.stats(clock, 0).codec)
  }

  @Test
  fun theStreamsOwnDescriptionWinsAndIsCachedForTheRemote() {
    store.useAccessory(AccessoryStrings("DJI", "m", "d", "v"))
    feed(
      HevcSamples.unitOf(
        HevcSamples.DELIMITER,
        HevcSamples.VPS,
        HevcSamples.SPS,
        HevcSamples.PPS,
        HevcSamples.slice(type = 20),
        HevcSamples.suffixSei(1),
      )
    )
    assertEquals(DescriptionSource.SESSION, sink.units.single().second.source)
    // The description, and the key unit with its sets
    assertEquals(2, preferences.size)
    val stats = pipeline.stats(clock, 0)
    assertEquals(1920, stats.width)
    assertEquals("5.0", stats.levelName)
    assertEquals(1L, stats.keyPictures)
  }

  @Test
  fun aLaterSessionJoinedMidStreamOffersTheKeyUnitOfTheRemoteOnce() {
    val remote = AccessoryStrings("DJI", "m", "d", "v")
    store.useAccessory(remote)
    val key = HevcSamples.unitOf(
      HevcSamples.DELIMITER,
      HevcSamples.VPS,
      HevcSamples.SPS,
      HevcSamples.PPS,
      HevcSamples.slice(type = 20),
      HevcSamples.suffixSei(1),
    )
    feed(key)
    feed(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(2)))
    // This session had its own key picture: nothing kept from earlier is offered
    assertTrue(sink.kept.isEmpty())
    // The next session opens while the remote streams: P pictures and the cached description only
    pipeline.newSource()
    store.useAccessory(remote)
    repeat(3) { feed(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(10 + it))) }
    assertEquals(3, sink.units.count { it.second.source == DescriptionSource.CACHE })
    val offered = sink.kept.single()
    assertTrue(offered.first.isKey)
    assertTrue(offered.first.bytes.contentEquals(key.bytes))
    // A replay keeps nothing and is offered nothing
    pipeline.newSource()
    store.useAccessory(null)
    repeat(40) { feed(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(20 + it))) }
    assertEquals(1, sink.kept.size)
  }

  @Test
  fun h264IsCountedAndNotDecoded() {
    val sps = byteArrayOf(0x67, 0x42, 0xC0.toByte(), 0x1E, 0x80.toByte())
    val pps = byteArrayOf(0x68, 0xCE.toByte(), 0x3C, 0x80.toByte())
    feed(HevcSamples.unitOf(sps, pps, byteArrayOf(0x65, 0x11, 0x22)))
    feed(HevcSamples.unitOf(byteArrayOf(0x41, 0x11, 0x22)))
    assertTrue(sink.units.isEmpty())
    assertEquals(VideoState.H264_NOT_DECODED, pipeline.stats(clock, 0).state)
  }

  @Test
  fun lostPicturesAndRestartsComeFromTheSeiCounter() {
    store.useAccessory(null)
    for (counter in listOf(10, 11, 14, 1, 2)) {
      feed(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(counter)))
    }
    val stats = pipeline.stats(clock, 0)
    assertEquals(2L, stats.lostPictures)
    assertEquals(1L, stats.encoderRestarts)
    assertEquals(5L, stats.pictureCounters)
  }

  /**
   * stage2b-review.md, finding 4: a headset that got the units the phone dropped for it (a gap of up to 300 pictures)
   * or a new loop of a played capture is told by BREAK; neither is a loss on the radio nor an encoder restart, and the
   * relayed description stays for the units that follow.
   */
  @Test
  fun aBreakOfTheRelayIsNeitherALossNorARestartAndKeepsTheDescription() {
    store.useAccessory(null)
    store.seed = null
    store.onRelayedDescription(ProfileRegistry.seed20261023!!, DescriptionSource.CACHE)
    fun unit(counter: Int) =
      HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(counter))
    feed(unit(10))
    feed(unit(11))
    // 288 units dropped on the phone for this headset
    pipeline.relayBreak()
    feed(unit(300))
    feed(unit(301))
    // A loop of Play in a loop: the counter goes back
    pipeline.relayBreak()
    feed(unit(7))
    var stats = pipeline.stats(clock, 0)
    assertEquals(0L, stats.lostPictures)
    assertEquals(0L, stats.encoderRestarts)
    assertEquals(5, sink.units.size)
    assertTrue(sink.units.all { it.second.source == DescriptionSource.CACHE })
    // The same jump without BREAK is what the radio lost
    feed(unit(20))
    stats = pipeline.stats(clock, 0)
    assertEquals(12L, stats.lostPictures)
  }

  @Test
  fun theStateFollowsTheDecoder() {
    repeat(CodecDetector.SIGNATURE_UNITS) {
      feed(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(it + 1)))
    }
    sink.status = DecoderStatus(name = "c2.android.hevc.decoder", kind = DecoderKind.SOFTWARE, running = true, parked = false, startedAtNs = clock)
    assertEquals(VideoState.BUILDING, pipeline.stats(clock, 0).state)
    val started = clock
    pipeline.statistics.onDecoded(10_000_000, clock)
    assertEquals(VideoState.BUILDING, pipeline.stats(clock + 1_000_000_000, 0).state)
    // Five more seconds of pictures with no key picture: the picture is built, the panel says decoding
    while (clock - started < VideoPipeline.BUILDING_NS) {
      feed(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice()))
    }
    assertEquals(VideoState.DECODING, pipeline.stats(clock, 0).state)
    sink.status = sink.status.copy(parked = true)
    assertEquals(VideoState.HIDDEN, pipeline.stats(clock, 0).state)
    sink.status = DecoderStatus(running = false, failure = "no-decoder")
    assertEquals(VideoState.FAILED, pipeline.stats(clock, 0).state)
  }

  @Test
  fun aStreamThatStoppedWaitsForVideoAgain() {
    repeat(CodecDetector.SIGNATURE_UNITS) {
      feed(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(it + 1)))
    }
    sink.status = DecoderStatus(name = "c2.android.hevc.decoder", running = true, parked = true, startedAtNs = 0)
    pipeline.statistics.onDecoded(5_000_000, clock)
    assertEquals(VideoState.HIDDEN, pipeline.stats(clock, 0).state)
    assertEquals(VideoState.WAITING_FOR_VIDEO, pipeline.stats(clock + 2_001_000_000, 0).state)
  }

  @Test
  fun aNewSourceStopsTheDecoderAndStartsTheCountersAgain() {
    feed(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice()))
    pipeline.newSource()
    assertEquals(1, sink.resets)
    assertEquals(VideoState.WAITING_FOR_VIDEO, pipeline.stats(clock, 0).state)
    assertEquals(0L, pipeline.stats(clock, 0).unitsIn)
  }
}
