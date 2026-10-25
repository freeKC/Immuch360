package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The rate of a steady receiver (p2/relay-bandwidth-2026-10-25.md, 7.6): each rule alone, then the capacity the Wi-Fi
 * had toward the TV in the flights of 25 October (relay-capacity-20261025.csv, made by make_relay_capacity.py beside
 * it) replayed through the controller and a model queue. The replay is a guard against regressions, not a promise for
 * another link.
 */
class RelayRateControlTest {
  private val ms = 1_000_000L
  private val second = 1_000_000_000L

  @Test
  fun itStartsAtEightMegabits() {
    val rate = RelayRateController()
    assertEquals(8_000_000, rate.allowedBps)
    assertFalse(rate.slow)
  }

  @Test
  fun anOldUnitLowersTheRateToFourFifthsOfWhatTheLastSecondCarriedAtMostEveryHalfSecond() {
    val rate = RelayRateController()
    assertTrue(rate.onTick(0, 260 * ms, 5_000_000, 0, dropped = false))
    assertEquals(4_000_000, rate.allowedBps)
    // 100 ms later, still old: not again
    rate.onTick(100 * ms, 300 * ms, 3_000_000, 0, dropped = false)
    assertEquals(4_000_000, rate.allowedBps)
    // 500 ms after the first
    rate.onTick(500 * ms, 300 * ms, 3_000_000, 0, dropped = false)
    assertEquals(2_400_000, rate.allowedBps)
    // At 250 ms exactly: no rule
    rate.onTick(1_100 * ms, 250 * ms, 1_000_000, 0, dropped = false)
    assertEquals(2_400_000, rate.allowedBps)
  }

  @Test
  fun aHeadsetLowersAt150Milliseconds() {
    val tv = RelayRateController(headset = false)
    val headset = RelayRateController(headset = true)
    tv.onTick(0, 160 * ms, 5_000_000, 0, dropped = false)
    headset.onTick(0, 160 * ms, 5_000_000, 0, dropped = false)
    assertEquals(8_000_000, tv.allowedBps)
    assertEquals(4_000_000, headset.allowedBps)
  }

  @Test
  fun aDropLowersTheRateToSevenTenthsOfWhatTheLastSecondCarried() {
    val rate = RelayRateController()
    rate.onTick(0, 0, 6_000_000, 0, dropped = true)
    assertEquals(4_200_000, rate.allowedBps)
    // A drop right after a lowering is not held back
    rate.onTick(100 * ms, 0, 4_000_000, 0, dropped = true)
    assertEquals(2_800_000, rate.allowedBps)
  }

  @Test
  fun aRuleThatLowersNeverRaisesEvenWhenABacklogLeftFast() {
    val rate = RelayRateController()
    rate.onTick(0, 400 * ms, 30_000_000, 0, dropped = false)
    assertEquals(8_000_000, rate.allowedBps)
    rate.onTick(500 * ms, 0, 20_000_000, 0, dropped = true)
    assertEquals(8_000_000, rate.allowedBps)
  }

  @Test
  fun twoClearSecondsRaiseTheRateByAQuarter() {
    val rate = RelayRateController()
    var now = 0L
    while (now < 2 * second) {
      rate.onTick(now, 10 * ms, 8_000_000, 5 * ms, dropped = false)
      now += 100 * ms
    }
    rate.onTick(now, 10 * ms, 8_000_000, 5 * ms, dropped = false)
    assertEquals(10_000_000, rate.allowedBps)
    // A write over 50 ms starts the clear time again
    now += 100 * ms
    rate.onTick(now, 10 * ms, 8_000_000, 60 * ms, dropped = false)
    val after = now
    while (now < after + 2 * second) {
      now += 100 * ms
      rate.onTick(now, 10 * ms, 8_000_000, 5 * ms, dropped = false)
    }
    assertEquals(10_000_000, rate.allowedBps)
    now += 100 * ms
    rate.onTick(now, 10 * ms, 8_000_000, 5 * ms, dropped = false)
    assertEquals(12_000_000, rate.allowedBps)
  }

