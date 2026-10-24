package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

/** The tee: both halves get every call, and the relay can never stop the phone's own decoder (design 3.2) */
class TeeSinkTest {
  private open class Recording : DecoderSink {
    val calls = mutableListOf<String>()
    val units = mutableListOf<AccessUnit>()

    override fun submit(unit: AccessUnit, description: ResolvedDescription) {
      calls += "submit"
      units += unit
    }

    override fun reset() {
      calls += "reset"
    }

    override fun newStream() {
      calls += "newStream"
    }

    override fun keepKey(unit: AccessUnit, description: ResolvedDescription) {
      calls += "keepKey"
    }

    override fun status(): DecoderStatus = DecoderStatus(name = "feed")
  }

  private class Throwing : Recording() {
    override fun submit(unit: AccessUnit, description: ResolvedDescription) = throw IllegalStateException("relay")

    override fun reset() = throw IllegalStateException("relay")

    override fun newStream() = throw IllegalStateException("relay")
  }

  private val description = ResolvedDescription(ProfileRegistry.seed20261023!!, DescriptionSource.PROFILE)

  @Test
  fun submitResetAndNewStreamReachBothAndTheBytesAreShared() {
    val feed = Recording()
    val relay = Recording()
    val tee = TeeSink(feed, relay)
    val unit = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice())
    tee.submit(unit, description)
    tee.newStream()
    tee.reset()
    assertEquals(listOf("submit", "newStream", "reset"), feed.calls)
    assertEquals(listOf("submit", "newStream", "reset"), relay.calls)
    assertSame(feed.units.single().bytes, relay.units.single().bytes)
    assertEquals("feed", tee.status().name)
  }

  @Test
  fun aKeptKeyUnitReachesBothAndAThrowingRelayDoesNotStopIt() {
    val feed = Recording()
    val relay = Recording()
    val key = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(type = 20))
    TeeSink(feed, relay).keepKey(key, description)
    assertEquals(listOf("keepKey"), feed.calls)
    assertEquals(listOf("keepKey"), relay.calls)
    val alone = Recording()
    TeeSink(alone, object : Recording() {
      override fun keepKey(unit: AccessUnit, description: ResolvedDescription) = throw IllegalStateException("relay")
    }).keepKey(key, description)
    assertEquals(listOf("keepKey"), alone.calls)
  }

  @Test
  fun aThrowingRelayNeverStopsTheDecoderFeed() {
    val feed = Recording()
    val tee = TeeSink(feed, Throwing())
    repeat(3) { tee.submit(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice()), description) }
    tee.newStream()
    tee.reset()
    assertEquals(listOf("submit", "submit", "submit", "newStream", "reset"), feed.calls)
    assertEquals(5L, tee.relayFailures)
  }

  @Test
  fun thePipelineTellsTheSinkOfANewStream() {
    val sink = Recording()
    val pipeline = VideoPipeline(ParameterSetStore(MemoryKeyValueStore()), sink)
    pipeline.newStream()
    pipeline.newSource()
    assertEquals(listOf("newStream", "reset"), sink.calls)
  }
}
