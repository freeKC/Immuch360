package app.alextran.immich.core

import org.junit.Assert.assertEquals
import org.junit.Test

class StreamingLoadControlTest {
  private val mib = 1024L * 1024L

  @Test
  fun `takes half of the heap`() {
    assertEquals((256 * mib).toInt(), StreamingLoadControl.targetBufferBytes(512 * mib))
  }

  @Test
  fun `takes half of the small heap of a TV, less than the Media3 default which would fill it`() {
    // The Google TV emulator gives 128 MiB, TVs with largeHeap 192 to 256 MiB; Media3 buffers about 137 MiB
    assertEquals((64 * mib).toInt(), StreamingLoadControl.targetBufferBytes(128 * mib))
    assertEquals((96 * mib).toInt(), StreamingLoadControl.targetBufferBytes(192 * mib))
  }

  @Test
  fun `never takes more than the maximum`() {
    assertEquals(StreamingLoadControl.MAX_TARGET_BUFFER_BYTES, StreamingLoadControl.targetBufferBytes(4096 * mib))
  }

  @Test
  fun `the least media before playing is the link rule's, which decides above it`() {
    assertEquals(1_000, StreamingLoadControl.BUFFER_FOR_PLAYBACK_MS)
    assertEquals(2_000, StreamingLoadControl.BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS)
  }

  @Test
  fun `a player that waits for what its link asks is fed only past it`() {
    assertEquals(5_000L, StreamingLoadControl.decoderFedMs(0L))
    assertEquals(5_000L, StreamingLoadControl.decoderFedMs(2_000L))
    // A link at 0.8 of the video after a stall waits for 12 s: 6 s buffered is the network, not the decoder
    assertEquals(12_000L, StreamingLoadControl.decoderFedMs(12_000L))
  }
}
