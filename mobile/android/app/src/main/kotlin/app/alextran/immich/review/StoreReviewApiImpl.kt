package app.alextran.immich.review

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.util.Log

// The invitation to rate the app (lib/domain/models/rate_app.dart): the review prompt of the store and the store
// page, through StoreReviews, an object of the flavour (src/phone: the Play In-App Review card; src/quest: no Play,
// the Meta Horizon Store page). For the engine of the app UI only: the card needs this activity.

/** See the top of this file */
class StoreReviewApiImpl(private val activity: Activity) : StoreReviewApi {
  override fun requestReview(callback: (Result<Boolean>) -> Unit) {
    try {
      StoreReviews.requestReview(activity) { shown -> callback(Result.success(shown)) }
    } catch (error: Throwable) {
      // Google asks that an error of the review flow changes nothing for the user
      Log.w(TAG, "The review prompt of the store did not open", error)
      callback(Result.success(false))
    }
  }

  override fun openStorePage(): Boolean =
    try {
      StoreReviews.openStorePage(activity)
    } catch (error: Exception) {
      Log.w(TAG, "The store page did not open", error)
      false
    }

  companion object {
    const val TAG = "StoreReview"
  }
}

/**
 * The deep link of Horizon OS that opens the page of an app on the Meta Horizon Store ("System Deep Linking", Open
 * Store): the action VIEW to the activity [className] of [packageName], the data [data] and the extra "uri" [uri], as
 * Meta's test line writes it (`adb shell am start -a android.intent.action.VIEW -n com.oculus.vrshell/.MainActivity -d
 * "systemux://store" -e "uri" "/item/<id>"`). An explicit component, so that no query of the package is needed.
 */
data class HorizonStoreLink(val packageName: String, val className: String, val data: String, val uri: String) {
  fun toIntent(): Intent {
    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(data))
    intent.setClassName(packageName, className)
    intent.putExtra("uri", uri)
    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    return intent
  }

  companion object {
    /** The id of the app on the Meta Horizon Store, the end of kHorizonStoreLink of constants.dart */
    const val APP_ID = "1384208401440714"

    /** The page of the app [appId] on the Meta Horizon Store */
    fun of(appId: String = APP_ID) =
      HorizonStoreLink(
        packageName = "com.oculus.vrshell",
        className = "com.oculus.vrshell.MainActivity",
        data = "systemux://store",
        uri = "/item/$appId",
      )
  }
}
