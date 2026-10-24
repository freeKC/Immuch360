package app.alextran.immich.djilink

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicLong

/**
 * The TVs a phone sends to (p2/design-tv-2026-10-24.md, 2.4 and 8.2): each TV proves the code it made itself, which the
 * pilot added on the phone; the phone proves that same code back; the wire, the records and the limits stay as they
 * are; removing a TV or making a new phone code closes only the connections that proved that code.
 */
class RelayScreenCodesTest {
  private val code = "K7M2Q9XRTH"
  private val tvCode = "MNPQRSTUVW"
  private val ms = 1_000_000L
  private val now = AtomicLong(1_000 * ms)
  private val server = RelayServer(clockNs = { now.get() }, runTicker = false)

  @After
  fun stop() = server.stop()

  private fun start(screens: List<RelayScreenCode> = listOf(RelayScreenCode("tv1", tvCode))): Int =
    server.start(code, 0, InetAddress.getLoopbackAddress(), screens)

  @Test
  fun aTvThatProvesItsOwnCodeIsWelcomedAndThePhoneProvesThatCode() {
    val port = start()
    TestHeadset(port).use { tv ->
      val welcome = tv.join(tvCode, name = "Living room TV", kind = "tv")
      assertEquals(RelayWire.WELCOME, welcome.type)
      assertTrue(tv.welcomeProved(welcome, tvCode))
      assertFalse(tv.welcomeProved(welcome, code))
      assertTrue(eventually { server.headsetCount == 1 })
      val row = server.snapshot().headsets.single()
      assertEquals("tv1", row.screenCodeId)
      assertEquals("tv", row.kind)
      assertEquals("Living room TV", row.name)
    }
  }

  @Test
  fun thePhonesOwnCodeStillWorksBesideTheScreenCodes() {
    val port = start()
    TestHeadset(port).use { headset ->
      val welcome = headset.join(code)
      assertEquals(RelayWire.WELCOME, welcome.type)
      assertTrue(headset.welcomeProved(welcome, code))
      assertTrue(eventually { server.headsetCount == 1 })
      val row = server.snapshot().headsets.single()
      assertNull(row.screenCodeId)
      assertNull(row.kind)
    }
  }

  @Test
  fun aProofOfNoCodeIsRefusedOnceAndCountsOneFailureWithEightCodes() {
    val eight = (1..8).map { RelayScreenCode("tv$it", "ABCDEFGHJ" + "KMNPQRSTU"[it]) }
    assertEquals(8, RelayServer.validScreenCodes(eight).size)
    val port = start(eight)
    TestHeadset(port).use { headset ->
      val answer = headset.join("WXYZ234567")
      assertEquals(RelayWire.REFUSED_CODE, reason(answer))
    }
    assertEquals(1L, server.refusedProofs)
    // Nine more wrong proofs from this address block it, as with one code
    repeat(9) {
      TestHeadset(port).use { headset -> assertEquals(RelayWire.REFUSED_CODE, reason(headset.join("WXYZ234567"))) }
    }
    assertEquals(10L, server.refusedProofs)
    TestHeadset(port).use { headset -> assertEquals(RelayWire.REFUSED_BLOCKED, reason(headset.read())) }
    // Each TV code still works once the minute passed
    now.addAndGet(60_001 * ms)
    TestHeadset(port).use { tv -> assertEquals(RelayWire.WELCOME, tv.join("ABCDEFGHJU").type) }
  }

  @Test
  fun aTvRemovedLeavesWithNewCodeAndTheHeadsetStays() {
    val port = start()
    TestHeadset(port).use { tv ->
      TestHeadset(port).use { headset ->
        assertEquals(RelayWire.WELCOME, tv.join(tvCode, kind = "tv").type)
        assertEquals(RelayWire.WELCOME, headset.join(code).type)
        assertTrue(eventually { server.headsetCount == 2 })
        server.setScreenCodes(emptyList())
        val bye = tv.readUntil(RelayWire.BYE)
        assertEquals("\"newCode\"", RelayWire.parseJson(bye.body)!!["why"].toString())
        assertTrue(eventually { server.headsetCount == 1 })
        assertNull(server.snapshot().headsets.single().screenCodeId)
        // The headset is still served: its ping is answered
        headset.ping(sendNs = 99)
        assertEquals(99L, RelayWire.parsePong(headset.readUntil(RelayWire.PONG).body).pingSendNs)
      }
    }
    // The removed code is refused from now on
    TestHeadset(port).use { tv -> assertEquals(RelayWire.REFUSED_CODE, reason(tv.join(tvCode))) }
  }

  @Test
  fun aNewPhoneCodeSendsTheHeadsetsAwayAndKeepsTheTvs() {
    val port = start()
    TestHeadset(port).use { tv ->
      TestHeadset(port).use { headset ->
        assertEquals(RelayWire.WELCOME, tv.join(tvCode, kind = "tv").type)
        assertEquals(RelayWire.WELCOME, headset.join(code).type)
        assertTrue(eventually { server.headsetCount == 2 })
        server.setCode("ABCDEFGHJK")
        val bye = headset.readUntil(RelayWire.BYE)
        assertEquals("\"newCode\"", RelayWire.parseJson(bye.body)!!["why"].toString())
        assertTrue(eventually { server.headsetCount == 1 })
        assertEquals("tv1", server.snapshot().headsets.single().screenCodeId)
        tv.ping(sendNs = 7)
        assertEquals(7L, RelayWire.parsePong(tv.readUntil(RelayWire.PONG).body).pingSendNs)
      }
    }
  }

