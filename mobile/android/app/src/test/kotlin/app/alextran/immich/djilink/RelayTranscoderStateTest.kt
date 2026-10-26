package app.alextran.immich.djilink

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Decoder 2 played by the test: the units it is given stay with the core until [pull] takes them */
class FakeRelayDecoder(private val core: RelayTranscoder) : RelayDecoderPort {
  override val name = "c2.fake.hevc.decoder"
  var wakes = 0
  var released = false

  override fun wake() {
    wakes += 1
  }

  override fun release() {
    released = true
  }

  /** Every unit waiting, in order, as the decoder's input thread takes them */
  fun pull(nowNs: Long): List<RelayDecoderInput> {
    val out = mutableListOf<RelayDecoderInput>()
    while (true) {
      out += core.nextInput(nowNs) ?: return out
    }
  }
}

class FakeRelayEncoder(var rateBps: Int, override val setup: RelayEncoderSetup) : RelayEncoderPort {
  override val name = "c2.fake.hevc.encoder"

  /** The rate it was made with */
  val madeAtBps = rateBps
  var keys = 0
  var released = false
  val bitrates = mutableListOf<Int>()

  override fun requestKey() {
    keys += 1
  }

  override fun setBitrate(bps: Int) {
    rateBps = bps
    bitrates += bps
  }

  override fun release() {
    released = true
  }
}

class FakeRelayCodecs : RelayCodecs {
  var encoderInfo: RelayEncoderInfo? = RelayEncoderInfo("c2.fake.hevc.encoder", hardware = true, cbr = true)
  var decoderRefused = false
  var encoderRefused = false

  /** What the encoder's output format says of a latency of one picture */
  var latencyAccepted: Boolean? = true

  /** Runs while the encoder is made, as the reader thread may meanwhile */
  var whileEncoderMade: (() -> Unit)? = null

  /** Runs while decoder 2 is made */
  var whileDecoderMade: (() -> Unit)? = null
  val decoders = mutableListOf<FakeRelayDecoder>()
  val encoders = mutableListOf<FakeRelayEncoder>()
  val openedWith = mutableListOf<StreamDescription>()

  override fun findEncoder(): RelayEncoderInfo? = encoderInfo

  override fun openDecoder(description: StreamDescription, core: RelayTranscoder): RelayDecoderPort? {
    whileDecoderMade?.invoke()
    if (decoderRefused) {
      return null
    }
    openedWith += description
    return FakeRelayDecoder(core).also { decoders += it }
  }

  override fun openEncoder(
    info: RelayEncoderInfo,
    bitrateBps: Int,
    decoder: RelayDecoderPort,
    core: RelayTranscoder,
  ): RelayEncoderPort? {
    whileEncoderMade?.let { during ->
      whileEncoderMade = null
      during()
    }
    // The encoder draws from decoder 2's GL stage: none can be made on one released meanwhile
    if (encoderRefused || (decoder as? FakeRelayDecoder)?.released == true) {
      return null
    }
    val setup = RelayEncoderSetup(
      1920,
      1080,
      30,
      "cbr",
      latencyAccepted = latencyAccepted,
      headersOnKeys = true,
      keyIntervalS = 2,
      level = 0,
    )
    return FakeRelayEncoder(bitrateBps, setup).also { encoders += it }
  }
}

/**
 * The steady stream's rules with fake codecs (p2/relay-bandwidth-2026-10-25.md, 7.2, 7.5 and 7.11): a clean start at
 * the drone's next key picture and a dirty one, the decimation and the units handed to the server, and every failure:
 * no encoder, a refused size, no second decoder, decoder 2 or the encoder too slow, a hot phone, the pilot's decoder
 * affected, codec and GL errors.
 */
class RelayTranscoderStateTest {
  private val ms = 1_000_000L
  private val second = 1_000_000_000L
  private var now = 0L
  private val codecs = FakeRelayCodecs()
  private val emitted = mutableListOf<Pair<AccessUnit, ResolvedDescription>>()
  private val core = RelayTranscoder(
    codecs,
    clockNs = { now },
    emit = { unit, description -> emitted += unit to description },
    worker = { it.run() },
  )
  private val drone = ResolvedDescription(ProfileRegistry.seed20261023!!, DescriptionSource.SESSION)
  private val vectors: JsonObject by lazy {
    val stream = javaClass.classLoader!!.getResourceAsStream("djilink/relay-encoder-vectors.json")!!
    val text = stream.bufferedReader().readText()
    Json.parseToJsonElement(text).jsonObject
  }

  private fun encoded(name: String, index: Int): ByteArray =
    StreamDescription.hexBytes(vectors[name]!!.jsonObject["units"]!!.jsonArray[index].jsonPrimitive.content)!!

  /** A drone unit at 60 a second: its content clock and its phone receive time follow [index] */
  private fun droneUnit(index: Int, key: Boolean = false): AccessUnit = HevcSamples.unitOf(
    HevcSamples.DELIMITER,
    HevcSamples.slice(type = if (key) 19 else 1),
    HevcSamples.suffixSei(index),
    arrivalNs = now,
  ).also { it.contentMs = 100_000L + index * 50L / 3 }

  private fun running(): RelayTranscoder {
    core.start(now)
    core.setEnabled(true, now)
    core.setCapableReceivers(true, now)
    return core
  }

