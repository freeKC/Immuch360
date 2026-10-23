package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The headset's receiver against a phone written for the test (design 4.9, 8.1) */
class RelayReceiverStateTest {
  private val code = "K7M2Q9XRTH"

  private fun receiver(listener: RelayReceiver.Listener) = RelayReceiver(
    listener,
    silenceMs = 300,
    pingIntervalMs = 50,
    retryDelaysMs = listOf(100, 200, 400),
    busyRetryMs = 600,
  )

  private fun unitRecord(sequence: Long, counter: Int = sequence.toInt()): ByteArray {
    val unit = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(counter))
    return RelayWire.unitHeader(RelayUnitHeader(sequence, 10, 20, 30, counter)) + unit.bytes
  }

  @Test
  fun connectsReceivesAndCountsWhatTheWifiLost() {
    val phone = TestPhone {
      welcome()
      send(RelayWire.PARAMETERS, RelayWire.parametersBody(ProfileRegistry.seed20261023!!), 3)
      send(RelayWire.UNIT, unitRecord(0))
      send(RelayWire.UNIT, unitRecord(1))
      // Three units dropped on the phone for this headset: the next one breaks and jumps
      send(RelayWire.UNIT, unitRecord(5), RelayWire.UNIT_BREAK)
      send(RelayWire.TELEMETRY, """{"t":5,"seq":1,"link":{"source":"replay","replayName":"dji-link-20261023-102731"}}""".toByteArray())
      send(RelayWire.RESET, """{"why":"newSource"}""".toByteArray())
      // Pings answered for a while, then silence
      val until = System.currentTimeMillis() + 400
      while (System.currentTimeMillis() < until) {
        val ping = RelayWire.parsePing(read().body)
        send(RelayWire.PONG, RelayWire.pongBody(ping.sendNs, ping.sendNs + 5, ping.sendNs + 6))
      }
      Thread.sleep(5_000)
    }
    phone.use {
      val listener = RecordingReceiverListener()
      val receiver = receiver(listener)
      receiver.connect("127.0.0.1", phone.port, code, "3f9c0a1b2c3d4e5f", "Quest 3", "test")
      assertNotNull(listener.await("connected Galaxy S24+"))
      assertNotNull(listener.await("parameters"))
      assertEquals(DescriptionSource.PROFILE, listener.parameters.single().second)
      assertNotNull(listener.await("unit 5"))
      assertNotNull(listener.await("reset"))
      assertTrue(eventually { receiver.snapshot().telemetry != null })
      val snapshot = receiver.snapshot()
      assertEquals(RelayReceiveState.RECEIVING, snapshot.state)
      assertEquals(3L, snapshot.lostOnWifi)
      assertEquals(1L, snapshot.breaks)
      assertEquals(3L, snapshot.units)
      assertEquals("replay", snapshot.phoneSource)
      assertEquals("dji-link-20261023-102731", snapshot.replayName)
      assertEquals("Galaxy S24+", snapshot.phoneName)
      // Each unit is whole: the bytes the phone sent, split into their NAL units
      val (unit, header) = listener.units.first()
      assertEquals(listOf(HevcNal.ACCESS_UNIT_DELIMITER, 1, HevcNal.SUFFIX_SEI), unit.nalTypes.toList())
      assertEquals(0, header.pictureCounter)
      // The pongs aligned the clocks: the phone's clock reads 5 ns ahead of the ping's send time
      assertTrue(eventually { receiver.clock.ready })
      // 300 ms without a record after the pongs stop: lost, then connecting again
      assertTrue(eventually { receiver.state == RelayReceiveState.LOST })
      assertNotNull(listener.await("disconnected"))
      receiver.disconnect()
      assertEquals(RelayReceiveState.IDLE, receiver.state)
    }
  }

  @Test
  fun aLostConnectionIsTriedAgainAfterGrowingDelays() {
    // A phone that accepts and closes at once, before any challenge
    val phone = TestPhone { }
    phone.use {
      val receiver = receiver(RecordingReceiverListener())
      receiver.connect("127.0.0.1", phone.port, code, null, "Quest 3", "test")
      val times = List(5) { phone.nextConnection()!! }
      receiver.disconnect()
      val gaps = times.zipWithNext { a, b -> (b - a) / 1_000_000 }
      // 100, 200, 400, then 400 ms in this test (0.5, 1, 2, then 2 s in the app)
      assertTrue(gaps.toString(), gaps[0] in 90..260)
      assertTrue(gaps.toString(), gaps[1] in 190..360)
      assertTrue(gaps.toString(), gaps[2] in 390..560)
      assertTrue(gaps.toString(), gaps[3] in 390..560)
      assertTrue(receiver.snapshot().failures >= 4 || receiver.state == RelayReceiveState.IDLE)
    }
  }

  @Test
  fun aWrongCodeStopsTheRetriesAndAsksForTheCodeAgain() {
    val phone = TestPhone { refuse(RelayWire.REFUSED_CODE) }
    phone.use {
      val receiver = receiver(RecordingReceiverListener())
      receiver.connect("127.0.0.1", phone.port, "ABCDEFGHJK", null, "Quest 3", "test")
      assertNotNull(phone.nextConnection())
      assertTrue(eventually { receiver.state == RelayReceiveState.WRONG_CODE })
      assertNull("no retry", phone.nextConnection(700))
      assertTrue(!receiver.active)
    }
  }

  @Test
  fun aFullPhoneIsTriedAgainEveryTenSeconds() {
    val phone = TestPhone { refuse(RelayWire.REFUSED_FULL) }
    phone.use {
      val receiver = receiver(RecordingReceiverListener())
      receiver.connect("127.0.0.1", phone.port, code, null, "Quest 3", "test")
      val first = phone.nextConnection()!!
      assertTrue(eventually { receiver.state == RelayReceiveState.FULL })
      val second = phone.nextConnection(2_000)!!
      receiver.disconnect()
      // 600 ms in this test, 10 s in the app
      assertTrue((second - first) / 1_000_000 >= 590)
    }
  }

  @Test
  fun aNewCodeOnThePhoneAsksForTheCodeAndAStopTriesAgain() {
    val newCode = TestPhone {
      welcome()
      send(RelayWire.BYE, """{"why":"newCode"}""".toByteArray())
    }
    newCode.use {
      val receiver = receiver(RecordingReceiverListener())
      receiver.connect("127.0.0.1", newCode.port, code, null, "Quest 3", "test")
      assertTrue(eventually { receiver.state == RelayReceiveState.WRONG_CODE })
      assertNull(newCode.connections.let { it.poll(); newCode.nextConnection(500) })
    }
    val stopped = TestPhone {
      welcome()
      send(RelayWire.BYE, """{"why":"stopped"}""".toByteArray())
    }
    stopped.use {
      val receiver = receiver(RecordingReceiverListener())
      receiver.connect("127.0.0.1", stopped.port, code, null, "Quest 3", "test")
      assertNotNull(stopped.nextConnection())
      assertNotNull("tried again", stopped.nextConnection(2_000))
      receiver.disconnect()
    }
  }

  @Test
  fun anotherVersionOfTheProtocolStops() {
    val phone = TestPhone {
      send(RelayWire.CHALLENGE, RelayWire.MAGIC + byteArrayOf(2) + ByteArray(16))
      Thread.sleep(500)
    }
    phone.use {
      val receiver = receiver(RecordingReceiverListener())
      receiver.connect("127.0.0.1", phone.port, code, null, "Quest 3", "test")
      assertTrue(eventually { receiver.state == RelayReceiveState.OTHER_VERSION })
    }
  }
}
