package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Automatic, Full stream and Steady stream (p2/relay-bandwidth-2026-10-25.md, 7.7): when a receiver goes steady, when
 * it goes back, the memory of a steady flight, and what the setting and the phone allow.
 */
class RelayStreamPolicyTest {
  private val ms = 1_000_000L
  private val second = 1_000_000_000L

  @Test
  fun aTvGoesSteadyWhenItsOldestUnitPasses400MillisecondsTwiceWithinTenSeconds() {
    val policy = RelayStreamPolicy()
    assertNull(policy.onFullTick(0, 450 * ms, dropped = false))
    // Still over: the same passing
    assertNull(policy.onFullTick(100 * ms, 500 * ms, dropped = false))
    assertNull(policy.onFullTick(200 * ms, 10 * ms, dropped = false))
    assertEquals(RelaySwitchWhy.QUEUE_TWICE, policy.onFullTick(5 * second, 420 * ms, dropped = false))
    assertEquals(RelayStream.STEADY, policy.stream)
  }

  @Test
  fun twoPassingsMoreThanTenSecondsApartAreNotEnough() {
    val policy = RelayStreamPolicy()
    assertNull(policy.onFullTick(0, 450 * ms, dropped = false))
    assertNull(policy.onFullTick(100 * ms, 0, dropped = false))
    assertNull(policy.onFullTick(11 * second, 450 * ms, dropped = false))
    assertEquals(RelayStream.FULL, policy.stream)
  }

  @Test
  fun aTvGoesSteadyAtOnceWhenItsOldestUnitPasses800Milliseconds() {
    val policy = RelayStreamPolicy()
    assertNull(policy.onFullTick(0, 800 * ms, dropped = false))
    assertEquals(RelaySwitchWhy.QUEUE_LONG, policy.onFullTick(100 * ms, 801 * ms, dropped = false))
  }

  @Test
  fun aDropSendsItSteadyAtOnce() {
    val policy = RelayStreamPolicy()
    assertEquals(RelaySwitchWhy.DROP, policy.onFullTick(0, 0, dropped = true))
  }

  @Test
  fun aHeadsetHasShorterBounds() {
    val twice = RelayStreamPolicy(headset = true)
    assertNull(twice.onFullTick(0, 210 * ms, dropped = false))
    assertNull(twice.onFullTick(100 * ms, 0, dropped = false))
    assertEquals(RelaySwitchWhy.QUEUE_TWICE, twice.onFullTick(2 * second, 210 * ms, dropped = false))
    val once = RelayStreamPolicy(headset = true)
    assertEquals(RelaySwitchWhy.QUEUE_LONG, once.onFullTick(0, 401 * ms, dropped = false))
    // A TV takes these in its stride
    val tv = RelayStreamPolicy()
    assertNull(tv.onFullTick(0, 401 * ms, dropped = false))
  }

  /** A steady receiver quiet since [quietFromNs] up to [toNs] */
  private fun quiet(policy: RelayStreamPolicy, quietFromNs: Long, toNs: Long) {
    var now = quietFromNs
    while (now <= toNs) {
      policy.onSteadyTick(now, 10 * ms)
      now += 100 * ms
    }
  }

  @Test
  fun aSteadyReceiverGoesBackOnlyAtADroneKeyAfterThirtyQuietSecondsWithRoomForTheDronesRate() {
    val policy = RelayStreamPolicy()
    policy.onFullTick(0, 0, dropped = true)
    assertEquals(RelayStream.STEADY, policy.stream)
    quiet(policy, 1 * second, 20 * second)
    // Not 30 s yet
    assertFalse(policy.backToFullAt(20 * second, droneRateBps = 4_800_000, bestSecondBps = 9_000_000))
    quiet(policy, 20 * second + 100 * ms, 32 * second)
    // Not enough room: 1.5 times 4.8 Mbit/s is 7.2
    assertFalse(policy.backToFullAt(32 * second, droneRateBps = 4_800_000, bestSecondBps = 7_000_000))
    // The flight's rate needs 26.9 Mbit/s
    assertFalse(policy.backToFullAt(32 * second, droneRateBps = 17_900_000, bestSecondBps = 9_000_000))
    assertTrue(policy.backToFullAt(32 * second, droneRateBps = 4_800_000, bestSecondBps = 7_300_000))
    assertEquals(RelayStream.FULL, policy.stream)
  }