  /** The drone's stream from a key picture, then the steady stream needed: decoder 2 and the encoder made */
  private fun steady(): Pair<FakeRelayDecoder, FakeRelayEncoder> {
    running()
    core.offer(droneUnit(0, key = true), drone)
    core.setNeeded(true, now)
    return codecs.decoders.last() to codecs.encoders.last()
  }

  /**
   * One step of the pipeline: a drone unit offered, decoder 2 decodes it 12 ms later, the kept pictures are drawn and
   * come out of the encoder [encodeMs] after
   */
  private fun step(index: Int, decoder: FakeRelayDecoder, encodeMs: Long = 15, key: Boolean = false): Int {
    core.offer(droneUnit(index, key), drone)
    var out = 0
    for (input in decoder.pull(now)) {
      if (core.onDecoded(input.ptsUs, now + 12 * ms)) {
        core.onDrawn(input.ptsUs, now + 14 * ms)
        val bytes = if (out == 0 && emitted.isEmpty()) encoded("a1080", 0) else encoded("a1080", 1)
        core.onEncoded(bytes, input.ptsUs, config = false, key = bytes.size > 1000, nowNs = now + (14 + encodeMs) * ms)
        out += 1
      }
    }
    return out
  }

  @Test
  fun withoutAnEncoderThereIsNoSteadyStream() {
    codecs.encoderInfo = null
    running()
    assertEquals(TranscoderState.UNAVAILABLE, core.state)
    assertEquals("noEncoder", core.why)
    assertFalse(core.available)
    assertFalse(core.usable)
    core.offer(droneUnit(0, key = true), drone)
    core.setNeeded(true, now)
    assertTrue(codecs.decoders.isEmpty())
    assertEquals("unavailable", core.line(now)!!.state)
  }

  @Test
  fun decoderTwoStartsCleanAtTheDronesNextKeyPictureAndTakesEveryUnitInOrder() {
    running()
    assertEquals(TranscoderState.STANDBY, core.state)
    core.offer(droneUnit(0), drone)
    assertTrue("no decoder before a key picture", codecs.decoders.isEmpty())
    core.offer(droneUnit(1, key = true), drone)
    val decoder = codecs.decoders.single()
    assertTrue(decoder.wakes > 0)
    now += 17 * ms
    core.offer(droneUnit(2), drone)
    core.offer(droneUnit(3), drone)
    val inputs = decoder.pull(now)
    assertEquals(3, inputs.size)
    assertTrue(inputs.first().unit.isKey)
    // The content time as presentation time, always increasing
    assertEquals(inputs.map { it.unit.contentMs * 1000 }, inputs.map { it.ptsUs })
    assertTrue(inputs.zipWithNext().all { (a, b) -> b.ptsUs > a.ptsUs })
    // No encoder yet: every picture released unseen
    inputs.forEach { assertFalse(core.onDecoded(it.ptsUs, now)) }
    assertTrue(codecs.encoders.isEmpty())
    val report = core.report(now)!!
    assertEquals(1, report["cleanStarts"]!!.jsonPrimitive.int)
    assertEquals(0, report["dirtyStarts"]!!.jsonPrimitive.int)
    assertEquals("c2.fake.hevc.decoder", report["decoderName"]!!.jsonPrimitive.content)
  }

  @Test
  fun newParameterSetsAtADroneKeyMakeDecoderTwoAgainAndTheUnitsAfterItGoToTheNewOne() {
    val (first, firstEncoder) = steady()
    first.pull(now)
    val other = ResolvedDescription(EncodedUnits.descriptionOf(encoded("a1080", 0))!!, DescriptionSource.SESSION)
    core.offer(droneUnit(10, key = true), other)
    assertTrue(first.released)
    assertTrue(firstEncoder.released)
    assertEquals(2, codecs.decoders.size)
    assertTrue(codecs.openedWith.last().sameSetsAs(other.description))
    // Still needed: the encoder is made again on the new decoder's stage
    assertEquals(2, codecs.encoders.size)
    core.offer(droneUnit(11), other)
    val inputs = codecs.decoders.last().pull(now)
    assertEquals(listOf(true, false), inputs.map { it.unit.isKey })
    // The same sets again: no new decoder
    core.offer(droneUnit(12, key = true), other)
    assertEquals(2, codecs.decoders.size)
  }

  @Test
  fun aNewSourceForgetsEverythingAndStartsAgainAtItsFirstKeyPicture() {
    val (decoder, encoder) = steady()
    core.reset()
    assertTrue(decoder.released)
    assertTrue(encoder.released)
    core.offer(droneUnit(1), drone)
    assertEquals(1, codecs.decoders.size)
    core.offer(droneUnit(2, key = true), drone)
    assertEquals(2, codecs.decoders.size)
    assertEquals(2, codecs.encoders.size)
  }

  @Test
  fun neededBeforeAnyKeyPictureItStartsDirtyFromTheKeptOne() {
    running()
    core.keepKey(droneUnit(0, key = true), drone)
    core.offer(droneUnit(1), drone)
    core.setNeeded(true, now)
    val decoder = codecs.decoders.single()
    assertEquals(1, codecs.encoders.size)
    assertEquals(TranscoderState.RUNNING, core.state)
    core.offer(droneUnit(2), drone)
    val inputs = decoder.pull(now)
    assertTrue(inputs.first().unit.isKey)
    assertEquals(2, inputs.size)
    assertEquals(1, core.report(now)!!["dirtyStarts"]!!.jsonPrimitive.int)
  }

