package app.alextran.immich.core.raw

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.video.VideoFrameMetadataListener

/**
 * A player for the decoded streams of a raw 360° video, stitched by a [TwoLensCompositor]: one ExoPlayer whose lens
 * renderers ([TwoLensRenderersFactory]) each decode one stream into the compositor, both tracks selected
 * ([TwoLensTrackSelector]); audio, clock, seeking, pause, buffering and errors stay with ExoPlayer, so the activities
 * keep their listeners on [player].
 *
 * The player's own surface API is never used: it would give the same Surface to both lens renderers. Each renderer
 * gets its Surface and its frame metadata listener by a message of its own ([bindRendererOutputs]); the destination
 * goes to the compositor ([setOutput]). Never call setVideoEffects, setVideoFrameMetadataListener or setVideoSurface*
 * on [player] (one exception: clearVideoSurface on the phone, before [bindRendererOutputs], to undo what
 * PlayerView.setPlayer did), and keep scrubbing mode off: Media3's frame metadata wrapper is replaced per renderer.
 */
@OptIn(UnstableApi::class)
class TwoLensPlayback
private constructor(
  val player: ExoPlayer,
  /** The decoded streams: [0, 1], or the one kept in one lens mode. */
  val streams: List<Int>,
  private val compositor: TwoLensCompositor,
  private val factory: TwoLensRenderersFactory,
  private val mediaSourceFactory: MediaSource.Factory,
) {
  /** What the activities hear, on the main thread. */
  interface Listener {
    /** The first stitched frame reached the destination. */
    fun onFirstFrameDrawn()

    /** Drawing failed at run time (a GL error): the video should play unstitched. */
    fun onStitchError(error: Exception)

    /** No decodable track was found for [streams]: the video should fall back to one lens. */
    fun onStreamsMissing(streams: List<Int>)
  }

  /** The largest output the GPU draws (viewport and texture limits). */
  val maxOutputSize: Size
    get() = compositor.maxOutputSize

  /**
   * Gives each lens renderer its input Surface and its frame metadata listener, by messages on the playback queue
   * (FIFO: after anything the player sent before, so after the wrapper listener Media3 sets at construction and after
   * a clearVideoSurface). Before prepare.
   */
  fun bindRendererOutputs() {
    for ((stream, renderer) in factory.renderers) {
      player
        .createMessage(renderer)
        .setType(Renderer.MSG_SET_VIDEO_OUTPUT)
        .setPayload(compositor.inputSurface(stream))
        .send()
      player
        .createMessage(renderer)
        .setType(Renderer.MSG_SET_VIDEO_FRAME_METADATA_LISTENER)
        .setPayload(compositor.metadataListener(stream))
        .send()
    }
  }

  /**
   * Plays [urls] from [startMs]: one file (both tracks of it, or the single track of one lens file), or the two files
   * of a split pair merged, the url first (source 0) then the second (source 1), which [LensAssignment.bySource]
   * relies on. Same headers and data sources for both: the media source factory of the player.
   */
  fun setMedia(urls: List<String>, startMs: Long) {
    compositor.expectFirstFrame()
    if (urls.size >= 2) {
      val sources = urls.take(2).map { mediaSourceFactory.createMediaSource(MediaItem.fromUri(it)) }
      player.setMediaSource(
        MergingMediaSource(/* adjustPeriodTimeOffsets= */ false, /* clipDurations= */ true, sources[0], sources[1]),
        startMs,
      )
    } else {
      player.setMediaItem(MediaItem.fromUri(urls.first()), startMs)
    }
  }

  /** Draws into [surface] of [width] x [height] (asynchronous, retried while a previous decoder leaves it). */
  fun setOutput(surface: Surface, width: Int, height: Int) = compositor.setOutput(surface, width, height)

  /** Stops drawing into the destination, synchronously: its owner is about to release it. */
  fun clearOutput() = compositor.clearOutput()

  /** The phone's spherical view, told about each stitched frame before it is presented. */
  fun setDownstream(listener: VideoFrameMetadataListener?) = compositor.setDownstream(listener)

  /** The player first, so that the decoders leave the compositor's Surfaces, then the compositor. */
  fun release() {
    player.release()
    compositor.release()
    Log.i(TAG, "released (streams $streams)")
  }

  companion object {
    private const val TAG = "TwoLensPlayer"

    /**
     * Builds the lens player of [streams] of [projection] from [builder] (load control, media source factory, audio
     * attributes as the activity sets them): starts the compositor, then the player with the lens renderers matched
     * by [assignment]. Stereo audio is preferred (a GoPro .360 also has 4 channel ambisonics; a 4 channel track still
     * plays when it is the only one). Throws [RawStitchException] when the compositor cannot start.
     */
    fun create(
      context: Context,
      projection: RawProjection,
      streams: List<Int>,
      assignment: LensAssignment,
      builder: ExoPlayer.Builder,
      mediaSourceFactory: MediaSource.Factory,
      listener: Listener,
    ): TwoLensPlayback {
      val main = Handler(Looper.getMainLooper())
      var missingReported = false
      val compositor =
        TwoLensCompositor(
          projection,
          streams,
          object : TwoLensCompositor.Callbacks {
            override fun onFirstFrameDrawn() {
              main.post { listener.onFirstFrameDrawn() }
            }

            override fun onStitchError(error: Exception) {
              main.post { listener.onStitchError(error) }
            }
          },
        )
      compositor.start()
      val factory = TwoLensRenderersFactory(context, streams, assignment)
      val selector =
        TwoLensTrackSelector(context, streams) { missing ->
          Log.w(TAG, "no decodable track for streams $missing ($assignment)")
          main.post {
            // Once per player: a new track selection of the same media says the same
            if (!missingReported) {
              missingReported = true
              listener.onStreamsMissing(missing)
            }
          }
        }
      val player =
        try {
          builder.setRenderersFactory(factory).setTrackSelector(selector).build()
        } catch (e: Exception) {
          compositor.release()
          throw e
        }
      player.trackSelectionParameters =
        player.trackSelectionParameters.buildUpon().setMaxAudioChannelCount(2).build()
      Log.i(TAG, "lens player: streams $streams, $assignment, ${projection.summary()}")
      return TwoLensPlayback(player, streams, compositor, factory, mediaSourceFactory)
    }
  }
}
