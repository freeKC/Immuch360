package app.alextran.immich.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The RTSP address of a live view: the camera account in the user info, every byte that must be encoded encoded */
class CameraRtspUriTest {
  @Test
  fun putsTheAccountInTheUserInfo() {
    assertEquals(
      "rtsp://viewer:secret@192.0.2.30:554/stream2",
      cameraRtspUri("rtsp://192.0.2.30:554/stream2", "viewer", "secret"),
    )
  }

  @Test
  fun encodesWhatAPasswordMayHold() {
    assertEquals(
      "rtsp://vi%40ewer:p%3Aa%2Fs%25s%20w%2Bo%C3%A9rd%21@192.0.2.30:554/stream1",
      cameraRtspUri("rtsp://192.0.2.30:554/stream1", "vi@ewer", "p:a/s%s w+oérd!"),
    )
  }

  @Test
  fun keepsTheUnreservedCharacters() {
    assertEquals("rtsp://a-b.c_d~e:F-9@h:554/p", cameraRtspUri("rtsp://h:554/p", "a-b.c_d~e", "F-9"))
  }

  @Test
  fun playsWithoutAnAccount() {
    assertEquals("rtsp://192.0.2.30:554/stream1", cameraRtspUri("rtsp://192.0.2.30:554/stream1", null, null))
    assertEquals("rtsp://192.0.2.30:554/stream1", cameraRtspUri("rtsp://192.0.2.30:554/stream1", "", "x"))
    assertEquals("rtsp://u@192.0.2.30:554/stream1", cameraRtspUri("rtsp://192.0.2.30:554/stream1", "u", ""))
  }

  @Test
  fun refusesAnotherAddress() {
    assertNull(cameraRtspUri("http://127.0.0.1:8080/live.m3u8", "u", "p"))
    assertNull(cameraRtspUri("rtsp://someone:else@192.0.2.30:554/stream1", "u", "p"))
    assertNull(cameraRtspUri("rtsp:///stream1", "u", "p"))
  }
}