  @Test
  fun theKeptPicturesAreEncodedWithTheirSourcesTimesAndAConsecutiveCounter() {
    val (decoder, encoder) = steady()
    assertEquals(RelayTranscoder.START_BPS, encoder.rateBps)
    var out = 0
    repeat(60) { index ->
      now += 50 * ms / 3
      out += step(index + 1, decoder)
    }
    // 60 a second in, 30 out
    assertTrue("$out kept", out in 30..31)
    assertEquals(out, emitted.size)
    assertEquals((0 until out).toList(), emitted.map { it.first.headerCounter })
    assertTrue(emitted.first().first.isKey)
    assertTrue(emitted.all { it.first.contentMs >= 100_000L })
    assertTrue(emitted.all { it.first.pictureCounter == null })
    // The parameter sets of the steady stream are the encoder's own
    assertEquals(1080, emitted.first().second.description.info.height)
    assertTrue(core.producing)
    val report = core.report(now)!!
    assertEquals(out, report["encoded"]!!.jsonPrimitive.int)
    assertEquals(15.0, report["encodeMedianMs"]!!.jsonPrimitive.content.toDouble(), 1.0)
    assertNotNull(report["receiveToEncodedMedianMs"]!!.jsonPrimitive.content.toDoubleOrNull())
    // 15 a second when a receiver's link needs it
    core.setPictureRate(15, now)
    emitted.clear()
    repeat(60) { index ->
      now += 50 * ms / 3
      step(index + 61, decoder)
    }
    assertTrue("${emitted.size} kept", emitted.size in 15..16)
  }

  @Test
  fun aKeyPictureWithoutItsSetsGetsThemInBandFromTheConfigurationBuffer() {
    val (decoder, _) = steady()
    val config = StreamDescription.hexBytes(vectors["b720"]!!.jsonObject["config"]!!.jsonPrimitive.content)!!
    core.onEncoded(config, 0, config = true, key = false, nowNs = now)
    core.offer(droneUnit(1), drone)
    val input = decoder.pull(now).first()
    assertTrue(core.onDecoded(input.ptsUs, now))
    core.onEncoded(encoded("b720", 0), input.ptsUs, config = false, key = true, nowNs = now)
    val unit = emitted.single().first
    assertTrue(unit.isKey)
    assertTrue(unit.hasParameterSets)
    assertEquals(720, emitted.single().second.description.info.height)
    assertEquals(1, core.report(now)!!["keySetsAddedInBand"]!!.jsonPrimitive.int)
  }

  @Test
  fun anEncoderThatRefusesBothSizesLeavesNoSteadyStream() {
    codecs.encoderRefused = true
    running()
    core.offer(droneUnit(0, key = true), drone)
    core.setNeeded(true, now)
    assertTrue(codecs.encoders.isEmpty())
    assertEquals(TranscoderState.UNAVAILABLE, core.state)
    assertEquals("refused", core.why)
    assertFalse(core.usable)
    assertTrue(codecs.decoders.single().released)
  }

  @Test
  fun noSecondDecoderLeavesNoSteadyStream() {
    codecs.decoderRefused = true
    running()
    core.offer(droneUnit(0, key = true), drone)
    assertEquals(TranscoderState.UNAVAILABLE, core.state)
    assertEquals("noSecondDecoder", core.why)
  }

  @Test
  fun aDecoderTooSlowStopsTheSteadyStream() {
    val (decoder, encoder) = steady()
    decoder.pull(now)
    repeat(70) { index ->
      now += 50 * ms / 3
      core.offer(droneUnit(index + 1), drone)
    }
    assertEquals(TranscoderState.STOPPED, core.state)
    assertEquals("decoderTooSlow", core.why)
    assertTrue(decoder.released)
    assertTrue(encoder.released)
    assertFalse(core.usable)
    assertTrue(core.available)
  }

  @Test
  fun aSlowEncoderGoesToFifteenAndStopsFiveSecondsLater() {
    val (decoder, _) = steady()
    var index = 1
    while (core.perSecond == 30 && now < 6 * second) {
      now += 50 * ms / 3
      step(index++, decoder, encodeMs = 80)
      core.tick(now)
    }
    // Slow for 3 s: 15 a second
    assertEquals(15, core.perSecond)
    assertTrue("15 a second at ${now / ms} ms", now >= 3 * second)
    assertTrue(core.usable)
    val fifteenAt = now
    while (now < fifteenAt + 5 * second + 200 * ms) {
      now += 50 * ms / 3
      step(index++, decoder, encodeMs = 80)
      core.tick(now)
    }
    assertEquals(TranscoderState.STOPPED, core.state)
    assertEquals("tooSlow", core.why)
  }

  @Test
  fun aHotPhoneGoesToFifteenUnderSixMegabitsThenStopsAndComesBackOnceCool() {
    val (_, encoder) = steady()
    core.setBitrate(10_000_000, now)
    assertEquals(10_000_000, encoder.rateBps)
    core.onThermal(RelayTranscoder.THERMAL_MODERATE, now)
    assertEquals(RelayTranscoder.HOT_CAP_BPS, encoder.rateBps)
    assertEquals(15, core.perSecond)
    core.onThermal(RelayTranscoder.THERMAL_SEVERE, now)
    assertEquals(TranscoderState.STOPPED, core.state)
    assertEquals("hot", core.why)
    assertTrue(encoder.released)
    core.onThermal(RelayTranscoder.THERMAL_LIGHT, now)
    now += 30 * second
    core.tick(now)
    assertFalse(core.usable)
    now += 31 * second
    core.tick(now)
    assertTrue(core.usable)
    val report = core.report(now)!!
    assertEquals(RelayTranscoder.THERMAL_SEVERE, report["thermalMax"]!!.jsonPrimitive.int)
  }