  @Test
  fun aLateUnitStartsTheQuietAgain() {
    val policy = RelayStreamPolicy()
    policy.onFullTick(0, 0, dropped = true)
    quiet(policy, 0, 25 * second)
    policy.onSteadyTick(25 * second + 50 * ms, 60 * ms)
    quiet(policy, 26 * second, 40 * second)
    assertFalse(policy.backToFullAt(40 * second, 4_800_000, 20_000_000))
    quiet(policy, 40 * second + 100 * ms, 56 * second)
    assertTrue(policy.backToFullAt(56 * second, 4_800_000, 20_000_000))
  }

  @Test
  fun theSettingAndThePhoneDecideFirst() {
    val steady = RelayStream.STEADY
    val full = RelayStream.FULL
    // Automatic follows the receiver's own policy
    assertEquals(steady, relayTargetStream(RelayQuality.AUTOMATIC, capable = true, usable = true, automatic = steady))
    assertEquals(full, relayTargetStream(RelayQuality.AUTOMATIC, capable = true, usable = true, automatic = full))
    // Full stream is the off switch; Steady stream forces the phone's stream
    assertEquals(full, relayTargetStream(RelayQuality.FULL, capable = true, usable = true, automatic = steady))
    assertEquals(steady, relayTargetStream(RelayQuality.STEADY, capable = true, usable = true, automatic = full))
    // A receiver of an earlier build is always full
    assertEquals(full, relayTargetStream(RelayQuality.STEADY, capable = false, usable = true, automatic = steady))
    // No steady stream on this phone, or it stopped: Automatic and Steady act as Full
    assertEquals(full, relayTargetStream(RelayQuality.AUTOMATIC, capable = true, usable = false, automatic = steady))
    assertEquals(full, relayTargetStream(RelayQuality.STEADY, capable = true, usable = false, automatic = steady))
  }

  @Test
  fun theQualityIsReadFromItsWordAutomaticByDefault() {
    assertEquals(RelayQuality.FULL, RelayQuality.of("full"))
    assertEquals(RelayQuality.STEADY, RelayQuality.of("steady"))
    assertEquals(RelayQuality.AUTOMATIC, RelayQuality.of("automatic"))
    assertEquals(RelayQuality.AUTOMATIC, RelayQuality.of(null))
    assertEquals(RelayQuality.AUTOMATIC, RelayQuality.of("anything"))
  }

  @Test
  fun theDronesRateInEachPhaseIsTheMedianOfItsLastSecondsOrThatOf25October() {
    val memory = DroneRateMemory()
    assertEquals(DroneRateMemory.FLYING_BPS, memory.expected(true))
    assertEquals(DroneRateMemory.GROUND_BPS, memory.expected(false))
    assertEquals(DroneRateMemory.FLYING_BPS, memory.expected(null))
    repeat(5) { memory.onSecond(5_000_000, motorsOn = false) }
    memory.onSecond(17_000_000, motorsOn = false)
    memory.onSecond(3_000_000, motorsOn = null)
    assertEquals(5_000_000L, memory.expected(false))
    repeat(3) { memory.onSecond(18_200_000, motorsOn = true) }
    assertEquals(18_200_000L, memory.expected(true))
    assertEquals(18_200_000L, memory.expected(null))
  }

  @Test
  fun aReceiverIsRememberedByItsNameAndAddress() {
    val memory = RelaySteadyMemory()
    val tv = memory.key("Salon 2", "192.168.0.142")
    assertFalse(memory.knows(tv))
    memory.remember(tv)
    assertTrue(memory.knows(memory.key("Salon 2", "192.168.0.142")))
    assertFalse(memory.knows(memory.key("Salon 2", "192.168.0.143")))
    memory.clear()
    assertFalse(memory.knows(tv))
  }
}
