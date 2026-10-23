package app.alextran.immich.djilink

import android.content.Context
import android.graphics.Color
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import io.flutter.plugin.platform.PlatformView

/**
 * Which video view gets the picture: the most recently created one that still has a surface. A view that loses its
 * surface hands the picture to the one before it, or to the decoder's parking surface when none is left, so moving
 * between the panel and full screen never restarts the decoder ([VideoDecoderFeed.setViewSurface] switches the output
 * with setOutputSurface).
 */
object DjiLinkVideoSurfaces {
  private val surfaces = linkedMapOf<Int, android.view.Surface>()

  /** Told whenever the surface that should show the picture changes; null means none is shown */
  @Volatile
  var listener: ((android.view.Surface?) -> Unit)? = null

  @Synchronized
  fun current(): android.view.Surface? = surfaces.values.lastOrNull()

  fun created(viewId: Int, surface: android.view.Surface) {
    val next = synchronized(this) {
      surfaces.remove(viewId)
      surfaces[viewId] = surface
      current()
    }
    listener?.invoke(next)
  }

  fun destroyed(viewId: Int) {
    val next = synchronized(this) {
      surfaces.remove(viewId) ?: return
      current()
    }
    listener?.invoke(next)
  }
}

/**
 * One video panel of the DJI link page, a platform view of type [DjiLinkVideoViewFactory.VIEW_TYPE]: a SurfaceView on
 * black, sized by the page to the stream's aspect ratio. The decoder renders straight into its surface, with no copy
 * and no Flutter frame pacing in the way. It takes no creation parameters and holds nothing but its surface.
 */
class DjiLinkVideoView(context: Context, private val viewId: Int, private val onDispose: () -> Unit) :
  PlatformView, SurfaceHolder.Callback {
  private val surfaceView = SurfaceView(context).apply { holder.addCallback(this@DjiLinkVideoView) }
  private val root = FrameLayout(context).apply {
    setBackgroundColor(Color.BLACK)
    addView(
      surfaceView,
      FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER),
    )
  }

  override fun getView(): View = root

  override fun surfaceCreated(holder: SurfaceHolder) {
    DjiLinkVideoSurfaces.created(viewId, holder.surface)
  }

  override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit

  override fun surfaceDestroyed(holder: SurfaceHolder) {
    // The decoder moves off this surface before this returns: the view destroys it right after
    DjiLinkVideoSurfaces.destroyed(viewId)
  }

  override fun dispose() {
    surfaceView.holder.removeCallback(this)
    DjiLinkVideoSurfaces.destroyed(viewId)
    onDispose()
  }
}
