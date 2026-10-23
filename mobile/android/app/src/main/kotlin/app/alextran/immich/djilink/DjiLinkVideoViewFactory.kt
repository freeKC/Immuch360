package app.alextran.immich.djilink

import android.content.Context
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * The video panels of the DJI link page, platform views of type [VIEW_TYPE], registered in MainActivity next to the
 * camera live view. No creation parameters: what a view shows is decided by [DjiLinkVideoSurfaces].
 */
class DjiLinkVideoViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  companion object {
    const val VIEW_TYPE = "immuch/dji_link_video"
  }

  override fun create(context: Context, viewId: Int, args: Any?): PlatformView = DjiLinkVideoView(context, viewId) {}
}