  @Test
  fun anOverrunOfThePilotsDecoderStopsItAtOnce() {
    running()
    core.onPilot(overruns = 4, decodeP95Ms = 20.0, nowNs = now)
    core.offer(droneUnit(0, key = true), drone)
    core.onPilot(overruns = 4, decodeP95Ms = 21.0, nowNs = now)
    assertTrue(core.usable)
    core.onPilot(overruns = 5, decodeP95Ms = 21.0, nowNs = now)
    assertEquals(TranscoderState.STOPPED, core.state)
    assertEquals("pilotFirst", core.why)
    assertEquals(20.0, core.report(now)!!["pilotDecodeP95BeforeMs"]!!.jsonPrimitive.content.toDouble(), 0.01)
  }

  @Test
  fun thePilotsDecodeTimeOverOneAndAHalfTimesItsValueForThreeSecondsStopsIt() {
    running()
    core.onPilot(overruns = 0, decodeP95Ms = 20.0, nowNs = now)
    core.offer(droneUnit(0, key = true), drone)
    repeat(5) {
      now += 500 * ms
      core.onPilot(overruns = 0, decodeP95Ms = 28.0, nowNs = now)
    }
    // Under 1.5 times: goes on
    assertTrue(core.usable)
    repeat(6) {
      now += 500 * ms
      core.onPilot(overruns = 0, decodeP95Ms = 40.0, nowNs = now)
    }
    assertTrue("not for 3 s yet", core.usable)
    now += 500 * ms
    core.onPilot(overruns = 0, decodeP95Ms = 40.0, nowNs = now)
    assertEquals("pilotFirst", core.why)
  }

  @Test
  fun aRecoverableCodecErrorMakesTheEncoderAgainAndThreeInAMinuteStopIt() {
    val (_, first) = steady()
    core.onEncoderError("0x80001001", recoverable = true, nowNs = now)
    assertTrue(first.released)
    assertEquals(2, codecs.encoders.size)
    assertTrue(core.usable)
    now += 10 * second
    core.onDecoderError("0x80001002", recoverable = true, nowNs = now)
    // Decoder 2 made again from the kept key picture, and the encoder with it
    assertEquals(2, codecs.decoders.size)
    assertEquals(3, codecs.encoders.size)
    now += 10 * second
    core.onEncoderError("0x80001003", recoverable = true, nowNs = now)
    assertEquals(TranscoderState.STOPPED, core.state)
    assertEquals("failed", core.why)
    val failures = core.report(now)!!["failures"]!!.jsonArray
    assertTrue(failures.size >= 3)
  }

  @Test
  fun aFatalCodecErrorStopsItAtOnce() {
    steady()
    core.onEncoderError("0x80000000", recoverable = false, nowNs = now)
    assertEquals("failed", core.why)
  }

  @Test
  fun theGlStageIsMadeAgainOnceThenAnotherErrorStopsIt() {
    steady()
    core.onGlError("EGL_BAD_SURFACE", now)
    assertTrue(core.usable)
    assertEquals(2, codecs.decoders.size)
    assertEquals(2, codecs.encoders.size)
    core.onGlError("EGL_BAD_SURFACE", now)
    assertEquals("failed", core.why)
  }

  @Test
  fun keyRequestsGoToTheEncoderCoalescedAndCountedByCause() {
    val (decoder, encoder) = steady()
    // The encoder's first output is a key picture
    now += 20 * ms
    step(1, decoder)
    core.requestKey(RelayKeyCause.JOIN, now)
    assertEquals(0, encoder.keys)
    now += 400 * ms
    core.tick(now)
    assertEquals(1, encoder.keys)
    core.requestKey(RelayKeyCause.DROP, now)
    assertEquals(1, encoder.keys)
    val counts =
      mapOf(RelayKeyCause.JOIN to 1L, RelayKeyCause.DROP to 1L, RelayKeyCause.SWITCH to 0L, RelayKeyCause.PERIOD to 0L)
    assertEquals(counts, core.keyCounts())
    val requests = core.report(now)!!["keyRequests"]!!.jsonObject
    assertEquals(1, requests["drop"]!!.jsonPrimitive.int)
  }

  @Test
  fun theEncoderGoesSixtySecondsAfterTheLastNeed() {
    val (decoder, encoder) = steady()
    decoder.pull(now)
    core.setNeeded(false, now)
    now += 59 * second
    core.tick(now)
    assertFalse(encoder.released)
    now += 2 * second
    core.tick(now)
    assertTrue(encoder.released)
    assertEquals(TranscoderState.STANDBY, core.state)
    // Needed again: made again
    core.setNeeded(true, now)
    assertEquals(2, codecs.encoders.size)
  }

  @Test
  fun turnedOffEverythingGoes() {
    val (decoder, encoder) = steady()
    core.setEnabled(false, now)
    assertTrue(decoder.released)
    assertTrue(encoder.released)
    assertEquals(TranscoderState.OFF, core.state)
    assertTrue(core.usable)
  }

