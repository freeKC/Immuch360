package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Every decision of the decoder feed that does not need a decoder */
class DecoderPolicyTest {
  private fun queue(policy: DecoderPolicy, units: Int, key: Boolean = false): PolicyAction {
    var last = PolicyAction.NONE
    repeat(units) {
      policy.beforeQueue(key)
      last = policy.afterQueue(key)
    }
    return last
  }

  /** The H.265 decoders of the Quest 3 (dumpsys media.player, 24 October 2026): no software one, no low latency flag */
  private val questLowLatency =
    DecoderCandidate("c2.qti.hevc.decoder.low_latency", hardware = true, lowLatencyFeature = false)
  private val questHardware = DecoderCandidate("c2.qti.hevc.decoder", hardware = true, lowLatencyFeature = false)
  private val quest = listOf(questLowLatency, questHardware)

  /** A phone with the three kinds */
  private val phone = HevcDecoders.order(
    listOf(
      DecoderCandidate(HevcDecoders.SOFTWARE_NAME, hardware = false, lowLatencyFeature = false),
      DecoderCandidate("c2.qti.hevc.decoder", hardware = true, lowLatencyFeature = true),
      DecoderCandidate("c2.qti.hevc.decoder.low_latency", hardware = true, lowLatencyFeature = true),
    )
  )

  /** A key picture at [atNs], then [units] units 33 ms apart with no picture out; the last action */
  private fun keyThenNothing(
    policy: DecoderPolicy,
    units: Int,
    atNs: Long = 0L,
    stepNs: Long = 33_000_000L,
  ): PolicyAction {
    policy.beforeQueue(isKey = true)
    var last = policy.afterQueue(isKey = true, nowNs = atNs)
    for (i in 1..units) {
      policy.beforeQueue(isKey = false)
      last = policy.afterQueue(isKey = false, nowNs = atNs + i * stepNs)
      if (last != PolicyAction.NONE) {
        return last
      }
    }
    return last
  }

  @Test
  fun softwareAfterNinetyUnitsWithNoPictureAndNoKeyPicture() {
    val policy = DecoderPolicy()
    assertEquals(DecoderKind.HARDWARE, policy.kind)
    assertEquals(PolicyAction.NONE, queue(policy, DecoderPolicy.JOIN_UNITS - 1))
    assertEquals(PolicyAction.SWITCH_TO_SOFTWARE, queue(policy, 1))
    assertEquals(DecoderKind.SOFTWARE, policy.kind)
    assertEquals(1, policy.switches)
    assertEquals(DecoderPolicy.SwitchReason.NO_OUTPUT_AFTER_JOIN, policy.lastSwitchReason)
  }

  @Test
  fun aPictureKeepsTheHardwareAndAKeyPictureKeepsItFromRuleOne() {
    val outputs = DecoderPolicy()
    queue(outputs, 10)
    outputs.onOutput()
    assertEquals(PolicyAction.NONE, queue(outputs, 200))
    // A key picture with its picture out: the hardware stays for good
    val keyed = DecoderPolicy()
    queue(keyed, 1, key = true)
    keyed.onOutput()
    assertEquals(PolicyAction.NONE, queue(keyed, 200))
    assertEquals(DecoderKind.HARDWARE, keyed.kind)
    assertEquals(0, keyed.switches)
  }

  @Test
  fun backToHardwareAtAKeyPictureOnceThenSoftwareForTheSession() {
    val policy = DecoderPolicy()
    queue(policy, DecoderPolicy.JOIN_UNITS)
    assertEquals(DecoderKind.SOFTWARE, policy.kind)
    queue(policy, 50)
    assertEquals(PolicyAction.SWITCH_TO_HARDWARE, policy.beforeQueue(isKey = true))
    assertEquals(DecoderKind.HARDWARE, policy.kind)
    policy.afterQueue(isKey = true)
    // Nothing comes out again within thirty units: software for the rest of the session
    assertEquals(PolicyAction.SWITCH_TO_SOFTWARE, queue(policy, DecoderPolicy.RETRY_UNITS - 1))
    assertTrue(policy.softwareForSession)
    assertEquals(DecoderPolicy.SwitchReason.HARDWARE_RETRY_FAILED, policy.lastSwitchReason)
    assertEquals(PolicyAction.NONE, policy.beforeQueue(isKey = true))
    assertEquals(DecoderKind.SOFTWARE, policy.kind)
    assertEquals(3, policy.switches)
  }

