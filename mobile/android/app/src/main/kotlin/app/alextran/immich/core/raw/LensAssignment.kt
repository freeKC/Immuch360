package app.alextran.immich.core.raw

import androidx.annotation.OptIn
import androidx.media3.common.Format
import androidx.media3.common.util.UnstableApi

/**
 * Which video format belongs to which decoded stream (texture k, `tracks[k]` of the rawProjection JSON), told by
 * Format.id: Media3 sets it to the tkhd track_ID of an MP4 track ("2"), and MergingMediaSource prefixes it with the
 * index of the source it comes from ("1:2"); both checked in the Media3 1.10 bytecode. Pure on the id and the MIME
 * type, so that the tests need no Format (which needs the Android runtime).
 */
class LensAssignment private constructor(private val rules: Map<Int, Rule>) {
  private sealed interface Rule

  /** One file: the track whose tkhd track_ID is [trackId], whatever source prefix Media3 put before it. */
  private data class ByTrackId(val trackId: Int) : Rule

  /** Two files merged: a track of source [source], and that track_ID when known. */
  private data class BySource(val source: Int, val trackId: Int?) : Rule

  /** A file with a single video track (one lens file, a transcoded stream): any video format. */
  private data object AnyVideo : Rule

  /** Whether the video format of id [id] and MIME type [mime] is the one of stream [stream]. */
  fun matches(stream: Int, id: String?, mime: String?): Boolean {
    if (mime?.startsWith("video/") != true) return false
    return when (val rule = rules[stream] ?: return false) {
      AnyVideo -> true
      is ByTrackId -> id != null && (id == rule.trackId.toString() || id.substringAfterLast(':') == "${rule.trackId}")
      is BySource -> {
        if (id == null || !id.startsWith("${rule.source}:")) return false
        rule.trackId == null || id.substringAfter(':') == rule.trackId.toString()
      }
    }
  }

  @OptIn(UnstableApi::class)
  fun matches(stream: Int, format: Format): Boolean = matches(stream, format.id, format.sampleMimeType)

  /** For the logs: what each stream is matched by. */
  override fun toString(): String = rules.entries.joinToString(", ") { (stream, rule) -> "$stream <- $rule" }

  companion object {
    /** Two tracks of one file: stream k is the track of tkhd track_ID `trackIds[k]`. */
    fun byTrackIds(trackIds: Map<Int, Int>): LensAssignment = LensAssignment(trackIds.mapValues { ByTrackId(it.value) })

    /**
     * Two files given to MergingMediaSource in this order: stream k is in source `sources[k]`, the track of
     * `trackIds[k]` there when known (a transcoded stream has its own track IDs: none then).
     */
    fun bySource(sources: Map<Int, Int>, trackIds: Map<Int, Int?> = emptyMap()): LensAssignment =
      LensAssignment(sources.mapValues { (stream, source) -> BySource(source, trackIds[stream]) })

    /** One file with a single video track, decoded as each of [streams] (only ever one). */
    fun anyVideo(streams: Collection<Int>): LensAssignment = LensAssignment(streams.associateWith { AnyVideo })
  }
}
