package app.alextran.immich.immersive.scene

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.ColorSpace
import android.net.Uri
import android.os.Handler
import android.util.Log
import app.alextran.immich.immersive.SceneStick
import app.alextran.immich.immersive.StereoComposer
import app.alextran.immich.immersive.TAG
import app.alextran.immich.immersive.VolumetricSceneSpec
import com.meta.spatial.core.Entity
import com.meta.spatial.core.Pose
import com.meta.spatial.core.Quaternion
import com.meta.spatial.core.SystemManager
import com.meta.spatial.core.Vector3
import com.meta.spatial.runtime.MaterialSidedness
import com.meta.spatial.runtime.SceneMaterial
import com.meta.spatial.runtime.SceneMesh
import com.meta.spatial.runtime.SceneTexture
import com.meta.spatial.runtime.StereoMode
import com.meta.spatial.runtime.TriangleMesh
import com.meta.spatial.toolkit.Material
import com.meta.spatial.toolkit.Mesh
import com.meta.spatial.toolkit.MeshCollision
import com.meta.spatial.toolkit.SceneObjectSystem
import com.meta.spatial.toolkit.Transform
import com.meta.spatial.toolkit.Visible
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.roundToLong

// The 3D scene of a photo in the Meta Quest (design-final 2026-10-27, sections 3.1 to 3.7, lot S3): its file opened
// from the cache of the viewer (SceneOpener, after SceneFile, SceneGate and GlbReader of lot S2), the panel and the
// passing texts that go with it (SceneTexts), and the scene itself (SceneView), one entity per mesh of the glb on the
// primitives of the 2.5D view of phase 1 (TriangleMesh, SceneMesh.fromTriangleMesh, an unlit material): no shader, no
// dependency, no glTF loader of the SDK. The root of the scene stays fixed in the world (SceneNavigator); beyond the
// safe zone the layers flatten towards the photo plane and the scene darkens. All but SceneView and the decoding of
// the textures is plain JVM code, tested by SceneViewTest.

/** Why a scene stays flat, the preview of the photo shown and the other versions within reach */
internal sealed interface SceneStop {
  /** The gate said no, before or after the glb was read */
  data class Refused(val verdict: SceneVerdict.Refused) : SceneStop

  /** The tail is missing or damaged, or nothing names it: "The 3D scene data is missing from this file" */
  data class Unreadable(val problem: SceneFileProblem) : SceneStop

  /** The glb is not of our subset, or of a newer format of ours */
  data class NotScene(val problem: GlbProblem) : SceneStop

  /** Something else went wrong: decoding a texture, making a mesh; [reason] is the message of the failure */
  data class Failed(val reason: String) : SceneStop
}

/** What opening a cached file gave: the scene ready to decode, or why it stays flat */
internal sealed interface SceneOpening {
  /** The request the viewer goes by ([spec]), the [head] it came from (null without our packet), the scene read */
  class Ready(
    val spec: VolumetricSceneSpec,
    val head: SceneHead?,
    val scene: GlbScene,
    val open: SceneVerdict.Open,
  ) : SceneOpening {
    /** Immuch360:HiddenFraction of the head, for the panel */
    val hiddenFraction: Double?
      get() = head?.hiddenFraction
  }

  data class Stopped(val stop: SceneStop) : SceneOpening
}

/**
 * Opens the scene of a cached file in the order of the design (section 3.2): the packet at the head, which wins over
 * the JSON of the request and may say a newer version or another kind at once (SceneGate.checkHead); the request
 * weighed with the size of the file and the heat before anything else is read; the tail, its length and its sum; the
 * glb; and the glb weighed again with its textures against the free memory.
 */
