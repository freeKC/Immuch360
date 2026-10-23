package me.albemala.native_video_player

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import java.util.Locale

/**
 * Immuch360: the audio and subtitle tracks of the video a player plays, for the track menus of the app (languages,
 * commentaries, subtitles), and the pick of the user among them as a track selection override.
 *
 * A track is named by its type ([AUDIO] or [TEXT]), the index of its group among the groups of [Player.getCurrentTracks]
 * and its index in that group: [select] checks that the group is still there with that type, since the tracks may
 * change between the listing and the pick.
 */
@OptIn(UnstableApi::class)
object VideoTracks {
    const val AUDIO = "audio"
    const val TEXT = "text"

    /** Language codes that name no language: undetermined, multiple languages, no linguistic content */
    private val NO_LANGUAGE = setOf("und", "mul", "zxx", "mis")

    /** The Media3 track type of [type], null for another one */
    fun trackType(type: String): Int? = when (type) {
        AUDIO -> C.TRACK_TYPE_AUDIO
        TEXT -> C.TRACK_TYPE_TEXT
        else -> null
    }

    /** The language the user asked the names in ([tag], BCP 47), the language of the device without one */
    fun displayLocale(tag: String?): Locale =
        tag?.takeIf { it.isNotBlank() }?.let(Locale::forLanguageTag)?.takeIf { it.language.isNotEmpty() }
            ?: Locale.getDefault()

    /** [language] (a language code of a track), null for none or for a code that names no language */
    fun languageOf(language: String?): String? =
        language?.trim()?.takeIf { it.isNotEmpty() && it.lowercase(Locale.ROOT) !in NO_LANGUAGE }

    /** "English (United States)", "Français": the name of [tag] in [displayLocale], or the tag itself when unknown */
    fun languageName(tag: String, displayLocale: Locale): String {
        val name = Locale.forLanguageTag(tag).getDisplayName(displayLocale)
        if (name.isBlank()) {
            return tag
        }
        return name.replaceFirstChar { if (it.isLowerCase()) it.titlecase(displayLocale) else it.toString() }
    }

    /**
     * What the app is told of one track: its [type], [group] and [track] indexes, its language code and the name of
     * that language in [displayLocale], its name in the file ([label]), its channels (audio, 0 when unknown), whether
     * it plays, and the default and forced flags of the file
     */
    fun entry(
        type: String,
        group: Int,
        track: Int,
        language: String?,
        label: String?,
        channels: Int,
        selected: Boolean,
        selectionFlags: Int,
        displayLocale: Locale,
    ): Map<String, Any?> {
        val code = languageOf(language)
        return mapOf(
            "type" to type,
            "group" to group,
            "track" to track,
            "language" to code,
            "languageName" to code?.let { languageName(it, displayLocale) },
            "label" to label?.trim()?.takeIf { it.isNotEmpty() },
            "channels" to if (channels == Format.NO_VALUE || channels < 0) 0 else channels,
            "selected" to selected,
            "isDefault" to (selectionFlags and C.SELECTION_FLAG_DEFAULT != 0),
            "isForced" to (selectionFlags and C.SELECTION_FLAG_FORCED != 0),
        )
    }

    /** The audio and subtitle tracks of [tracks] the device can play, in the order of the file */
    fun describe(tracks: Tracks, displayLocale: Locale): List<Map<String, Any?>> =
        tracks.groups.withIndex().flatMap { (groupIndex, group) ->
            val type = when (group.type) {
                C.TRACK_TYPE_AUDIO -> AUDIO
                C.TRACK_TYPE_TEXT -> TEXT
                else -> return@flatMap emptyList()
            }
            (0 until group.length)
                .filter { group.isTrackSupported(it) }
                .map { index ->
                    val format = group.getTrackFormat(index)
                    entry(
                        type,
                        groupIndex,
                        index,
                        format.language,
                        format.label,
                        format.channelCount,
                        group.isTrackSelected(index),
                        format.selectionFlags,
                        displayLocale,
                    )
                }
        }

    /**
     * The track parameters of a new player, from the defaults of the device ([parameters], the caption settings of
     * the accessibility settings among them): the audio language the user picked last ([audioLanguage], null before
     * any pick), and subtitles only when asked for.
     *
     * Media3 turns on a subtitle track that the file flags as default (Matroska flags a track default when the file
     * says nothing), which the user never asked for: this player showed no subtitles at all before it drew them. The
     * default flag of a subtitle track is ignored, so subtitles start off, but for forced ones in the language of the
     * audio (the lines of a film spoken in another language) and those the caption settings of the device ask for,
     * until the user picks a track in the subtitle menu ([select]).
     */
    fun initialParameters(parameters: TrackSelectionParameters, audioLanguage: String?): TrackSelectionParameters =
        parameters.buildUpon()
            .setIgnoredTextSelectionFlags(C.SELECTION_FLAG_DEFAULT)
            .apply { audioLanguage?.let { setPreferredAudioLanguage(it) } }
            .build()

    /**
     * Plays track [track] of group [group] of [type]: its format, null when the tracks changed since and it is gone.
     * An audio track becomes the preferred language too, for the next videos of this player.
     */
    fun select(player: Player, type: String, group: Int, track: Int): Format? {
        val trackType = trackType(type) ?: return null
        val chosen = player.currentTracks.groups.getOrNull(group)
            ?.takeIf { it.type == trackType && track in 0 until it.length }
            ?: return null
        val format = chosen.getTrackFormat(track)
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setOverrideForType(TrackSelectionOverride(chosen.mediaTrackGroup, track))
            .setTrackTypeDisabled(trackType, false)
            .apply {
                if (trackType == C.TRACK_TYPE_AUDIO) {
                    languageOf(format.language)?.let { setPreferredAudioLanguage(it) }
                }
            }
            .build()
        return format
    }

    /** No track of [type]: subtitles off */
    fun disable(player: Player, type: String) {
        val trackType = trackType(type) ?: return
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .clearOverridesOfType(trackType)
            .setTrackTypeDisabled(trackType, true)
            .build()
    }
}
