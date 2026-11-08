package app.alextran.immich.images

import org.junit.Assert.assertEquals
import org.junit.Test

class NativeDecodeSizeTest {
  @Test
  fun `a panorama too large for any bitmap fits the 360 view, and half of it after an OutOfMemoryError`() {
    // 32768 x 16384 in ARGB is 2 GiB, more than Android allocates for one bitmap on any device
    assertEquals(DecodeSize(8190, 4095), NativeDecodeSize.fit(32768, 16384, 8191, 4095))
    assertEquals(DecodeSize(4095, 2048), NativeDecodeSize.fit(32768, 16384, 8191, 4095, factor = 0.5))
  }

  @Test
  fun `fits the box of the page, the tiles and the photos opened from another app, never larger than the image`() {
    assertEquals(DecodeSize(4096, 3072), NativeDecodeSize.fit(12000, 9000, 4096, 4096))
    assertEquals(DecodeSize(600, 800), NativeDecodeSize.fit(3000, 4000, 800, 800))
    assertEquals(DecodeSize(4000, 3000), NativeDecodeSize.fit(4000, 3000, 4096, 4096))
    assertEquals(DecodeSize(64, 32), NativeDecodeSize.fit(64, 32, 800, 800))
  }

  @Test
  fun `a side without bound is free, and the long side stays within the largest texture`() {
    assertEquals(DecodeSize(7680, 1920), NativeDecodeSize.fit(8000, 2000, 7680, 0))
    assertEquals(DecodeSize(6000, 4000), NativeDecodeSize.fit(6000, 4000, 0, 0))
    assertEquals(DecodeSize(16384, 8192), NativeDecodeSize.fit(20000, 10000, 0, 0))
    assertEquals(DecodeSize(16384, 1), NativeDecodeSize.fit(40000, 1, 0, 0))
  }

  @Test
  fun `the cover rule of the server pictures, as decodeBitmap with exactSize, and its half`() {
    assertEquals(DecodeSize(1024, 512), NativeDecodeSize.cover(4096, 2048, 512, 512))
    assertEquals(DecodeSize(512, 256), NativeDecodeSize.cover(4096, 2048, 512, 512, factor = 0.5))
    assertEquals(DecodeSize(256, 128), NativeDecodeSize.cover(256, 128, 512, 512))
    assertEquals(DecodeSize(6000, 4000), NativeDecodeSize.cover(6000, 4000, 0, 0))
    assertEquals(DecodeSize(16384, 8192), NativeDecodeSize.cover(32768, 16384, 0, 0))
    assertEquals(DecodeSize(8192, 4096), NativeDecodeSize.cover(32768, 16384, 0, 0, factor = 0.5))
  }

  @Test
  fun `a size the header does not tell is left as it is`() {
    assertEquals(DecodeSize(0, 0), NativeDecodeSize.fit(0, 0, 800, 800))
    assertEquals(DecodeSize(0, 10), NativeDecodeSize.cover(0, 10, 800, 800))
  }
}
