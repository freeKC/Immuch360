package app.alextran.immich.immersive.splat

import android.net.Uri
import android.os.Handler
import android.util.Log
import app.alextran.immich.immersive.SceneStick
import app.alextran.immich.immersive.TAG
import app.alextran.immich.immersive.VolumetricSceneSpec.SafeZone
import app.alextran.immich.immersive.scene.SceneNavigation
import app.alextran.immich.immersive.scene.SceneNavigator
import com.meta.spatial.core.Entity
import com.meta.spatial.core.Pose
import com.meta.spatial.core.Quaternion
import com.meta.spatial.core.SystemManager
import com.meta.spatial.core.Vector3
import com.meta.spatial.toolkit.Transform
import com.meta.spatial.toolkit.Visible
import java.io.File
import kotlin.math.abs

/**
 * The splat of the immersive viewer in the world (lot S5): its entity made by the splat module ([SplatEngine]) once
 * the file is prepared ([SplatPreparer]), its life kept by [SplatSession], its place given by [SplatPlacement] in the
 * frame of a [SceneNavigator] anchored at the head (the glide of the left thumbstick at [GLIDE_SPEED] in a zone of
 * [ZONE] each way, Reset, Turn upright). Everything runs on the main thread; the load event of the module is posted
 * there. Once the scene of the SDK is down ([shutDown], from onSpatialShutdown) nothing here calls the SDK again.
 */
