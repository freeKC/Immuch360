package app.alextran.immich.camera

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * The live view of the Tapo cameras, a platform view of type [VIEW_TYPE]. Each view is kept by its id, so that
 * [CameraLiveApiImpl] reaches the one Flutter names. The creation parameters never hold a credential: the stream and
 * its account come through CameraLiveApi.setSource.
 */
class CameraLiveViewFactory(
  /** For the events of the views towards Flutter (CameraLiveEvents) */
  val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  companion object {
    const val VIEW_TYPE = "immuch/camera_live"
  }

  private val views = mutableMapOf<Int, CameraLiveView>()
  private val events by lazy { CameraLiveEvents(messenger) }

  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    val view = CameraLiveView(context, viewId, events) { views.remove(viewId) }
    views[viewId] = view
    return view
  }

  /** The view of [viewId], null once Flutter disposed of it */
  fun view(viewId: Int): CameraLiveView? = views[viewId]
}
