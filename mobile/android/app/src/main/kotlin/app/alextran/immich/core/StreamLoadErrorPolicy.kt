package app.alextran.immich.core

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy

/**
 * When a streamed video tries its connection again, see [StreamLoadErrorPolicy]. Pure, so that it is tested.
 */
object StreamRetry {
  /** The waits before the first tries, then [STEADY_DELAY_MS] between each */
  val FIRST_DELAYS_MS = longArrayOf(1_000L, 2_000L, 4_000L)
  const val STEADY_DELAY_MS = 5_000L

  /** A link with no progress for this long stops trying until the user plays again (a new load) */
  const val GIVE_UP_MS = 10L * 60L * 1000L

  /** Tries of a request the server answered with an error, as Media3 does: the server is there, and said no */
  const val HTTP_ERROR_TRIES = 3

  /**
   * The wait before try number [errorCount] + 1 (after [errorCount] errors in a row, 1 for the first), with
   * [sinceProgressMs] since the link last brought anything (null when unknown); null to stop trying: Media3 would not
   * try such an error again ([fatal]: a file not found, a container it cannot read), the server answered [httpStatus]
   * (a refusal of 4xx at once, other statuses after [HTTP_ERROR_TRIES]), or nothing came for [GIVE_UP_MS]. A link that
   * sends nothing (a timeout, a connection refused or cut) is tried again and again.
   */
  fun delayMs(errorCount: Int, sinceProgressMs: Long?, fatal: Boolean, httpStatus: Int? = null): Long? {
    if (fatal) return null
    if (httpStatus != null) {
      val refused = httpStatus in 400..499 && httpStatus != 408 && httpStatus != 429
      if (refused || errorCount > HTTP_ERROR_TRIES) return null
    }
    if (sinceProgressMs != null && sinceProgressMs >= GIVE_UP_MS) return null
    val index = (errorCount - 1).coerceAtLeast(0)
    return if (index < FIRST_DELAYS_MS.size) FIRST_DELAYS_MS[index] else STEADY_DELAY_MS
  }
}

/**
 * The load errors of a streamed video (a server, the media bridge of a share): Media3 tries a progressive load three
 * times, one per 8 s read timeout of Cronet, then stops the video for good with a "Source error", even with media
 * still buffered and even when the server answers again a moment later (measured on 31 October 2026: a server silent
 * for 60 s ended the video 35 s after its last byte). Here the load is tried again after 1, 2 and 4 s, then every 5 s,
 * for as long as the link brought something within [StreamRetry.GIVE_UP_MS] ([meter]), so that the video plays on by
 * itself as soon as the bytes come back. The errors Media3 never tries again (a file not found, a container it cannot
 * read, a range past the end) stay fatal, and so does a server that answers with an error (see [StreamRetry.delayMs]).
 */
@OptIn(UnstableApi::class)
class StreamLoadErrorPolicy(private val meter: LinkMeter) : LoadErrorHandlingPolicy {
  private val default = DefaultLoadErrorHandlingPolicy()

  override fun getFallbackSelectionFor(
    fallbackOptions: LoadErrorHandlingPolicy.FallbackOptions,
    loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo,
  ): LoadErrorHandlingPolicy.FallbackSelection? = default.getFallbackSelectionFor(fallbackOptions, loadErrorInfo)

  override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo): Long {
    val delay = default.getRetryDelayMsFor(loadErrorInfo)
    // A file of the device keeps Media3's rule
    if (!meter.isNetwork) return delay
    val fatal = delay == C.TIME_UNSET
    val status = (loadErrorInfo.exception as? HttpDataSource.InvalidResponseCodeException)?.responseCode
    return StreamRetry.delayMs(loadErrorInfo.errorCount, meter.sinceProgressMs(), fatal, status) ?: C.TIME_UNSET
  }

  // Never thrown while it tries: the player waits, and says why (the link's time since progress). A file of the device
  // keeps Media3's count
  override fun getMinimumLoadableRetryCount(dataType: Int): Int =
    if (meter.isNetwork) Int.MAX_VALUE - 1 else default.getMinimumLoadableRetryCount(dataType)
}