  @Test
  fun aHardwareDecoderThatShowsAPictureAfterTheKeyPictureStays() {
    val policy = DecoderPolicy()
    queue(policy, DecoderPolicy.JOIN_UNITS)
    policy.beforeQueue(isKey = true)
    policy.afterQueue(isKey = true)
    policy.onOutput()
    assertEquals(PolicyAction.NONE, queue(policy, 300))
    assertEquals(DecoderKind.HARDWARE, policy.kind)
    assertFalse(policy.softwareForSession)
  }

  @Test
  fun twoFatalErrorsOnHardwareMeanSoftware() {
    val policy = DecoderPolicy()
    assertEquals(PolicyAction.NONE, policy.onError(recoverable = false, transient = true))
    assertEquals(PolicyAction.RESTART_SAME, policy.onError(recoverable = true, transient = false))
    assertEquals(PolicyAction.RESTART_SAME, policy.onError(recoverable = false, transient = false))
    assertEquals(PolicyAction.SWITCH_TO_SOFTWARE, policy.onError(recoverable = false, transient = false))
    assertTrue(policy.softwareForSession)
    assertEquals(DecoderPolicy.SwitchReason.FATAL_ERRORS, policy.lastSwitchReason)
    assertEquals(PolicyAction.RESTART_SAME, policy.onError(recoverable = false, transient = false))
    assertEquals(PolicyAction.FAIL, policy.onError(recoverable = false, transient = false))
  }

  @Test
  fun aBacklogOfSixteenFlushesAndIsCounted() {
    val policy = DecoderPolicy()
    assertFalse(policy.mustFlush(DecoderPolicy.MAX_QUEUED_UNITS))
    assertTrue(policy.mustFlush(DecoderPolicy.MAX_QUEUED_UNITS + 1))
    queue(policy, 80)
    policy.onFlushed()
    assertEquals(1, policy.flushes)
    // The flush starts the count of the join rule again
    assertEquals(PolicyAction.NONE, queue(policy, 80))
  }

  @Test
  fun aResolutionChangeConfiguresAgain() {
    val policy = DecoderPolicy()
    val seed = ProfileRegistry.seed20261023!!
    val smaller = StreamDescription(seed.vps, seed.sps, seed.pps, seed.info.copy(codedWidth = 1280, codedHeight = 720))
    assertTrue(policy.mustReconfigure(null, seed))
    assertFalse(policy.mustReconfigure(seed, seed))
    assertTrue(policy.mustReconfigure(seed, smaller))
  }

  @Test
  fun theChoiceOfThePilotIsKept() {
    val software = DecoderPolicy(choice = DecoderChoice.SOFTWARE)
    assertEquals(DecoderKind.SOFTWARE, software.kind)
    assertEquals(PolicyAction.NONE, software.beforeQueue(isKey = true))
    val hardware = DecoderPolicy(choice = DecoderChoice.HARDWARE)
    assertEquals(PolicyAction.NONE, queue(hardware, 500))
    assertEquals(DecoderKind.HARDWARE, hardware.kind)
    val noHardware = DecoderPolicy(candidates = DecoderPolicy.GENERIC_CANDIDATES.filter { !it.hardware })
    assertEquals(DecoderKind.SOFTWARE, noHardware.kind)
    // Software asked for on a device that has none: the hardware runs
    val questSoftware = DecoderPolicy(choice = DecoderChoice.SOFTWARE, candidates = quest)
    assertEquals(questLowLatency, questSoftware.current)
    assertEquals(null, DecoderPolicy(candidates = emptyList()).current)
  }

  @Test
  fun aDecoderThePlatformWillNotMakeGivesWayToTheNextOne() {
    val policy = DecoderPolicy()
    assertEquals(PolicyAction.SWITCH_TO_SOFTWARE, policy.onCandidateRefused())
    assertTrue(policy.softwareForSession)
    assertEquals(PolicyAction.FAIL, policy.onCandidateRefused())
    // On the Quest: the low latency decoder refused, the other one; both refused, nothing
    val onQuest = DecoderPolicy(candidates = quest)
    assertEquals(PolicyAction.SWITCH_DECODER, onQuest.onCandidateRefused())
    assertEquals(questHardware, onQuest.current)
    assertEquals(PolicyAction.FAIL, onQuest.onCandidateRefused())
    // A manual hardware choice never falls to software
    val hardwareOnly = DecoderPolicy(choice = DecoderChoice.HARDWARE)
    assertEquals(PolicyAction.FAIL, hardwareOnly.onCandidateRefused())
  }