internal object SceneOpener {
  /**
   * The scene of [source] for [request] (the stereoPair JSON, which the packet of the head overrides) on a headset of
   * [caps]; [availableMemory] and [thermalStatus] are read when the gate needs them, null when unknown
   */
  fun open(
    source: SceneSource,
    request: VolumetricSceneSpec?,
    caps: SceneCaps,
    availableMemory: () -> Long?,
    thermalStatus: () -> Int?,
  ): SceneOpening {
    val head = SceneFile.readHead(source)
    if (head != null) {
      SceneGate.checkHead(head)?.let { return SceneOpening.Stopped(SceneStop.Refused(SceneVerdict.Refused(it))) }
    }
    val spec =
      SceneFile.specOf(head, request) ?: return SceneOpening.Stopped(SceneStop.Unreadable(SceneFileProblem.MISSING))
    val formatVersion = head?.formatVersion
    val before = SceneGate.check(SceneWeight.of(spec, formatVersion, source.length), caps, null, thermalStatus())
    if (before is SceneVerdict.Refused) return SceneOpening.Stopped(SceneStop.Refused(before))
    val glb =
      when (val tail = SceneFile.readTail(source, spec.sceneLength, spec.sceneSha256)) {
        is SceneTailResult.Read -> tail.glb
        is SceneTailResult.Failed -> return SceneOpening.Stopped(SceneStop.Unreadable(tail.problem))
      }
    val scene =
      try {
        GlbReader.read(glb)
      } catch (e: GlbException) {
        return SceneOpening.Stopped(SceneStop.NotScene(e.problem))
      }
    val weight = SceneWeight.of(scene, formatVersion, source.length)
    return when (val after = SceneGate.check(weight, caps, availableMemory(), thermalStatus())) {
      is SceneVerdict.Open -> SceneOpening.Ready(spec, head, scene, after)
      is SceneVerdict.Refused -> SceneOpening.Stopped(SceneStop.Refused(after))
    }
  }
}

/**
 * The texts of a scene in the headset (design-final 2026-10-27, sections 3.3, 3.5 and 3.7), translated by Flutter in
 * stereoLabels under these keys (sceneViewerLabels of immersive_viewer_labels.dart), each with its English text for a
 * key Flutter did not send. The numbers go where the translations put {triangles}, {max}, {size}, {percent} and
 * {reason}.
 */
internal object SceneTexts {
  const val LABEL_HONESTY = "sceneHonesty"
  const val LABEL_PREPARING = "scenePreparing"
  const val LABEL_EDGE = "sceneEdge"
  const val LABEL_RESET = "sceneReset"
  const val LABEL_PHOTO_2D = "scenePhoto2d"
  const val LABEL_SCENE_3D = "scene3d"
  const val LABEL_HINT = "sceneHint"
  const val LABEL_ZONE = "sceneZone"
  const val LABEL_HIDDEN = "sceneHidden"
  const val LABEL_TOO_HEAVY = "sceneTooHeavy"
  const val LABEL_TOO_HEAVY_PLAIN = "sceneTooHeavyPlain"
  const val LABEL_NEWER = "sceneNewer"
  const val LABEL_NOT_OURS = "sceneNotOurs"
  const val LABEL_NO_MEMORY = "sceneNoMemory"
  const val LABEL_TOO_WARM = "sceneTooWarm"
  const val LABEL_MISSING = "sceneMissing"
  const val LABEL_FAILED = "sceneFailed"

  /** The key of the line of a quality flag of the file, "sceneFlag" and its token: sceneFlag_fovGuessed */
  fun flagKey(flag: String): String = "sceneFlag_$flag"

  const val TRIANGLES = "{triangles}"
  const val MAX = "{max}"
  const val SIZE = "{size}"
  const val PERCENT = "{percent}"
  const val REASON = "{reason}"

  /** The flags a scene may carry that the panel says, in this order; wideGamut is about other apps only */
  val PANEL_FLAGS = listOf("lowRelief", "hiddenAreas", "dark", "sky", "fovGuessed", "smallZone")


