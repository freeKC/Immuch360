package app.alextran.immich.core

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.TrackSelectionParameters
import java.util.Locale
import me.albemala.native_video_player.VideoTracks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/** What the flat player of the viewers tells the app of the audio and subtitle tracks of a video */
class VideoTracksTest {
  @Test
  fun describesATrackWithItsLanguageNamedInTheLanguageAsked() {
    val entry = VideoTracks.entry(
      VideoTracks.AUDIO,
      group = 2,
      track = 1,
      language = "fr",
      label = " Commentaire ",
      channels = 6,
      selected = true,
      selectionFlags = C.SELECTION_FLAG_DEFAULT,
      displayLocale = Locale.ENGLISH,
    )
    assertEquals(
      mapOf(
        "type" to "audio",
        "group" to 2,
        "track" to 1,
        "language" to "fr",
        "languageName" to "French",
        "label" to "Commentaire",
        "channels" to 6,
        "selected" to true,
        "isDefault" to true,
        "isForced" to false,
      ),
      entry,
    )
  }

  @Test
  fun leavesOutWhatTheFileDoesNotTell() {
    val entry = VideoTracks.entry(
      VideoTracks.TEXT,
      group = 0,
      track = 0,
      language = "und",
      label = "",
      channels = Format.NO_VALUE,
      selected = false,
      selectionFlags = C.SELECTION_FLAG_FORCED,
      displayLocale = Locale.FRENCH,
    )
    assertNull(entry["language"])
    assertNull(entry["languageName"])
    assertNull(entry["label"])
    assertEquals(0, entry["channels"])
    assertEquals(true, entry["isForced"])
    assertEquals(false, entry["isDefault"])
  }

  @Test
  fun namesTheLanguageInTheLanguageOfTheApp() {
    assertEquals("Anglais", VideoTracks.languageName("en", Locale.FRENCH))
    assertEquals("Portuguese (Brazil)", VideoTracks.languageName("pt-BR", Locale.ENGLISH))
    assertEquals(Locale.FRENCH.language, VideoTracks.displayLocale("fr").language)
    assertEquals(Locale.getDefault(), VideoTracks.displayLocale(null))
    assertEquals(Locale.getDefault(), VideoTracks.displayLocale(""))
  }

  @Test
  fun startsWithoutTheSubtitlesAFileFlagsAsDefault() {
    // The defaults of a device whose caption settings ask for French captions
    val device = TrackSelectionParameters.Builder()
      .setPreferredTextLanguage("fr")
      .setPreferredTextRoleFlags(C.ROLE_FLAG_CAPTION)
      .build()
    val parameters = VideoTracks.initialParameters(device, audioLanguage = "de")
    assertEquals(C.SELECTION_FLAG_DEFAULT, parameters.ignoredTextSelectionFlags)
    // Forced subtitles still start, and so do the captions the device asks for
    assertEquals(0, parameters.ignoredTextSelectionFlags and C.SELECTION_FLAG_FORCED)
    assertEquals(listOf("fr"), parameters.preferredTextLanguages)
    assertEquals(C.ROLE_FLAG_CAPTION, parameters.preferredTextRoleFlags)
    assertFalse(C.TRACK_TYPE_TEXT in parameters.disabledTrackTypes)
    // The audio language the user picked last
    assertEquals(listOf("de"), parameters.preferredAudioLanguages)
  }

  @Test
  fun leavesTheAudioToTheFileBeforeAnyPick() {
    val parameters = VideoTracks.initialParameters(TrackSelectionParameters.Builder().build(), audioLanguage = null)
    assertEquals(emptyList<String>(), parameters.preferredAudioLanguages)
    assertEquals(C.SELECTION_FLAG_DEFAULT, parameters.ignoredTextSelectionFlags)
  }

  @Test
  fun knowsTheTypesOfTheMenus() {
    assertEquals(C.TRACK_TYPE_AUDIO, VideoTracks.trackType("audio"))
    assertEquals(C.TRACK_TYPE_TEXT, VideoTracks.trackType("text"))
    assertNull(VideoTracks.trackType("video"))
  }
}
