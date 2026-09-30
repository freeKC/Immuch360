package app.alextran.immich.immersive

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ImmersiveMediaTest {
  @Test
  fun `H264 above 4K exceeds the headset decoder`() {
    assertTrue(ImmersiveMedia.exceedsAvcDecoder("video/avc", 5760, 2880))
    assertTrue(ImmersiveMedia.exceedsAvcDecoder("video/avc", 7680, 3840))
    assertTrue(ImmersiveMedia.exceedsAvcDecoder("video/avc", 4097, 2048))
    assertTrue(ImmersiveMedia.exceedsAvcDecoder("video/avc", 4096, 2305))
    assertTrue(ImmersiveMedia.exceedsAvcDecoder("video/avc", 3840, 3840))
  }

  @Test
  fun `H264 up to 4096x2304 fits`() {
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/avc", 4096, 2304))
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/avc", 4096, 2048))
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/avc", 3840, 2160))
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/avc", 3840, 1920))
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/avc", 2880, 1440))
  }

  @Test
  fun `portrait sizes are checked on the long and the short side`() {
    assertTrue(ImmersiveMedia.exceedsAvcDecoder("video/avc", 2880, 5760))
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/avc", 2160, 3840))
  }

  @Test
  fun `other codecs never exceed`() {
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/hevc", 5760, 2880))
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/av01", 7680, 3840))
    assertFalse(ImmersiveMedia.exceedsAvcDecoder(null, 5760, 2880))
  }

  @Test
  fun `mime type is compared without case`() {
    assertTrue(ImmersiveMedia.exceedsAvcDecoder("VIDEO/AVC", 5760, 2880))
  }

  @Test
  fun `unknown sizes do not exceed`() {
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/avc", -1, -1))
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/avc", 0, 0))
  }
}
