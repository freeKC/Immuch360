package app.alextran.immich.immersive

import androidx.media3.common.PlaybackException
import app.alextran.immich.immersive.PlaybackRecovery.Action
import app.alextran.immich.immersive.PlaybackRecovery.Cause
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackRecoveryTest {
  private val decoderFailed = PlaybackException.ERROR_CODE_DECODING_FAILED
  private val audioWriteFailed = PlaybackException.ERROR_CODE_AUDIO_TRACK_WRITE_FAILED

  /** A video that started at [startMs] and showed its first frame, then played with frames up to [untilMs]. */
  private fun playing(startMs: Long = 0L, untilMs: Long = 10_000L): PlaybackRecovery =
    PlaybackRecovery().apply {
      onMedia()
      onPlay()
      onFrame()
      var frames = 0
      var position = startMs
      while (position <= untilMs) {
        frames += 15
        assertEquals(Action.None, onTick(playing = true, positionMs = position, renderedFrames = frames))
        position += 500
      }
    }

  /** Ticks every 500 ms of media from [fromMs] to [toMs] while the frame count stays at [frames]. */
  private fun PlaybackRecovery.tickWithoutFrames(fromMs: Long, toMs: Long, frames: Int): List<Action> {
    val actions = ArrayList<Action>()
    var position = fromMs
    while (position <= toMs) {
      actions += onTick(playing = true, positionMs = position, renderedFrames = frames)
      position += 500
    }
    return actions.filter { it != Action.None }
  }

  @Test
  fun `a decoder failure in the middle of a video restarts it once where it stopped`() {
    val recovery = playing(untilMs = 440_000L)

    assertEquals(Action.Restart(440_000L, Cause.DECODER), recovery.onFailure(decoderFailed, 440_000L))
  }

  @Test
  fun `a second failure after the restart is left to the viewer, so the retries never loop`() {
    val recovery = playing(untilMs = 440_000L)
    assertTrue(recovery.onFailure(decoderFailed, 440_000L) is Action.Restart)
    recovery.onPlay()
    recovery.onFrame()

    assertEquals(Action.PassOn, recovery.onFailure(decoderFailed, 445_000L))
    assertEquals(Action.PassOn, recovery.onFailure(decoderFailed, 446_000L))
  }

  @Test
  fun `a restarted player that fails before its first frame is left to the viewer`() {
    val recovery = playing(untilMs = 20_000L)
    assertTrue(recovery.onFailure(decoderFailed, 20_000L) is Action.Restart)
    recovery.onPlay()

    assertEquals(Action.PassOn, recovery.onFailure(decoderFailed, 20_000L))
  }

  @Test
  fun `a new url on the same media, the transcoded stream, does not give the retry back`() {
    val recovery = playing(untilMs = 20_000L)
    assertTrue(recovery.onFailure(decoderFailed, 20_000L) is Action.Restart)
    recovery.onPlay()
    recovery.onFrame()
    recovery.onPlay()
    recovery.onFrame()

    assertEquals(Action.PassOn, recovery.onFailure(decoderFailed, 30_000L))
  }

  @Test
  fun `a new media, or the next visitor of a kiosk, gets its own retry`() {
    val recovery = playing(untilMs = 20_000L)
    assertTrue(recovery.onFailure(decoderFailed, 20_000L) is Action.Restart)
    recovery.onMedia()
    recovery.onPlay()
    recovery.onFrame()

    assertEquals(Action.Restart(5_000L, Cause.DECODER), recovery.onFailure(decoderFailed, 5_000L))
  }

  @Test
  fun `a failure before the first frame is a video that does not start, left to the viewer`() {
    val recovery = PlaybackRecovery().apply {
      onMedia()
      onPlay()
    }

    assertEquals(Action.PassOn, recovery.onFailure(decoderFailed, 0L))
    assertEquals(Action.PassOn, recovery.onFailure(PlaybackException.ERROR_CODE_DECODER_INIT_FAILED, 0L))
  }

  @Test
  fun `the media server and the audio server count, the source and the format do not`() {
    val restarted =
      listOf(
        PlaybackException.ERROR_CODE_DECODING_FAILED to Cause.DECODER,
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED to Cause.DECODER,
        PlaybackException.ERROR_CODE_DECODING_RESOURCES_RECLAIMED to Cause.DECODER,
        PlaybackException.ERROR_CODE_AUDIO_TRACK_INIT_FAILED to Cause.MEDIA_SERVER,
        PlaybackException.ERROR_CODE_AUDIO_TRACK_WRITE_FAILED to Cause.MEDIA_SERVER,
      )
    for ((code, cause) in restarted) {
      assertEquals("code $code", Action.Restart(10_000L, cause), playing().onFailure(code, 10_000L))
    }
    val passed =
      listOf(
        PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
        PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND,
        PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
        PlaybackException.ERROR_CODE_VIDEO_FRAME_PROCESSING_FAILED,
        PlaybackException.ERROR_CODE_UNSPECIFIED,
      )
    for (code in passed) {
      assertEquals("code $code", Action.PassOn, playing().onFailure(code, 10_000L))
    }
  }

  @Test
  fun `a failure that reports no position restarts at the last one read`() {
    val recovery = playing(untilMs = 7 * 60_000L + 20_000L)

    assertEquals(Action.Restart(440_000L, Cause.DECODER), recovery.onFailure(decoderFailed, 0L))
    assertEquals(Action.PassOn, recovery.onFailure(decoderFailed, -1L))
  }

  @Test
  fun `a position read while paused, after a seek, is where a failure without position restarts`() {
    val recovery = playing(untilMs = 30_000L)
    recovery.onSeek()
    assertEquals(Action.None, recovery.onTick(playing = false, positionMs = 90_000L, renderedFrames = 15 * 61))

    assertEquals(Action.Restart(90_000L, Cause.MEDIA_SERVER), recovery.onFailure(audioWriteFailed, 0L))
  }

  @Test
  fun `no picture for 3 s of a playing video from its start is said once, never restarted`() {
    val recovery = PlaybackRecovery().apply {
      onMedia()
      onPlay()
    }

    val actions = recovery.tickWithoutFrames(0L, 10_000L, frames = 0)

    assertEquals(listOf(Action.NoPicture(3_000L, framesBefore = false)), actions)
  }

  @Test
  fun `a picture that stops while the sound plays on restarts the player once, then is said`() {
    val recovery = playing(untilMs = 60_000L)
    val frames = 15 * 121

    val first = recovery.tickWithoutFrames(60_500L, 70_000L, frames)
    assertEquals(listOf<Action>(Action.Restart(63_000L, Cause.PICTURE_STOPPED)), first)

    recovery.onPlay()
    recovery.onFrame()
    val second = recovery.tickWithoutFrames(63_500L, 70_000L, frames = 40)
    assertEquals(listOf<Action>(Action.NoPicture(66_500L, framesBefore = true)), second)
  }

  @Test
  fun `a picture that stops after the retry was spent on a failure is said, not restarted`() {
    val recovery = playing(untilMs = 30_000L)
    assertTrue(recovery.onFailure(decoderFailed, 30_000L) is Action.Restart)
    recovery.onPlay()
    recovery.onFrame()

    val actions = recovery.tickWithoutFrames(30_000L, 40_000L, frames = 10)

    assertEquals(listOf<Action>(Action.NoPicture(33_000L, framesBefore = true)), actions)
  }

  @Test
  fun `a pause, a stall of the source or a seek never count as a picture missing`() {
    val recovery = playing(untilMs = 10_000L)
    val frames = 15 * 21

    // Paused for a minute, then buffering: playing is false, the position and the frames do not move
    repeat(130) {
      assertEquals(Action.None, recovery.onTick(playing = false, positionMs = 10_000L, renderedFrames = frames))
    }
    // Playing again: the count goes on from where it stopped
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 12_500L, renderedFrames = frames))
    // A seek forward of a minute: the frames after it take a moment
    recovery.onSeek()
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 70_000L, renderedFrames = frames))
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 72_000L, renderedFrames = frames))
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 72_500L, renderedFrames = frames + 10))
  }

  @Test
  fun `the position going back, a loop or a seek back, starts the count again there`() {
    val recovery = playing(untilMs = 10_000L)
    val frames = 15 * 21

    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 12_000L, renderedFrames = frames))
    // The loop starts over without a seek reported: from there, 3 s without a frame is a picture that stopped
    val actions = recovery.tickWithoutFrames(0L, 5_000L, frames)

    assertEquals(listOf<Action>(Action.Restart(3_000L, Cause.PICTURE_STOPPED)), actions)
  }

  @Test
  fun `frames that move on after the position went back are no stall`() {
    val recovery = playing(untilMs = 10_000L)
    val frames = 15 * 21

    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 0L, renderedFrames = frames))
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 2_500L, renderedFrames = frames))
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 2_600L, renderedFrames = frames + 1))
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 5_500L, renderedFrames = frames + 40))
  }

  @Test
  fun `frames counted again from zero by a new renderer move the count, they are no stall`() {
    val recovery = playing(untilMs = 10_000L)

    recovery.onPlay()
    // The old counters, then none while the renderer is enabled again, then the new ones
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 10_000L, renderedFrames = 315))
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 10_500L, renderedFrames = 0))
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 11_000L, renderedFrames = 12))
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 13_400L, renderedFrames = 12))
  }

  @Test
  fun `no picture is said once per url, a new url may say it again`() {
    val recovery = PlaybackRecovery().apply {
      onMedia()
      onPlay()
    }
    assertEquals(1, recovery.tickWithoutFrames(0L, 20_000L, frames = 0).size)

    recovery.onPlay()

    assertEquals(
      listOf<Action>(Action.NoPicture(23_000L, framesBefore = false)),
      recovery.tickWithoutFrames(20_000L, 40_000L, frames = 0),
    )
  }

  @Test
  fun `frames counted between two reads are seen without the first frame callback`() {
    val recovery = PlaybackRecovery().apply {
      onMedia()
      onPlay()
    }
    // One read alone may still be the counters of the previous url, before its renderer is enabled again
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 0L, renderedFrames = 315))
    assertFalse(recovery.framesSeen)
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 100L, renderedFrames = 0))
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 400L, renderedFrames = 12))

    assertTrue(recovery.framesSeen)
    assertEquals(Action.Restart(400L, Cause.DECODER), recovery.onFailure(decoderFailed, 400L))
  }

  @Test
  fun `nothing is seen before the first frame of the url`() {
    val recovery = PlaybackRecovery().apply {
      onMedia()
      onPlay()
    }

    assertFalse(recovery.framesSeen)
    recovery.onFrame()
    assertTrue(recovery.framesSeen)
    recovery.onPlay()
    assertFalse(recovery.framesSeen)
  }
}