  /**
   * The English texts of these keys, which StereoComposer.label falls back to with those of the stereo quad (Flutter
   * sends the translations)
   */
  val englishLabels: Map<String, String> =
    mapOf(
      LABEL_HONESTY to "Reconstructed from one photo, explore within its limits",
      LABEL_PREPARING to "Preparing the 3D scene",
      LABEL_EDGE to "Edge of the reconstructed area. Reset is in the panel.",
      LABEL_RESET to "Reset",
      LABEL_PHOTO_2D to "Photo (2D)",
      LABEL_SCENE_3D to "3D scene",
      LABEL_HINT to
        "Left thumbstick: glide. Click a thumbstick: Reset. A, X or grip: show or hide this panel. B or Y: back to " +
          "the app.",
      LABEL_ZONE to "Room to move: about $SIZE each way",
      LABEL_HIDDEN to "Hidden areas filled: $PERCENT%",
      LABEL_TOO_HEAVY to "This scene is too heavy for this headset ($TRIANGLES triangles, at most $MAX)",
      LABEL_TOO_HEAVY_PLAIN to "This scene is too heavy for this headset",
      LABEL_NEWER to "Made by a newer version of Immuch360: shown flat",
      LABEL_NOT_OURS to "Not a scene made by Immuch360",
      LABEL_NO_MEMORY to "Not enough free memory",
      LABEL_TOO_WARM to "Headset too warm",
      LABEL_MISSING to "The 3D scene data is missing from this file",
      LABEL_FAILED to "The 3D scene could not be shown: $REASON",
      flagKey("lowRelief") to "Little depth found: the relief may be weak",
      flagKey("hiddenAreas") to "Large hidden areas were filled in",
      flagKey("dark") to "Dark photo: the relief may be wrong",
      flagKey("sky") to "Much of the photo is sky: it stays far away",
      flagKey("fovGuessed") to "Field of view guessed: shapes may be off",
      flagKey("smallZone") to "Barely any movement is possible here: the 3D photo may suit this picture better.",
    )

  /** The text of [key] from the translated [labels], the English one when it is missing or blank */
  fun label(labels: Map<String, String>, key: String): String = StereoComposer.label(labels, key)

  /** What a scene that stays flat for [stop] says, a passing text over the preview */
  fun stopText(labels: Map<String, String>, stop: SceneStop): String =
    when (stop) {
      is SceneStop.Refused -> {
        val verdict = stop.verdict
        when (verdict.reason) {
          SceneRefusal.TOO_HEAVY ->
            if (verdict.limit == SceneLimit.TRIANGLES) {
              label(labels, LABEL_TOO_HEAVY).replace(TRIANGLES, "${verdict.value}").replace(MAX, "${verdict.max}")
            } else {
              // Only the triangles have their numbers in the sentence: the other limits say it plainly
              label(labels, LABEL_TOO_HEAVY_PLAIN)
            }
          SceneRefusal.NEWER_VERSION -> label(labels, LABEL_NEWER)
          SceneRefusal.NOT_OURS -> label(labels, LABEL_NOT_OURS)
          SceneRefusal.NOT_ENOUGH_MEMORY -> label(labels, LABEL_NO_MEMORY)
          SceneRefusal.TOO_WARM -> label(labels, LABEL_TOO_WARM)
        }
      }
      is SceneStop.Unreadable -> label(labels, LABEL_MISSING)
      is SceneStop.NotScene ->
        label(labels, if (stop.problem == GlbProblem.NEWER_FORMAT) LABEL_NEWER else LABEL_NOT_OURS)
      is SceneStop.Failed -> label(labels, LABEL_FAILED).replace(REASON, stop.reason)
    }

  /** The room the eye has on the floor: the mean of the reaches to the side, forward and backward, in metres */
  fun reachOf(safe: VolumetricSceneSpec.SafeZone): Double = (safe.lateral + safe.forward + safe.backward) / 3

  /** [metres] rounded to the centimetre, "18 cm"; from a metre on, to the decimetre, "1.2 m" or "1 m" */
  fun sizeText(metres: Double): String {
    // A hair over, so that 17.5 cm read back from a sum of decimals rounds the way it is written
    val centimetres = (metres * 100 + 1e-9).roundToLong()
    if (centimetres < 100) return "$centimetres cm"
    val decimetres = (metres * 10 + 1e-9).roundToLong()
    return if (decimetres % 10 == 0L) "${decimetres / 10} m"
    else String.format(Locale.ROOT, "%d.%d m", decimetres / 10, decimetres % 10)
  }

