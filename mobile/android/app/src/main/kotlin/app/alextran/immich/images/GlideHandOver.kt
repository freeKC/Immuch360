package app.alextran.immich.images

/**
 * The bitmap Glide decodes for a local image before Android 10 (LocalImagesImpl.decodeSource), handed from Glide to the
 * caller that copies its pixels and recycles it.
 *
 * Glide recycles the bitmap of a request as soon as its target is cleared: the app gives it no bitmap pool
 * (AppGlideModule), and BitmapPoolAdapter.put recycles what it is given. The cancel of a request cleared its target
 * at any time, so a cancel that came after Glide answered, while the caller copied the pixels on its worker thread,
 * freed them under the copy: "Error, cannot access an invalid/free'd bitmap here!" in Bitmap_copyPixelsToBuffer, an
 * abort of the app (Play cluster 427264, a Sony BRAVIA TV on Android 9, build 3030038).
 *
 * [take] clears the target on a cancel only while Glide decodes. Once Glide answered, the cancel no longer reaches the
 * target, and the bitmap is the caller's; a cancel that came in between leaves the bitmap to Glide, and the caller
 * gets null, nothing to read.
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

  /** What [get] answers, now the caller's, or null when the request was cancelled (Glide then frees it) */
  fun <T : Any> take(cancel: Cancel, clear: () -> Unit, get: () -> T): T? {
    if (cancel.isCanceled) return null
    cancel.onCancel(clear)
    val value =
      try {
        get()
      } finally {
        cancel.onCancel(null)
      }
    return if (cancel.isCanceled) null else value
  }
}
