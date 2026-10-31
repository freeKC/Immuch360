package app.alextran.immich.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
}
