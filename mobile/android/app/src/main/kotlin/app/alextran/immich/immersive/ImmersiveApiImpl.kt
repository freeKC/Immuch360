package app.alextran.immich.immersive

import android.content.Context
import android.util.Log

/** Host side of the ImmersiveApi pigeon: device detection and launch of the immersive viewer. */
class ImmersiveApiImpl(context: Context) : ImmersiveApi {
  private val appContext = context.applicationContext

  override fun isHorizonOs(): Boolean = isHorizonOsDevice()

  /**
   * [headers] stays in the pigeon signature but is ignored: HttpClientManager already adds the user's custom
   * headers (and the session cookie) to every OkHttp and Cronet request, adding them again would duplicate them.
   * [stereoLayout] is the 3D layout Flutter guessed from the media size, [stereoLabels] the translated labels of
   * the 3D control.
   */
  override fun open(
    url: String,
    headers: Map<String, String>,
    isVideo: Boolean,
    title: String,
    stereoLayout: ImmersiveStereoLayout,
    stereoLabels: Map<String, String>,
  ) {
    if (!isHorizonOsDevice()) {
      throw FlutterError("unsupported", "The immersive viewer needs a Meta Quest headset", null)
    }
    Log.i(TAG, "open immersive viewer, video=$isVideo, 3D layout=$stereoLayout")
    appContext.startActivity(
      ImmersiveViewerActivity.intent(appContext, url, isVideo, title, stereoLayout, stereoLabels),
    )
  }
}
