package app.alextran.immich.immersive.scene

import app.alextran.immich.immersive.VolumetricSceneSpec.SafeZone
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Where the eye is in a 3D scene, and what the scene does about it (design-final 2026-10-27, sections 3.3 and 3.4).
 *
 * The scene is fixed to the world: [anchor] lays the camera of the photo at the head, looking where the head looks
 * (yaw only, the horizon level), when the scene opens and at Reset. Walking is never stopped. The left thumbstick
 * glides the eye in the horizontal plane, in the frame of the gaze, at [GLIDE_SPEED] eased in and out over
 * [GLIDE_EASE] (the Controller component gives directions only, hence one speed); the glide stops at the edge of the
 * zone. The eye, head plus glide, sits at the normalised distance rho of the ellipsoid of the safe zone; beyond 1 the
 * layers flatten towards the photo plane on the rays from the camera, flat at [FLATTEN_TO], and from [DARKEN_FROM]
 * the scene darkens up to [DARKEN_MAX], when "Edge of the reconstructed area. Reset is in the panel." shows once.
 * The meshes are made again only when the flattening moved by [FLATTEN_STEP] (updateGeometry, as the 2.5D mesh).
 *
 * The curves are those of .github/desktop/ai/make_scene_golden.py, step 10, read again by SceneNavigatorTest in
 * scene_golden_v1.json. Pure JVM; the viewer feeds the pose of the head in the world each frame and moves the root of
 * the scene to the pose this gives.
 *
 * Frames: right handed, as the glb. The scene is the frame of the camera of the photo (x right, y up, looking towards
 * -z), whose root sits at [SceneNavigation.rootX], rootY, rootZ turned by rootYaw about y; the world is the world of
 * the Spatial SDK with its z turned the other way, the SDK being left handed (z forward). A yaw turns counter
 * clockwise seen from above: at yaw a the gaze looks towards (-sin a, 0, -cos a) ([yawOf]). The viewer gives and
 * takes the poses of the SDK through [anchorInSdk], [updateInSdk] and SceneNavigation.sdkRootX and the like, and
 * writes the meshes through [SdkFrame]: fed the numbers of the SDK as they are, the scene would show mirrored and the
 * stick would glide the wrong way sideways.
 */
