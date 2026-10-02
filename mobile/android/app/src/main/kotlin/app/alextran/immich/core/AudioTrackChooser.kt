package app.alextran.immich.core

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import java.util.Locale

/**
 * The audio tracks of the video a Media3 player plays (languages, commentary), and the pick of the user among them,
 * for the native video players. A video with two audio tracks or more shows an audio track button; its dialog lists
 * the tracks by language, name and channels, and the pick goes to the player as a track selection override.
 *
 * The language of the track picked is remembered for every video (shared preferences), and the players prefer it for
 * the next videos. The pick itself is kept for the video in play: a new player for it (after a stop, or a recreated
 * activity, see [chosenIndex]) gets it back once its tracks are known.
 *
 * [labels] are the translated labels from Flutter, under the keys of the companion; English is the fallback.
 */
@OptIn(UnstableApi::class)
class AudioTrackChooser(context: Context, private val labels: Map<String, String>) {
  /** An audio track of the video: [format] is track [trackIndex] of [group] */
  data class Option(val group: Tracks.Group, val trackIndex: Int, val format: Format, val selected: Boolean)

  companion object {
    /** Label of the button and title of the dialog */
    const val LABEL_AUDIO_TRACK = "audioTrack"

    /** Marks the track the file plays by default */
    const val LABEL_DEFAULT = "audioTrackDefault"

    /** Name of a track with neither language nor name, "{track}" standing for its number */
    const val LABEL_NUMBER = "audioTrackNumber"
    const val LABEL_MONO = "audioTrackMono"
    const val LABEL_STEREO = "audioTrackStereo"

    /** More than two channels, other than 5.1 and 7.1: "{channels}" stands for their number */
    const val LABEL_CHANNELS = "audioTrackChannels"

    /** Language tag (BCP 47) of the app, the language the names of the track languages are written in */
    const val LABEL_LOCALE = "audioTrackLocale"

    private val DEFAULT_LABELS = mapOf(
      LABEL_AUDIO_TRACK to "Audio track",
      LABEL_DEFAULT to "Default",
      LABEL_NUMBER to "Track {track}",
      LABEL_MONO to "Mono",
      LABEL_STEREO to "Stereo",
      LABEL_CHANNELS to "{channels} channels",
    )

    private const val PREFERENCES = "video_audio_track"
    private const val KEY_LANGUAGE = "language"

    /** Language codes that name no language: undetermined, multiple languages, no linguistic content */
    private val NO_LANGUAGE = setOf("und", "mul", "zxx", "mis")

    /** The audio tracks of [tracks] the device can play, in the order of the file */
    fun options(tracks: Tracks): List<Option> =
      tracks.groups
        .filter { it.type == C.TRACK_TYPE_AUDIO }
        .flatMap { group ->
          (0 until group.length)
            .filter { group.isTrackSupported(it) }
            .map { Option(group, it, group.getTrackFormat(it), group.isTrackSelected(it)) }
        }

    /** The language [format] declares, null for none or for a code that names no language */
    fun languageOf(format: Format): String? = languageOf(format.language)

    /** [language] (a language code of a track), null for none or for a code that names no language */
    fun languageOf(language: String?): String? =
      language?.trim()?.takeIf { it.isNotEmpty() && it.lowercase(Locale.ROOT) !in NO_LANGUAGE }

    /**
     * Name of an audio track, number [number] (from 1) among the audio tracks, of [language], named [name] in the
     * file, with [channelCount] channels ([Format.NO_VALUE] when unknown): its language written in [displayLocale],
     * its name when it says more, and its channels; "Track 2" for a track with neither language nor name.
     * [markDefault] adds the default mark, for the one track the file plays by default.
     */
    fun trackName(
      language: String?,
      name: String?,
      channelCount: Int,
      number: Int,
      markDefault: Boolean,
      displayLocale: Locale,
      label: (String) -> String,
    ): String {
      val parts = mutableListOf<String>()
      val languageName = languageOf(language)?.let { languageName(it, displayLocale) }
      languageName?.let(parts::add)
      name?.trim()?.takeIf { it.isNotEmpty() && !it.equals(languageName, ignoreCase = true) }?.let(parts::add)
      if (parts.isEmpty()) {
        parts.add(label(LABEL_NUMBER).replace("{track}", number.toString()))
      }
      channelsName(channelCount, label)?.let(parts::add)
      if (markDefault) {
        parts.add(label(LABEL_DEFAULT))
      }
      return parts.joinToString(", ")
    }

    /** "English (United States)", "Français": the name of [tag] in [displayLocale], or the tag itself when unknown */
    fun languageName(tag: String, displayLocale: Locale): String {
      val name = Locale.forLanguageTag(tag).getDisplayName(displayLocale)
      if (name.isBlank()) {
        return tag
      }
      return name.replaceFirstChar { if (it.isLowerCase()) it.titlecase(displayLocale) else it.toString() }
    }

    /** "Mono", "Stereo", "5.1", "7.1", "4 channels"; null when the file does not tell */
    fun channelsName(channelCount: Int, label: (String) -> String): String? = when {
      channelCount == Format.NO_VALUE || channelCount <= 0 -> null
      channelCount == 1 -> label(LABEL_MONO)
      channelCount == 2 -> label(LABEL_STEREO)
      channelCount == 6 -> "5.1"
      channelCount == 8 -> "7.1"
      else -> label(LABEL_CHANNELS).replace("{channels}", channelCount.toString())
    }

    /** Whether [format] is the track the file plays by default */
    private fun isDefault(format: Format): Boolean = format.selectionFlags and C.SELECTION_FLAG_DEFAULT != 0
  }

