package app.alextran.immich.immersive

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackDetailsTest {
  private val english = emptyMap<String, String>()

  @Test
  fun `the line of a video tells its codec, its size, its frame rate and its bit rate`() {
    val line = PlaybackDetails.line("HEVC", "hvc1.2.4.L153.B0", 7680, 3840, 29.97f, 120_400_000, english, Locale.US)

    assertEquals("HEVC (hvc1.2.4.L153.B0) • 7680 x 3840 • 29.97 fps • 120 Mbit/s", line)
  }

  @Test
  fun `what the player does not know is left out`() {
    assertEquals("H.264 • 3840 x 1920", PlaybackDetails.line("H.264", null, 3840, 1920, -1f, -1, english, Locale.US))
    assertEquals("HEVC • 30 fps", PlaybackDetails.line("HEVC", " ", 0, 0, 30f, 0, english, Locale.US))
    assertEquals("?", PlaybackDetails.line("?", null, -1, -1, -1f, -1, english, Locale.US))
  }

  @Test
  fun `frame rates read as on the details of the app, without a useless decimal`() {
    assertEquals("30", PlaybackDetails.frameRate(30f))
    assertEquals("29.97", PlaybackDetails.frameRate(29.97003f))
    assertEquals("59.94", PlaybackDetails.frameRate(59.94006f))
    assertEquals("25", PlaybackDetails.frameRate(25.000002f))
    assertEquals("23.98", PlaybackDetails.frameRate(23.976f))
  }

  @Test
  fun `bit rates read as on the details of the app, one decimal below 10 Mbit per second only`() {
    assertEquals("120 Mbit/s", PlaybackDetails.bitRate(120_400_000, english, Locale.US))
    assertEquals("4.5 Mbit/s", PlaybackDetails.bitRate(4_520_000, english, Locale.US))
    assertEquals("4,5 Mbit/s", PlaybackDetails.bitRate(4_520_000, english, Locale.FRANCE))
    assertEquals("10 Mbit/s", PlaybackDetails.bitRate(9_960_000, english, Locale.US))
    assertEquals("850 kbit/s", PlaybackDetails.bitRate(850_400, english, Locale.US))
  }

  @Test
  fun `the units come translated from the app, the value filled in`() {
    val labels =
      mapOf(PlaybackDetails.LABEL_MBPS to "{value} Мбит/с", PlaybackDetails.LABEL_KBPS to "{value} кбит/с")

    assertEquals("4,5 Мбит/с", PlaybackDetails.bitRate(4_520_000, labels, Locale.forLanguageTag("ru")))
    assertEquals("850 кбит/с", PlaybackDetails.bitRate(850_000, labels, Locale.forLanguageTag("ru")))
  }

  @Test
  fun `the notices come translated from the app, else in English, their places filled in`() {
    val labels = mapOf(PlaybackDetails.LABEL_RESTARTED to "La vidéo s'est arrêtée à {position}, elle reprend là")

    assertEquals(
      "La vidéo s'est arrêtée à 7:20, elle reprend là",
      PlaybackDetails.text(labels, PlaybackDetails.LABEL_RESTARTED, "position" to "7:20"),
    )
    assertEquals(
      "The video stopped at 7:20, it plays again from there",
      PlaybackDetails.text(english, PlaybackDetails.LABEL_RESTARTED, "position" to "7:20"),
    )
    assertEquals(
      "No picture for 3 seconds from HEVC • 7680 x 3840, trying the server playback stream",
      PlaybackDetails.text(english, PlaybackDetails.LABEL_NO_PICTURE_SWITCH, "video" to "HEVC • 7680 x 3840"),
    )
    val notice = PlaybackDetails.text(english, PlaybackDetails.LABEL_NO_PICTURE, "video" to "HEVC • 7680 x 3840")
    assertEquals(
      "No picture for 3 seconds while the sound plays (HEVC • 7680 x 3840). What the headset saw is in the Logs of " +
        "the app",
      notice,
    )
  }

  @Test
  fun `a blank label falls back to the English text`() {
    val labels = mapOf(PlaybackDetails.LABEL_RESTARTED to "  ")

    assertEquals(
      "The video stopped at 0:05, it plays again from there",
      PlaybackDetails.text(labels, PlaybackDetails.LABEL_RESTARTED, "position" to "0:05"),
    )
  }

  @Test
  fun `the keys are the ones the app sends, see immersive_playback_labels dart`() {
    assertEquals("playbackRestarted", PlaybackDetails.LABEL_RESTARTED)
    assertEquals("playbackNoPicture", PlaybackDetails.LABEL_NO_PICTURE)
    assertEquals("playbackNoPictureSwitch", PlaybackDetails.LABEL_NO_PICTURE_SWITCH)
    assertEquals("playbackMbps", PlaybackDetails.LABEL_MBPS)
    assertEquals("playbackKbps", PlaybackDetails.LABEL_KBPS)
  }

  @Test
  fun `where a video plays from, in words for the report`() {
    assertEquals(
      "the server transcoded stream",
      PlaybackDetails.sourceOf("https://photos.example/api/assets/1/video/playback", isFallback = true),
    )
    assertEquals(
      "the server transcoded stream",
      PlaybackDetails.sourceOf("https://photos.example/api/assets/1/video/playback", isFallback = false),
    )
    assertEquals(
      "a network share, through the media bridge",
      PlaybackDetails.sourceOf("http://127.0.0.1:41234/secret/1/film.mp4", isFallback = false),
    )
    assertEquals(
      "the server original",
      PlaybackDetails.sourceOf("https://photos.example/api/assets/1/original", isFallback = false),
    )
    assertEquals("a file on the headset", PlaybackDetails.sourceOf("file:///sdcard/Movies/film.mp4", false))
    assertEquals("a file on the headset", PlaybackDetails.sourceOf("content://media/external/video/media/12", false))
    assertEquals("a network URL", PlaybackDetails.sourceOf("https://cdn.example/film.mp4", isFallback = false))
    // The stream Flutter sent as the fallback, whatever its path
    assertEquals("the server transcoded stream", PlaybackDetails.sourceOf("https://cdn.example/film.mp4", true))
  }

  @Test
  fun `the report of a restart says what failed, where, on what video, decoder and headset`() {
    val report =
      PlaybackDetails.report(
        event = PlaybackDetails.restartEvent("ERROR_CODE_DECODING_FAILED (MediaCodecDecoderException)", "7:20"),
        title = "FANTO.mp4",
        source = "a file on the headset",
        video = "HEVC (hvc1.2.4.L153) • 7680 x 3840 • 30 fps • 120 Mbit/s",
        decoder = "c2.qti.hevc.decoder",
        renderedFrames = 13_200,
        droppedFrames = 12,
        surfaceReady = true,
        device = "Meta Quest Pro, SoC QTI SM8250, Android 12 (API 32)",
      )

    assertEquals(
      "Immersive viewer, FANTO.mp4 from a file on the headset: restarted at 7:20 after " +
        "ERROR_CODE_DECODING_FAILED (MediaCodecDecoderException). " +
        "Video: HEVC (hvc1.2.4.L153) • 7680 x 3840 • 30 fps • 120 Mbit/s. Decoder: c2.qti.hevc.decoder. " +
        "Frames rendered: 13200, dropped: 12. Video surface: ready. " +
        "Device: Meta Quest Pro, SoC QTI SM8250, Android 12 (API 32).",
      report,
    )
  }

  @Test
  fun `the report of a picture missing tells whether it ever showed, and an unknown decoder or surface`() {
    val fromStart =
      PlaybackDetails.report(
        event = PlaybackDetails.noPictureEvent("0:03", framesBefore = false),
        title = null,
        source = "a file on the headset",
        video = null,
        decoder = null,
        renderedFrames = 0,
        droppedFrames = 0,
        surfaceReady = false,
        device = "Meta Quest Pro",
      )

    assertEquals(
      "Immersive viewer, a video from a file on the headset: no picture at 0:03 while the sound plays, none since " +
        "the start. Video: no video track selected. Decoder: none started. Frames rendered: 0, dropped: 0. " +
        "Video surface: not given by the headset yet. Device: Meta Quest Pro.",
      fromStart,
    )
    assertEquals(
      "no picture at 1:03 while the sound plays, the picture stopped",
      PlaybackDetails.noPictureEvent("1:03", framesBefore = true),
    )
    assertEquals(
      "restarted at 1:03, no new picture for 3 s while the sound played",
      PlaybackDetails.stoppedEvent("1:03"),
    )
  }

  @Test
  fun `a url in the error of a report is taken out, a share url holds its token`() {
    val event =
      PlaybackDetails.errorEvent("ERROR_CODE_IO_UNSPECIFIED (IOException: http://127.0.0.1:41234/secret/a.mp4)")

    assertEquals("cannot be played: ERROR_CODE_IO_UNSPECIFIED (IOException: (a URL))", event)
    assertEquals(
      "restarted at 0:00 after ERROR_CODE_DECODING_FAILED ((a URL))",
      PlaybackDetails.restartEvent("ERROR_CODE_DECODING_FAILED (file:///sdcard/a.mp4)", "0:00"),
    )
  }
}
