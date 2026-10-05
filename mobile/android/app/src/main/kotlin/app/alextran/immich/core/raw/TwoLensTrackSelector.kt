package app.alextran.immich.core.raw

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.exoplayer.trackselection.MappingTrackSelector.MappedTrackInfo

/**
 * Selects one video track for each lens renderer. DefaultTrackSelector enables a single video renderer (its
 * selectVideoTrack gives one renderer index), so after its own selection, which keeps audio, text and metadata (the
 * audio track chosen with [app.alextran.immich.core.AudioTrackChooser] included), each lens renderer gets the first
 * track of its own groups that it can decode, see [lensSelections]. A stream with no such track is reported to
 * [onMissing] (on the playback thread) so that the player falls back to one lens.
 */
@OptIn(UnstableApi::class)
class TwoLensTrackSelector(
  context: Context,
  private val streams: List<Int>,
  private val onMissing: (List<Int>) -> Unit,
) : DefaultTrackSelector(context) {
  override fun selectAllTracks(
    definitions: Array<ExoTrackSelection.Definition?>,
    mappedTrackInfo: MappedTrackInfo,
    rendererFormatSupports: Array<Array<IntArray>>,
    rendererMixedMimeTypeAdaptationSupports: IntArray,
    params: DefaultTrackSelector.Parameters,
  ) {
    super.selectAllTracks(
      definitions,
      mappedTrackInfo,
      rendererFormatSupports,
      rendererMixedMimeTypeAdaptationSupports,
      params,
    )
    val names = (0 until mappedTrackInfo.rendererCount).map { mappedTrackInfo.getRendererName(it) }
    val picks = lensSelections(names, rendererFormatSupports, streams)
    val missing = mutableListOf<Int>()
    for (stream in streams) {
      val renderer = names.indexOf(LensVideoRenderer.nameOf(stream))
      if (renderer < 0) {
        missing += stream
        continue
      }
      val pick = picks[stream]
      definitions[renderer] =
        pick?.let { ExoTrackSelection.Definition(mappedTrackInfo.getTrackGroups(renderer)[it.group], it.track) }
      if (pick == null) missing += stream
    }
    if (missing.isNotEmpty()) onMissing(missing)
  }

  /** A track of a lens renderer: its group among that renderer's groups, and the track within it. */
  data class Pick(val renderer: Int, val group: Int, val track: Int)

  companion object {
    /** RendererCapabilities.FORMAT_SUPPORT_MASK, the format support bits of a capabilities value. */
    private const val FORMAT_SUPPORT_MASK = 0b111

    /** C.FORMAT_HANDLED and C.FORMAT_EXCEEDS_CAPABILITIES. */
    private const val FORMAT_HANDLED = 4
    private const val FORMAT_EXCEEDS_CAPABILITIES = 3

    /**
     * For each stream, the renderer named [LensVideoRenderer.nameOf] among [rendererNames] and the first track of
     * its groups ([formatSupports] is rendererFormatSupports[renderer][group][track], RendererCapabilities values)
     * that it handles, else the first that exceeds its capabilities (worth a try: a failing codec goes through the
     * fallback ladder); null for a stream without either, or without a renderer.
     */
    fun lensSelections(
      rendererNames: List<String>,
      formatSupports: Array<Array<IntArray>>,
      streams: List<Int>,
    ): Map<Int, Pick?> =
      streams.associateWith { stream ->
        val renderer = rendererNames.indexOf(LensVideoRenderer.nameOf(stream))
        if (renderer < 0 || renderer >= formatSupports.size) return@associateWith null
        firstWith(renderer, formatSupports[renderer], FORMAT_HANDLED)
          ?: firstWith(renderer, formatSupports[renderer], FORMAT_EXCEEDS_CAPABILITIES)
      }

    private fun firstWith(renderer: Int, groups: Array<IntArray>, support: Int): Pick? {
      for ((group, tracks) in groups.withIndex()) {
        for ((track, capabilities) in tracks.withIndex()) {
          if (capabilities and FORMAT_SUPPORT_MASK == support) return Pick(renderer, group, track)
        }
      }
      return null
    }
  }
}