  private val preferences = context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

  private val displayLocale: Locale =
    labels[LABEL_LOCALE]?.takeIf { it.isNotBlank() }?.let(Locale::forLanguageTag)
      ?.takeIf { it.language.isNotEmpty() } ?: Locale.getDefault()

  /**
   * Index among the [options] of the track the user picked for this video, -1 before any pick. The activity keeps
   * it in its saved state, so that a recreated activity plays the same track.
   */
  var chosenIndex = -1

  /** The pick still has to reach the current player, which did not know its tracks yet */
  private var choicePending = false

  private var dialog: AlertDialog? = null

  /** Label of the audio track button and title of its dialog */
  val buttonLabel: String
    get() = label(LABEL_AUDIO_TRACK)

  /**
   * Prepares a new [player] for the video: it prefers the language picked last, and gets the pick of the user back
   * once its tracks are known (see [onTracksChanged]). Call it before the player is prepared.
   */
  fun attach(player: Player) {
    val language = preferences.getString(KEY_LANGUAGE, null)
    if (language != null) {
      player.trackSelectionParameters =
        player.trackSelectionParameters.buildUpon().setPreferredAudioLanguage(language).build()
    }
    choicePending = chosenIndex >= 0
  }

  /**
   * The audio tracks of the video, from the tracks of [player]. A pick of the user from a previous player goes to
   * this one here, once the tracks are known. Otherwise [chosenIndex] follows the track the player plays once the
   * user picked one, also with the track menu of the player settings, so that a new player gets the last pick back.
   */
  fun onTracksChanged(player: Player, tracks: Tracks): List<Option> {
    val options = options(tracks)
    if (options.isEmpty()) {
      return options
    }
    if (choicePending) {
      choicePending = false
      options.getOrNull(chosenIndex)?.takeIf { !it.selected }?.let { select(player, it) }
    } else if (player.trackSelectionParameters.overrides.keys.any { it.type == C.TRACK_TYPE_AUDIO }) {
      // An audio override is a pick of the user, from the dialog or from the settings of the player
      options.indexOfFirst { it.selected }.takeIf { it >= 0 }?.let { chosenIndex = it }
    }
    return options
  }

  /** Shows the audio tracks of [player] in a dialog with the one playing checked; [onClosed] runs when it closes */
  fun showDialog(activity: Activity, player: Player, onClosed: () -> Unit = {}) {
    val options = options(player.currentTracks)
    if (options.isEmpty()) {
      onClosed()
      return
    }
    dismissDialog()
    val names = names(options).toTypedArray<CharSequence>()
    val checked = options.indexOfFirst { it.selected }
    dialog = AlertDialog.Builder(activity)
      .setTitle(label(LABEL_AUDIO_TRACK))
      .setSingleChoiceItems(names, checked) { shown, which ->
        options.getOrNull(which)?.let { choose(player, it, which) }
        shown.dismiss()
      }
      .setOnDismissListener {
        dialog = null
        onClosed()
      }
      .show()
  }

  /** Closes the dialog, when the activity stops or the player goes */
  fun dismissDialog() {
    dialog?.dismiss()
    dialog = null
  }

  /** Names of [options], in their order (see [trackName]) */
  fun names(options: List<Option>): List<String> {
    // Many files mark every track as default: the mark only tells something when one track has it
    val defaultIndex = options.indexOfFirst { isDefault(it.format) }
      .takeIf { index -> index >= 0 && options.count { isDefault(it.format) } == 1 }
    return options.mapIndexed { index, option ->
      val format = option.format
      val markDefault = index == defaultIndex
      trackName(format.language, format.label, format.channelCount, index + 1, markDefault, displayLocale, ::label)
    }
  }

  /** Plays [option], number [index] among the options, and remembers its language for the next videos */
  private fun choose(player: Player, option: Option, index: Int) {
    chosenIndex = index
    choicePending = false
    select(player, option)
    val language = languageOf(option.format)
    preferences.edit().apply {
      // A track without a language leaves the next videos to their own default
      if (language == null) remove(KEY_LANGUAGE) else putString(KEY_LANGUAGE, language)
    }.apply()
  }

  private fun select(player: Player, option: Option) {
    player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
      .setOverrideForType(TrackSelectionOverride(option.group.mediaTrackGroup, option.trackIndex))
      .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, false)
      .apply { languageOf(option.format)?.let { setPreferredAudioLanguage(it) } }
      .build()
  }

  private fun label(key: String): String = labels[key]?.takeIf { it.isNotBlank() } ?: DEFAULT_LABELS.getValue(key)
}