  @Test
  fun fourReceiversAtMostHeadsetsAndTvsTogether() {
    val port = start(listOf(RelayScreenCode("tv1", tvCode), RelayScreenCode("tv2", "ABCDEFGHJK")))
    val joined = mutableListOf<TestHeadset>()
    try {
      for (proof in listOf(tvCode, "ABCDEFGHJK", code, code)) {
        val receiver = TestHeadset(port).also { joined += it }
        assertEquals(RelayWire.WELCOME, receiver.join(proof).type)
      }
      assertTrue(eventually { server.headsetCount == 4 })
      TestHeadset(port).use { fifth -> assertEquals(RelayWire.REFUSED_FULL, reason(fifth.join(tvCode))) }
    } finally {
      joined.forEach { it.close() }
    }
  }

  @Test
  fun aHelloThatSaysNothingOrSomethingOddHasNoKind() {
    val port = start()
    TestHeadset(port).use { headset ->
      assertEquals(RelayWire.WELCOME, headset.join(code, kind = "Not A Kind!").type)
      assertTrue(eventually { server.headsetCount == 1 })
      assertNull(server.snapshot().headsets.single().kind)
    }
  }

  @Test
  fun theScreenCodesKeptAreCodesOfTheAlphabetOnePerIdEightAtMost() {
    val kept = RelayServer.validScreenCodes(
      listOf(
        RelayScreenCode("a", tvCode),
        RelayScreenCode("a", "ABCDEFGHJK"),
        RelayScreenCode("b", "mnpqrstuvw"),
        RelayScreenCode("c", "ABCDEFGHJ0"),
        RelayScreenCode("", "ABCDEFGHJK"),
        RelayScreenCode("d", "ABCDEFGHJK"),
      ) + (1..10).map { RelayScreenCode("x$it", "ABCDEFGHJK") },
    )
    assertEquals(listOf("a", "d", "x1", "x2", "x3", "x4", "x5", "x6"), kept.map { it.id })
    assertEquals(tvCode, kept.first().code)
  }

  @Test
  fun theScreenCodesSetWhileOffAreKeptForTheNextStart() {
    server.setScreenCodes(listOf(RelayScreenCode("tv1", tvCode)))
    assertEquals(listOf("tv1"), server.screenCodesKept().map { it.id })
    val port = start()
    TestHeadset(port).use { tv -> assertEquals(RelayWire.WELCOME, tv.join(tvCode).type) }
  }

  @Test
  fun aTvReceiverSaysItIsATvAndReadsItsRemovalAsARefusedCode() {
    val port = start()
    val listener = RecordingReceiverListener()
    val receiver = RelayReceiver(listener, pingIntervalMs = 50)
    try {
      receiver.connect("127.0.0.1", port, tvCode, null, "Living room TV", "test", kind = "tv")
      assertTrue(eventually { server.headsetCount == 1 })
      val row = server.snapshot().headsets.single()
      assertEquals("tv", row.kind)
      assertEquals("tv1", row.screenCodeId)
      assertTrue(eventually { receiver.state == RelayReceiveState.RECEIVING })
      server.setScreenCodes(emptyList())
      assertTrue(eventually { receiver.state == RelayReceiveState.WRONG_CODE })
      assertFalse(receiver.active)
    } finally {
      receiver.disconnect()
    }
  }

  @Test
  fun theVolumeOfADeviceWhoseVolumeIsFixedNeverSaysSilent() {
    assertTrue(mediaVolumeSilent(volumeFixed = false, volume = 0))
    assertFalse(mediaVolumeSilent(volumeFixed = false, volume = 7))
    assertFalse(mediaVolumeSilent(volumeFixed = true, volume = 0))
  }

  @Test
  fun aTelevisionNeverTakesTheCablePathWhateverItsUsbFeatures() {
    fun report(television: Boolean, accessory: Boolean) = UsbEnvironmentReport(
      deviceManufacturer = "Google",
      deviceModel = "Chromecast HD",
      buildFingerprint = "google/sabrina/sabrina:12/STTE.1/1:user/release-keys",
      androidRelease = "12",
      sdkInt = 31,
      appVersion = "3.3.0",
      flavour = "phone",
      hasAccessoryFeature = accessory,
      hasHostFeature = true,
      accessoryNodeExists = accessory,
      accessoryNodeWritable = false,
      futureUsbLibraryPresent = false,
      adbEnabled = false,
      usbStateKnown = false,
      usbConnected = false,
      usbConfigured = false,
      usbAccessoryMode = false,
      usbAdbFunction = false,
      djiApplicationInstalled = false,
      chargeCurrentMicroAmps = null,
      accessoriesListed = 0,
      television = television,
    )
    assertFalse(report(television = true, accessory = true).transportPossible)
    assertTrue(report(television = false, accessory = true).transportPossible)
    assertFalse(report(television = false, accessory = false).transportPossible)
  }
}
