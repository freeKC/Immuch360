package app.alextran.immich.djilink

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress

/**
 * The parameter sets reach every headset right after its welcome, before every key picture and whenever the
 * description changes, always in a record of their own (design 4.6); BREAK, RESET and REPLAY as section 4.3 says.
 */
class RelayParametersTest {
  private val code = "K7M2Q9XRTH"
  private val server = RelayServer(runTicker = false)
  private val seed = ProfileRegistry.seed20261023!!
  private val session = ResolvedDescription(seed, DescriptionSource.SESSION)

  /** Another description: the same VPS and SPS, another PPS */
  private val other = ResolvedDescription(
    StreamDescription(seed.vps, seed.sps, seed.pps + byteArrayOf(0x40), seed.info),
    DescriptionSource.CACHE,
  )

  @After
  fun stop() = server.stop()

  private fun pUnit(counter: Int) = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(counter))

  private fun keyUnit(counter: Int) = HevcSamples.unitOf(
    HevcSamples.DELIMITER,
    HevcSamples.VPS,
    HevcSamples.SPS,
    HevcSamples.PPS,
    HevcSamples.slice(type = 19),
    HevcSamples.suffixSei(counter),
  )

  private fun joined(): TestHeadset {
    val port = server.start(code, 0, InetAddress.getLoopbackAddress())
    val headset = TestHeadset(port)
    assertEquals(RelayWire.WELCOME, headset.join(code).type)
    assertTrue(eventually { server.headsetCount == 1 })
    return headset
  }

  @Test
  fun aHeadsetJoiningMidStreamGetsTheLastDescriptionFirst() {
    server.source = RelaySource.CABLE
    server.start(code, 0, InetAddress.getLoopbackAddress())
    // Units before any headset: nothing is sent, the description is kept
    server.submit(pUnit(1), session)
    val headset = TestHeadset(server.port!!)
    headset.use {
      assertEquals(RelayWire.WELCOME, it.join(code).type)
      assertTrue(eventually { server.headsetCount == 1 })
      val parameters = it.read()
      assertEquals(RelayWire.PARAMETERS, parameters.type)
      assertEquals(1, parameters.flags)
      assertTrue(RelayWire.parseParameters(parameters.body)!!.sameSetsAs(seed))
      server.submit(pUnit(2), session)
      val unit = it.read()
      assertEquals(RelayWire.UNIT, unit.type)
      assertEquals(0, unit.flags)
      assertEquals(0L, RelayWire.parseUnitHeader(unit.body).sequence)
    }
  }

  @Test
  fun aHeadsetJoiningMidStreamGetsTheLastKeyUnitRightAfterTheSets() {
    server.source = RelaySource.CABLE
    server.start(code, 0, InetAddress.getLoopbackAddress())
    // The key unit came before any headset, then P pictures: the headset would never see a key picture
    val key = keyUnit(1)
    server.submit(key, session)
    server.submit(pUnit(2), session)
    TestHeadset(server.port!!).use {
      assertEquals(RelayWire.WELCOME, it.join(code).type)
      assertTrue(eventually { server.headsetCount == 1 })
      assertEquals(RelayWire.PARAMETERS, it.read().type)
      val primer = it.read()
      assertEquals(RelayWire.UNIT, primer.type)
      assertEquals(RelayWire.UNIT_KEY or RelayWire.UNIT_PRIMER or RelayWire.UNIT_IN_BAND, primer.flags)
      assertArrayEquals(key.bytes, primer.body.copyOfRange(RelayWire.UNIT_HEADER_BYTES, primer.body.size))
      assertEquals(0L, RelayWire.parseUnitHeader(primer.body).sequence)
      // The live units follow with the next sequence numbers, no break and no primer flag
      server.submit(pUnit(3), session)
      val live = it.read()
      assertEquals(RelayWire.UNIT, live.type)
      assertEquals(0, live.flags)
      assertEquals(1L, RelayWire.parseUnitHeader(live.body).sequence)
      assertEquals(1L, server.primersSent)
    }
  }

  @Test
  fun aKeyUnitKeptFromAnEarlierSessionIsSentUntilALiveOneReplacesIt() {
    server.source = RelaySource.CABLE
    server.start(code, 0, InetAddress.getLoopbackAddress())
    val earlier = keyUnit(1)
    val live = keyUnit(9)
    server.keepKey(earlier, session)
    server.submit(pUnit(2), session)
    TestHeadset(server.port!!).use {
      assertEquals(RelayWire.WELCOME, it.join(code).type)
      assertTrue(eventually { server.headsetCount == 1 })
      assertEquals(RelayWire.PARAMETERS, it.read().type)
      val primer = it.read()
      assertEquals(RelayWire.UNIT_KEY or RelayWire.UNIT_PRIMER or RelayWire.UNIT_IN_BAND, primer.flags)
      assertArrayEquals(earlier.bytes, primer.body.copyOfRange(RelayWire.UNIT_HEADER_BYTES, primer.body.size))
    }
    assertTrue(eventually { server.headsetCount == 0 })
    // A live key picture replaces it, and a later kept one does not replace the live one
    server.submit(live, session)
    server.keepKey(earlier, session)
    server.submit(pUnit(10), session)
    TestHeadset(server.port!!).use {
      assertEquals(RelayWire.WELCOME, it.join(code).type)
      assertTrue(eventually { server.headsetCount == 1 })
      assertEquals(RelayWire.PARAMETERS, it.read().type)
      val primer = it.read()
      assertArrayEquals(live.bytes, primer.body.copyOfRange(RelayWire.UNIT_HEADER_BYTES, primer.body.size))
    }
    assertEquals(2L, server.primersSent)
  }

  @Test
  fun noKeyUnitIsSentFirstForOtherSetsOrAfterANewSource() {
    server.source = RelaySource.REPLAY
    server.start(code, 0, InetAddress.getLoopbackAddress())
    // The key unit belongs to the seed; the description then changed without a key picture
    server.submit(keyUnit(1), session)
    server.submit(pUnit(2), other)
    TestHeadset(server.port!!).use {
      assertEquals(RelayWire.WELCOME, it.join(code).type)
      assertTrue(eventually { server.headsetCount == 1 })
      assertEquals(RelayWire.PARAMETERS, it.read().type)
      server.submit(pUnit(3), other)
      val live = it.read()
      assertEquals(RelayWire.UNIT_REPLAY, live.flags)
    }
    assertTrue(eventually { server.headsetCount == 0 })
    // A new source forgets the key unit of the old one
    server.submit(keyUnit(4), session)
    server.reset()
    server.submit(pUnit(5), session)
    TestHeadset(server.port!!).use {
      assertEquals(RelayWire.WELCOME, it.join(code).type)
      assertTrue(eventually { server.headsetCount == 1 })
      assertEquals(RelayWire.PARAMETERS, it.read().type)
      server.submit(pUnit(6), session)
      assertEquals(RelayWire.UNIT_REPLAY, it.read().flags)
    }
    assertEquals(0L, server.primersSent)
  }

  @Test
  fun parametersComeBeforeEveryKeyPictureAndOnAChangedDescriptionOnly() {
    server.source = RelaySource.CABLE
    joined().use { headset ->
      val key = keyUnit(10)
      server.submit(key, session)
      server.submit(pUnit(11), session)
      server.submit(keyUnit(12), session)
      server.submit(pUnit(13), other)
      server.submit(pUnit(14), other)
      val types = mutableListOf<Int>()
      val records = mutableListOf<RelayRecord>()
      repeat(8) {
        val record = headset.read()
        types += record.type
        records += record
      }
      val p = RelayWire.PARAMETERS
      val u = RelayWire.UNIT
      assertEquals(listOf(p, u, u, p, u, p, u, u), types)
      // The key unit carries its own flags, its sets in band, and its bytes exactly as received: never a set inside
      val firstUnit = records[1]
      assertEquals(RelayWire.UNIT_KEY or RelayWire.UNIT_IN_BAND, firstUnit.flags)
      assertArrayEquals(key.bytes, firstUnit.body.copyOfRange(RelayWire.UNIT_HEADER_BYTES, firstUnit.body.size))
      assertEquals(10, RelayWire.parseUnitHeader(firstUnit.body).pictureCounter)
      assertEquals(2, records[5].flags)
      assertTrue(RelayWire.parseParameters(records[5].body)!!.sameSetsAs(other.description))
      assertEquals(listOf(0L, 1L, 2L, 3L, 4L), records.filter { it.type == u }.map { RelayWire.parseUnitHeader(it.body).sequence })
    }
  }

  @Test
  fun aNewStreamBreaksTheNextUnitAndANewSourceResetsAndSendsTheSetsAgain() {
    server.source = RelaySource.REPLAY
    joined().use { headset ->
      server.submit(pUnit(1), session)
      server.newStream()
      server.submit(pUnit(2), session)
      // Read before the reset, which drops what is still queued for the old source
      val before = List(3) { headset.read() }
      server.reset()
      server.reset()
      server.newStream()
      server.submit(pUnit(3), session)
      val after = List(3) { headset.read() }
      val records = before + after
      assertEquals(
        listOf(
          RelayWire.PARAMETERS,
          RelayWire.UNIT,
          RelayWire.UNIT,
          RelayWire.RESET,
          RelayWire.PARAMETERS,
          RelayWire.UNIT,
        ),
        records.map { it.type },
      )
      val units = records.filter { it.type == RelayWire.UNIT }
      // Every unit of a played capture is flagged REPLAY; BREAK on the one after the new stream only (one reset sent,
      // and no break after it: the decoder starts again anyway)
      assertEquals(RelayWire.UNIT_REPLAY, units[0].flags)
      assertEquals(RelayWire.UNIT_REPLAY or RelayWire.UNIT_BREAK, units[1].flags)
      assertEquals(RelayWire.UNIT_REPLAY, units[2].flags)
      assertEquals(listOf(0L, 1L, 2L), units.map { RelayWire.parseUnitHeader(it.body).sequence })
    }
  }

  @Test
  fun nothingIsRelayedWithoutASource() {
    server.source = RelaySource.NONE
    joined().use { headset ->
      server.submit(keyUnit(1), session)
      server.source = RelaySource.CABLE
      server.submit(pUnit(2), session)
      assertEquals(RelayWire.PARAMETERS, headset.read().type)
      val unit = headset.read()
      assertEquals(2, RelayWire.parseUnitHeader(unit.body).pictureCounter)
    }
  }

  @Test
  fun telemetryGoesAt10HertzWithASourceAndOnceASecondWithout() {
    var built = 0
    val now = java.util.concurrent.atomic.AtomicLong(0)
    val timed = RelayServer(
      clockNs = { now.get() },
      runTicker = false,
      telemetry = { sequence ->
        built += 1
        """{"seq":$sequence}""".toByteArray()
      },
    )
    try {
      timed.source = RelaySource.CABLE
      timed.start(code, 0, InetAddress.getLoopbackAddress())
      TestHeadset(timed.port!!).use { headset ->
        assertEquals(RelayWire.WELCOME, headset.join(code).type)
        assertTrue(eventually { timed.headsetCount == 1 })
        for (step in 0..10) {
          now.set(step * 100_000_000L)
          timed.tick(now.get())
        }
        assertEquals(11, built)
        timed.source = RelaySource.NONE
        for (step in 11..30) {
          now.set(step * 100_000_000L)
          timed.tick(now.get())
        }
        assertEquals("1 Hz without a source over 2 s", 13, built)
        // A headset reads the newest record of each moment
        val first = headset.read()
        assertEquals(RelayWire.TELEMETRY, first.type)
      }
    } finally {
      timed.stop()
    }
  }
}
