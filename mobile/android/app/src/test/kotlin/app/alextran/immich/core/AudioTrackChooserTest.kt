package app.alextran.immich.core

import androidx.media3.common.Format
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The names of the audio tracks in the dialog of the native video players */
class AudioTrackChooserTest {
  private val english = mapOf(
    AudioTrackChooser.LABEL_DEFAULT to "Default",
    AudioTrackChooser.LABEL_NUMBER to "Track {track}",
    AudioTrackChooser.LABEL_MONO to "Mono",
    AudioTrackChooser.LABEL_STEREO to "Stereo",
    AudioTrackChooser.LABEL_CHANNELS to "{channels} channels",
  )

  private fun label(key: String): String = english.getValue(key)

  /** A track as Media3 describes it (Format needs the Android runtime, which these tests run without) */
  private data class Track(val language: String? = null, val name: String? = null, val channels: Int = Format.NO_VALUE)

  private fun name(track: Track, number: Int = 1, markDefault: Boolean = false, locale: Locale = Locale.ENGLISH) =
    AudioTrackChooser.trackName(track.language, track.name, track.channels, number, markDefault, locale, ::label)

  @Test
  fun namesTheLanguageInTheLanguageOfTheApp() {
    assertEquals("French, 5.1", name(Track("fr", channels = 6)))
    val french = AudioTrackChooser.trackName("en", null, 2, 1, false, Locale.FRENCH) {
      if (it == AudioTrackChooser.LABEL_STEREO) "Stéréo" else label(it)
    }
    assertEquals("Anglais, Stéréo", french)
  }

  @Test
  fun writesTheLanguageWithACapital() {
    // Java names languages in French in lower case
    assertEquals("Français", AudioTrackChooser.languageName("fr", Locale.FRENCH))
  }

  @Test
  fun keepsTheRegion() {
    assertEquals("Portuguese (Brazil)", AudioTrackChooser.languageName("pt-BR", Locale.ENGLISH))
  }

  @Test
  fun addsTheNameOfTheTrackWhenItSaysMore() {
    assertEquals("English, Director's commentary, Stereo", name(Track("en", "Director's commentary", 2)))
    // A name that only repeats the language is left out
    assertEquals("English, Stereo", name(Track("en", "english", 2)))
  }

  @Test
  fun numbersATrackWithNeitherLanguageNorName() {
    assertEquals("Track 2, Mono", name(Track(channels = 1), number = 2))
    assertEquals("Track 3", name(Track("und"), number = 3))
    assertEquals("Commentary", name(Track("und", "Commentary")))
  }

  @Test
  fun marksTheDefaultTrack() {
    assertEquals("German, 7.1, Default", name(Track("de", channels = 8), markDefault = true))
  }

  @Test
  fun namesTheChannels() {
    assertNull(AudioTrackChooser.channelsName(Format.NO_VALUE, ::label))
    assertEquals("Mono", AudioTrackChooser.channelsName(1, ::label))
    assertEquals("Stereo", AudioTrackChooser.channelsName(2, ::label))
    assertEquals("4 channels", AudioTrackChooser.channelsName(4, ::label))
    assertEquals("5.1", AudioTrackChooser.channelsName(6, ::label))
    assertEquals("7.1", AudioTrackChooser.channelsName(8, ::label))
  }

  @Test
  fun ignoresCodesThatNameNoLanguage() {
    for (code in listOf("und", "mul", "zxx", "")) {
      assertNull(code, AudioTrackChooser.languageOf(code))
    }
    assertNull(AudioTrackChooser.languageOf(null as String?))
    assertEquals("ja", AudioTrackChooser.languageOf(" ja "))
  }
}