  /** "Room to move: about 18 cm each way" */
  fun zoneText(labels: Map<String, String>, safe: VolumetricSceneSpec.SafeZone): String =
    label(labels, LABEL_ZONE).replace(SIZE, sizeText(reachOf(safe)))

  /**
   * The lines the panel keeps for a scene (design-final 2026-10-27, sections 3.3 and 3.7): the honesty sentence, the
   * room to move, the part hidden and filled when the head says it (from 1 %), then a line per quality flag the panel
   * says (see [PANEL_FLAGS]), the hidden areas once only
   */
  fun detailLines(labels: Map<String, String>, spec: VolumetricSceneSpec, hiddenFraction: Double?): List<String> {
    val lines = mutableListOf(label(labels, LABEL_HONESTY), zoneText(labels, spec.safe))
    val percent = hiddenFraction?.let { (it * 100 + 1e-9).roundToInt() } ?: 0
    if (percent >= 1) lines += label(labels, LABEL_HIDDEN).replace(PERCENT, "$percent")
    for (flag in PANEL_FLAGS) {
      if (flag !in spec.flags || (flag == "hiddenAreas" && percent >= 1)) continue
      lines += label(labels, flagKey(flag))
    }
    return lines
  }
}

/** How the scene darkens beyond the zone (design-final 2026-10-27, section 3.4), the first that shows in the headset */
internal enum class SceneDarkening(val key: String) {
  /**
   * The albedo colour of each material: the shader of the SDK multiplies the texture by it and by the vertex colour
   * (metaSpatialSdkUberShader.glsl of 0.14.0, shaders.zip of the aar), unlit included
   */
  ALBEDO("albedo"),

  /** The colour of each vertex, written with the positions (updateGeometry), the same product of the shader */
  VERTEX_COLOURS("vertex"),
}

/**
 * The darkening of a scene: the grey its brightness gives, made again by steps as the flattening is (SceneNavigator
 * FLATTEN_STEP), and exactly at no darkening and at the most
 */
internal object SceneShade {
  /** An opaque white vertex: no darkening */
  const val WHITE = -1

  const val STEP = 0.02

  /** What is left of the light at [darken] (0: none taken, SceneNavigator.DARKEN_MAX: 95 % taken) */
  fun brightness(darken: Double): Double = (1.0 - darken).coerceIn(0.0, 1.0)

  /** The opaque grey of [darken], as a vertex colour */
  fun grey(darken: Double): Int {
    val level = (brightness(darken) * 255).roundToInt()
    return (0xFF shl 24) or (level shl 16) or (level shl 8) or level
  }

  /** Whether the darkening shown [shown] must be made again for [next] */
  fun needsUpdate(shown: Double, next: Double): Boolean =
    abs(next - shown) >= STEP - 1e-12 ||
      (next != shown && (next == 0.0 || next == SceneNavigator.DARKEN_MAX))
}

/**
 * The choices a measuring session may push to the headset without a new build (lot MQ, second session): how the
 * scene darkens and whether its faces show from both sides, read from [FILE_NAME] in the external files folder of the
 * app (adb push to /sdcard/Android/data/<package>/files/) when a scene opens. Without the file, the defaults: the
 * albedo colour, and both sides, which shows the scene whatever winding the native renderer takes as the front
 * (SdkFrame writes the triangles to face the camera; that the renderer culls the other side is read from
 * SceneMesh.singleSidedQuad, not seen yet). Lines "darken=albedo|vertex" and "sides=double|single".
 */
