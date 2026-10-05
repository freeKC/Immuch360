package app.alextran.immich.core.raw

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pairing of the two lens streams, with made up timestamps: frames of 30 fps (33 333 us), release times in
 * nanoseconds on the same clock as "now".
 */
class LensFramePairerTest {
  private val frameUs = 33_333L

  private fun pts(frame: Int): Long = frame * frameUs

  /** Release time of a frame: 1 s after the start, plus its presentation time. */
  private fun release(frame: Int, offsetNs: Long = 0): Long = 1_000_000_000L + pts(frame) * 1000 + offsetNs

  private fun pairer(streams: List<Int> = listOf(0, 1)) = LensFramePairer<String>(streams, 30.0)

  @Test
  fun `frames of the same time pair as soon as both arrived`() {
    val pairer = pairer()
    pairer.onMetadata(0, release(0), pts(0), "f0", 30f)
    pairer.onMetadata(1, release(0, 300_000), pts(0), "f1", 30f)
    assertEquals(LensFramePairer.Idle, pairer.onAcquired(0, release(0), release(0)))
    val draw = pairer.onAcquired(1, release(0, 300_000), release(0)) as LensFramePairer.Draw<*>
    assertTrue(draw.paired)
    assertEquals(pts(0), draw.ptsUs)
    // The later of the two release times
    assertEquals(release(0, 300_000), draw.releaseNs)
    assertEquals("f0", draw.format)
    // Drawn: nothing more until a new frame
    assertEquals(LensFramePairer.Idle, pairer.onTimeout(release(1)))
    assertEquals(1, pairer.stats.paired)
  }

  @Test
  fun `a stream one frame late pairs when its frame arrives`() {
    val pairer = pairer()
    for (frame in 0..1) {
      pairer.onMetadata(0, release(frame), pts(frame), "f", 30f)
      pairer.onMetadata(1, release(frame), pts(frame), "f", 30f)
    }
    pairer.onAcquired(0, release(0), release(0))
    pairer.onAcquired(1, release(0), release(0))
    // Stream 0 is a frame ahead: it waits for its pair, at most two frames
    val wait = pairer.onAcquired(0, release(1), release(1)) as LensFramePairer.Wait
    assertEquals(release(1) + pairer.unpairedTimeoutNs(), wait.deadlineNs)
    val draw = pairer.onAcquired(1, release(1), release(1) + 5_000_000) as LensFramePairer.Draw<*>
    assertTrue(draw.paired)
    assertEquals(pts(1), draw.ptsUs)
    assertEquals(0, pairer.stats.unpaired)
  }

  @Test
  fun `a frame the queue replaced skips its metadata`() {
    val pairer = pairer(listOf(0))
    for (frame in 0..2) pairer.onMetadata(0, release(frame), pts(frame), "f$frame", 30f)
    // Frames 0 and 1 never reached the texture
    val draw = pairer.onAcquired(0, release(2), release(2)) as LensFramePairer.Draw<*>
    assertEquals(pts(2), draw.ptsUs)
    assertEquals("f2", draw.format)
    assertEquals(2, pairer.stats.replaced)
    assertFalse(pairer.releaseTimePairing)
  }

  @Test
  fun `streams more than a second apart wait for each other instead of mixing two moments`() {
    val pairer = pairer()
    pairer.onMetadata(0, release(0), pts(0), "f", 30f)
    pairer.onMetadata(1, release(90), pts(90), "f", 30f)
    pairer.onAcquired(0, release(0), release(0))
    assertEquals(LensFramePairer.Wait(null), pairer.onAcquired(1, release(90), release(0)))
    // Even long after: no frame of one stream with the other at a far away position
    assertEquals(LensFramePairer.Wait(null), pairer.onTimeout(release(200)))
  }

  @Test
  fun `a stream ahead draws alone after the timeout`() {
    val pairer = pairer()
    pairer.onMetadata(0, release(0), pts(0), "f", 30f)
    pairer.onMetadata(1, release(0), pts(0), "f", 30f)
    pairer.onAcquired(0, release(0), release(0))
    pairer.onAcquired(1, release(0), release(0))
    pairer.onMetadata(0, release(1), pts(1), "f", 30f)
    val now = release(1)
    val wait = pairer.onAcquired(0, release(1), now) as LensFramePairer.Wait
    assertEquals(LensFramePairer.Wait(wait.deadlineNs), pairer.onTimeout(now + 1_000_000))
    val draw = pairer.onTimeout(wait.deadlineNs!!) as LensFramePairer.Draw<*>
    assertFalse(draw.paired)
    assertEquals(pts(1), draw.ptsUs)
    assertEquals(1, pairer.stats.unpaired)
    // Once drawn alone, the late frame of the other stream draws the pair again
    pairer.onMetadata(1, release(1), pts(1), "f", 30f)
    assertTrue((pairer.onAcquired(1, release(1), now + 80_000_000) as LensFramePairer.Draw<*>).paired)
  }

  @Test
  fun `one stream draws every frame`() {
    val pairer = pairer(listOf(1))
    for (frame in 0..4) {
      pairer.onMetadata(1, release(frame), pts(frame), "f", 30f)
      val draw = pairer.onAcquired(1, release(frame), release(frame)) as LensFramePairer.Draw<*>
      assertEquals(pts(frame), draw.ptsUs)
    }
    assertEquals(5, pairer.stats.paired)
    // A stream the pairer does not know is ignored
    assertEquals(LensFramePairer.Idle, pairer.onAcquired(0, release(5), release(5)))
  }

  @Test
  fun `texture timestamps that match no release time switch to pairing by texture time`() {
    val pairer = pairer()
    pairer.onMetadata(0, release(0), pts(0), "f", 30f)
    pairer.onMetadata(1, release(0), pts(0), "f", 30f)
    // This device stamps the textures with another clock
    val stamp = 5_000_000_000L
    assertEquals(LensFramePairer.Idle, pairer.onAcquired(0, stamp, release(0)))
    assertTrue(pairer.releaseTimePairing)
    val draw = pairer.onAcquired(1, stamp + 1_000_000, release(0)) as LensFramePairer.Draw<*>
    assertTrue(draw.paired)
    assertEquals(stamp / 1000, draw.ptsUs)
    assertEquals("f", draw.format)
  }

  @Test
  fun `the tolerance and the timeout follow the slower stream`() {
    val pairer = pairer()
    assertEquals(16_666L, pairer.toleranceUs())
    assertEquals(66_666_000L, pairer.unpairedTimeoutNs())
    pairer.onMetadata(0, release(0), pts(0), "f", 60f)
    pairer.onMetadata(1, release(0), pts(0), "f", 24f)
    assertEquals(20_833L, pairer.toleranceUs())
    // A fast stream keeps at least 50 ms
    val fast = pairer(listOf(0))
    fast.onMetadata(0, release(0), pts(0), "f", 120f)
    assertEquals(50_000_000L, fast.unpairedTimeoutNs())
  }
}