  @Test
  fun theReportHasItsTimelineAndItsRates() {
    val (decoder, encoder) = steady()
    core.setBitrate(4_000_000, now)
    core.setBitrate(4_000_000, now)
    core.setBitrate(3_000_000, now)
    assertEquals(listOf(4_000_000, 3_000_000), encoder.bitrates)
    var index = 1
    repeat(3) {
      repeat(60) {
        now += 50 * ms / 3
        step(index++, decoder)
      }
      core.tick(now)
    }
    val report = core.report(now)!!
    assertEquals(RelayTranscoder.TIMELINE_HEADER, report["timelineColumns"]!!.jsonPrimitive.content)
    val lines = report["timeline"]!!.jsonArray
    assertTrue(lines.size >= 2)
    val columns = RelayTranscoder.TIMELINE_HEADER.split(',')
    val line = lines.last().jsonPrimitive.content.split(',')
    assertEquals(columns.size, line.size)
    assertEquals("3000", line[columns.indexOf("bitrateKbps")])
    assertEquals(3_000L, report["bitrateNowKbps"]!!.jsonPrimitive.long)
    assertEquals(3_000L, report["bitrateMinKbps"]!!.jsonPrimitive.long)
    assertEquals(8_000L, report["bitrateMaxKbps"]!!.jsonPrimitive.long)
    assertEquals(2L, report["bitrateChanges"]!!.jsonPrimitive.long)
    assertEquals("running", report["state"]!!.jsonPrimitive.content)
    assertEquals("cbr", report["bitrateMode"]!!.jsonPrimitive.content)
    assertNull(report["why"]!!.jsonPrimitive.contentOrNullSafe())
    val line2 = core.line(now)!!
    assertEquals("c2.fake.hevc.encoder", line2.encoderName)
    assertEquals(3_000_000, line2.bitrateBps)
    assertEquals(1920, line2.width)
  }

  // The fix round of p2/review-bandwidth-2026-10-25.md, with the clock moving and the codecs made as on a phone

  /** B1: a dirty start a minute after the kept key, decoder 2 made 150 ms later while the units come */
  @Test
  fun aDirtyStartFromAKeyAMinuteOldKeepsRunningWithADecoderMade150MillisecondsLater() {
    running()
    core.setCapableReceivers(false, now)
    // The take off key, while no receiver of this build is connected
    core.offer(droneUnit(0, key = true), drone)
    now += 60 * second
    var index = 1
    codecs.whileDecoderMade = {
      repeat(9) {
        now += 17 * ms
        core.offer(droneUnit(index++), drone)
      }
    }
    // A TV joins in flight; the steady stream is needed before any new drone key picture
    core.setCapableReceivers(true, now)
    core.offer(droneUnit(index++), drone)
    core.setNeeded(true, now)
    codecs.whileDecoderMade = null
    assertEquals(TranscoderState.RUNNING, core.state)
    assertNull(core.why)
    assertEquals(1, core.report(now)!!["dirtyStarts"]!!.jsonPrimitive.int)
    // Decoder 2 takes the kept key and the units that waited, then keeps up for 2 s
    val decoder = codecs.decoders.single()
    val inputs = decoder.pull(now)
    assertTrue(inputs.first().unit.isKey)
    assertEquals(10, inputs.size)
    repeat(120) {
      now += 50 * ms / 3
      step(index++, decoder)
      core.tick(now)
    }
    assertEquals(TranscoderState.RUNNING, core.state)
    assertTrue(core.report(now)!!["inputQueueMaxMs"]!!.jsonPrimitive.long < 1_000)
  }

  /** B1: a recoverable decoder error in flight makes decoder 2 again from the kept key, which is old by then */
  @Test
  fun aDecoderErrorInFlightStartsAgainFromTheOldKeyAndKeepsRunning() {
    val (first, _) = steady()
    first.pull(now)
    var index = 1
    repeat(60) {
      now += second
      step(index++, first)
      core.tick(now)
    }
    core.onDecoderError("0x80001002", recoverable = true, nowNs = now)
    val again = codecs.decoders.last()
    assertTrue(again !== first)
    repeat(60) {
      now += 50 * ms / 3
      step(index++, again)
      core.tick(now)
    }
    assertEquals(TranscoderState.RUNNING, core.state)
    assertEquals(1, core.report(now)!!["dirtyStarts"]!!.jsonPrimitive.int)
  }

  /**
   * M1: the encoder is being made on decoder 2 when the take off key brings new parameter sets and releases it: not a
   * refusal; the encoder is made again on the new decoder 2
   */
  @Test
  fun aTakeOffKeyWithNewSetsWhileTheEncoderIsMadeLeavesTheSteadyStreamRunning() {
    val tasks = ArrayDeque<Runnable>()
    val queued = RelayTranscoder(codecs, clockNs = { now }, worker = { tasks.addLast(it) })
    queued.start(now)
    queued.setEnabled(true, now)
    queued.setCapableReceivers(true, now)
    queued.offer(droneUnit(0, key = true), drone)
    while (tasks.isNotEmpty()) tasks.removeFirst().run()
    val other = ResolvedDescription(EncodedUnits.descriptionOf(encoded("a1080", 0))!!, DescriptionSource.SESSION)
    queued.setNeeded(true, now)
    codecs.whileEncoderMade = { queued.offer(droneUnit(1, key = true), other) }
    while (tasks.isNotEmpty()) tasks.removeFirst().run()
    assertEquals(TranscoderState.RUNNING, queued.state)
    assertNull(queued.why)
    assertTrue(codecs.decoders.first().released)
    assertEquals(2, codecs.decoders.size)
    assertTrue(codecs.openedWith.last().sameSetsAs(other.description))
    assertEquals(1, codecs.encoders.size)
    assertEquals(0, queued.report(now)!!["creationFailures"]!!.jsonPrimitive.int)
  }