internal data class SceneViewerOptions(
  val darkening: SceneDarkening = SceneDarkening.ALBEDO,
  val doubleSided: Boolean = true,
) {
  companion object {
    const val FILE_NAME = "scene-viewer.properties"

    /** The options [text] holds; a line or a value this build does not know leaves the default */
    fun parse(text: String?): SceneViewerOptions {
      var options = SceneViewerOptions()
      for (line in text.orEmpty().lines()) {
        val trimmed = line.trim()
        val equals = trimmed.indexOf('=')
        // A comment, "#darken=...", is a key of its own, which this build does not know
        if (equals <= 0) continue
        val value = trimmed.substring(equals + 1).trim().lowercase(Locale.ROOT)
        when (trimmed.substring(0, equals).trim()) {
          "darken" ->
            SceneDarkening.entries.firstOrNull { it.key == value }?.let { options = options.copy(darkening = it) }
          "sides" ->
            when (value) {
              "double" -> options = options.copy(doubleSided = true)
              "single" -> options = options.copy(doubleSided = false)
            }
        }
      }
      return options
    }
  }
}

/**
 * The arrays of one mesh handed to the triangles of the Spatial SDK: its positions written for the left handed world of
 * the SDK after the flattening of the edge (SceneNavigator.flatten, then SdkFrame.positions, in one array rewritten in
 * place), its triangles with two corners swapped (SdkFrame.indices, once), its texture coordinates as the glb holds
 * them, normals towards the camera (an unlit material does not read them) and the vertex colours of the darkening.
 */
internal class SceneMeshBuffers(val mesh: GlbMesh) {
  val vertexCount: Int = mesh.vertexCount
  val indices: IntArray = SdkFrame.indices(mesh.indices)
  val uvs: FloatArray
    get() = mesh.uvs

  val normals: FloatArray = FloatArray(3 * vertexCount).also { for (k in 0 until vertexCount) it[3 * k + 2] = -1f }
  val colours: IntArray = IntArray(vertexCount) { SceneShade.WHITE }

  /** The positions last written */
  val positions: FloatArray = FloatArray(3 * vertexCount)

  /** The positions flattened by [flatten] towards [photoPlane] (no flattening without one), for the SDK */
  fun write(flatten: Double, photoPlane: Double?): FloatArray {
    if (photoPlane == null || flatten == 0.0) mesh.positions.copyInto(positions)
    else SceneNavigator.flatten(mesh, flatten, photoPlane, positions)
    return SdkFrame.positions(positions, positions)
  }

  /** The vertex colours of [darken], for the vertex mechanism */
  fun shade(darken: Double): IntArray {
    colours.fill(SceneShade.grey(darken))
    return colours
  }
}

/**
 * A scene ready for the headset, prepared off the main thread: its request, the arrays of each mesh at no flattening,
 * the photo plane the layers flatten towards, and the part hidden and filled for the panel
 */
internal class ScenePrepared(
  val spec: VolumetricSceneSpec,
  val meshes: List<SceneMeshBuffers>,
  val photoPlane: Double?,
  val hiddenFraction: Double?,
) {
  val vertices: Int
    get() = meshes.sumOf { it.vertexCount }

  val triangles: Int
    get() = meshes.sumOf { it.indices.size / 3 }

  companion object {
    fun of(ready: SceneOpening.Ready): ScenePrepared {
      val plane = SceneNavigator.photoPlane(ready.scene.meshes)
      val meshes = ready.scene.meshes.map { SceneMeshBuffers(it).also { buffers -> buffers.write(0.0, plane) } }
      return ScenePrepared(ready.spec, meshes, plane, ready.hiddenFraction)
    }
  }
}

/**
 * The scene in the world of the Spatial SDK (design-final 2026-10-27, section 3.1): one entity per mesh, each a
 * TriangleMesh made by the mesh creator of the viewer ([createMesh], under [MESH_URI]) with an unlit material showing
 * its texture, decoded in sRGB; all at the pose of the root SceneNavigator gives, which changes only with the glide
 * and Reset, never with the head. Each frame ([onFrame]) the navigator reads the head and the left thumbstick: the
 * meshes are made again when the flattening moves by a step, the darkening follows, and the text of the edge shows once
 * (the [listener] says it). Hidden until every mesh is made and the first frame placed it ([Listener.onSceneShown]);
 * hidden again for Photo (2D). Main thread only, as the systems of the SDK run.
 */