internal class SceneNavigator(private val safe: SafeZone) {
  companion object {
    /** The layers flatten from rho [FLATTEN_FROM] to [FLATTEN_TO] and darken from [DARKEN_FROM] up to [DARKEN_MAX] */
    const val FLATTEN_FROM = 1.0
    const val FLATTEN_TO = 1.5
    const val DARKEN_FROM = 1.25
    const val DARKEN_MAX = 0.95

    /** Flat, the background stays this far behind the photo plane */
    const val FLAT_BACKGROUND = 0.01

    /** The meshes are made again when the flattening moved by this much */
    const val FLATTEN_STEP = 0.02

    /** The glide of the left thumbstick, in metres per second, eased in and out over [GLIDE_EASE] seconds */
    const val GLIDE_SPEED = 0.25
    const val GLIDE_EASE = 0.2

    /** A frame longer than this (the headset busy) moves the glide no further than this would */
    const val MAX_FRAME_SECONDS = 0.1

    /** smooth(t) = t * t * (3 - 2 * t), t clamped to [0, 1]: the curve of ReliefMesh, without plateaus */
    fun smooth(t: Double): Double {
      val x = t.coerceIn(0.0, 1.0)
      return x * x * (3 - 2 * x)
    }

    /** How far the layers are flattened at [rho]: 0 within the zone, 1 from [FLATTEN_TO] */
    fun flattenOf(rho: Double): Double = smooth((rho - FLATTEN_FROM) / (FLATTEN_TO - FLATTEN_FROM))

    /** How dark the scene is at [rho]: 0 up to [DARKEN_FROM], [DARKEN_MAX] from [FLATTEN_TO] */
    fun darkenOf(rho: Double): Double = DARKEN_MAX * smooth((rho - DARKEN_FROM) / (FLATTEN_TO - DARKEN_FROM))

    /**
     * The normalised distance of an eye at [x], [y], [z] from where it started, in the frame of the scene: towards the
     * scene (z < 0) the forward reach, away from it the backward one. A reach of 0 allows no movement on its axis.
     */
    fun rhoOf(x: Double, y: Double, z: Double, safe: SafeZone): Double {
      fun part(value: Double, reach: Double): Double =
        when {
          value == 0.0 -> 0.0
          reach <= 0.0 -> Double.POSITIVE_INFINITY
          else -> value / reach
        }
      val a = part(x, safe.lateral)
      val b = part(y, safe.vertical)
      val c = part(z, if (z < 0) safe.forward else safe.backward)
      return sqrt(a * a + b * b + c * c)
    }

    /** The yaw of a gaze whose horizontal direction is [forwardX], [forwardZ] (in the world, or in the scene) */
    fun yawOf(forwardX: Double, forwardZ: Double): Double = atan2(-forwardX, -forwardZ)

    /**
     * A vertex at [x], [y], [z] (its depth -z) slid on its ray from the camera to the depth (1 - a) z + a [plane]: the
     * view from the start does not change, and no hole can open
     */
    fun flattened(x: Double, y: Double, z: Double, a: Double, plane: Double): DoubleArray {
      val depth = -z
      if (depth <= 0.0) return doubleArrayOf(x, y, z)
      val ratio = ((1 - a) * depth + a * plane) / depth
      return doubleArrayOf(x * ratio, y * ratio, z * ratio)
    }

    /** The median of [depths], the lower middle one of an even count; null when there is none */
    fun planeOf(depths: DoubleArray): Double? {
      if (depths.isEmpty()) return null
      val sorted = depths.sortedArray()
      return sorted[(sorted.size - 1) / 2]
    }

    /**
     * The depth of each vertex the triangles of the photo layer use, a vertex shared by two bands of the layer (the
     * same position in both) counted once
     */
    fun photoDepths(meshes: List<GlbMesh>): DoubleArray {
      val seen = HashSet<Triple<Float, Float, Float>>()
      val depths = ArrayList<Double>()
      for (mesh in meshes) {
        if (mesh.layer != SceneLayer.PHOTO) continue
        val used = BooleanArray(mesh.vertexCount)
        for (index in mesh.indices) used[index] = true
        for (k in used.indices) {
          if (!used[k]) continue
          val p = mesh.positions
          if (seen.add(Triple(p[3 * k], p[3 * k + 1], p[3 * k + 2]))) depths += -p[3 * k + 2].toDouble()
        }
      }
      return depths.toDoubleArray()
    }

    /** The photo plane of a scene: the median depth of its photo layer (step 10 of the golden); null without one */
    fun photoPlane(meshes: List<GlbMesh>): Double? = planeOf(photoDepths(meshes))

    /**
     * The positions of [mesh] flattened by [a] towards [photoPlane] (its background [FLAT_BACKGROUND] further), written
     * in [out] (3 floats per vertex at least), which is returned. At 0 the positions are those of the file.
     */
    fun flatten(mesh: GlbMesh, a: Double, photoPlane: Double, out: FloatArray): FloatArray {
      val plane = if (mesh.layer == SceneLayer.PHOTO) photoPlane else photoPlane + FLAT_BACKGROUND
      val p = mesh.positions
      for (k in 0 until mesh.vertexCount) {
        val depth = -p[3 * k + 2].toDouble()
        val ratio = if (a == 0.0 || depth <= 0.0) 1.0 else ((1 - a) * depth + a * plane) / depth
        out[3 * k] = (p[3 * k] * ratio).toFloat()
        out[3 * k + 1] = (p[3 * k + 1] * ratio).toFloat()
        out[3 * k + 2] = (p[3 * k + 2] * ratio).toFloat()
      }
      return out
    }
  }

  private var anchored = false

  // The camera of the photo in the world: where the head was and where it looked at the anchor
  private var originX = 0.0
  private var originY = 0.0
  private var originZ = 0.0
  private var originYaw = 0.0

  // The glide in the frame of the scene (horizontal), and its speed
  private var glideX = 0.0
  private var glideZ = 0.0
  private var speedX = 0.0
  private var speedZ = 0.0

  // The flattening the meshes hold now, and whether the text of the edge may show again
  private var applied = 0.0
  private var edgeArmed = true

  /** Lays the camera of the photo at the head ([x], [y], [z] in the world, looking at [yaw]): the opening, and Reset */
  fun anchor(x: Double, y: Double, z: Double, yaw: Double) {
    originX = x
    originY = y
    originZ = z
    originYaw = yaw
    glideX = 0.0
    glideZ = 0.0
    speedX = 0.0
    speedZ = 0.0
    edgeArmed = true
    anchored = true
  }

  /**
   * [anchor] for a head at [x], [y], [z] in the world of the Spatial SDK whose horizontal gaze is [gazeX], [gazeZ]
   * there (the forward of its pose, y left aside)
   */
  fun anchorInSdk(x: Double, y: Double, z: Double, gazeX: Double, gazeZ: Double) =
    anchor(x, y, -z, SdkFrame.yawOfGaze(gazeX, gazeZ))

  /**
   * [update] for a head at [x], [y], [z] in the world of the Spatial SDK whose horizontal gaze is [gazeX], [gazeZ]
   * there; the root of the scene goes to SceneNavigation.sdkRootX, sdkRootY, sdkRootZ, turned by
   * Quaternion(0f, sdkRootYawDegrees, 0f)
   */
  fun updateInSdk(
    x: Double,
    y: Double,
    z: Double,
    gazeX: Double,
    gazeZ: Double,
    stickRight: Double,
    stickForward: Double,
    seconds: Double,
  ): SceneNavigation = update(x, y, -z, SdkFrame.yawOfGaze(gazeX, gazeZ), stickRight, stickForward, seconds)