  /** m5: an encoder refused once is tried again 30 s later, and no more after three refusals in the session */
  @Test
  fun aRefusedEncoderIsTriedAgainThirtySecondsLaterThreeTimesASession() {
    codecs.encoderRefused = true
    running()
    core.offer(droneUnit(0, key = true), drone)
    core.setNeeded(true, now)
    assertEquals("refused", core.why)
    // Offered to a receiver that joins meanwhile: the phone has an encoder
    assertTrue(core.available)
    assertFalse(core.usable)
    now += 29 * second
    core.tick(now)
    assertEquals("refused", core.why)
    now += 2 * second
    core.tick(now)
    assertNull(core.why)
    assertTrue(core.usable)
    // It takes this time: from the kept key, as a dirty start
    codecs.encoderRefused = false
    core.setNeeded(true, now)
    assertEquals(TranscoderState.RUNNING, core.state)
    assertEquals(1, core.report(now)!!["creationRetries"]!!.jsonPrimitive.int)
    // Three refusals in a session: no more tries
    val again = FakeRelayCodecs().apply { encoderRefused = true }
    val refusing = RelayTranscoder(again, clockNs = { now }, worker = { it.run() })
    refusing.start(now)
    refusing.setEnabled(true, now)
    refusing.setCapableReceivers(true, now)
    refusing.offer(droneUnit(0, key = true), drone)
    repeat(3) {
      refusing.setNeeded(true, now)
      now += 31 * second
      refusing.tick(now)
    }
    assertEquals("refused", refusing.why)
    assertFalse(refusing.available)
    assertEquals(3, refusing.report(now)!!["creationFailures"]!!.jsonPrimitive.int)
  }

  /**
   * M3, in the field's order: decoder 2 starts with the link, before the pilot has any decode time, and the flight's
   * phase (60 a second) was never seen without decoder 2. Two picture periods bound the pilot's p95 then.
   */
  @Test
  fun thePilotGuardHoldsWhenDecoderTwoStartsWithTheLink() {
    running()
    core.offer(droneUnit(0, key = true), drone)
    repeat(20) {
      now += 500 * ms
      core.onPilot(overruns = 0, decodeP95Ms = 22.7, nowNs = now, flying = true, picturesPerSecond = 60.0)
    }
    assertTrue("22.7 ms at 60 a second is under two periods", core.usable)
    assertEquals(33.3, core.report(now)!!["pilotBoundMs"]!!.jsonPrimitive.content.toDouble(), 0.1)
    repeat(6) {
      now += 500 * ms
      core.onPilot(overruns = 0, decodeP95Ms = 80.0, nowNs = now, flying = true, picturesPerSecond = 60.0)
    }
    assertTrue("not for 3 s yet", core.usable)
    now += 500 * ms
    core.onPilot(overruns = 0, decodeP95Ms = 80.0, nowNs = now, flying = true, picturesPerSecond = 60.0)
    assertEquals("pilotFirst", core.why)
  }

  /** M3: the ground's decode time is not the flight's bound */
  @Test
  fun theGroundsDecodeTimeIsNotComparedWithTheFlights() {
    running()
    core.setCapableReceivers(false, now)
    // On the ground at 30 a second, no TV of this build yet: 14 ms is the ground's
    repeat(10) {
      now += 500 * ms
      core.onPilot(overruns = 0, decodeP95Ms = 14.0, nowNs = now, flying = false, picturesPerSecond = 30.0)
    }
    core.setCapableReceivers(true, now)
    // The take off key starts decoder 2; the flight at 60 a second decodes in 22 ms, with or without it
    core.offer(droneUnit(0, key = true), drone)
    repeat(20) {
      now += 500 * ms
      core.onPilot(overruns = 0, decodeP95Ms = 22.0, nowNs = now, flying = true, picturesPerSecond = 60.0)
    }
    assertTrue(core.usable)
    val report = core.report(now)!!
    assertEquals("flying60", report["pilotPhase"]!!.jsonPrimitive.content)
    val ground = report["pilotDecodeP95BeforeByPhaseMs"]!!.jsonObject["ground30"]!!
    assertEquals(14.0, ground.jsonPrimitive.content.toDouble(), 0.01)
    // Back on the ground with decoder 2 running: the ground's own bound, 1.5 times 14 ms but at least a period (33 ms)
    repeat(8) {
      now += 500 * ms
      core.onPilot(overruns = 0, decodeP95Ms = 40.0, nowNs = now, flying = false, picturesPerSecond = 30.0)
    }
    assertEquals("pilotFirst", core.why)
  }

  /** m2: an encoder that did not take a latency of one picture may hold three; it is not slow for that */
  @Test
  fun anEncoderHoldingPicturesWithoutALatencyOfOneIsNotSlow() {
    codecs.latencyAccepted = false
    val (decoder, _) = steady()
    var index = 1
    while (now < 10 * second) {
      now += 50 * ms / 3
      step(index++, decoder, encodeMs = 110)
      core.tick(now)
    }
    assertEquals(30, core.perSecond)
    assertTrue(core.usable)
  }