  @Test
  fun noPictureFortyUnitsAfterAKeyPictureMeansTheNextDecoder() {
    val policy = DecoderPolicy(candidates = quest)
    assertEquals(questLowLatency, policy.current)
    // The key picture and 38 more units: still waiting
    assertEquals(PolicyAction.NONE, keyThenNothing(policy, DecoderPolicy.NO_PICTURE_UNITS - 2, stepNs = 1_000_000))
    assertEquals(questLowLatency, policy.current)
    policy.beforeQueue(isKey = false)
    assertEquals(PolicyAction.SWITCH_DECODER, policy.afterQueue(isKey = false, nowNs = 40_000_000))
    assertEquals(questHardware, policy.current)
    assertEquals(DecoderKind.HARDWARE, policy.kind)
    assertEquals(1, policy.switches)
    assertEquals(DecoderPolicy.SwitchReason.NO_PICTURE_WITH_KEY, policy.lastSwitchReason)
    assertEquals(listOf(questLowLatency.name), policy.takeGaveNoPicture())
    assertEquals(emptyList<String>(), policy.takeGaveNoPicture())
    // The next decoder shows a picture: it stays
    keyThenNothing(policy, 3)
    policy.onOutput()
    assertEquals(PolicyAction.NONE, queue(policy, 300))
    assertEquals(questHardware, policy.current)
  }

  @Test
  fun noPictureTwoSecondsAfterAKeyPictureMeansTheNextDecoderButAStallIsNotBlamed() {
    // Units 300 ms apart: the time decides at 2 s, the eighth unit after the key picture
    val slow = DecoderPolicy(candidates = quest)
    assertEquals(PolicyAction.SWITCH_DECODER, keyThenNothing(slow, 20, stepNs = 300_000_000))
    assertEquals(questHardware, slow.current)
    // A key picture, then the input stalls for 5 s and three units come: too few to blame the decoder
    val stalled = DecoderPolicy(candidates = quest)
    stalled.beforeQueue(isKey = true)
    stalled.afterQueue(isKey = true, nowNs = 0)
    for (i in 1..3) {
      assertEquals(PolicyAction.NONE, stalled.afterQueue(isKey = false, nowNs = 5_000_000_000L + i))
    }
    assertEquals(questLowLatency, stalled.current)
  }

  @Test
  fun withoutAKeyPictureTheNewRuleWaits() {
    // The Quest has no software decoder, so rule 1 cannot act, and rule 6 needs a key picture: nothing moves
    val policy = DecoderPolicy(candidates = quest)
    assertEquals(PolicyAction.NONE, queue(policy, 1000))
    assertEquals(questLowLatency, policy.current)
    assertEquals(null, policy.lastSwitchReason)
  }

  @Test
  fun theOrderIsLowLatencyHardwareThenHardwareThenSoftware() {
    assertEquals(
      listOf("c2.qti.hevc.decoder.low_latency", "c2.qti.hevc.decoder", HevcDecoders.SOFTWARE_NAME),
      phone.map { it.name },
    )
    val policy = DecoderPolicy(candidates = phone)
    assertEquals("c2.qti.hevc.decoder.low_latency", policy.current?.name)
    assertEquals(PolicyAction.SWITCH_DECODER, keyThenNothing(policy, 100))
    assertEquals("c2.qti.hevc.decoder", policy.current?.name)
    // The decoder the feed configures next with KEY_LOW_LATENCY, since the platform reports the feature
    assertTrue(policy.current!!.lowLatencyFeature)
    assertEquals(PolicyAction.SWITCH_DECODER, keyThenNothing(policy, 100))
    assertEquals(HevcDecoders.SOFTWARE_NAME, policy.current?.name)
    assertEquals(DecoderKind.SOFTWARE, policy.kind)
    assertTrue(policy.softwareForSession)
    assertEquals(2, policy.switches)
    assertEquals(listOf("c2.qti.hevc.decoder.low_latency", "c2.qti.hevc.decoder"), policy.takeGaveNoPicture())
  }

  @Test
  fun whenNoOtherDecoderIsLeftTheLastOneStaysAndThePageSaysSo() {
    val policy = DecoderPolicy(candidates = quest)
    assertEquals(PolicyAction.SWITCH_DECODER, keyThenNothing(policy, 100))
    assertEquals(PolicyAction.NONE, keyThenNothing(policy, 100))
    assertEquals(questHardware, policy.current)
    assertEquals(DecoderPolicy.SwitchReason.NO_PICTURE_NOTHING_LEFT, policy.lastSwitchReason)
    assertEquals(listOf(questLowLatency.name, questHardware.name), policy.takeGaveNoPicture())
    // No going back and forth
    assertEquals(PolicyAction.NONE, keyThenNothing(policy, 300))
    assertEquals(1, policy.switches)
    assertEquals(emptyList<String>(), policy.takeGaveNoPicture())
  }

