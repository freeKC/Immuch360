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

  /** A decoder failure at [positionMs]: 3 s past it, after 1.5 s, when the file tells no later sync frame. */
  private fun decoderRestart(positionMs: Long) = Action.Restart(positionMs, Cause.DECODER, positionMs + 3_000L, 1_500L)

  @Test
  fun `a decoder failure in the middle of a video restarts it once, past where it stopped, after a wait`() {
    val recovery = playing(untilMs = 432_000L)

    // The film of the exhibition builds fails around 432519 ms: the frames there broke the decoder, a new one starts
    // 3 s later, once the media service had time to come back
    assertEquals(
      Action.Restart(432_519L, Cause.DECODER, resumeMs = 435_519L, delayMs = 1_500L),
      recovery.onFailure(decoderFailed, 432_519L, durationMs = 497_000L),
    )
  }

  @Test
  fun `the media server that went away waits as long, the video plays again where it stopped`() {
    val recovery = playing(untilMs = 60_000L)

    assertEquals(
      Action.Restart(60_000L, Cause.MEDIA_SERVER, resumeMs = 60_000L, delayMs = 1_500L),
      recovery.onFailure(audioWriteFailed, 60_000L, durationMs = 497_000L),
    )
  }

  @Test
  fun `the restart of a decoder starts at the next sync frame the file tells, past the failure`() {
    val restart = decoderRestart(432_519L)

    assertEquals(435_519L, restart.syncFromMs)
    // The fork's own restart point, the sync frame they asked for at 7:20
    assertEquals(440_000L, PlaybackRecovery.resumeAt(432_519L, Cause.DECODER, 497_000L, nextSyncMs = 440_000L))
    // A sync frame before the place looked from is none: 3 s past the failure
    assertEquals(435_519L, PlaybackRecovery.resumeAt(432_519L, Cause.DECODER, 497_000L, nextSyncMs = 432_000L))
    assertEquals(435_519L, PlaybackRecovery.resumeAt(432_519L, Cause.DECODER, 497_000L, nextSyncMs = null))
    // A duration not known yet (C.TIME_UNSET) clamps nothing
    assertEquals(440_000L, PlaybackRecovery.resumeAt(432_519L, Cause.DECODER, Long.MIN_VALUE + 1, 440_000L))
    // The other causes play again where it stopped, nothing looked up
    assertEquals(null, Action.Restart(60_000L, Cause.MEDIA_SERVER, 60_000L, 1_500L).syncFromMs)
    assertEquals(null, Action.Restart(63_000L, Cause.PICTURE_STOPPED, 63_000L, 0L).syncFromMs)
    assertEquals(60_000L, PlaybackRecovery.resumeAt(60_000L, Cause.MEDIA_SERVER, 497_000L, nextSyncMs = 62_000L))
    assertEquals(63_000L, PlaybackRecovery.resumeAt(63_000L, Cause.PICTURE_STOPPED, 497_000L, nextSyncMs = 64_000L))
  }

  @Test
  fun `a restart past the failure stays before the end of the video, which would end it`() {
    // 3 s past the failure is still 1 s before the end; the next sync frame after it is not
    assertEquals(495_000L, PlaybackRecovery.resumeAt(492_000L, Cause.DECODER, 497_000L, nextSyncMs = 496_500L))
    assertEquals(495_000L, PlaybackRecovery.resumeAt(492_000L, Cause.DECODER, 497_000L, nextSyncMs = null))
    assertEquals(496_000L, PlaybackRecovery.resumeAt(492_000L, Cause.DECODER, 497_000L, nextSyncMs = 496_000L))
    // Too close to the end for 3 s: 1 s before the end
    assertEquals(496_000L, PlaybackRecovery.resumeAt(494_500L, Cause.DECODER, 497_000L, nextSyncMs = null))
    // In the last second: where it stopped, never before
    assertEquals(496_500L, PlaybackRecovery.resumeAt(496_500L, Cause.DECODER, 497_000L, nextSyncMs = null))
    val recovery = playing(untilMs = 20_000L)
    assertEquals(
      Action.Restart(20_500L, Cause.DECODER, resumeMs = 22_000L, delayMs = 1_500L),
      recovery.onFailure(decoderFailed, 20_500L, durationMs = 23_000L),
    )
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

    assertEquals(decoderRestart(5_000L), recovery.onFailure(decoderFailed, 5_000L))
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
      val resume = if (cause == Cause.DECODER) 13_000L else 10_000L
      assertEquals("code $code", Action.Restart(10_000L, cause, resume, 1_500L), playing().onFailure(code, 10_000L))
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

    assertEquals(decoderRestart(440_000L), recovery.onFailure(decoderFailed, 0L))
    assertEquals(decoderRestart(440_000L), playing(untilMs = 440_000L).onFailure(decoderFailed, -1L))
  }

  @Test
  fun `a position read while paused, after a seek, is where a failure without position restarts`() {
    val recovery = playing(untilMs = 30_000L)
    recovery.onSeek()
    assertEquals(Action.None, recovery.onTick(playing = false, positionMs = 90_000L, renderedFrames = 15 * 61))

    assertEquals(
      Action.Restart(90_000L, Cause.MEDIA_SERVER, 90_000L, 1_500L),
      recovery.onFailure(audioWriteFailed, 0L),
    )
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
    // No wait and no skip: the decoder did not fail, the picture plays again from where the sound is
    assertEquals(listOf<Action>(Action.Restart(63_000L, Cause.PICTURE_STOPPED, 63_000L, 0L)), first)

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

    assertEquals(listOf<Action>(Action.Restart(3_000L, Cause.PICTURE_STOPPED, 3_000L, 0L)), actions)
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
    assertEquals(decoderRestart(400L), recovery.onFailure(decoderFailed, 400L))
  }

  @Test
  fun `a slide show made into a video is not watched, any other video is, its rate known or not`() {
    assertFalse(PlaybackRecovery.watches(0.2f))
    assertFalse(PlaybackRecovery.watches(0.99f))
    assertTrue(PlaybackRecovery.watches(1f))
    assertTrue(PlaybackRecovery.watches(29.97f))
    assertTrue(PlaybackRecovery.watches(-1f))
    assertTrue(PlaybackRecovery.watches(0f))
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

  @Test
  fun `while the restart waits, the errors and the reads of the old player are those of the failure`() {
    val recovery = playing(untilMs = 30_000L)
    assertTrue(recovery.onFailure(decoderFailed, 30_000L) is Action.Restart)

    assertTrue(recovery.restartPending)
    assertEquals(Action.None, recovery.onFailure(decoderFailed, 30_000L))
    assertEquals(Action.None, recovery.onFailure(PlaybackException.ERROR_CODE_IO_UNSPECIFIED, 30_000L))
    assertEquals(emptyList<Action>(), recovery.tickWithoutFrames(30_000L, 40_000L, frames = 0))
    // The new player starts the url: its own failures count again, the retry spent
    recovery.onPlay()
    assertFalse(recovery.restartPending)
    recovery.onFrame()
    assertEquals(Action.PassOn, recovery.onFailure(decoderFailed, 36_000L))
  }

  @Test
  fun `a restart dropped, the media changed or stopped meanwhile, waits no more`() {
    val recovery = playing(untilMs = 30_000L)
    assertTrue(recovery.onFailure(decoderFailed, 30_000L) is Action.Restart)

    recovery.cancelRestart()

    assertFalse(recovery.restartPending)
    assertEquals(Action.PassOn, recovery.onFailure(decoderFailed, 30_000L))
    val next = playing(untilMs = 10_000L)
    assertTrue(next.onFailure(decoderFailed, 10_000L) is Action.Restart)
    next.onMedia()
    assertFalse(next.restartPending)
  }

  @Test
  fun `frames that move again after a picture said missing take the notice away, once`() {
    val recovery = PlaybackRecovery().apply {
      onMedia()
      onPlay()
    }
    assertEquals(listOf(Action.NoPicture(3_000L, framesBefore = false)), recovery.tickWithoutFrames(0L, 4_000L, 0))

    // The decoder catches up: the first read above the last one
    assertEquals(Action.PictureBack, recovery.onTick(playing = true, positionMs = 4_500L, renderedFrames = 12))
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 5_000L, renderedFrames = 27))
    // Said once for the url: a picture that stops again is not said again
    assertEquals(emptyList<Action>(), recovery.tickWithoutFrames(5_500L, 12_000L, frames = 27))
  }

  @Test
  fun `the surface of the video panel given late watches the url again`() {
    val recovery = PlaybackRecovery().apply {
      onMedia()
      onPlay()
    }
    // No surface yet: no frame rendered, said once
    assertEquals(listOf(Action.NoPicture(3_000L, framesBefore = false)), recovery.tickWithoutFrames(0L, 6_000L, 0))
    assertEquals(emptyList<Action>(), recovery.tickWithoutFrames(6_500L, 12_000L, frames = 0))

    recovery.onSurface()

    // Still no frame with the surface: a decoder problem, said again (the viewer then tries the transcoded stream)
    assertEquals(
      listOf(Action.NoPicture(15_500L, framesBefore = false)),
      recovery.tickWithoutFrames(12_500L, 20_000L, frames = 0),
    )
  }

  @Test
  fun `the surface given late, the frames that come take the notice away`() {
    val recovery = PlaybackRecovery().apply {
      onMedia()
      onPlay()
    }
    assertEquals(listOf(Action.NoPicture(3_000L, framesBefore = false)), recovery.tickWithoutFrames(0L, 4_000L, 0))

    recovery.onSurface()

    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 4_500L, renderedFrames = 0))
    assertEquals(Action.PictureBack, recovery.onTick(playing = true, positionMs = 5_000L, renderedFrames = 15))
    assertTrue(recovery.framesSeen)
  }

  @Test
  fun `a new url forgets a picture said missing`() {
    val recovery = PlaybackRecovery().apply {
      onMedia()
      onPlay()
    }
    assertEquals(1, recovery.tickWithoutFrames(0L, 4_000L, frames = 0).size)

    recovery.onPlay()

    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 4_500L, renderedFrames = 0))
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 5_000L, renderedFrames = 15))
  }

  @Test
  fun `a new media restarts from its own position, never from the last one read of the media before`() {
    val recovery = playing(untilMs = 20_000L)
    recovery.onMedia()
    recovery.onPlay()
    recovery.onFrame()

    // A failure that reports no position before the first read of the new media
    assertEquals(decoderRestart(0L), recovery.onFailure(decoderFailed, 0L))
  }

  @Test
  fun `the counters read once after a new url are not frames of that url`() {
    val recovery = playing(untilMs = 10_000L)

    recovery.onPlay()
    // Above the count of the previous url: one read alone may still be its counters
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = 10_000L, renderedFrames = 330))

    assertFalse(recovery.framesSeen)
    assertEquals(Action.PassOn, recovery.onFailure(decoderFailed, 10_000L))
  }

  @Test
  fun `a failure restarts from the position it reports, even below the last one read`() {
    val recovery = playing(untilMs = 20_000L)

    assertEquals(decoderRestart(15_000L), recovery.onFailure(decoderFailed, 15_000L))
  }

  @Test
  fun `a position read below 0 is the start, for a failure that reports none`() {
    val recovery = playing(untilMs = 1_000L)
    assertEquals(Action.None, recovery.onTick(playing = true, positionMs = -40L, renderedFrames = 40))

    assertEquals(decoderRestart(0L), recovery.onFailure(decoderFailed, 0L))
  }

  @Test
  fun `a player that does not say it plays is never taken for a picture missing`() {
    val recovery = PlaybackRecovery().apply {
      onMedia()
      onPlay()
    }
    var position = 0L
    while (position <= 10_000L) {
      assertEquals(Action.None, recovery.onTick(playing = false, positionMs = position, renderedFrames = 0))
      position += 500
    }
  }
}