  /** m4: a new relay session counts from zero; the pilot's decode times of each phase stay */
  @Test
  fun aNewRelaySessionStartsItsCountersAndFailuresAgain() {
    val (decoder, _) = steady()
    core.onPilot(overruns = 0, decodeP95Ms = null, nowNs = now)
    repeat(30) { step(it + 1, decoder) }
    core.onGlError("EGL_BAD_SURFACE", now)
    core.stop()
    core.onPilot(overruns = 0, decodeP95Ms = 15.0, nowNs = now, flying = false, picturesPerSecond = 30.0)
    now += 10 * second
    core.start(now)
    val report = core.report(now)!!
    assertEquals(0, report["encoded"]!!.jsonPrimitive.int)
    assertEquals(0, report["failures"]!!.jsonArray.size)
    assertEquals(0, report["cleanStarts"]!!.jsonPrimitive.int)
    assertEquals(0, report["timeline"]!!.jsonArray.size)
    val ground = report["pilotDecodeP95BeforeByPhaseMs"]!!.jsonObject["ground30"]!!
    assertEquals(15.0, ground.jsonPrimitive.content.toDouble(), 0.01)
    // One GL error in this session is the first of this session: made again, not stopped
    core.setEnabled(true, now)
    core.setCapableReceivers(true, now)
    core.offer(droneUnit(100, key = true), drone)
    core.setNeeded(true, now)
    core.onGlError("EGL_BAD_SURFACE", now)
    assertTrue(core.usable)
  }

  /** M2: the export says the steady stream's coded size, and whether the key pictures came with their sets */
  @Test
  fun theReportSaysTheCodedSizeAndWhetherTheKeysCameWithTheirSets() {
    val (decoder, _) = steady()
    assertNull(core.report(now)!!["headersOnKeysTaken"]!!.jsonPrimitive.contentOrNullSafe())
    repeat(10) {
      now += 50 * ms / 3
      step(it + 1, decoder)
    }
    val report = core.report(now)!!
    // The libx265 vector codes 1080 lines as 1088, as most hardware encoders do
    assertEquals(1920, report["codedWidth"]!!.jsonPrimitive.int)
    assertEquals(1088, report["codedHeight"]!!.jsonPrimitive.int)
    assertEquals("true", report["headersOnKeysTaken"]!!.jsonPrimitive.content)
  }

  /**
   * p2/noon-test-check-2026-10-26.md 3.4 (item 4 of its section 4): a rate the tick asks while the encoder is being made
   * reaches the encoder once it is made, and is counted; so does the thermal cap that comes meanwhile
   */
  @Test
  fun aRateAskedWhileTheEncoderIsMadeReachesItAndIsCounted() {
    running()
    core.offer(droneUnit(0, key = true), drone)
    codecs.whileEncoderMade = { core.setBitrate(3_000_000, now) }
    core.setNeeded(true, now)
    val encoder = codecs.encoders.single()
    assertEquals(8_000_000, encoder.madeAtBps)
    assertEquals(3_000_000, encoder.rateBps)
    val report = core.report(now)!!
    assertEquals(3_000L, report["bitrateNowKbps"]!!.jsonPrimitive.long)
    assertEquals(1L, report["bitrateChanges"]!!.jsonPrimitive.long)
    assertEquals(3_000L, report["bitrateMinKbps"]!!.jsonPrimitive.long)
    assertEquals(8_000L, report["bitrateMaxKbps"]!!.jsonPrimitive.long)
    // Made again (a recoverable encoder error) while the phone gets hot: the cap reaches the new one
    core.setBitrate(8_000_000, now)
    codecs.whileEncoderMade = { core.onThermal(RelayTranscoder.THERMAL_MODERATE, now) }
    core.onEncoderError("reset", recoverable = true, nowNs = now)
    val again = codecs.encoders.last()
    assertEquals(2, codecs.encoders.size)
    assertEquals(RelayTranscoder.HOT_CAP_BPS, again.rateBps)
    assertEquals(6_000L, core.report(now)!!["bitrateNowKbps"]!!.jsonPrimitive.long)
  }

  /**
   * The encoder of the S24+ as the noon test of 26 October read it (p2/noon-test-check-2026-10-26.md 3.5): its key
   * period is 60 pictures, counted at whatever rate it is fed, and an asked key starts the count again. Runs [seconds]
   * of the drone's stream at 60 a second, the steady stream at [perSecond], the server's tick every 100 ms; returns the
   * times the key pictures came out.
   */
  private fun keysOfAnEncoderCountingPictures(perSecond: Int, seconds: Int): List<Long> {
    val (decoder, encoder) = steady()
    core.setPictureRate(perSecond, now)
    val keyTimes = mutableListOf<Long>()
    var sinceKey = 0
    var asked = encoder.keys
    var index = 1
    val end = now + seconds * second
    var nextTick = now + 100 * ms
    while (now < end) {
      now += 50 * ms / 3
      core.offer(droneUnit(index++), drone)
      for (input in decoder.pull(now)) {
        if (!core.onDecoded(input.ptsUs, now)) {
          continue
        }
        core.onDrawn(input.ptsUs, now)
        val key = keyTimes.isEmpty() || sinceKey >= 60 || encoder.keys > asked
        asked = encoder.keys
        sinceKey = if (key) 1 else sinceKey + 1
        core.onEncoded(encoded("a1080", if (key) 0 else 1), input.ptsUs, config = false, key = key, nowNs = now)
        if (key) keyTimes += now
      }
      if (now >= nextTick) {
        core.tick(now)
        nextTick += 100 * ms
      }
    }
    return keyTimes
  }