  @Test
  fun aManualChoiceStaysWithinItsKind() {
    val hardware = DecoderPolicy(choice = DecoderChoice.HARDWARE, candidates = phone)
    assertEquals(PolicyAction.SWITCH_DECODER, keyThenNothing(hardware, 100))
    assertEquals("c2.qti.hevc.decoder", hardware.current?.name)
    assertEquals(PolicyAction.NONE, keyThenNothing(hardware, 100))
    assertEquals(DecoderKind.HARDWARE, hardware.kind)
    assertEquals(DecoderPolicy.SwitchReason.NO_PICTURE_NOTHING_LEFT, hardware.lastSwitchReason)
  }

  @Test
  fun theDeviceRemembersADecoderThatGaveNoPictureUntilAnUpdate() {
    val preferences = MemoryKeyValueStore()
    val memory = DecoderMemory(preferences, build = "eureka/14 1729780000000", wallMs = { 1_000L })
    assertFalse(memory.gaveNoPicture(questLowLatency.name))
    memory.remember(questLowLatency.name)
    assertTrue(memory.gaveNoPicture(questLowLatency.name))
    assertFalse(memory.gaveNoPicture(questHardware.name))
    // The next automatic session starts from the next decoder and says why
    val next = DecoderPolicy(candidates = quest, gaveNoPictureBefore = memory::gaveNoPicture)
    assertEquals(questHardware, next.current)
    assertEquals(listOf(questLowLatency.name), next.skippedAtStart)
    assertEquals(0, next.switches)
    // Choosing automatic again forgets nothing; a manual choice overrides the memory
    assertEquals(questHardware, DecoderPolicy(DecoderChoice.AUTOMATIC, quest, memory::gaveNoPicture).current)
    val manual = DecoderPolicy(DecoderChoice.HARDWARE, quest, memory::gaveNoPicture)
    assertEquals(questLowLatency, manual.current)
    assertEquals(emptyList<String>(), manual.skippedAtStart)
    // A new install of the app or a system update gives the decoder its chance again
    val updated = DecoderMemory(preferences, build = "eureka/14 1729790000000")
    assertFalse(updated.gaveNoPicture(questLowLatency.name))
    memory.forget(questLowLatency.name)
    assertFalse(memory.gaveNoPicture(questLowLatency.name))
  }

  @Test
  fun whenEveryDecoderIsRememberedTheOrderStartsAgainFromTheFirst() {
    val all = DecoderPolicy(candidates = quest, gaveNoPictureBefore = { true })
    assertEquals(questLowLatency, all.current)
    assertEquals(emptyList<String>(), all.skippedAtStart)
    // A remembered decoder is never the next of rule 6, but it is tried when the others will not even start
    val one = DecoderPolicy(candidates = quest, gaveNoPictureBefore = { it == questLowLatency.name })
    assertEquals(questHardware, one.current)
    assertEquals(PolicyAction.NONE, keyThenNothing(one, 100))
    assertEquals(DecoderPolicy.SwitchReason.NO_PICTURE_NOTHING_LEFT, one.lastSwitchReason)
    val refused = DecoderPolicy(candidates = quest, gaveNoPictureBefore = { it == questLowLatency.name })
    assertEquals(PolicyAction.SWITCH_DECODER, refused.onCandidateRefused())
    assertEquals(questLowLatency, refused.current)
  }

  @Test
  fun twoFatalErrorsWithNoSoftwareDecoderMeanTheNextHardwareOne() {
    val policy = DecoderPolicy(candidates = quest)
    assertEquals(PolicyAction.RESTART_SAME, policy.onError(recoverable = false, transient = false))
    assertEquals(PolicyAction.SWITCH_DECODER, policy.onError(recoverable = false, transient = false))
    assertEquals(questHardware, policy.current)
    assertEquals(DecoderPolicy.SwitchReason.FATAL_ERRORS, policy.lastSwitchReason)
    // Errors are not a missing picture: nothing is remembered
    assertEquals(emptyList<String>(), policy.takeGaveNoPicture())
    assertEquals(PolicyAction.RESTART_SAME, policy.onError(recoverable = false, transient = false))
    assertEquals(PolicyAction.RESTART_SAME, policy.onError(recoverable = false, transient = false))
    assertEquals(questHardware, policy.current)
  }

