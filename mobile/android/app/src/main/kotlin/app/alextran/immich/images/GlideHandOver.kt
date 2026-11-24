package app.alextran.immich.images

import java.util.concurrent.Future

/**
 * The bitmap Glide decodes for a local image before Android 10 (LocalImagesImpl.decodeSource), handed from Glide to the
 * caller that copies its pixels and recycles it.
 *
 * Glide recycles the bitmap of a request as soon as its request is cleared: the app gives it no bitmap pool
 * (AppGlideModule), and BitmapPoolAdapter.put recycles what it is given. The cancel of a request cleared it at any
 * time, so a cancel that came after Glide answered, while the caller copied the pixels on its worker thread, freed them
 * under the copy: "Error, cannot access an invalid/free'd bitmap here!" in Bitmap_copyPixelsToBuffer, an abort of the
 * app (Play cluster 427264, a Sony BRAVIA TV on Android 9, build 3030038).
 *
 * The cancel also has to wake the caller: the get() of Glide's RequestFutureTarget waits with no time limit, and only
 * an answer, a failure or its own cancel() end that wait. A clear through Glide.with(ctx).clear does not (its
 * onLoadCleared is empty), and left the worker thread waiting for good, one worker of the pool lost per cancel.
 *
 * [take] cancels the future on a cancel, which wakes get() with a CancellationException and clears the request while
 * Glide decodes. Once Glide answered, that cancel returns false and frees nothing, and the bitmap is the caller's; when
 * the request was cancelled in between, the caller gets null and [take] gives the bitmap to its release.
 */
object GlideHandOver {
  /** The cancellation of a request: Android's CancellationSignal in the app, a fake in the tests */
  interface Cancel {
    val isCanceled: Boolean

    /**
     * Runs [action] on a cancel, at once when the request is cancelled already; null removes it, after a cancel that
     * is running has ended (as CancellationSignal.setOnCancelListener does)
     */
    fun onCancel(action: (() -> Unit)?)
  }

  /**
   * What [future] answers, now the caller's, or null when the request was cancelled. A cancel while Glide decodes
   * throws the CancellationException of get(); one that came once Glide answered gives the answer to [release].
   */
  fun <T : Any> take(cancel: Cancel, future: Future<T>, release: (T) -> Unit): T? {
    if (cancel.isCanceled) {
      future.cancel(true)
      return null
    }
    cancel.onCancel { future.cancel(true) }
    val value =
      try {
        future.get()
      } finally {
        cancel.onCancel(null)
      }
    if (cancel.isCanceled) {
      release(value)
      return null
    }
    return value
  }
}
