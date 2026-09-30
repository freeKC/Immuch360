package app.alextran.immich.spherical

import android.app.Activity
import android.content.Context
import android.content.Intent

class SphericalVideoApiImpl(private val context: Context) : SphericalVideoApi {
  override fun open(
    url: String,
    headers: Map<String, String>,
    title: String,
    closeLabel: String?,
    errorMessage: String?,
  ) {
    val intent = SphericalVideoActivity.intent(context, url, headers, title, closeLabel, errorMessage)
    if (context !is Activity) {
      intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    context.startActivity(intent)
  }
}
