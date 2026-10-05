package app.alextran.immich.core.raw

import android.content.Context
import android.os.Handler
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.RendererCapabilities
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener

/**
 * The video renderer of one decoded stream of a raw 360° video ([stream], texture k of the stitch shaders), one per
 * stream in the same ExoPlayer, each decoding into its own SurfaceTexture of [TwoLensCompositor].
 *
 * Media3 gives a track group to the renderer with the strictly highest support and keeps the first renderer on a tie
 * (MappingTrackSelector.findRenderer, 1.10): two HEVC lens tracks would both go to the first video renderer. So each
 * renderer reports the formats of the other streams as an unsupported subtype: lens A's track reaches renderer A with
 * its real support and renderer B with 1, and the other way round ([LensAssignment] tells the formats apart).
 *
 * Hardware decoders only: a software HEVC decoder at 3840x3840 would decode a few frames per second and starve the
 * pairing without an error, where failing at once sends the fallback ladder to one lens.
 */
@OptIn(UnstableApi::class)
class LensVideoRenderer private constructor(
  builder: MediaCodecVideoRenderer.Builder,
  val stream: Int,
  private val assignment: LensAssignment,
) : MediaCodecVideoRenderer(builder) {
  override fun supportsFormat(mediaCodecSelector: MediaCodecSelector, format: Format): Int {
    if (format.sampleMimeType?.startsWith("video/") != true) return super.supportsFormat(mediaCodecSelector, format)
    if (!assignment.matches(stream, format)) return RendererCapabilities.create(C.FORMAT_UNSUPPORTED_SUBTYPE)
    return super.supportsFormat(mediaCodecSelector, format)
  }

  override fun getName(): String = nameOf(stream)

  override fun onCodecInitialized(
    name: String,
    configuration: MediaCodecAdapter.Configuration,
    initializedTimestampMs: Long,
    initializationDurationMs: Long,
  ) {
    Log.i(
      TAG,
      "stream $stream: decoder $name for ${configuration.format.sampleMimeType} " +
        "${configuration.format.width}x${configuration.format.height} (id ${configuration.format.id}), " +
        "initialized in $initializationDurationMs ms",
    )
    super.onCodecInitialized(name, configuration, initializedTimestampMs, initializationDurationMs)
  }

  companion object {
    private const val TAG = "LensVideoRenderer"

    /** Name Media3 reports for the renderer of [stream], which [TwoLensTrackSelector] finds it by. */
    fun nameOf(stream: Int): String = "LensVideoRenderer$stream"

    /** The decoders of a MIME type, hardware ones only. */
    val hardwareOnly = MediaCodecSelector { mimeType, requiresSecureDecoder, requiresTunnelingDecoder ->
      MediaCodecUtil.getDecoderInfos(mimeType, requiresSecureDecoder, requiresTunnelingDecoder).filter {
        it.hardwareAccelerated && !it.softwareOnly
      }
    }

    fun create(
      context: Context,
      stream: Int,
      assignment: LensAssignment,
      eventHandler: Handler?,
      eventListener: VideoRendererEventListener?,
      allowedJoiningTimeMs: Long,
      maxDroppedFramesToNotify: Int,
    ): LensVideoRenderer {
      val builder =
        MediaCodecVideoRenderer.Builder(context)
          .setMediaCodecSelector(hardwareOnly)
          .setEnableDecoderFallback(false)
          .setAllowedJoiningTimeMs(allowedJoiningTimeMs)
          .setMaxDroppedFramesToNotify(maxDroppedFramesToNotify)
      if (eventHandler != null) builder.setEventHandler(eventHandler)
      if (eventListener != null) builder.setEventListener(eventListener)
      return LensVideoRenderer(builder, stream, assignment)
    }
  }
}
