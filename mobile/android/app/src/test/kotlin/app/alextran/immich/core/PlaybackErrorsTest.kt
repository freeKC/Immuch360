package app.alextran.immich.core

import androidx.media3.common.PlaybackException
import androidx.media3.common.util.StuckPlayerException
import app.alextran.immich.core.PlaybackErrors.Kind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class PlaybackErrorsTest {
  private val timeout = PlaybackException.ERROR_CODE_TIMEOUT

  @Test
  fun `the stuck playing check of Media3 on a video is a decoder that gives no picture`() {
    // The flat player of 30 October: H.264 5760 x 2880 on a Quest 3, "Player stuck playing with no progress for
    // 10000 ms", the decoder full of data and no frame out of it
    assertEquals(
      Kind.NO_FRAME,
      PlaybackErrors.kindOf(
        timeout,
        StuckPlayerException.STUCK_PLAYING_NO_PROGRESS,
        videoKnown = true,
        decoderGotMedia = false,
      ),
    )
  }

  @Test
  fun `a buffer full that does not play is the decoder too, a buffer that does not fill is the network`() {
    assertEquals(
      Kind.NO_FRAME,
      PlaybackErrors.kindOf(timeout, StuckPlayerException.STUCK_BUFFERING_NOT_LOADING, true, false),
    )
    assertEquals(
      Kind.STALLED,
      PlaybackErrors.kindOf(timeout, StuckPlayerException.STUCK_BUFFERING_NO_PROGRESS, true, false),
    )
    assertEquals(
      Kind.NO_FRAME,
      PlaybackErrors.kindOf(timeout, StuckPlayerException.STUCK_BUFFERING_NO_PROGRESS, true, true),
    )
  }

  @Test
  fun `without a video track a stuck player is the network, or a video that stopped`() {
    assertEquals(
      Kind.STALLED,
      PlaybackErrors.kindOf(timeout, StuckPlayerException.STUCK_BUFFERING_NOT_LOADING, false, false),
    )
    assertEquals(
      Kind.STOPPED,
      PlaybackErrors.kindOf(timeout, StuckPlayerException.STUCK_PLAYING_NO_PROGRESS, false, false),
    )
  }

  @Test
  fun `every other stuck check is a video that stopped, never the text of Media3`() {
    for (type in listOf(StuckPlayerException.STUCK_PLAYING_NOT_ENDING, StuckPlayerException.STUCK_SUPPRESSED)) {
      assertEquals("$type", Kind.STOPPED, PlaybackErrors.kindOf(timeout, type, true, true))
    }
  }

  @Test
  fun `a decoder that refuses or fails is the decoder, a connection that times out the network`() {
    for (code in
      listOf(
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
        PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
      )) {
      assertEquals("$code", Kind.DECODER, PlaybackErrors.kindOf(code, null, true, false))
    }
    assertEquals(
      Kind.STALLED,
      PlaybackErrors.kindOf(PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT, null, true, false),
    )
  }

  @Test
  fun `the other errors keep the words of the player`() {
    for (code in
      listOf(
        PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
        PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND,
        PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
        PlaybackException.ERROR_CODE_UNSPECIFIED,
      )) {
      assertNull("$code", PlaybackErrors.kindOf(code, null, true, true))
    }
    // A timeout of another kind than the stuck checks
    assertNull(PlaybackErrors.kindOf(timeout, null, true, true))
  }

  @Test
  fun `each kind reads the label of the players`() {
    assertEquals("errorDecoder", Kind.DECODER.label)
    assertEquals("errorNoFrame", Kind.NO_FRAME.label)
    assertEquals("errorStalled", Kind.STALLED.label)
    assertNull(Kind.STOPPED.label)
  }

  @Test
  fun `the token for Flutter carries the kind, the codec and the frame, and is told from a text of the player`() {
    assertEquals(
      "immuch360-playback-error:noFrame:video/avc:5760:2880",
      PlaybackErrors.token(Kind.NO_FRAME, "video/avc", 5760, 2880),
    )
    assertEquals("immuch360-playback-error:stalled::0:0", PlaybackErrors.token(Kind.STALLED, null, 0, 0))
    assertEquals("immuch360-playback-error:stopped::0:0", PlaybackErrors.token(Kind.STOPPED, null, -1, -1))
    assertFalse("Player stuck playing with no progress for 10000 ms".startsWith(PlaybackErrors.TOKEN_PREFIX))
  }
}
