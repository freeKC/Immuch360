package app.alextran.immich.immersive

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The end of the immersive viewer against the end of the Spatial SDK 0.14.0 (VrActivity.destroy: onSpatialShutdown,
 * then the scene and the data model destroyed, then EntityContext cleared, so that any later call on an entity throws
 * NotImplementedError). The viewer below holds its objects of the scene as ImmersiveViewerActivity does, through a
 * [SpatialHold], and drops them as its onSpatialShutdown and onDestroy do; its entities throw as the SDK does once
 * their context is cleared. Build 33 crashed there on 30 October 2026 (logcat 10:21:57, onDestroy hiding the photo
 * layer after the shutdown), and its 2D window went with the process.
 */
class SpatialHoldTest {
  /**
   * The data model of the SDK, one for the process as EntityContext is: its entities are ids in it, and once it is
   * cleared every call on them throws, as EntityContext$clear makes them.
   */
  private class SceneContext {
    var cleared = false
    var calls = 0
    val hidden = mutableSetOf<Long>()
    private var lastId = 0L

    fun newEntity() = FakeEntity(this, ++lastId)

    /** The next viewer sets the context again: a new data model, whose ids start again. */
    fun renew() {
      cleared = false
      calls = 0
      hidden.clear()
      lastId = 0L
    }
  }

  private class FakeEntity(private val context: SceneContext, private val id: Long) {
    val visible: Boolean
      get() = id !in context.hidden

    fun setVisible(value: Boolean) {
      if (context.cleared) throw NotImplementedError("An operation is not implemented.")
      context.calls++
      if (value) context.hidden -= id else context.hidden += id
    }
  }

  /** A bitmap of the viewer: not an object of the scene, recycled by the drops whatever the scene. */
  private class FakePicture {
    var recycled = 0
  }

  /**
   * The cleanup of ImmersiveViewerActivity in the order the SDK runs it: [finish] for a viewer closed (VrActivity
   * onPause of a finishing activity runs destroy() before the viewer's own onPause, onStop and onDestroy),
   * [destroyWithoutFinish] for a viewer the system destroys without a finish (its onDestroy drops first, then
   * VrActivity.onDestroy runs destroy()).
   */
  private class Viewer(val context: SceneContext = SceneContext()) {
    val spatial = SpatialHold()
    var photoLayerEntity: FakeEntity? by spatial.ref()
    var videoEntity: FakeEntity? by spatial.ref()
    var photoLayerPicture: FakePicture? = null
    var shutdowns = 0

    fun showPhotoOnLayer() {
      photoLayerEntity = context.newEntity()
      photoLayerPicture = FakePicture()
    }

    /** dropPhotoLayer of the viewer: the layer hidden, its bitmap recycled. */
    fun dropPhotoLayer() {
      photoLayerEntity?.setVisible(false)
      photoLayerPicture?.let { it.recycled++ }
      photoLayerPicture = null
    }

    fun onSpatialShutdown() {
      shutdowns++
      spatial.shutDown()
      dropPhotoLayer()
    }

    fun onDestroy() {
      dropPhotoLayer()
      videoEntity?.setVisible(false)
    }

    /** VrActivity.destroy: once per activity, onSpatialShutdown then EntityContext cleared. */
    private fun sdkDestroy() {
      if (shutdowns > 0) return
      onSpatialShutdown()
      context.cleared = true
    }

    fun finish() {
      sdkDestroy()
      onDestroy()
    }

    fun destroyWithoutFinish() {
      onDestroy()
      sdkDestroy()
    }
  }

  @Test
  fun `shutdown then destroy touches no entity`() {
    val viewer = Viewer()
    viewer.showPhotoOnLayer()
    val picture = viewer.photoLayerPicture!!
    viewer.videoEntity = viewer.context.newEntity()

    viewer.finish()

    assertEquals(0, viewer.context.calls)
    assertEquals(1, picture.recycled)
    assertNull(viewer.photoLayerPicture)
  }

  @Test
  fun `destroy without shutdown still drops`() {
    val viewer = Viewer()
    viewer.showPhotoOnLayer()
    val entity = viewer.photoLayerEntity!!
    val picture = viewer.photoLayerPicture!!

    viewer.destroyWithoutFinish()

    assertFalse(entity.visible)
    assertEquals(1, viewer.context.calls)
    assertEquals(1, picture.recycled)
    assertTrue(viewer.spatial.isDown)
  }

  @Test
  fun `every reference reads null once the scene is down`() {
    val viewer = Viewer()
    viewer.showPhotoOnLayer()
    viewer.videoEntity = viewer.context.newEntity()

    viewer.spatial.shutDown()

    assertNull(viewer.photoLayerEntity)
    assertNull(viewer.videoEntity)
  }

  @Test
  fun `a reference set once the scene is down keeps nothing`() {
    val viewer = Viewer()
    viewer.spatial.shutDown()

    viewer.photoLayerEntity = viewer.context.newEntity()

    assertNull(viewer.photoLayerEntity)
  }

  @Test
  fun `a reference keeps what it was given while the scene is up`() {
    val viewer = Viewer()
    val entity = viewer.context.newEntity()

    viewer.photoLayerEntity = entity

    assertSame(entity, viewer.photoLayerEntity)
    assertFalse(viewer.spatial.isDown)
    viewer.photoLayerEntity = null
    assertNull(viewer.photoLayerEntity)
  }

  @Test
  fun `a second shutdown changes nothing`() {
    val viewer = Viewer()
    viewer.spatial.shutDown()
    viewer.spatial.shutDown()

    assertTrue(viewer.spatial.isDown)
    assertNull(viewer.photoLayerEntity)
  }

  @Test
  fun `the late drop of a viewer gone never reaches the entities of the next one`() {
    val context = SceneContext()
    val old = Viewer(context)
    old.showPhotoOnLayer()
    old.onSpatialShutdown()
    context.cleared = true
    // The next viewer sets EntityContext again: its photo layer gets the id the old one had
    context.renew()
    val next = Viewer(context)
    next.showPhotoOnLayer()

    // A drop of the old viewer that comes late: a post, a coroutine, a callback
    old.dropPhotoLayer()

    assertTrue(next.photoLayerEntity!!.visible)
    assertEquals(0, context.calls)
  }
}