  /**
   * One frame of [seconds]: the head at [x], [y], [z] in the world looking at [yaw], the left thumbstick held at
   * [stickRight] and [stickForward] (each from -1 to 1, a diagonal no faster than a straight push). The first frame
   * anchors a navigator that was never anchored.
   */
  fun update(
    x: Double,
    y: Double,
    z: Double,
    yaw: Double,
    stickRight: Double,
    stickForward: Double,
    seconds: Double,
  ): SceneNavigation {
    if (!anchored) anchor(x, y, z, yaw)
    val dt = seconds.coerceIn(0.0, MAX_FRAME_SECONDS)
    // The head in the frame of the scene
    val dx = x - originX
    val dz = z - originZ
    val c = cos(originYaw)
    val s = sin(originYaw)
    val headX = dx * c - dz * s
    val headY = y - originY
    val headZ = dx * s + dz * c
    glide(headX, headY, headZ, yaw - originYaw, stickRight, stickForward, dt)
    val eyeX = headX + glideX
    val eyeZ = headZ + glideZ
    val rho = rhoOf(eyeX, headY, eyeZ, safe)
    val flatten = flattenOf(rho)
    val rebuild =
      abs(flatten - applied) >= FLATTEN_STEP || ((flatten == 0.0 || flatten == 1.0) && flatten != applied)
    if (rebuild) applied = flatten
    var edgeNotice = false
    if (rho <= FLATTEN_FROM) {
      edgeArmed = true
    } else if (rho >= DARKEN_FROM && edgeArmed) {
      edgeArmed = false
      edgeNotice = true
    }
    // The root of the scene moves against the glide: origin - R(yaw) glide
    return SceneNavigation(
      rootX = originX - (glideX * c + glideZ * s),
      rootY = originY,
      rootZ = originZ - (-glideX * s + glideZ * c),
      rootYaw = originYaw,
      eyeX = eyeX,
      eyeY = headY,
      eyeZ = eyeZ,
      rho = rho,
      flatten = flatten,
      darken = darkenOf(rho),
      rebuild = rebuild,
      edgeNotice = edgeNotice,
    )
  }

  /**
   * Moves the glide for one frame of [dt] seconds: the speed eases towards the push of the stick, turned by [gaze] (the
   * yaw of the head in the scene); a step that would take the eye out of the zone stops at its edge, one that brings
   * an eye beyond the zone closer is taken whole
   */
  private fun glide(
    headX: Double,
    headY: Double,
    headZ: Double,
    gaze: Double,
    right: Double,
    forward: Double,
    dt: Double,
  ) {
    var pushRight = right.coerceIn(-1.0, 1.0)
    var pushForward = forward.coerceIn(-1.0, 1.0)
    val push = hypot(pushRight, pushForward)
    if (push > 1.0) {
      pushRight /= push
      pushForward /= push
    }
    // Right of the gaze: (cos g, -sin g); ahead of it: (-sin g, -cos g)
    val c = cos(gaze)
    val s = sin(gaze)
    val targetX = GLIDE_SPEED * (pushRight * c - pushForward * s)
    val targetZ = GLIDE_SPEED * (-pushRight * s - pushForward * c)
    val change = hypot(targetX - speedX, targetZ - speedZ)
    val most = GLIDE_SPEED / GLIDE_EASE * dt
    if (change <= most) {
      speedX = targetX
      speedZ = targetZ
    } else {
      speedX += (targetX - speedX) * most / change
      speedZ += (targetZ - speedZ) * most / change
    }
    val stepX = speedX * dt
    val stepZ = speedZ * dt
    if (stepX == 0.0 && stepZ == 0.0) return
    val now = rhoOf(headX + glideX, headY, headZ + glideZ, safe)
    val next = rhoOf(headX + glideX + stepX, headY, headZ + glideZ + stepZ, safe)
    if (next <= 1.0 || next < now) {
      glideX += stepX
      glideZ += stepZ
      return
    }
    // Out of the zone: as far as its edge when the eye is inside, not at all when it is already beyond
    var low = 0.0
    if (now <= 1.0) {
      var high = 1.0
      repeat(40) {
        val middle = (low + high) / 2
        if (rhoOf(headX + glideX + middle * stepX, headY, headZ + glideZ + middle * stepZ, safe) <= 1.0) low = middle
        else high = middle
      }
    }
    glideX += low * stepX
    glideZ += low * stepZ
    speedX = 0.0
    speedZ = 0.0
  }
}