  @Test
  fun aHardwareDecoderThatFailsItsRetryIsRemembered() {
    val policy = DecoderPolicy()
    queue(policy, DecoderPolicy.JOIN_UNITS)
    policy.beforeQueue(isKey = true)
    policy.afterQueue(isKey = true)
    queue(policy, DecoderPolicy.RETRY_UNITS - 1)
    assertEquals(DecoderPolicy.SwitchReason.HARDWARE_RETRY_FAILED, policy.lastSwitchReason)
    assertEquals(listOf("hardware"), policy.takeGaveNoPicture())
  }

  @Test
  fun aCodecStartsFromTheKeptKeyPictureWhenTheNextUnitIsNotOne() {
    val seed = ProfileRegistry.seed20261023!!
    val other = StreamDescription(seed.vps, seed.sps, seed.pps + byteArrayOf(0x40), seed.info)
    val key = HevcSamples.unitOf(
      HevcSamples.DELIMITER,
      HevcSamples.VPS,
      HevcSamples.SPS,
      HevcSamples.PPS,
      HevcSamples.slice(type = 20),
    )
    val p = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(2))
    val primer = KeyPrimer()
    // Nothing kept, or a codec already under way: nothing to add
    primer.onCodecStarted()
    assertEquals(null, primer.before(p, seed))
    primer.keep(p, seed)
    assertFalse(primer.holds)
    primer.keep(key, seed)
    assertTrue(primer.holds)
    assertEquals(null, primer.before(p, seed))
    // A codec starts on a P picture: the kept key unit goes first, once
    primer.onCodecStarted()
    assertTrue(primer.before(p, seed) === key)
    assertEquals(null, primer.before(p, seed))
    // A codec that starts on a key picture needs nothing
    primer.onCodecStarted()
    assertEquals(null, primer.before(key, seed))
    assertEquals(null, primer.before(p, seed))
    // Other parameter sets: the kept unit would not decode
    primer.onCodecStarted()
    assertEquals(null, primer.before(p, other))
    // A new source forgets it
    primer.clear()
    primer.onCodecStarted()
    assertEquals(null, primer.before(p, seed))
  }

  @Test
  fun severalPicturesWithinEightMillisecondsShowOnlyTheNewest() {
    val pacer = DisplayPacer()
    assertEquals(DisplayPacer.Decision.RenderNow, pacer.onOutput(0))
    val second = pacer.onOutput(2_000_000)
    assertEquals(DisplayPacer.Decision.Hold(atNs = 8_000_000, dropHeld = false), second)
    val third = pacer.onOutput(4_000_000)
    assertEquals(DisplayPacer.Decision.Hold(atNs = 8_000_000, dropHeld = true), third)
    assertTrue(pacer.onTimer(8_000_000))
    assertFalse(pacer.onTimer(9_000_000))
    // A steady stream at 30 pictures per second is shown with no wait
    assertEquals(DisplayPacer.Decision.RenderNow, pacer.onOutput(41_000_000))
    assertEquals(DisplayPacer.Decision.RenderNow, pacer.onOutput(74_000_000))
  }

  @Test
  fun decodersAreTriedLowLatencyHardwareFirstThenHardwareThenThePlatformSoftware() {
    val ordered = HevcDecoders.order(
      listOf(
        DecoderCandidate("c2.android.hevc.decoder", hardware = false, lowLatencyFeature = false),
        DecoderCandidate("c2.exynos.hevc.decoder", hardware = true, lowLatencyFeature = false),
        DecoderCandidate("OMX.google.hevc.decoder", hardware = false, lowLatencyFeature = false),
        DecoderCandidate("c2.exynos.hevc.decoder.low_latency", hardware = true, lowLatencyFeature = true),
      )
    )
    assertEquals(
      listOf(
        "c2.exynos.hevc.decoder.low_latency",
        "c2.exynos.hevc.decoder",
        "c2.android.hevc.decoder",
        "OMX.google.hevc.decoder",
      ),
      ordered.map { it.name },
    )
    assertTrue(HevcDecoders.isQualcomm("c2.qti.hevc.decoder"))
    assertTrue(HevcDecoders.isQualcomm("OMX.qcom.video.decoder.hevc"))
    assertFalse(HevcDecoders.isQualcomm("c2.exynos.hevc.decoder"))
    assertTrue(HevcDecoders.isSoftwareName("c2.android.hevc.decoder"))
  }
}