  @Test
  fun theRateStaysWithinItsBounds() {
    val rate = RelayRateController()
    rate.onTick(0, 0, 100_000, 0, dropped = true)
    assertEquals(RelayRateController.MIN_BPS, rate.allowedBps)
    var now = 0L
    repeat(400) {
      now += 100 * ms
      rate.onTick(now, 0, 1_000_000, 0, dropped = false)
    }
    assertEquals(RelayRateController.MAX_BPS, rate.allowedBps)
    assertEquals(RelayRateController.MIN_BPS, rate.minBps)
    assertEquals(RelayRateController.MAX_BPS, rate.maxBps)
    assertTrue(rate.changes >= 8)
  }

  @Test
  fun atTheFloorAndStillLateItGoesToFifteenAndBackAfterFiveClearSecondsAtThreeMegabits() {
    val rate = RelayRateController()
    rate.onTick(0, 0, 1_000_000, 0, dropped = true)
    assertEquals(RelayRateController.MIN_BPS, rate.allowedBps)
    assertFalse(rate.slow)
    rate.onTick(600 * ms, 300 * ms, 1_000_000, 0, dropped = false)
    assertTrue(rate.slow)
    // Clear from now on: the rate climbs back by a quarter every 2 s, then 5 s at 3 Mbit/s or more
    var now = 700 * ms
    var backAt: Long? = null
    while (now < 30 * second && backAt == null) {
      rate.onTick(now, 0, 2_000_000, 0, dropped = false)
      if (!rate.slow) {
        backAt = now
      }
      now += 100 * ms
    }
    val back = backAt!!
    assertTrue("back at ${back / ms} ms", rate.allowedBps >= RelayRateController.SLOW_BACK_BPS)
    // 1.5, 1.875, 2.34, 2.93, 3.66 Mbit/s: four raises of 2 s, then 5 s at 3.66
    assertTrue("back at ${back / ms} ms", back in (12 * second)..(15 * second))
  }

  @Test
  fun theEncoderTakesTheLeastAllowedRateAtMostEveryHalfSecondUnderTheThermalCap() {
    val encoder = RelayEncoderRate()
    assertNull(encoder.next(emptyList(), null, 0))
    assertEquals(4_000_000, encoder.next(listOf(8_000_000, 4_000_000), null, 0))
    // Unchanged: nothing to set
    assertNull(encoder.next(listOf(4_000_000), null, 600 * ms))
    // Changed, but too soon
    assertNull(encoder.next(listOf(3_000_000), null, 300 * ms))
    assertEquals(3_000_000, encoder.next(listOf(3_000_000), null, 600 * ms))
    assertEquals(6_000_000, encoder.next(listOf(12_000_000), 6_000_000, 1_200 * ms))
    assertEquals(6_000_000, encoder.currentBps)
  }

  @Test
  fun theUnsentBytesBoundIsATenthOfASecondOfTheRateAndAtLeast32KiB() {
    assertEquals(100_000, RelayLowWater.bytesFor(8_000_000))
    assertEquals(32 * 1024, RelayLowWater.bytesFor(1_500_000))
    assertEquals(150_000, RelayLowWater.bytesFor(12_000_000))
    assertTrue(RelayLowWater.shouldApply(null, 100_000))
    assertFalse(RelayLowWater.shouldApply(100_000, 120_000))
    assertTrue(RelayLowWater.shouldApply(100_000, 130_000))
    assertTrue(RelayLowWater.shouldApply(262_144, 100_000))
  }

  /** One second of the fixture: what the path took in it, at least the drone's 17.9 Mbit/s when it kept up */
  private fun capacity(): List<Double> {
    val text = javaClass.classLoader!!.getResourceAsStream("djilink/relay-capacity-20261025.csv")!!
      .bufferedReader().readText()
    return text.lines().filter { it.isNotBlank() && !it.startsWith("#") && !it.startsWith("streamS") }.map { line ->
      val cells = line.split(',')
      if (cells[2] == "1") cells[1].toDouble() * 1024 * 8 else 17.9e6
    }
  }

