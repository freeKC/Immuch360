package app.alextran.immich.camera

/**
 * What Flutter asks of the live views made by [views] (see CameraLiveViewFactory.view): the stream to play, the
 * sound, the end. A view already disposed of ignores the call.
 */
class CameraLiveApiImpl(private val views: CameraLiveViewFactory) : CameraLiveApi {
  override fun setSource(viewId: Long, source: CameraLiveSource) {
    views.view(viewId.toInt())?.play(source)
  }

  override fun setMuted(viewId: Long, muted: Boolean) {
    views.view(viewId.toInt())?.setMuted(muted)
  }

  override fun stop(viewId: Long) {
    views.view(viewId.toInt())?.stop()
  }
}
