package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The splits of the way from the phone and the "behind the phone screen" sum, on synthetic stamps (design 9.3) */
class RelayLatencyTest {
  private val ms = 1_000_000L

  private fun readyClock(offset: Long): ClockOffset = ClockOffset().apply {
    repeat(3) { index ->
      val t0 = index * 500 * ms
      onPong(t0, t0 + offset + ms, t0 + offset + ms, t0 + 2 * ms)
    }
  }

  @Test
  fun theRelayDelayIsThePhoneQueuePlusTheNetwork() {
    val offset = 9_000 * ms
    val clock = readyClock(offset)
    val latency = RelayLatency()
    for (index in 0 until 30) {
      val arrival = 10_000 * ms + index * 33 * ms
      // On the phone's clock: first fragment 22 ms before the last, the write 1 ms after it, 13 ms on the network
      val lastRx = arrival + offset - 14 * ms
      latency.onUnit(arrival, RelayUnitHeader(index.toLong(), lastRx - 22 * ms, lastRx, lastRx + ms, index))
    }
    val numbers = latency.numbers(10_000 * ms + 29 * 33 * ms, clock)
    assertEquals(14.0, numbers.relayDelayMedianMs!!, 1e-6)
    assertEquals(1.0, numbers.phoneQueueMedianMs!!, 1e-6)
    assertEquals(13.0, numbers.networkMedianMs!!, 1e-6)
    assertEquals(22.0, numbers.arrivalSpreadMedianMs!!, 1e-6)
    assertEquals(1.0, numbers.clockUncertaintyMs!!, 1e-6)
    assertEquals(30.0, numbers.unitsPerSecond, 1e-6)
  }

  @Test
  fun withoutAlignedClocksOnlyThePhoneSideIsGiven() {
    val latency = RelayLatency()
    latency.onUnit(5 * ms, RelayUnitHeader(0, 100 * ms, 120 * ms, 125 * ms, -1))
    val numbers = latency.numbers(5 * ms, ClockOffset())
    assertNull(numbers.relayDelayMedianMs)
    assertNull(numbers.networkMedianMs)
    assertEquals(5.0, numbers.phoneQueueMedianMs!!, 1e-6)
  }

  @Test
  fun oldUnitsLeaveTheWindow() {
    val latency = RelayLatency(windowNs = 2_000 * ms)
    latency.onUnit(0, RelayUnitHeader(0, 0, 0, 0, -1))
    assertEquals(RelayLatencyNumbers.EMPTY, latency.numbers(3_000 * ms, ClockOffset()))
  }

  @Test
  fun behindThePhoneScreenIsReceiveToPictureMinusThePhonesOwnPath() {
    val receiveToPicture = RelayLatencyNumbers.receiveToPicture(14.0, 1.0, 9.0)!!
    assertEquals(24.0, receiveToPicture, 1e-9)
    // The phone takes 0.4 ms in process and 9 ms to decode: the headset shows its picture 14.6 ms later
    assertEquals(14.6, RelayLatencyNumbers.behindPhone(receiveToPicture, 0.4, 9.0)!!, 1e-9)
    assertNull(RelayLatencyNumbers.receiveToPicture(null, 1.0, 9.0))
    assertNull(RelayLatencyNumbers.behindPhone(24.0, 0.4, null))
  }
}
