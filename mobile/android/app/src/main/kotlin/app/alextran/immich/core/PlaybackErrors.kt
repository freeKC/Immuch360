package app.alextran.immich.core

import androidx.media3.common.PlaybackException
import androidx.media3.common.util.StuckPlayerException

/**
 * What a Media3 error means for the user, so that its own text ("Player stuck playing with no progress for 10000 ms",
 * the stuck checks of Media3 1.10) never reaches the screen: a decoder that refused or failed ([Kind.DECODER]), a
 * decoder full of data that gives no picture ([Kind.NO_FRAME]: on a Meta Quest 3, H.264 above 4096 x 2304), a video
 * the network or the server sends too slowly ([Kind.STALLED]), or a video that stopped for another reason the player
 * found ([Kind.STOPPED]). Each kind has the label the players read (the keys of videoSourceLabels in Flutter); the
 * flat player of the app sends Flutter a [token] instead of the text of the player. Pure, so that it is tested.
 */
object PlaybackErrors {
  /** Keys of the labels Flutter sends the players for each kind, the same as VideoDecoders.LABEL_ERROR_*. */
  const val LABEL_DECODER = "errorDecoder"
  const val LABEL_NO_FRAME = "errorNoFrame"
  const val LABEL_STALLED = "errorStalled"

  /** The start of the error the flat player sends Flutter for a known kind, see [token]. */
  const val TOKEN_PREFIX = "immuch360-playback-error:"

  enum class Kind(val token: String, val label: String?) {
    DECODER("decoder", LABEL_DECODER),
    NO_FRAME("noFrame", LABEL_NO_FRAME),
    STALLED("stalled", LABEL_STALLED),
    STOPPED("stopped", null),
  }

  /**
   * The kind of the error [errorCode] (PlaybackException), whose cause is a StuckPlayerException of [stuckType] or null
   * for none, for a player that has a video track ([videoKnown]) and whose decoder had media enough to give a picture
   * ([decoderGotMedia]: more buffered than the playback waits for). Null for the errors whose own words tell (a file
   * that is not found, an HTTP status).
   */
  fun kindOf(errorCode: Int, stuckType: Int?, videoKnown: Boolean, decoderGotMedia: Boolean): Kind? {
    if (stuckType != null) {
      return when (stuckType) {
        // Ready, asked to play, and the position stands: the decoder gives nothing, or with no video track the audio
        StuckPlayerException.STUCK_PLAYING_NO_PROGRESS -> if (videoKnown) Kind.NO_FRAME else Kind.STOPPED
        // The buffer is full and nothing plays: the decoder again
        StuckPlayerException.STUCK_BUFFERING_NOT_LOADING -> if (videoKnown) Kind.NO_FRAME else Kind.STALLED
        StuckPlayerException.STUCK_BUFFERING_NO_PROGRESS ->
          if (videoKnown && decoderGotMedia) Kind.NO_FRAME else Kind.STALLED
        else -> Kind.STOPPED
      }
    }
    return when (errorCode) {
      PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
      PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
      PlaybackException.ERROR_CODE_DECODING_FAILED,
      PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
      PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED -> Kind.DECODER
      PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT -> Kind.STALLED
      else -> null
    }
  }

  /** [kindOf] for [error], read from its code and its cause. */
  fun kindOf(error: PlaybackException, videoKnown: Boolean, decoderGotMedia: Boolean): Kind? =
    kindOf(error.errorCode, (error.cause as? StuckPlayerException)?.stuckType, videoKnown, decoderGotMedia)

  /**
   * What the flat player sends Flutter for an error of [kind] on a video of [mime] (null when unknown) and [width] x
   * [height] (0 or less when unknown): "immuch360-playback-error:noFrame:video/avc:5760:2880", which Flutter puts in
   * its own words with the codec and the size.
   */
  fun token(kind: Kind, mime: String?, width: Int, height: Int): String =
    "$TOKEN_PREFIX${kind.token}:${mime.orEmpty()}:${width.coerceAtLeast(0)}:${height.coerceAtLeast(0)}"
}
