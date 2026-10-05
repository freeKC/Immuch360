package app.alextran.immich.core.raw

import android.content.Context
import android.os.Handler
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.audio.AudioRendererEventListener
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.metadata.MetadataOutput
import androidx.media3.exoplayer.text.TextOutput
import androidx.media3.exoplayer.video.VideoRendererEventListener

/**
 * The renderers of a lens player: one [LensVideoRenderer] per decoded stream in place of the default video renderer,
 * the default audio, text, metadata, camera motion and image renderers. The lens renderers are kept here once
 * ExoPlayer.Builder.build() made them, so that [TwoLensPlayback] can message each one its own output.
 *
 * No secondary renderers: a message sent straight to a lens renderer would bypass the prewarming state that
 * RendererHolder keeps for a renderer pair.
 */
@OptIn(UnstableApi::class)
class TwoLensRenderersFactory(
  context: Context,
  private val streams: List<Int>,
  private val assignment: LensAssignment,
) : DefaultRenderersFactory(context) {
  private val built = HashMap<Int, LensVideoRenderer>()

  /** The renderer of each stream, once the player is built. */
  val renderers: Map<Int, LensVideoRenderer>
    get() = synchronized(built) { HashMap(built) }

  override fun buildVideoRenderers(
    context: Context,
    extensionRendererMode: Int,
    mediaCodecSelector: MediaCodecSelector,
    enableDecoderFallback: Boolean,
    eventHandler: Handler,
    eventListener: VideoRendererEventListener,
    allowedVideoJoiningTimeMs: Long,
    out: ArrayList<Renderer>,
  ) {
    for (stream in streams) {
      val renderer =
        LensVideoRenderer.create(
          context,
          stream,
          assignment,
          eventHandler,
          eventListener,
          allowedVideoJoiningTimeMs,
          MAX_DROPPED_VIDEO_FRAME_COUNT_TO_NOTIFY,
        )
      synchronized(built) { built[stream] = renderer }
      out.add(renderer)
    }
  }

  override fun createSecondaryRenderer(
    renderer: Renderer,
    eventHandler: Handler,
    videoRendererEventListener: VideoRendererEventListener,
    audioRendererEventListener: AudioRendererEventListener,
    textRendererOutput: TextOutput,
    metadataRendererOutput: MetadataOutput,
  ): Renderer? = null
}
