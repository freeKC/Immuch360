package app.alextran.immich.camera

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The live views play as HLS only the playlists of the local media bridge: what Dart makes of a camera's media port */
class CameraLivePlaylistTest {
  @Test
  fun takesThePlaylistOfTheBridge() {
    assertTrue(isLocalLivePlaylist("http://127.0.0.1:41234/token/live-abc/live.m3u8"))
  }

  @Test
  fun refusesAnythingElse() {
    assertFalse(isLocalLivePlaylist("https://127.0.0.1:41234/token/live.m3u8"))
    assertFalse(isLocalLivePlaylist("http://192.0.2.30:8800/stream"))
    assertFalse(isLocalLivePlaylist("http://127.0.0.1.example.com:80/live.m3u8"))
    assertFalse(isLocalLivePlaylist("http://127.0.0.1:/live.m3u8"))
    assertFalse(isLocalLivePlaylist("http://127.0.0.1:41234"))
    assertFalse(isLocalLivePlaylist("http://127.0.0.1:41234/"))
    assertFalse(isLocalLivePlaylist("rtsp://127.0.0.1:554/stream1"))
  }
}
