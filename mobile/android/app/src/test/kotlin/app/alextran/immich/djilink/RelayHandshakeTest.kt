package app.alextran.immich.djilink

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicLong

/** The handshake and the rules of who may connect, on real sockets of 127.0.0.1 (design 4.5, 4.11, 6) */
class RelayHandshakeTest {
  private val code = "K7M2Q9XRTH"
  private val ms = 1_000_000L
  private val now = AtomicLong(1_000 * ms)
  private var server = RelayServer(clockNs = { now.get() }, runTicker = false)

  @After
  fun stop() = server.stop()

  private fun start(): Int = server.start(code, 0, InetAddress.getLoopbackAddress())

  @Test
  fun theRightCodeIsWelcomedWithAProofOfThePhone() {
    val port = start()
    TestHeadset(port).use { headset ->
      val welcome = headset.join(code)
      assertEquals(RelayWire.WELCOME, welcome.type)
      assertTrue(headset.welcomeProved(welcome, code))
      val json = RelayWire.parseJson(welcome.body, RelayWire.PROOF_BYTES)!!
      assertEquals("4", json["maxClients"].toString())
      assertTrue(eventually { server.headsetCount == 1 })
      assertEquals("Quest 3", server.snapshot().headsets.single().name)
    }
  }

  @Test
  fun aWrongCodeIsRefusedAndCounted() {
    val port = start()
    TestHeadset(port).use { headset ->
      val answer = headset.join("ABCDEFGHJK")
      assertEquals(RelayWire.REFUSED, answer.type)
      assertEquals(RelayWire.REFUSED_CODE, reason(answer))
      assertTrue(headset.closedByPhone())
    }
    assertEquals(1L, server.refusedProofs)
    assertEquals(0, server.headsetCount)
  }

  @Test
  fun noHelloInTimeIsRefused() {
    server = RelayServer(clockNs = { now.get() }, runTicker = false, helloTimeoutMs = 300)
    val port = start()
    TestHeadset(port).use { headset ->
      assertEquals(RelayWire.CHALLENGE, headset.challenge().type)
      val answer = headset.read()
      assertEquals(RelayWire.REFUSED, answer.type)
      assertEquals(RelayWire.REFUSED_TIMEOUT, reason(answer))
    }
  }

  @Test
  fun theEleventhFailureFromAnAddressIsBlockedForAMinute() {
    val port = start()
    repeat(10) {
      TestHeadset(port).use { headset ->
        assertEquals(RelayWire.REFUSED_CODE, reason(headset.join("ABCDEFGHJK")))
      }
    }
    TestHeadset(port).use { headset ->
      // Blocked before any challenge: even the right code is not tried
      val answer = headset.read()
      assertEquals(RelayWire.REFUSED, answer.type)
      assertEquals(RelayWire.REFUSED_BLOCKED, reason(answer))
    }
    now.addAndGet(60_001 * ms)
    TestHeadset(port).use { headset ->
      assertEquals(RelayWire.WELCOME, headset.join(code).type)
    }
  }

  @Test
  fun aFifthHeadsetIsRefusedFull() {
    val port = start()
    val four = List(4) { TestHeadset(port) }
    try {
      four.forEach { assertEquals(RelayWire.WELCOME, it.join(code).type) }
      assertTrue(eventually { server.headsetCount == 4 })
      TestHeadset(port).use { fifth ->
        val answer = fifth.join(code)
        assertEquals(RelayWire.REFUSED_FULL, reason(answer))
      }
    } finally {
      four.forEach { it.close() }
    }
  }

  @Test
  fun anAddressOutsideTheRuleIsClosedBeforeAByte() {
    server = RelayServer(clockNs = { now.get() }, runTicker = false, addressRule = { false })
    val port = start()
    TestHeadset(port).use { headset ->
      assertTrue(headset.closedByPhone())
    }
  }

  @Test
  fun aPingBeforeTheWelcomeClosesTheConnection() {
    val port = start()
    TestHeadset(port).use { headset ->
      headset.challenge()
      headset.ping()
      assertTrue(headset.closedByPhone())
    }
    assertTrue(eventually { server.unexpectedRecords == 1L })
  }

