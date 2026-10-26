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
    // Three ticks of 20 not clear (a write over 50 ms, an oldest unit at 80 ms): no raise after 2 s
    val after = now
    while (now < after + 2 * second) {
      now += 100 * ms
      val tick = (now - after) / (100 * ms)
      when (tick) {
        3L -> rate.onTick(now, 10 * ms, 8_000_000, 60 * ms, dropped = false)
        9L, 15L -> rate.onTick(now, 80 * ms, 8_000_000, 5 * ms, dropped = false)
        else -> rate.onTick(now, 10 * ms, 8_000_000, 5 * ms, dropped = false)
      }
    }
    assertEquals(10_000_000, rate.allowedBps)
    // Once the last 2 s hold at most two of them, it rises
    while (rate.allowedBps == 10_000_000 && now < after + 3 * second) {
      now += 100 * ms
      rate.onTick(now, 10 * ms, 8_000_000, 5 * ms, dropped = false)
    }
    assertEquals(12_000_000, rate.allowedBps)
    assertTrue("raised at ${(now - after) / ms} ms", now - after in (2_000 * ms)..(2_500 * ms))
  }

  /**
   * p2/review-bandwidth-2026-10-25.md M4: the key picture the encoder makes every 2 s, whose write blocks for its bytes
   * over the unsent bound, no longer keeps the rate from rising
   */
  @Test
  fun aKeyPictureWriteOver50MsEvery2SecondsNoLongerKeepsTheRateDown() {
    val rate = RelayRateController()
    // Down to 3 Mbit/s once, then a clear link: queue empty, every write short but one every 2 s
    rate.onTick(0, 300 * ms, 3_750_000, 0, dropped = false)
    assertEquals(3_000_000, rate.allowedBps)
    var now = 0L
    for (tick in 1..300) {
      now = tick * 100 * ms
      val write = if (tick % 20 == 0) 60 * ms else 5 * ms
      rate.onTick(now, 0, 3_000_000, write, dropped = false)
    }
    assertEquals(RelayRateController.MAX_BPS, rate.allowedBps)
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
  fun atTheFloorAndStillLateItGoesToFifteenAndBackAfterOneClearSecondAtThreeMegabits() {
    val rate = RelayRateController()
    rate.onTick(0, 0, 1_000_000, 0, dropped = true)
    assertEquals(RelayRateController.MIN_BPS, rate.allowedBps)
    assertFalse(rate.slow)
    rate.onTick(600 * ms, 300 * ms, 1_000_000, 0, dropped = false)
    assertTrue(rate.slow)
    // Clear from now on: the rate climbs back by a quarter every 2 s, then 1 s at 3 Mbit/s or more
    // (p2/noon-test-check-2026-10-26.md C10: 5 s before, about 13 s at 15 a second after each fall)
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
    // 1.5, 1.875, 2.34, 2.93, 3.66 Mbit/s: four raises of 2 s, then 1 s at 3.66
    assertTrue("back at ${back / ms} ms", back in (9 * second)..(11 * second))
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

  /** p2/noon-test-check-2026-10-26.md C9: with nobody on the steady stream, the next encoder starts at 8 Mbit/s */
  @Test
  fun withNoSteadyReceiverTheEncoderRateGoesBackToEightMegabitsAndTheNextOneIsGivenAtOnce() {
    val encoder = RelayEncoderRate()
    assertEquals(1_500_000, encoder.next(listOf(1_500_000), null, 0))
    assertEquals(RelayRateController.START_BPS, encoder.next(emptyList(), null, 100 * ms))
    assertNull(encoder.next(emptyList(), null, 150 * ms))
    // The next receiver's rate at once, though the last one was given 100 ms ago
    assertEquals(1_500_000, encoder.next(listOf(1_500_000), null, 200 * ms))
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

  /**
   * The TV's path on the steady stream in the noon test of 26 October, its seconds 19 to 77 (relay-line-20261026.csv,
   * made by make_relay_line.py beside it): what it carried when backlogged, else at least the best second it carried in
   * the session, 13.4 Mbit/s
   */
  private fun line26(): List<Double> {
    val text = javaClass.classLoader!!.getResourceAsStream("djilink/relay-line-20261026.csv")!!
      .bufferedReader().readText()
    return text.lines().filter { it.isNotBlank() && !it.startsWith("#") && !it.startsWith("second") }.map { line ->
      val cells = line.split(',')
      val carried = cells[1].toDouble() * 1024 * 8
      if (cells[2] == "1") carried else maxOf(carried, 13.4e6)
    }
  }

  private class Replay(
    val drops: Int,
    val underAtEnd: Double,
    val underAll: Double,
    val medianBps: Double,
    val rates: List<Int> = emptyList(),
    /** Seconds at 15 pictures a second */
    val slowSeconds: Double = 0.0,
  )

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
    var slowSteps = 0
    for (step in 0 until seconds.size * 10) {
      val now = step * 100 * ms
      val bps = if (adaptive) rate.allowedBps else RelayRateController.START_BPS
      val perSecond = if (rate.slow) 15 else 30
      if (rate.slow) slowSteps += 1
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
    return Replay(
      drops,
      underEnd / count,
      underAll / count,
      sorted[sorted.size / 2].toDouble(),
      slowSeconds = slowSteps / 10.0,
    )
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

  /**
   * The same capacity with what the encoder does (p2/review-bandwidth-2026-10-25.md M4): a key picture [keyTimes] the
   * size of a P picture every 2 s at the allowed rate, one after each drop with the units skipped until it, and the
   * write of each unit blocking for its bytes over the unsent bound ([RelayLowWater]) at the path's rate, the key
   * pictures left out of the rate's write clause as the server leaves them out. [seconds] of capacity, from [startBps].
   */
  private fun replayWithKeys(seconds: List<Double>, keyTimes: Double = 8.0, startBps: Int? = null): Replay {
    val rate = RelayRateController()
    if (startBps != null) {
      // A drop at the start brings the rate down to the asked one
      rate.onTick(0, 0, (startBps / RelayRateController.DROP_FACTOR).toLong() + 1, 0, dropped = true)
    }
    val bound = RelayQueue.STEADY_TV_MAX_AGE_NS
    // A unit: queued at, bytes left, bytes, key
    val queue = ArrayDeque<DoubleArray>()
    val carried = ArrayDeque<DoubleArray>()
    var drops = 0
    var underEnd = 0
    var underAll = 0
    var maxAge = 0L
    var produce = 0.0
    var frame = 0
    var waitKey = false
    val rates = mutableListOf<Int>()
    var slowSteps = 0
    val first = if (startBps != null) 1 else 0
    for (step in first until seconds.size * 10) {
      val now = step * 100 * ms
      val bps = rate.allowedBps
      val perSecond = if (rate.slow) 15 else 30
      if (rate.slow) slowSteps += 1
      val group = 2 * perSecond
      produce += perSecond / 10.0
      while (produce >= 1 - 1e-9) {
        produce -= 1
        val p = bps * 2.0 / 8 / (group - 1 + keyTimes)
        val key = frame % group == 0 || waitKey
        if (key) {
          waitKey = false
          frame = 0
        }
        frame += 1
        val size = if (key) p * keyTimes else p
        queue.addLast(doubleArrayOf(now.toDouble(), size, size, if (key) 1.0 else 0.0))
      }
      val path = seconds[step / 10]
      var budget = path / 8 / 10
      var longest = 0L
      val low = RelayLowWater.bytesFor(bps).toDouble()
      while (queue.isNotEmpty() && budget > 0) {
        val head = queue.first()
        val take = minOf(budget, head[1])
        head[1] -= take
        budget -= take
        carried.addLast(doubleArrayOf(now.toDouble(), take))
        if (head[1] <= 1e-9) {
          queue.removeFirst()
          if (head[3] == 0.0) {
            longest = maxOf(longest, (maxOf(0.0, head[2] - low) / (path / 8) * 1e9).toLong())
          }
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
        waitKey = true
      }
      maxAge = maxOf(maxAge, age)
      if ((step + 1) % 10 == 0) {
        if (age < 300 * ms) underEnd += 1
        if (maxAge < 300 * ms) underAll += 1
        maxAge = 0
      }
      rate.onTick(now, age, (carried.sumOf { it[1] } * 8).toLong(), longest, dropped)
      rates += rate.allowedBps
    }
    val sorted = rates.sorted()
    val count = seconds.size.toDouble()
    return Replay(drops, underEnd / count, underAll / count, sorted[sorted.size / 2].toDouble(), rates, slowSteps / 10.0)
  }

  @Test
  fun theFlightsOf25OctoberReplayedWithKeyPicturesAndTheirWritesKeepFewDropsAndAShortQueue() {
    val replayed = replayWithKeys(capacity())
    println(
      "25 October flights with key pictures of 8 P pictures and their writes: ${replayed.drops} drops, " +
        "${"%.1f".format(replayed.underAtEnd * 100)} % of seconds under 0.3 s at their end " +
        "(${"%.1f".format(replayed.underAll * 100)} % all through), median " +
        "${"%.1f".format(replayed.medianBps / 1e6)} Mbit/s",
    )
    assertTrue("drops ${replayed.drops}", replayed.drops <= 40)
    assertTrue("under 0.3 s at the end of ${replayed.underAtEnd}", replayed.underAtEnd >= 0.85)
    assertTrue("under 0.3 s all through ${replayed.underAll}", replayed.underAll >= 0.78)
  }

  /**
   * p2/noon-test-check-2026-10-26.md C10 (item 6 of its section 4): after each fall to the floor the TV stayed about
   * 13 s at 15 a second, 44 of its 59 steady seconds; the replay of its line gives the same 44 s with the 5 s hold.
   * With 1 s the same line spends about half of that at 15, and neither line drops more than with the 5 s hold
   * (25 October: 19 drops with uniform units, 20 with key pictures; 26 October: 5 and 6). A faster climb from the
   * floor was replayed too and dropped more on 25 October (23 to 27): not taken.
   */
  @Test
  fun theTvsSteadyLineOf26OctoberSpendsLessTimeAtFifteenWithNoMoreDrops() {
    val line = line26()
    assertEquals(59, line.size)
    val uniform = replay(line)
    val keys = replayWithKeys(line)
    val october25 = replay(capacity())
    val october25Keys = replayWithKeys(capacity())
    println(
      "26 October, the TV's steady line, 59 s: ${uniform.drops} drops, ${"%.1f".format(uniform.slowSeconds)} s at " +
        "15 a second; with key pictures ${keys.drops} drops, ${"%.1f".format(keys.slowSeconds)} s at 15; 25 October " +
        "${october25.drops} and ${october25Keys.drops} drops, ${"%.1f".format(october25.slowSeconds)} and " +
        "${"%.1f".format(october25Keys.slowSeconds)} s at 15",
    )
    assertTrue("drops ${uniform.drops}", uniform.drops <= 5)
    assertTrue("drops with keys ${keys.drops}", keys.drops <= 6)
    assertTrue("25 October drops ${october25.drops}", october25.drops <= 19)
    assertTrue("25 October drops with keys ${october25Keys.drops}", october25Keys.drops <= 20)
    assertTrue("at 15 a second ${uniform.slowSeconds} s", uniform.slowSeconds <= 30.0)
    assertTrue("at 15 a second with keys ${keys.slowSeconds} s", keys.slowSeconds <= 30.0)
  }

  @Test
  fun fromTheFloorTheRateClimbsToWhatAConstantLinkCarriesWithKeyPictures() {
    for ((link, reached) in listOf(10e6 to 9_000_000, 15e6 to RelayRateController.MAX_BPS)) {
      val replayed = replayWithKeys(List(60) { link }, startBps = RelayRateController.MIN_BPS)
      val at20 = replayed.rates[20 * 10 - 2]
      val at30 = replayed.rates[30 * 10 - 2]
      println("constant ${link / 1e6} Mbit/s from 1.5: ${at20 / 1e6} Mbit/s at 20 s, ${at30 / 1e6} at 30 s")
      assertEquals(0, replayed.drops)
      // Before this round a 10 Mbit/s link stalled at 3.7 and a 15 Mbit/s one at 5.7 (the review's model)
      assertTrue("$at20 at 20 s on ${link / 1e6} Mbit/s", at20 >= 9_000_000)
      assertTrue("$at30 at 30 s on ${link / 1e6} Mbit/s", at30 >= reached)
    }
  }
}