internal class SplatStage(
  private val engine: SplatEngine,
  private val systems: SystemManager,
  private val main: Handler,
  private val memory: SplatUprightMemory,
  private val listener: Listener,
) {
  interface Listener {
    /** The splat shows, after its load event and the pause of the options */
    fun onSplatShown()

    /** The module could not load it, or did not answer: [reason] for the user */
    fun onSplatFailed(reason: String)
  }

  /** The splat asked for last: its file, what it is, where it is */
  private class Current(
    val prepared: SplatPreparation.Ready,
    val spec: GaussianSplatSpec,
    val options: SplatViewerOptions,
    var upright: SplatUpright,
  ) {
    val navigator = SceneNavigator(SafeZone(ZONE, ZONE, ZONE, ZONE), GLIDE_SPEED)
    var entity: Entity? = null
    var shown = false
    var reanchor = true

    /** The position of the entity in the frame of the anchor and its rotation, for the orientation of now */
    var local: Pair<Vector3, Quaternion>? = null
    var lastPose: FloatArray? = null
  }

  private val files = HashMap<Entity, File>()
  private val session =
    SplatSession(
      object : SplatSession.Effects<Entity> {
        override fun destroy(handle: Entity) {
          runCatching { handle.destroy() }.onFailure { Log.w(TAG, "splat: entity not destroyed: ${it.message}") }
          files.remove(handle)?.delete()
          Log.i(TAG, "splat gone")
        }

        override fun show(handle: Entity) = reveal(handle)
      }
    )
  private var current: Current? = null

  /** The scene of the SDK is down: no splat any more */
  val isDown: Boolean
    get() = session.isDown

  /** A splat shows now */
  val isShown: Boolean
    get() = current?.shown == true

  /** The orientation of the splat asked for last, null without one */
  val upright: SplatUpright?
    get() = current?.upright

  /** A new splat is being read: the one shown goes; false once the scene is down */
  fun prepare(): Boolean {
    current = null
    return session.prepare()
  }

  /**
   * Shows the splat [prepared] for [spec], placed from the head at [headPosition] looking along [headForward] (null
   * before the first head pose: placed from a head 1.6 m above the origin, then again at the first head pose), once
   * no splat dropped before is still loading
   */
  fun show(
    prepared: SplatPreparation.Ready,
    spec: GaussianSplatSpec,
    options: SplatViewerOptions,
    headPosition: Vector3?,
    headForward: Vector3?,
  ) {
    if (session.isDown) return
    val upright = memory.read(spec.name, spec.fileBytes)
    val splat = Current(prepared, spec, options, upright)
    current = splat
    session.whenFree { start(splat, headPosition, headForward) }
  }

  private fun start(splat: Current, headPosition: Vector3?, headForward: Vector3?) {
    if (current !== splat) {
      if (splat.prepared.owned) splat.prepared.file.delete()
      return
    }
    val pose = anchorAndPlace(splat, headPosition ?: DEFAULT_POSITION, headForward ?: DEFAULT_FORWARD)
    // Without a head pose yet, placed again at the first one
    if (headPosition == null) splat.reanchor = true
    val holder = arrayOfNulls<Entity>(1)
    val entity =
      try {
        engine.create(Uri.fromFile(splat.prepared.file), pose) { success, error ->
          main.post { holder[0]?.let { loaded(it, success, error) } }
        }
      } catch (e: Throwable) {
        Log.e(TAG, "splat: the module made no entity", e)
        session.drop()
        listener.onSplatFailed(e.message ?: e.javaClass.simpleName)
        return
      }
    holder[0] = entity
    if (!session.made(entity)) {
      runCatching { entity.destroy() }
      return
    }
    if (splat.prepared.owned) files[entity] = splat.prepared.file
    splat.entity = entity
    splat.lastPose = valuesOf(pose)
    Log.i(
      TAG,
      "splat: ${splat.prepared.file.name} loading, ${splat.prepared.verdict}, ${splat.prepared.bounds}, " +
        "upright ${splat.upright.key}, moved by ${splat.options.move.key}",
    )
    main.postDelayed(
      {
        if (session.timedOut(entity) == SplatSession.Loaded.FAILED) {
          listener.onSplatFailed("no answer from the splat module in ${SplatSession.LOAD_TIMEOUT_MS / 1000} s")
        }
      },
      SplatSession.LOAD_TIMEOUT_MS,
    )
  }

  private fun loaded(entity: Entity, success: Boolean, error: String?) {
    Log.i(TAG, "splat: load event, ${if (success) "loaded" else "failed: $error"}")
    if (session.loaded(entity, success) == SplatSession.Loaded.FAILED) {
      listener.onSplatFailed(error?.takeIf { it.isNotBlank() } ?: "the splat module could not load the file")
    }
  }

  private fun reveal(entity: Entity) {
    val splat = current ?: return
    main.postDelayed(
      {
        if (session.isDown || current !== splat || session.handle !== entity) return@postDelayed
        entity.setComponent(Visible(true))
        splat.shown = true
        Log.i(TAG, "splat shown")
        listener.onSplatShown()
      },
      splat.options.revealDelayMs,
    )
  }

  /**
   * One frame of [seconds] with the [head] pose of the SDK and the buttons [held]: the glide once the splat shows, a
   * new anchor after Reset or Turn upright, and the splat moved when its pose changed
   */
  fun onFrame(head: Pose, held: Int, seconds: Double) {
    if (session.isDown) return
    val splat = current ?: return
    val entity = splat.entity ?: return
    if (splat.reanchor) {
      // Reset or Turn upright: placed again from the head of now, the glide back to nothing
      move(splat, entity, anchorAndPlace(splat, head.t, head.forward()))
      return
    }
    // The stick glides only once the splat shows; the root stays fixed in the world otherwise, and nothing is set
    val (right, forward) = if (splat.shown) SceneStick.of(held) else 0.0 to 0.0
    move(splat, entity, poseOf(splat, update(splat, head.t, head.forward(), right, forward, seconds)))
  }

  /** Reset, from the panel or a click of a thumbstick: the splat placed again from where the user is now */
  fun reset() {
    val splat = current ?: return
    if (!splat.shown) return
    splat.reanchor = true
    Log.i(TAG, "splat: Reset")
  }

  /** Turn upright: the next orientation, remembered for the file, the splat placed again in front; null without one */
  fun turnUpright(): SplatUpright? {
    val splat = current ?: return null
    if (!splat.shown) return null
    splat.upright = splat.upright.next()
    splat.local = null
    splat.reanchor = true
    memory.write(splat.spec.name, splat.spec.fileBytes, splat.upright)
    Log.i(TAG, "splat: upright ${splat.upright.key}")
    return splat.upright
  }

  /** Another media, or the end of the viewer before the scene goes: the splat goes, now or once it loaded */
  fun drop() {
    if (session.isDown) return
    current = null
    session.drop()
  }

  /** The scene of the SDK goes down with its entities (onSpatialShutdown): only the references go */
  fun shutDown() {
    session.shutDown()
    current = null
    files.clear()
  }

  private fun anchorAndPlace(splat: Current, t: Vector3, gaze: Vector3): Pose {
    splat.reanchor = false
    splat.navigator.anchorInSdk(t.x.toDouble(), t.y.toDouble(), t.z.toDouble(), gaze.x.toDouble(), gaze.z.toDouble())
    return poseOf(splat, update(splat, t, gaze, 0.0, 0.0, 0.0))
  }

  private fun update(
    splat: Current,
    t: Vector3,
    gaze: Vector3,
    right: Double,
    forward: Double,
    seconds: Double,
  ): SceneNavigation =
    splat.navigator.updateInSdk(
      t.x.toDouble(),
      t.y.toDouble(),
      t.z.toDouble(),
      gaze.x.toDouble(),
      gaze.z.toDouble(),
      right,
      forward,
      seconds,
    )

  /** The pose of the entity in the world for the root of [frame]: the root, then the place in its frame */
  private fun poseOf(splat: Current, frame: SceneNavigation): Pose {
    val (position, rotation) = splat.local ?: localOf(splat).also { splat.local = it }
    val root = Quaternion(0f, frame.sdkRootYawDegrees.toFloat(), 0f)
    val origin = Vector3(frame.sdkRootX.toFloat(), frame.sdkRootY.toFloat(), frame.sdkRootZ.toFloat())
    return Pose(origin.plus(root.times(position)), root.times(rotation))
  }

  /** The place of the entity in the frame of the anchor, and its rotation, for the orientation of [splat] */
  private fun localOf(splat: Current): Pair<Vector3, Quaternion> {
    val rotation = Quaternion(splat.upright.pitchDegrees, 0f, 0f)
    val bounds = splat.prepared.bounds
    val centre =
      if (bounds == null) doubleArrayOf(0.0, 0.0, 0.0)
      else {
        val c = bounds.center
        val turned = rotation.times(Vector3(c[0].toFloat(), c[1].toFloat(), c[2].toFloat()))
        doubleArrayOf(turned.x.toDouble(), turned.y.toDouble(), turned.z.toDouble())
      }
    val local = SplatPlacement.localPosition(bounds, centre)
    return Vector3(local[0].toFloat(), local[1].toFloat(), local[2].toFloat()) to rotation
  }

  private fun valuesOf(pose: Pose): FloatArray =
    floatArrayOf(pose.t.x, pose.t.y, pose.t.z, pose.q.w, pose.q.x, pose.q.y, pose.q.z)

  private fun move(splat: Current, entity: Entity, pose: Pose) {
    val values = valuesOf(pose)
    val last = splat.lastPose
    if (last != null && values.indices.all { abs(values[it] - last[it]) < MOVE_EPSILON }) return
    splat.lastPose = values
    when (splat.options.move) {
      SplatViewerOptions.Move.TRANSFORM -> entity.setComponent(Transform(pose))
      SplatViewerOptions.Move.SYSTEM ->
        if (!engine.moveBySystem(systems, entity, pose)) entity.setComponent(Transform(pose))
      SplatViewerOptions.Move.BOTH -> {
        entity.setComponent(Transform(pose))
        engine.moveBySystem(systems, entity, pose)
      }
    }
  }

  companion object {
    /** The glide of the left thumbstick in a splat, in metres per second */
    const val GLIDE_SPEED = 0.5

    /** How far the glide goes each way from where the splat was placed, in metres */
    const val ZONE = 5.0

    private const val MOVE_EPSILON = 1e-5f

    /** A head at 1.6 m looking along +z, for a splat made before the first head pose */
    private val DEFAULT_POSITION = Vector3(0f, 1.6f, 0f)
    private val DEFAULT_FORWARD = Vector3(0f, 0f, 1f)
  }
}