  @Test
  fun anUnknownTypeASecondHelloAndAnOversizedHelloCloseTheConnection() {
    val port = start()
    TestHeadset(port).use { headset ->
      assertEquals(RelayWire.WELCOME, headset.join(code).type)
      headset.send(0x99, ByteArray(0))
      assertTrue(headset.closedByPhone())
    }
    TestHeadset(port).use { headset ->
      assertEquals(RelayWire.WELCOME, headset.join(code).type)
      headset.hello(code)
      assertTrue(headset.closedByPhone())
    }
    TestHeadset(port).use { headset ->
      headset.challenge()
      headset.output.write(RelayWire.header(RelayWire.HELLO, 0, 1025))
      headset.output.flush()
      assertTrue(headset.closedByPhone())
    }
    assertTrue(eventually { server.unexpectedRecords == 3L })
    assertTrue(eventually { server.headsetCount == 0 })
  }

  @Test
  fun aPingIsAnsweredFirstWithThePhonesTimes() {
    val port = start()
    TestHeadset(port).use { headset ->
      assertEquals(RelayWire.WELCOME, headset.join(code).type)
      headset.ping(sendNs = 777)
      val pong = RelayWire.parsePong(headset.readUntil(RelayWire.PONG).body)
      assertEquals(777L, pong.pingSendNs)
      assertEquals(now.get(), pong.receivedNs)
      assertEquals(now.get(), pong.sentNs)
      assertTrue(eventually { server.snapshot().headsets.single().relayDelayMs == 12.0 })
      assertEquals(29.0, server.snapshot().headsets.single().picturesShownPerSecond!!, 1e-9)
    }
  }

  @Test
  fun aSilentHeadsetIsClosedAfter5Seconds() {
    val port = start()
    TestHeadset(port).use { headset ->
      assertEquals(RelayWire.WELCOME, headset.join(code).type)
      assertTrue(eventually { server.headsetCount == 1 })
      now.addAndGet(4_900 * ms)
      server.tick(now.get())
      assertEquals(1, server.headsetCount)
      now.addAndGet(200 * ms)
      server.tick(now.get())
      assertTrue(eventually { server.headsetCount == 0 })
    }
  }

  @Test
  fun aHeadsetByeEndsItsConnection() {
    val port = start()
    TestHeadset(port).use { headset ->
      assertEquals(RelayWire.WELCOME, headset.join(code).type)
      assertTrue(eventually { server.headsetCount == 1 })
      headset.send(RelayWire.HEADSET_BYE, ByteArray(0))
      assertTrue(eventually { server.headsetCount == 0 })
      assertEquals(0L, server.unexpectedRecords)
    }
  }

  @Test
  fun aNewCodeAndAStopSayByeToEveryHeadset() {
    val port = start()
    TestHeadset(port).use { headset ->
      assertEquals(RelayWire.WELCOME, headset.join(code).type)
      assertTrue(eventually { server.headsetCount == 1 })
      server.setCode("ABCDEFGHJK")
      val bye = headset.readUntil(RelayWire.BYE)
      assertEquals("\"newCode\"", RelayWire.parseJson(bye.body)!!["why"].toString())
    }
    TestHeadset(port).use { headset ->
      assertEquals(RelayWire.REFUSED_CODE, reason(headset.join(code)))
    }
    TestHeadset(port).use { headset ->
      assertEquals(RelayWire.WELCOME, headset.join("ABCDEFGHJK").type)
      assertTrue(eventually { server.headsetCount == 1 })
      server.stop()
      val bye = headset.readUntil(RelayWire.BYE)
      assertEquals("\"stopped\"", RelayWire.parseJson(bye.body)!!["why"].toString())
      assertFalse(server.isRunning)
    }
  }

  @Test
  fun aPhoneThatDoesNotProveTheCodeShowsNothing() {
    val phone = TestPhone {
      welcome(proofCode = "ABCDEFGHJK")
      // What it would send next is never shown
      send(RelayWire.PARAMETERS, RelayWire.parametersBody(ProfileRegistry.seed20261023!!), 1)
      Thread.sleep(500)
    }
    phone.use {
      val listener = RecordingReceiverListener()
      val receiver = RelayReceiver(listener)
      receiver.connect("127.0.0.1", phone.port, code, null, "Quest 3", "test")
      assertTrue(eventually { receiver.state == RelayReceiveState.PHONE_UNPROVEN })
      assertTrue(listener.parameters.isEmpty())
      assertFalse(receiver.active)
      receiver.disconnect()
    }
  }
}