internal class SceneView(
  private val context: Context,
  private val systemManager: SystemManager,
  private val main: Handler,
  private val prepared: ScenePrepared,
  private val textures: List<SceneTexture>,
  private val options: SceneViewerOptions,
  private val listener: Listener,
) {
  interface Listener {
    fun onSceneShown()

    fun onSceneFailed(reason: String)

    fun onSceneEdge()
  }

  private class Slot(val buffers: SceneMeshBuffers) {
    var entity: Entity? = null
    @Volatile var triangles: TriangleMesh? = null
    @Volatile var sceneMesh: SceneMesh? = null
    @Volatile var material: SceneMaterial? = null
    var ready = false
  }

  /** This scene among the scenes of the process, in the URI of its meshes */
  val id: Long = lastId.incrementAndGet()

  private val slots = prepared.meshes.map(::Slot)
  private val navigator = SceneNavigator(prepared.spec.safe)
  private var placed = false
  private var shown = false
  private var visible = true
  private var failed = false
  private var destroyed = false
  private var resetPending = false

  // What the meshes and the root show now
  private var flatten = 0.0
  private var darken = 0.0
  private var rootPose: DoubleArray? = null

  /** Whether the scene shows in the world (every mesh made, placed, not hidden for Photo (2D)) */
  val isShown: Boolean
    get() = shown && visible

  /** Every mesh made and the scene placed, neither failed nor gone: Photo (2D) and Reset may be offered */
  val isReady: Boolean
    get() = shown && !failed && !destroyed

  /** Creates the entities of the meshes, hidden; their meshes come from [createMesh] */
  fun attach() {
    val sceneObjects = systemManager.findSystem<SceneObjectSystem>()
    Log.i(
      TAG,
      "scene: ${slots.size} meshes, ${prepared.vertices} vertices, ${prepared.triangles} triangles, " +
        "darkening by ${options.darkening.key}, ${if (options.doubleSided) "double" else "single"} sided",
    )
    for ((k, slot) in slots.withIndex()) {
      val entity =
        Entity.create(
          listOf(
            Mesh(Uri.parse("$MESH_URI?scene=$id&mesh=$k"), hittable = MeshCollision.NoCollision),
            Material().apply { unlit = true },
            Transform(Pose(Vector3(0f, 0f, 0f), Quaternion(0f, 0f, 0f))),
            Visible(false),
          ),
        )
      slot.entity = entity
      val future = sceneObjects.getSceneObject(entity)
      if (future == null) {
        fail("no scene object for mesh $k")
        continue
      }
      future.thenAccept { main.post { onMeshMade(k) } }
    }
  }

  /**
   * The mesh of [uri] for [entity], from the mesh creator of the viewer; null when the URI names another scene (one
   * already gone) or the SDK could not make it, which hides the scene and says why
   */
  fun createMesh(entity: Entity, uri: Uri): SceneMesh? {
    if (uri.getQueryParameter("scene")?.toLongOrNull() != id || destroyed) return null
    val k = uri.getQueryParameter("mesh")?.toIntOrNull() ?: return null
    val slot = slots.getOrNull(k) ?: return null
    val buffers = slot.buffers
    return try {
      val texture = textures[buffers.mesh.texture]
      val material =
        entity.getComponent<Material>().generateSceneMaterial(entity, context).apply {
          setAlbedoTexture(texture)
          setStereoMode(StereoMode.None)
          setSidedness(if (options.doubleSided) MaterialSidedness.DOUBLE_SIDED else MaterialSidedness.FRONT_SIDED)
        }
      val count = buffers.indices.size
      val triangles = TriangleMesh(buffers.vertexCount, count, intArrayOf(0, count), arrayOf(material))
      triangles.updateGeometry(0, buffers.positions, buffers.normals, buffers.uvs, buffers.colours)
      triangles.updatePrimitives(0, buffers.indices)
      val sceneMesh = SceneMesh.fromTriangleMesh(triangles, false)
      slot.material = material
      slot.triangles = triangles
      slot.sceneMesh = sceneMesh
      sceneMesh
    } catch (e: Throwable) {
      Log.e(TAG, "scene: mesh $k could not be made", e)
      main.post { fail(e.message ?: e.javaClass.simpleName) }
      null
    }
  }

  private fun onMeshMade(k: Int) {
    if (destroyed || failed) return
    val slot = slots[k]
    if (slot.sceneMesh == null) {
      fail("mesh $k was not made")
      return
    }
    slot.ready = true
    showWhenReady()
  }

  /** Lays the camera of the photo at the head again at the next frame: the eye back in the zone, the scene whole */
  fun reset() {
    resetPending = true
    Log.i(TAG, "scene: Reset")
  }

  /** Shows the scene, or hides it for Photo (2D) */
  fun setVisible(visible: Boolean) {
    this.visible = visible
    if (shown) slots.forEach { it.entity?.setComponent(Visible(visible)) }
  }

  /**
   * One frame of [seconds] with the [head] pose of the SDK and the buttons [held]: the navigator moves the root for the
   * glide, the meshes follow the flattening and the darkening, the text of the edge shows once
   */
  fun onFrame(head: Pose, held: Int, seconds: Double) {
    if (destroyed || failed) return
    val gaze = head.forward()
    val t = head.t
    if (resetPending) {
      resetPending = false
      navigator.anchorInSdk(t.x.toDouble(), t.y.toDouble(), t.z.toDouble(), gaze.x.toDouble(), gaze.z.toDouble())
    }
    // The stick glides only once the scene shows
    val (right, forward) = if (isShown) SceneStick.of(held) else 0.0 to 0.0
    val frame =
      navigator.updateInSdk(
        t.x.toDouble(),
        t.y.toDouble(),
        t.z.toDouble(),
        gaze.x.toDouble(),
        gaze.z.toDouble(),
        right,
        forward,
        seconds,
      )
    if (!placed) {
      placed = true
      Log.i(TAG, "scene: placed at the head, root ${frame.sdkRootX}, ${frame.sdkRootY}, ${frame.sdkRootZ}")
    }
    placeRoot(frame)
    if (frame.rebuild) rebuild(frame.flatten)
    if (SceneShade.needsUpdate(darken, frame.darken)) shade(frame.darken)
    if (frame.edgeNotice && isShown) {
      Log.i(TAG, "scene: edge of the zone, rho ${frame.rho}")
      listener.onSceneEdge()
    }
    showWhenReady()
  }

  private fun placeRoot(frame: SceneNavigation) {
    val pose = doubleArrayOf(frame.sdkRootX, frame.sdkRootY, frame.sdkRootZ, frame.sdkRootYawDegrees)
    val last = rootPose
    if (last != null && (0 until 4).all { abs(last[it] - pose[it]) < 1e-5 }) return
    rootPose = pose
    val transform =
      Transform(
        Pose(
          Vector3(pose[0].toFloat(), pose[1].toFloat(), pose[2].toFloat()),
          Quaternion(0f, pose[3].toFloat(), 0f),
        )
      )
    slots.forEach { it.entity?.setComponent(transform) }
  }

  private fun rebuild(next: Double) {
    if ((next == 0.0 || next == 1.0) && next != flatten) {
      Log.i(TAG, "scene: the layers are now ${if (next == 0.0) "whole" else "flat"}")
    }
    flatten = next
    val colours = options.darkening == SceneDarkening.VERTEX_COLOURS
    for (slot in slots) {
      val positions = slot.buffers.write(next, prepared.photoPlane)
      write(slot, positions, if (colours) slot.buffers.colours else null)
    }
  }

  private fun shade(next: Double) {
    if ((next == 0.0 || next == SceneNavigator.DARKEN_MAX) && next != darken) {
      Log.i(TAG, "scene: darkened to ${(next * 100).roundToInt()}% by ${options.darkening.key}")
    }
    darken = next
    when (options.darkening) {
      SceneDarkening.ALBEDO -> {
        val level = SceneShade.brightness(next).toFloat()
        val colour = Color.valueOf(level, level, level, 1f)
        slots.forEach { slot -> slot.material?.let { runCatching { it.setAlbedoColor(colour) } } }
      }
      SceneDarkening.VERTEX_COLOURS ->
        slots.forEach { slot -> write(slot, slot.buffers.positions, slot.buffers.shade(next)) }
    }
  }

  private fun write(slot: Slot, positions: FloatArray, colours: IntArray?) {
    val triangles = slot.triangles ?: return
    val sceneMesh = slot.sceneMesh ?: return
    try {
      triangles.updateGeometry(0, positions, slot.buffers.normals, null, colours)
      sceneMesh.updateWithTriangleMesh(triangles, false)
    } catch (e: Throwable) {
      Log.e(TAG, "scene: a mesh could not be written again", e)
      fail(e.message ?: e.javaClass.simpleName)
    }
  }

  private fun showWhenReady() {
    if (shown || failed || destroyed || !placed || slots.any { !it.ready }) return
    shown = true
    slots.forEach { it.entity?.setComponent(Visible(visible)) }
    Log.i(TAG, "scene shown")
    listener.onSceneShown()
  }

  private fun fail(reason: String) {
    if (failed || destroyed) return
    failed = true
    slots.forEach { it.entity?.setComponent(Visible(false)) }
    Log.e(TAG, "scene failed: $reason")
    listener.onSceneFailed(reason)
  }

  /**
   * Takes the scene out of the world: its entities, then its textures a moment later, once the renderer let go of
   * the materials that show them
   */
  fun destroy() {
    if (destroyed) return
    destroyed = true
    for (slot in slots) {
      runCatching { slot.entity?.destroy() }
      slot.entity = null
      slot.material = null
      slot.sceneMesh = null
      slot.triangles = null
    }
    main.postDelayed({ textures.forEach { runCatching { it.destroy() } } }, TEXTURE_RELEASE_DELAY_MS)
    Log.i(TAG, "scene gone")
  }

  /**
   * The scene of the SDK goes down with its entities and its textures (onSpatialShutdown): only the references go, no
   * call reaches the SDK any more
   */
  fun abandon() {
    destroyed = true
    for (slot in slots) {
      slot.entity = null
      slot.material = null
      slot.sceneMesh = null
      slot.triangles = null
    }
  }

  companion object {
    /** The base of the URIs of the meshes of the scenes, the key of the mesh creator of the viewer */
    const val MESH_URI = "mesh://immuch_scene_mesh"

    /** How long the textures of a scene gone are kept, for the frames still in flight */
    const val TEXTURE_RELEASE_DELAY_MS = 1000L

    private val lastId = AtomicLong()

    /**
     * The textures of [scene] decoded off the main thread at the [sampleSizes] of the gate, in sRGB (design-final
     * 2026-10-27, section 8.7: a glTF holds sRGB colours, a Display P3 photo is read into sRGB here), as bitmaps for
     * SceneTexture. Null when one does not decode; the bitmaps decoded so far are recycled then.
     */
    fun decodeTextures(scene: GlbScene, sampleSizes: List<Int>): List<Bitmap>? {
      val decoded = mutableListOf<Bitmap>()
      for ((index, texture) in scene.textures.withIndex()) {
        val options =
          BitmapFactory.Options().apply {
            inSampleSize = sampleSizes.getOrElse(index) { 1 }
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
            inScaled = false
          }
        val bitmap =
          try {
            BitmapFactory.decodeByteArray(texture.data, texture.offset, texture.length, options)
          } catch (e: Throwable) {
            decoded.forEach { it.recycle() }
            throw e
          }
        if (bitmap == null) {
          Log.e(TAG, "scene: texture $index of ${texture.width}x${texture.height} does not decode")
          decoded.forEach { it.recycle() }
          return null
        }
        Log.i(
          TAG,
          "scene: texture $index ${texture.width}x${texture.height} decoded ${bitmap.width}x${bitmap.height} " +
            "(sample ${options.inSampleSize}, ${bitmap.colorSpace?.name})",
        )
        decoded += bitmap
      }
      return decoded
    }
  }
}
