package app.alextran.immich.review

import android.app.Activity
import android.util.Log
import com.google.android.play.core.review.ReviewManagerFactory

// The review prompt of the phone flavour: the Play In-App Review card (com.google.android.play:review 2.0.2, under the
// Play Core Software Development Kit Terms of Service), on phones, tablets and Google TV installed from Google Play.
// The ReviewInfo is asked right before the card, as Google asks: it is valid for a limited time. Google Play never
// says whether the card showed nor what the user did; an error changes nothing for the user. The Dart side calls it
// only for a build installed from Google Play (storeChannelOf), never on a Quest, where Google Play does not exist.

/** See the top of this file */
internal object StoreReviews {
  /** Asks Google Play for its card; [done] gets true once the flow went through, false on an error */
  fun requestReview(activity: Activity, done: (Boolean) -> Unit) {
    val manager = ReviewManagerFactory.create(activity)
    manager.requestReviewFlow().addOnCompleteListener { request ->
      if (!request.isSuccessful) {
        Log.w(StoreReviewApiImpl.TAG, "Google Play gave no review flow", request.exception)
        done(false)
        return@addOnCompleteListener
      }
      if (activity.isFinishing || activity.isDestroyed) {
        done(false)
        return@addOnCompleteListener
      }
      manager.launchReviewFlow(activity, request.result).addOnCompleteListener { done(true) }
    }
  }

  /** The phone flavour opens Google Play's page through its address, from the Dart side */
  @Suppress("UNUSED_PARAMETER")
  fun openStorePage(activity: Activity): Boolean = false
}
