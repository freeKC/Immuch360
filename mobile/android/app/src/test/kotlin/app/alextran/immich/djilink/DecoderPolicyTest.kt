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
  fun aPictureOrAKeyPictureKeepsTheHardware() {
    val outputs = DecoderPolicy()
    queue(outputs, 10)
    outputs.onOutput()
    assertEquals(PolicyAction.NONE, queue(outputs, 200))
    val keyed = DecoderPolicy()
    queue(keyed, 1, key = true)
    assertEquals(PolicyAction.NONE, queue(keyed, 200))
    assertEquals(DecoderKind.HARDWARE, keyed.kind)
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
    val noHardware = DecoderPolicy(hardwareAvailable = false)
    assertEquals(DecoderKind.SOFTWARE, noHardware.kind)
  }

  @Test
  fun aDeviceWithoutTheKindAskedForFallsBack() {
    val policy = DecoderPolicy()
    assertEquals(PolicyAction.SWITCH_TO_SOFTWARE, policy.onKindUnavailable())
    assertEquals(PolicyAction.FAIL, policy.onKindUnavailable())
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