  /** p2/noon-test-check-2026-10-26.md 3.5 (item 5): at 15 a second a key picture still comes every 2 s */
  @Test
  fun atFifteenASecondAKeyIsAskedWhenNoneCameForTwoSeconds() {
    val keyTimes = keysOfAnEncoderCountingPictures(15, 20)
    val gaps = keyTimes.zipWithNext { a, b -> (b - a) / ms }
    assertTrue("gaps $gaps", gaps.all { it <= 2_300 })
    assertTrue("keys ${keyTimes.size}", keyTimes.size >= 9)
    val report = core.report(now)!!
    val asked = report["keyRequests"]!!.jsonObject["period"]!!.jsonPrimitive.long
    // Asked for the period with its own cause, and answered: every key but the encoder's first
    assertEquals(keyTimes.size - 1L, asked)
    assertEquals(keyTimes.size - 1L, report["keysAsked"]!!.jsonPrimitive.long)
    assertEquals(1L, report["keysFirst"]!!.jsonPrimitive.long)
    assertEquals(0L, report["keysPeriodic"]!!.jsonPrimitive.long)
  }

  /** At 30 a second the encoder's own period is 2 s: nothing is asked, no key twice */
  @Test
  fun atThirtyASecondTheEncodersOwnKeysAreEnough() {
    val keyTimes = keysOfAnEncoderCountingPictures(30, 20)
    val gaps = keyTimes.zipWithNext { a, b -> (b - a) / ms }
    assertTrue("gaps $gaps", gaps.all { it in 1_900..2_100 })
    val report = core.report(now)!!
    assertEquals(0L, report["keyRequests"]!!.jsonObject["period"]!!.jsonPrimitive.long)
    assertEquals(0L, report["keysAsked"]!!.jsonPrimitive.long)
    assertEquals(1L, report["keysFirst"]!!.jsonPrimitive.long)
    assertEquals(keyTimes.size - 1L, report["keysPeriodic"]!!.jsonPrimitive.long)
  }

  /**
   * p2/noon-test-check-2026-10-26.md R4 (item 7): the first key of an encoder made again at a drone key with new sets
   * is counted apart, not as one of the encoder's periodic keys
   */
  @Test
  fun theFirstKeyOfEachEncoderIsCountedApartFromItsPeriodicOnes() {
    val (decoder, _) = steady()
    now += 20 * ms
    step(1, decoder)
    repeat(5) {
      now += 50 * ms / 3
      step(2 + it, decoder)
    }
    // The drone's encoder restarts with new sets: decoder 2 and the encoder are made again, its first output a key
    val other = ResolvedDescription(EncodedUnits.descriptionOf(encoded("a1080", 0))!!, DescriptionSource.SESSION)
    now += 50 * ms / 3
    core.offer(droneUnit(10, key = true), other)
    assertEquals(2, codecs.encoders.size)
    for (input in codecs.decoders.last().pull(now)) {
      if (core.onDecoded(input.ptsUs, now)) {
        core.onDrawn(input.ptsUs, now)
        core.onEncoded(encoded("a1080", 0), input.ptsUs, config = false, key = true, nowNs = now + 15 * ms)
      }
    }
    val report = core.report(now)!!
    assertEquals(0L, report["keysPeriodic"]!!.jsonPrimitive.long)
    assertEquals(0L, report["keysAsked"]!!.jsonPrimitive.long)
    assertEquals(2L, report["keysFirst"]!!.jsonPrimitive.long)
  }

  /**
   * p2/noon-test-check-2026-10-26.md C13 (item 8): megabitsPerSecondMean divides by the relay's time, which pins the
   * relay's start; the export says that time and the rate over the encoder's own time beside it
   */
  @Test
  fun theReportSaysTheRelaysTimeAndTheRateWhileTheEncoderRan() {
    running()
    // 10 s of relay with no steady receiver, then 4 s of steady stream
    now += 10 * second
    core.tick(now)
    core.offer(droneUnit(0, key = true), drone)
    core.setNeeded(true, now)
    val decoder = codecs.decoders.last()
    core.tick(now)
    repeat(4 * 60) {
      now += 50 * ms / 3
      step(it + 1, decoder)
      if (it % 6 == 5) core.tick(now)
    }
    core.tick(now)
    val report = core.report(now)!!
    val bytes = report["encodedBytes"]!!.jsonPrimitive.long
    assertTrue(bytes > 0)
    val relayS = report["relayRunningS"]!!.jsonPrimitive.double
    val encoderS = report["encoderRunningS"]!!.jsonPrimitive.double
    assertEquals(14.0, relayS, 0.01)
    assertEquals(4.0, encoderS, 0.01)
    assertEquals(bytes * 8 / 1e6 / relayS, report["megabitsPerSecondMean"]!!.jsonPrimitive.double, 1e-9)
    assertEquals(bytes * 8 / 1e6 / encoderS, report["megabitsPerSecondWhileRunning"]!!.jsonPrimitive.double, 1e-9)
  }

  private fun kotlinx.serialization.json.JsonPrimitive.contentOrNullSafe(): String? = if (isString) content else null
}
