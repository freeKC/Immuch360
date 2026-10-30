package app.alextran.immich.immersive

import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

/**
 * Whether the scene of the Spatial SDK still holds what the immersive viewer made in it (its entities, panels,
 * materials, textures, meshes and the Surfaces of its layers), and the viewer's references to those objects.
 *
 * VrActivity of the Spatial SDK 0.14.0 runs its destroy() once, at the first of onPause, onStop or onDestroy that
 * finds the activity finishing, else at onDestroy: onSpatialShutdown, then the systems, the scene and the data model
 * destroyed, then EntityContext cleared, so that any later call on an entity of the process throws NotImplementedError
 * ("An operation is not implemented", from EntityContext$clear). A viewer closed by Back or by the system thus runs its
 * own onPause, onStop and onDestroy after that: in build 33 the onDestroy of the viewer hid the photo layer of the flat
 * screens there, the process crashed and the 2D window of the app went with it (logcat of 30 October 2026, 10:21:57).
 * EntityContext is one for the process, so a late call could also reach the entities of the next viewer.
 *
 * [shutDown] runs first in onSpatialShutdown. From then on every reference made by [ref] reads null and keeps nothing
 * it is given, so that a drop of onDestroy, a coroutine, a posted runnable or a callback of the SDK that comes later
 * touches nothing; [isDown] tells the code that would make a new object, or that waited for one (a post, a future of
 * the SDK), not to go on. The bitmaps and the jobs of the viewer are not held here: its drops still let them go. Pure,
 * unit tested (SpatialHoldTest).
 */
internal class SpatialHold {
  /** The scene of the SDK is gone or going: set at the start of onSpatialShutdown, never cleared. */
  @Volatile
  var isDown = false
    private set

  private val refs = mutableListOf<Ref<*>>()

  /**
   * A reference to an object of the scene, for a property of the viewer (`var photoLayerEntity: Entity? by
   * spatial.ref()`): what was set while the scene is up, null once it is down.
   */
  fun <T : Any> ref(): ReadWriteProperty<Any?, T?> = Ref<T>().also { refs += it }

  /** The scene goes down: every reference lets its object go and takes none after. A second call changes nothing. */
  fun shutDown() {
    isDown = true
    refs.forEach { it.value = null }
  }

  private inner class Ref<T : Any> : ReadWriteProperty<Any?, T?> {
    // The mesh creators of the SDK write some of them off the main thread
    @Volatile var value: T? = null

    override fun getValue(thisRef: Any?, property: KProperty<*>): T? = if (isDown) null else value

    override fun setValue(thisRef: Any?, property: KProperty<*>, value: T?) {
      this.value = if (isDown) null else value
    }
  }
}
