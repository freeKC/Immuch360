package app.alextran.immich.review

import android.app.Activity
import android.content.ActivityNotFoundException
import android.util.Log

// The quest flavour: Horizon OS has no Google Play, and Meta's Rate and Review API is not in the Platform SDK yet, so
// there is no review prompt; the app shows a sentence of its own, whose Rate button opens the page of the app on the
// Meta Horizon Store through the system deep link (HorizonStoreLink). No Play library in this flavour.

/** See the top of this file */
internal object StoreReviews {
  /** No review prompt on the Quest */
  @Suppress("UNUSED_PARAMETER")
  fun requestReview(activity: Activity, done: (Boolean) -> Unit) = done(false)

  /** Opens the page of the app on the Meta Horizon Store; false when the system shell is not there (not a Quest) */
  fun openStorePage(activity: Activity): Boolean =
    try {
      activity.startActivity(HorizonStoreLink.of().toIntent())
      true
    } catch (error: ActivityNotFoundException) {
      Log.w(StoreReviewApiImpl.TAG, "No Meta Horizon Store to open here", error)
      false
    } catch (error: SecurityException) {
      Log.w(StoreReviewApiImpl.TAG, "The Meta Horizon Store did not open", error)
      false
    }
}