  private class Replay(val drops: Int, val underAtEnd: Double, val underAll: Double, val medianBps: Double)

  /**
   * The flights' capacity in steps of 100 ms (the relay's tick): units at the rate allowed, 30 a second (15 when slow),
   * into a queue that the path empties at its capacity, dropped whole when the oldest passes the TV's steady bound
   * (0.5 s); the controller on each step
   */
  private fun replay(seconds: List<Double>, adaptive: Boolean = true): Replay {
    val rate = RelayRateController()
    val bound = RelayQueue.STEADY_TV_MAX_AGE_NS
    val queue = ArrayDeque<DoubleArray>()
    val carried = ArrayDeque<DoubleArray>()
    var drops = 0
    var underEnd = 0
    var underAll = 0
    var maxAge = 0L
    var produce = 0.0
    val rates = mutableListOf<Int>()
    for (step in 0 until seconds.size * 10) {
      val now = step * 100 * ms
      val bps = if (adaptive) rate.allowedBps else RelayRateController.START_BPS
      val perSecond = if (rate.slow) 15 else 30
      produce += perSecond / 10.0
      while (produce >= 1 - 1e-9) {
        produce -= 1
        queue.addLast(doubleArrayOf(now.toDouble(), bps / 8.0 / perSecond))
      }
      var budget = seconds[step / 10] / 8 / 10
      while (queue.isNotEmpty() && budget > 0) {
        val head = queue.first()
        val take = minOf(budget, head[1])
        head[1] -= take
        budget -= take
        carried.addLast(doubleArrayOf(now.toDouble(), take))
        if (head[1] <= 1e-9) {
          queue.removeFirst()
        }
      }
      while (carried.isNotEmpty() && now - carried.first()[0] >= second - 1) {
        carried.removeFirst()
      }
      var age = queue.firstOrNull()?.let { now - it[0].toLong() } ?: 0L
      var dropped = false
      if (age > bound) {
        queue.clear()
        drops += 1
        dropped = true
        age = 0
      }
      maxAge = maxOf(maxAge, age)
      if ((step + 1) % 10 == 0) {
        if (age < 300 * ms) underEnd += 1
        if (maxAge < 300 * ms) underAll += 1
        maxAge = 0
      }
      val carriedBps = (carried.sumOf { it[1] } * 8).toLong()
      rate.onTick(now, age, carriedBps, 0, dropped)
      rates += rate.allowedBps
    }
    val sorted = rates.sorted()
    val count = seconds.size.toDouble()
    return Replay(drops, underEnd / count, underAll / count, sorted[sorted.size / 2].toDouble())
  }

  @Test
  fun theFlightsOf25OctoberReplayedGiveFewCleanDropsAndAShortQueue() {
    val seconds = capacity()
    assertEquals(250, seconds.size)
    val adapted = replay(seconds)
    val fixed = replay(seconds, adaptive = false)
    println(
      "25 October flights, 250 s: adapted ${adapted.drops} drops, ${"%.1f".format(adapted.underAtEnd * 100)} % of " +
        "seconds under 0.3 s at their end (${"%.1f".format(adapted.underAll * 100)} % all through), median " +
        "${"%.1f".format(adapted.medianBps / 1e6)} Mbit/s; fixed 8 Mbit/s ${fixed.drops} drops, " +
        "${"%.1f".format(fixed.underAtEnd * 100)} %",
    )
    assertTrue("drops ${adapted.drops}", adapted.drops <= 40)
    assertTrue("under 0.3 s at the end of ${adapted.underAtEnd}", adapted.underAtEnd >= 0.85)
    assertTrue("under 0.3 s all through ${adapted.underAll}", adapted.underAll >= 0.80)
    // The adapted rate does better than a fixed 8 Mbit/s on the same link
    assertTrue(adapted.drops < fixed.drops)
    assertTrue(adapted.underAtEnd > fixed.underAtEnd)
  }
}