/**
 * The passage between the left handed world of the Spatial SDK and the right handed frames of [SceneNavigator] and of
 * the glb (design-final 2026-10-27, sections 3.1.4 and 3.4). The glb is right handed, x right, y up, its camera looking
 * towards -z; the Spatial SDK is left handed, x right, y up, z forward (StereoComposer.quadRotation, ReliefMesh, the
 * gaze Vector3(0f, 0f, 1f) of the viewer), and only its own glTF loader converts a glTF, which section 3.1.2 leaves
 * aside. No rotation turns one into the other: the same place has its z turned the other way.
 *
 * 1. The head: (x, y, z) of the SDK is (x, y, -z) for the navigator, and its yaw is [yawOfGaze] of its horizontal
 *    gaze, 0 when it looks along +z of the SDK ([SceneNavigator.anchorInSdk] and [SceneNavigator.updateInSdk]).
 * 2. The root of the scene: at (rootX, rootY, -rootZ) of the SDK, turned by Quaternion(0f, [yawDegrees] of rootYaw,
 *    0f), a positive yaw taking +z towards +x (ImmersiveInputSystem.snapTurnDegrees): the yaw of the navigator, the
 *    other way round ([SceneNavigation.sdkRootX] and the like).
 * 3. The meshes: each position written with its z turned ([positions]), after SceneNavigator.flatten; each triangle
 *    with its last two corners swapped ([indices]). The triangles face the camera in the glb (counter clockwise seen
 *    from it, glTF's front); written so they turn counter clockwise about their normal towards the camera in the
 *    numbers of the SDK, as the two triangles of SceneMesh.singleSidedQuad turn about its normal +z (javap of 0.14.0),
 *    so that a single sided material shows them. The texture coordinates stay as they are: 0, 0 is the top left of
 *    the texture in both (the uv of singleSidedQuad say so).
 *
 * Tested by SceneNavigatorTest: the right edge of the photo at the right of the user, the stick pushed to the right
 * gliding to the right, the corners facing the camera. That the native renderer culls the faces singleSidedQuad
 * turns away is read from that quad, not seen yet: the first scene in the headset (lot S3, second session of MQ)
 * shows it, a double sided material, as the phase 1 quad has, showing the scene whatever the winding.
 */
internal object SdkFrame {
  /** The yaw for [SceneNavigator] of a head whose horizontal gaze in the world of the SDK is [gazeX], [gazeZ] */
  fun yawOfGaze(gazeX: Double, gazeZ: Double): Double = SceneNavigator.yawOf(gazeX, -gazeZ)

  /** The yaw in degrees of Quaternion(0f, yaw, 0f) of the SDK that turns as [yaw] of [SceneNavigator] does */
  fun yawDegrees(yaw: Double): Double = Math.toDegrees(-yaw)

  /** The positions of the glb in [positions] (3 floats a vertex) written for the SDK in [out], which may be the same */
  fun positions(positions: FloatArray, out: FloatArray): FloatArray {
    for (k in 0 until positions.size / 3) {
      out[3 * k] = positions[3 * k]
      out[3 * k + 1] = positions[3 * k + 1]
      out[3 * k + 2] = -positions[3 * k + 2]
    }
    return out
  }

  /** The triangles of the glb in [indices] (3 per triangle) written for the SDK: a, b, c becomes a, c, b */
  fun indices(indices: IntArray): IntArray =
    IntArray(indices.size) { i ->
      when (i % 3) {
        1 -> indices[i + 1]
        2 -> indices[i - 1]
        else -> indices[i]
      }
    }
}

/**
 * One frame of a scene: the pose of its root in the world, the eye in the frame of the scene, its normalised distance
 * [rho], the [flatten] and [darken] it brings; [rebuild] when the meshes must be made again at [flatten] (flatten),
 * [edgeNotice] when the text of the edge must show. The frames are those of [SceneNavigator]; [sdkRootX], [sdkRootY],
 * [sdkRootZ] and [sdkRootYawDegrees] give the pose of the root in the world of the Spatial SDK ([SdkFrame]).
 */
internal data class SceneNavigation(
  val rootX: Double,
  val rootY: Double,
  val rootZ: Double,
  val rootYaw: Double,
  val eyeX: Double,
  val eyeY: Double,
  val eyeZ: Double,
  val rho: Double,
  val flatten: Double,
  val darken: Double,
  val rebuild: Boolean,
  val edgeNotice: Boolean,
) {
  val sdkRootX: Double
    get() = rootX

  val sdkRootY: Double
    get() = rootY

  val sdkRootZ: Double
    get() = -rootZ

  /** The yaw of Quaternion(0f, sdkRootYawDegrees, 0f), in degrees */
  val sdkRootYawDegrees: Double
    get() = SdkFrame.yawDegrees(rootYaw)
}
