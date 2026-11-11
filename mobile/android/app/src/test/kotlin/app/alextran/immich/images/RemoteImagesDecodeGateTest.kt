package app.alextran.immich.images

import org.junit.Assert.assertEquals
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

  @Test
  fun `a JPEG XL the core did not decode reaches Dart as an undecodable photo`() {
    // Dart turns this code into an ImageDecodeException, which keeps the preview on screen (UndecodablePhotos)
    val error = RemoteImagesImpl.undecodableJpegXl(length = 1234, contentType = "image/jxl")
    assertEquals(UNDECODABLE_IMAGE, error.code)
    assertEquals("UndecodableImage", error.code)
    assertTrue(error.message!!.contains("1234 bytes"))
    assertTrue(error.message!!.contains("image/jxl"))
    assertTrue(RemoteImagesImpl.undecodableJpegXl(length = 0, contentType = null).message!!.contains("no type"))
  }
}
