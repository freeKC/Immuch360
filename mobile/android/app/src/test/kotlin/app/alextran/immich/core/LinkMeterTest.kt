package app.alextran.immich.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LinkMeterTest {
  private var now = 1_000_000L
  private val meter = LinkMeter { now }

  /** [bytesPerSecond] for [ms], in 50 ms steps */
  private fun receive(bytesPerSecond: Long, ms: Long) {
    var left = ms
    while (left > 0) {
      now += 50
      left -= 50
      meter.onBytes(bytesPerSecond / 20)
    }
  }

  @Test
  fun `no rate before a quarter of a megabyte or a second of loading`() {
    meter.onStart()
    receive(100_000L, 500)
    assertNull(meter.rate())
    receive(100_000L, 600)
    assertEquals(100_000.0, meter.rate()!!.toDouble(), 8_000.0)
  }

  @Test
  fun `the rate is the one of the last four seconds`() {
    meter.onStart()
    receive(1_000_000L, 4_000)
    receive(250_000L, 4_000)
    assertEquals(250_000.0, meter.rate()!!.toDouble(), 20_000.0)
  }

  @Test
  fun `a buffer full that stops the loading does not count as a slow link`() {
    meter.onStart()
    receive(1_000_000L, 4_000)
    meter.setLoadingWanted(false)
    now += 10_000
    // Nothing wanted in the window: the last value stands
    assertEquals(1_000_000.0, meter.rate()!!.toDouble(), 60_000.0)
    meter.setLoadingWanted(true)
    receive(1_000_000L, 2_000)
    assertEquals(1_000_000.0, meter.rate()!!.toDouble(), 60_000.0)
  }

  @Test
  fun `a server that falls silent while the player wants more brings the rate down`() {
    meter.onStart()
    receive(1_000_000L, 4_000)
    now += 3_000
    assertEquals(250_000.0, meter.rate()!!.toDouble(), 30_000.0)
  }

  @Test
  fun `the need is the size of the files over the duration, else the bytes per second loaded`() {
    meter.onStart()
    assertNull(meter.need())
    meter.onTimeline(durationMs = -1L, bufferedPositionMs = 1_000L)
    meter.onBytes(4_000_000L)
    assertNull(meter.need())
    meter.onTimeline(durationMs = -1L, bufferedPositionMs = 4_000L)
    assertEquals(1_000_000L, meter.need())
    // Two files of one video, the lenses of a raw 360 video, are consumed together
    meter.onFileSize("a", 600_000_000L)
    meter.onFileSize("b", 600_000_000L)
    meter.onTimeline(durationMs = 600_000L, bufferedPositionMs = 4_000L)
    assertEquals(2_000_000L, meter.need())
  }

  @Test
  fun `a film loaded at its place counts the media loaded from there, not from its start`() {
    // A two hour film resumed at 2:09: its index of 3 MB arrives before its media, the position already at 2:09
    meter.onStart()
    meter.onTimeline(durationMs = -1L, bufferedPositionMs = 129_000L, positionMs = 129_000L)
    meter.onBytes(3_000_000L)
    meter.onTimeline(durationMs = -1L, bufferedPositionMs = 129_000L, positionMs = 129_000L)
    assertNull(meter.need())
    meter.onBytes(1_000_000L)
    meter.onTimeline(durationMs = -1L, bufferedPositionMs = 133_000L, positionMs = 129_000L)
    assertEquals(1_000_000L, meter.need())
  }

  @Test
  fun `progress is every 16 KiB, counted from the first read`() {
    assertNull(meter.sinceProgressMs())
    meter.onStart()
    now += 5_000
    assertEquals(5_000L, meter.sinceProgressMs())
    meter.onBytes(10_000L)
    now += 1_000
    // A trickle is no progress
    assertEquals(6_000L, meter.sinceProgressMs())
    meter.onBytes(10_000L)
    assertEquals(0L, meter.sinceProgressMs())
    now += 31_000
    assertEquals(31_000L, meter.sinceProgressMs())
  }

  @Test
  fun `the total of a Content-Range`() {
    assertEquals(12345L, LinkMeter.totalOfContentRange("bytes 0-99/12345"))
    assertNull(LinkMeter.totalOfContentRange("bytes 0-99/*"))
    assertNull(LinkMeter.totalOfContentRange(null))
  }

  @Test
  fun `a reset forgets the video before`() {
    meter.onStart()
    receive(1_000_000L, 2_000)
    meter.reset()
    assertNull(meter.rate())
    assertNull(meter.sinceProgressMs())
    assertEquals(0L, meter.receivedBytes)
  }

  // The "no progress" clock counts only the time the player asks for bytes (review of 1 November 2026, run A2: a film
  // paused for a while with its buffer full, a seek while paused, a server that answers 2.5 s later, and the app said
  // "The server stopped sending this video" at once)

  @Test
  fun `a pause with the buffer full, then a seek that waits for its first byte, is no dead link`() {
    meter.onStart()
    receive(1_000_000L, 4_000)
    // The buffer is full: Media3 asks for nothing while the film is paused
    meter.setLoadingWanted(false)
    now += 40_000
    // The seek: Media3 wants media again, the server answers 2 s later
    meter.setLoadingWanted(true)
    meter.onStart()
    now += 2_000
    assertEquals(2_000L, meter.sinceProgressMs())
    assertFalse(LinkStartRule.isDead(waiting = true, sinceProgressMs = meter.sinceProgressMs()))
  }

  @Test
  fun `a clip loaded to its end, seeked back after a while, is no dead link`() {
    meter.onStart()
    receive(1_000_000L, 2_000)
    // The whole file is in: its read ends, Media3 asks nothing more (it stops calling the load control)
    meter.onEnd()
    now += 40_000
    // A seek back: the back buffer is 0, a new read starts and waits for the server
    meter.onInitializing()
    now += 2_000
    assertEquals(2_000L, meter.sinceProgressMs())
  }

  @Test
  fun `a load error after a pause of eleven minutes is tried again`() {
    meter.onStart()
    receive(1_000_000L, 4_000)
    meter.setLoadingWanted(false)
    now += 11L * 60_000L
    // Played on: the server closed the idle connection meanwhile, the first read fails at once
    meter.setLoadingWanted(true)
    now += 50
    meter.onLoadError()
    assertNotNull(StreamRetry.delayMs(1, meter.sinceProgressMs(), fatal = false))
  }

  @Test
  fun `a server that takes the request and never answers is a network link, dead after 30 s`() {
    // Media3 opens the read: no header comes, ever
    meter.onInitializing()
    assertTrue(meter.isNetwork)
    now += 30_000
    assertEquals(30_000L, meter.sinceProgressMs())
    assertTrue(LinkStartRule.isDead(waiting = true, sinceProgressMs = meter.sinceProgressMs()))
  }

  @Test
  fun `the tries of a link that sends nothing keep the clock, dead 30 s after the last byte`() {
    meter.onStart()
    receive(1_000_000L, 2_000)
    // Each try waits 8 s for a byte (Cronet's read timeout), fails, and Media3 tries again after 1, 2, 4 s
    for (delay in longArrayOf(1_000L, 2_000L, 4_000L)) {
      now += 8_000
      meter.onEnd()
      meter.onLoadError()
      now += delay
      meter.onInitializing()
    }
    assertEquals(31_000L, meter.sinceProgressMs())
    assertTrue(LinkStartRule.isDead(waiting = true, sinceProgressMs = meter.sinceProgressMs()))
    assertNotNull(StreamRetry.delayMs(4, meter.sinceProgressMs(), fatal = false))
  }

  // The rate counts the time the player asked for bytes to the millisecond (review of 1 November 2026: with the
  // buffer at its bytes cap, Media3 loads 1 MiB each time the film frees room, every slot of 250 ms counted as asked,
  // and the meter measured what the film consumes: "it will pause now and then" over a link four times faster)

  /**
   * A film that needs [needBps] played from a buffer at its cap over a link of [linkBps] for [ms]: Media3 asks for
   * 1 MiB, the link brings it, Media3 asks nothing until the film consumed 1 MiB at [consumedBps]
   */
  private fun playAtTheCap(linkBps: Long, consumedBps: Long, ms: Long) {
    val chunk = 1L shl 20
    val end = now + ms
    while (now < end) {
      meter.setLoadingWanted(true)
      var left = chunk
      while (left > 0) {
        now += 10
        val bytes = minOf(left, linkBps / 100)
        meter.onBytes(bytes)
        left -= bytes
      }
      meter.setLoadingWanted(false)
      now += chunk * 1000L / consumedBps
    }
  }

  @Test
  fun `a buffer at its cap fed 1 MiB at a time measures the link, not what the film consumes`() {
    // A 4K film of 48 Mbit/s over a link of 200 Mbit/s, a calmer scene that consumes 15 % less than the average
    meter.onStart()
    meter.onFileSize("film", 6_000_000L * 3_600L)
    meter.onTimeline(durationMs = 3_600_000L, bufferedPositionMs = 50_000L)
    playAtTheCap(linkBps = 25_000_000L, consumedBps = 5_100_000L, ms = 20_000)
    val ratio = meter.ratio()!!
    assertTrue("ratio $ratio", ratio >= LinkStartRule.FAST_RATIO)
    assertFalse(LinkStartRule.isSlow(ratio, slowForMs = 20_000L))
  }
}
