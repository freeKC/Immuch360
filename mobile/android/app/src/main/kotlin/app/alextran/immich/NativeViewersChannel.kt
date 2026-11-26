package app.alextran.immich

import app.alextran.immich.immersive.ImmersiveViewerActivity
import app.alextran.immich.spherical.SphericalVideoActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The app's own viewers that run as activities of their own, for "Play from a phone" on a big screen
 * (lib/providers/play_on_screen/screen_native_viewers.dart): "closeAll" closes the 360° player and the immersive
 * viewer of the Meta Quest, as their close button and Back do, before a phone's next item or Stop. Each sends its
 * closed event to Flutter as usual. Answers whether one was open. "inFront" answers whether one of them is on screen
 * (started), which a stopped viewer that is not yet destroyed is not. For the engine of the app UI only.
 */
object NativeViewersChannel {
  private const val NAME = "app.immuch360/native_viewers"

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
      when (call.method) {
        "closeAll" -> {
          // Both, whichever is open: not a short circuit
          val player = SphericalVideoActivity.closeCurrent()
          val viewer = ImmersiveViewerActivity.closeLive()
          result.success(player || viewer)
        }
        // Started, so on screen: false once Home or the Meta button sent it to the background
        "inFront" -> result.success(SphericalVideoActivity.inFront || ImmersiveViewerActivity.inFront)
        else -> result.notImplemented()
      }
    }
  }

  fun detach(messenger: BinaryMessenger) {
    MethodChannel(messenger, NAME).setMethodCallHandler(null)
  }
}
