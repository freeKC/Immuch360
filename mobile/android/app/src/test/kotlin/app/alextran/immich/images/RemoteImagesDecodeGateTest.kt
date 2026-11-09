package app.alextran.immich.images

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Where a photo of the server is decoded on Android: here from Android 9, as the native decoder of NativeImageDecodeApi,
 * so that a HEIF or raw original with "Load original image" on shows on Android 9 too (Dart keeps them away from the
 * engine, see encoded_image_probe.dart)
 */
class RemoteImagesDecodeGateTest {
  @Test
  fun `the photos are decoded here from Android 9 when the caller wants pixels`() {
    assertTrue(RemoteImagesImpl.decodesHere(preferEncoded = false, sdk = 28))
    assertTrue(RemoteImagesImpl.decodesHere(preferEncoded = false, sdk = 29))
    assertTrue(RemoteImagesImpl.decodesHere(preferEncoded = false, sdk = 36))
  }

  @Test
  fun `below Android 9, and for the encoded bytes of an animation, Flutter gets the bytes`() {
    // Below Android 9 neither ImageDecoder nor the fallback decoder of the engine exist
    assertFalse(RemoteImagesImpl.decodesHere(preferEncoded = false, sdk = 27))
    assertFalse(RemoteImagesImpl.decodesHere(preferEncoded = true, sdk = 28))
    assertFalse(RemoteImagesImpl.decodesHere(preferEncoded = true, sdk = 36))
  }
}
