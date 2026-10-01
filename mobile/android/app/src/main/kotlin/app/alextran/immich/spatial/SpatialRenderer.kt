package app.alextran.immich.spatial

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.opengl.GLSurfaceView
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tan

/** Where the two eyes sit in the video frame. The swapped variants hold the right eye first. */
enum class EyeLayout { SIDE_BY_SIDE, TOP_BOTTOM, SIDE_BY_SIDE_SWAPPED, TOP_BOTTOM_SWAPPED, NONE }

/** How each eye image maps to the screen: a flat picture, or a 360 (or 180) equirectangular image */
enum class Projection { FLAT, EQUIRECTANGULAR }

/** Cost of the disparity estimation: its resolution, how often it runs, and the left to right check */
enum class Quality { LOW, MEDIUM, HIGH }

/** What the renderer achieved over the last second, for the debug overlay */
data class SpatialStats(
  val renderFps: Float,
  val disparityFps: Float,
  val renderMs: Float,
  val disparityWidth: Int,
  val disparityHeight: Int,
  val quality: Quality,
  val viewpoint: Float,
)

/**
 * GPU renderer of the Spatial 2.5D player. The video decoder draws into a SurfaceTexture; every frame the renderer
 * 1. extracts both eyes (or, for a 360 video, renders the viewport of each eye) into two textures,
 * 2. downsamples them to grayscale at the disparity resolution,
 * 3. matches them horizontally to get a disparity map, checks it from both sides and blends it over time,
 * 4. blurs the map,
 * 5. synthesises the view at [viewpoint] between the two cameras and draws it letterboxed on the screen.
 * Steps 2 to 4 only run every few video frames, depending on [quality].
 *
 * [onVideoSurface] receives, on the main thread, the surface the player must render into. It is called again with
 * a new surface when the GL context is recreated. Anything that goes wrong in the spatial passes falls back to the
 * left eye, so the video stays visible. When no program can read the video at all, the renderer gives no surface
 * and calls [onUnavailable] instead.
 */
class SpatialRenderer(private val onVideoSurface: (Surface) -> Unit) : GLSurfaceView.Renderer {
  private companion object {
    const val TAG = SpatialGl.TAG

    /** Largest disparity the maps can store, as a fraction of the eye width, in each direction */
    const val DISPARITY_RANGE = 0.1f

    /** Search range of the block matching, as a fraction of the disparity width: 24 pixels at 480 */
    const val SEARCH_FRACTION = 0.05f

    /** Weight of a new disparity in the temporal blend (the previous map keeps 0.6) */
    const val NEW_DISPARITY_WEIGHT = 0.4f

    /** Disagreement, in disparity pixels, over which the left to right check rejects a match */
    const val CONSISTENCY_TOLERANCE = 1.0f

    /** Eye textures larger than this many pixels are scaled down; the synthesis upscales them on the screen */
    const val MAX_EYE_PIXELS = 1920 * 1080

    /** After the eyes stop changing (paused video), the disparity runs a few more times to settle */
    const val SETTLE_DELAY_NS = 100_000_000L
    const val SETTLE_RUNS = 4

    /** Adaptive quality: step down over this average render time, step up after five seconds under the other */
    const val SLOW_MS = 12f
    const val FAST_MS = 6f
    const val FAST_SECONDS_TO_STEP_UP = 5

    /** After leaving a tier for being slow, the adaptive rule does not step back up to it for a minute */
    const val STEP_UP_BLOCK_NS = 60_000_000_000L

    /** 360: a view change over these, since the last disparity estimation, restarts the temporal blend */
    const val MAP_RESET_DEGREES = 0.5f
    const val MAP_RESET_FOV_DEGREES = 0.5f

    /** Without GPU timers, one frame in this many is timed on the CPU around glFinish */
    const val CPU_TIMING_PERIOD = 15L

    /** GL_EXT_disjoint_timer_query */
    const val GL_TIME_ELAPSED_EXT = 0x88BF
    const val GL_GPU_DISJOINT_EXT = 0x8FBB

    const val NANOS_PER_SECOND = 1_000_000_000L

    /** Eye rectangles inside the frame (x, y, width, height), texture coordinates with y up: top is y 0.5 to 1 */
    val LEFT_HALF = floatArrayOf(0f, 0f, 0.5f, 1f)
    val RIGHT_HALF = floatArrayOf(0.5f, 0f, 0.5f, 1f)
    val TOP_HALF = floatArrayOf(0f, 0.5f, 1f, 0.5f)
    val BOTTOM_HALF = floatArrayOf(0f, 0f, 1f, 0.5f)
    val WHOLE_FRAME = floatArrayOf(0f, 0f, 1f, 1f)
  }

  /** Disparity resolution (for a 16:9 eye), how many changed frames between two estimations, and the check */
  private class Tier(val width: Int, val height: Int, val interval: Int, val consistencyCheck: Boolean)

  private fun tierOf(quality: Quality): Tier = when (quality) {
    Quality.LOW -> Tier(320, 180, 4, false)
    Quality.MEDIUM -> Tier(480, 270, 2, true)
    Quality.HIGH -> Tier(640, 360, 1, true)
  }

  @Volatile var layout: EyeLayout = EyeLayout.SIDE_BY_SIDE
  @Volatile var projection: Projection = Projection.FLAT

  /**
   * 360 only: each eye image covers the front half of the sphere (VR180), longitude -90 to +90 degrees, instead of
   * the whole sphere. Directions outside the image are black.
   */
  @Volatile var halfSphere: Boolean = false

  /** 0 = left camera, 0.5 = between the cameras, 1 = right camera */
  @Volatile var viewpoint: Float = 0.5f

  /** 360 only: positive turns to the right */
  @Volatile var yawDegrees: Float = 0f

  /** 360 only: positive looks up */
  @Volatile var pitchDegrees: Float = 0f

  /** 360 only: horizontal field of view of the screen */
  @Volatile var fieldOfViewDegrees: Float = 80f

  /** Current tier; the adaptive rule changes it when [adaptiveQuality] is true */
  @Volatile var quality: Quality = Quality.MEDIUM
  @Volatile var adaptiveQuality: Boolean = true

  /** Debug: draws the disparity map instead of the synthesis */
  @Volatile var showDisparity: Boolean = false

  /**
   * Optional, called from any thread when the decoder delivers a frame, typically GLSurfaceView::requestRender.
   * Not needed with RENDERMODE_CONTINUOUSLY, which suits the player since the viewpoint follows the head.
   */
  @Volatile var onFrameAvailable: (() -> Unit)? = null

  /**
   * Optional, called on the main thread when no program of this device can read the video. The renderer then gives
   * no video surface, so the caller should hand the video back to another player.
   */
  @Volatile var onUnavailable: (() -> Unit)? = null

  private val lock = Any()
  private val mainHandler = Handler(Looper.getMainLooper())
  private val frameAvailable = AtomicBoolean(false)
  @Volatile private var released = false

  @Volatile private var videoWidth = 0
  @Volatile private var videoHeight = 0

  // Video input
  private var videoTexture = 0
  private var surfaceTexture: SurfaceTexture? = null
  private var surface: Surface? = null
  private val texMatrix = FloatArray(16)
  private var hasVideoFrame = false

  // Programs; the spatial ones are null when they failed to build, and the renderer then shows the left eye
  private var vertexArray = 0
  /** Triangle corners at attribute 0, only for the GLSL ES 1.00 eye programs */
  private var cornerBuffer = 0
  private var eyeFlatProgram: GlProgram? = null
  private var eyeEquirectProgram: GlProgram? = null
  private var copyProgram: GlProgram? = null
  private var grayProgram: GlProgram? = null
  private var disparityProgram: GlProgram? = null
  private var blendProgram: GlProgram? = null
  private var blurProgram: GlProgram? = null
  private var synthesisProgram: GlProgram? = null
  private var showDisparityProgram: GlProgram? = null
  private var spatialReady = false
  private var mapFormat = TargetFormat.RGBA8

  // Screen geometry: the view, and the rectangle the eyes are drawn into
  private var viewWidth = 0
  private var viewHeight = 0
  private var outX = 0
  private var outY = 0
  private var outWidth = 0
  private var outHeight = 0

  // Eye textures, at the output size (capped)
  private var leftEye: GlTarget? = null
  private var rightEye: GlTarget? = null
  private var eyeTargetsFailed = false
  private var eyesValid = false
  private var lastLayout: EyeLayout? = null
  private var lastProjection: Projection? = null
  private var lastHalfSphere: Boolean? = null
  private var lastYaw = Float.NaN
  private var lastPitch = Float.NaN
  private var lastFov = Float.NaN

  // Disparity targets, at the disparity resolution of the active tier
  @Volatile private var activeQuality: Quality? = null
  @Volatile private var disparityWidth = 0
  @Volatile private var disparityHeight = 0
  private var disparityFailed = false
  private var grayLeft: GlTarget? = null
  private var grayRight: GlTarget? = null
  private var rawLeft: GlTarget? = null
  private var rawRight: GlTarget? = null
  private val maps = arrayOfNulls<GlTarget>(2)
  private var currentMap = 0
  private var blurTemp: GlTarget? = null
  private var blurred: GlTarget? = null
  private var mapEmpty = true
  private var mapReset = true
  // View the current disparity map was computed for (360 only)
  private var mapYaw = Float.NaN
  private var mapPitch = Float.NaN
  private var mapFov = Float.NaN
  private var changesSinceDisparity = 0
  private var lastEyeChangeNs = 0L
  private var settleRuns = 0

  // Timing
  private var timerSupported = false
  private var timerChecked = false
  private val queries = IntArray(4)
  private val queryPending = BooleanArray(4)
  private var nextQuery = 0
  private var activeQuery = -1
  private val queryResult = IntArray(1)
  private var cpuTimingStart = 0L
  private var frameCount = 0L
  private var windowStart = 0L
  private var framesInWindow = 0
  private var disparityRunsInWindow = 0
  private var spatialFramesInWindow = 0
  private var timingSum = 0f
  private var timingCount = 0
  private var fastSeconds = 0
  /** Seconds the adaptive rule ignores after a tier change or new targets: the first draws compile the pipelines */
  private var warmupWindows = 1
  /** Per tier, the time (System.nanoTime) before which the adaptive rule must not step up to it */
  private val stepUpBlockedUntil = LongArray(Quality.entries.size) { Long.MIN_VALUE }

  // Statistics of the last second, read from any thread
  @Volatile private var statRenderFps = 0f
  @Volatile private var statDisparityFps = 0f
  @Volatile private var statRenderMs = 0f

  /** The decoded frame size, from the player's VideoSize (width already multiplied by the pixel aspect ratio) */
  fun setVideoSize(width: Int, height: Int) {
    videoWidth = width
    videoHeight = height
  }

  fun stats(): SpatialStats = SpatialStats(
    renderFps = statRenderFps,
    disparityFps = statDisparityFps,
    renderMs = statRenderMs,
    disparityWidth = disparityWidth,
    disparityHeight = disparityHeight,
    quality = activeQuality ?: quality,
    viewpoint = viewpoint,
  )

  /**
   * Frees the GL objects (only when called on the GL thread, otherwise they go with the context), the
   * SurfaceTexture and the video surface. Detach the surface from the player first. The renderer draws nothing
   * afterwards.
   */
  fun release() {
    synchronized(lock) {
      if (released) return
      released = true
      if (EGL14.eglGetCurrentContext() != EGL14.EGL_NO_CONTEXT) releaseGlObjects()
      forgetGlObjects()
      surfaceTexture?.setOnFrameAvailableListener(null)
      surfaceTexture?.release()
      surfaceTexture = null
      surface?.release()
      surface = null
    }
  }

  override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
    synchronized(lock) {
      if (released) return
      // A new context: the objects of a previous one, if any, are gone with it
      forgetGlObjects()
      SpatialGl.clearErrors()
      GLES30.glDisable(GLES30.GL_DEPTH_TEST)
      GLES30.glDisable(GLES30.GL_BLEND)
      GLES30.glDisable(GLES30.GL_CULL_FACE)
      GLES30.glDisable(GLES30.GL_DITHER)

      val ids = IntArray(1)
      GLES30.glGenVertexArrays(1, ids, 0)
      vertexArray = ids[0]
      createPrograms()
      val eyeProgram = if (projection == Projection.EQUIRECTANGULAR) eyeEquirectProgram else eyeFlatProgram
      if (eyeProgram == null) {
        // Nothing can read the video texture, not even to copy the raw frame: rather than a black screen while the
        // audio plays, give no surface, so that the caller (or its surface timeout) hands the video back
        Log.e(TAG, "No eye program can read the video on this device, the spatial player cannot show it")
        mainHandler.post { if (!released) onUnavailable?.invoke() }
        return
      }
      mapFormat = pickMapFormat()
      timerSupported = SpatialGl.hasExtension("GL_EXT_disjoint_timer_query")
      timerChecked = false
      if (timerSupported) GLES30.glGenQueries(queries.size, queries, 0)

      videoTexture = SpatialGl.createExternalTexture()
      if (videoTexture == 0) {
        Log.e(TAG, "Cannot create the video texture")
        return
      }
      val oldTexture = surfaceTexture
      val oldSurface = surface
      val newTexture = SurfaceTexture(videoTexture)
      newTexture.setOnFrameAvailableListener {
        frameAvailable.set(true)
        onFrameAvailable?.invoke()
      }
      val newSurface = Surface(newTexture)
      surfaceTexture = newTexture
      surface = newSurface
      frameAvailable.set(false)
      mainHandler.post {
        if (!released && surface === newSurface) onVideoSurface(newSurface)
        // The player now renders into the new surface, the old one can go
        oldSurface?.release()
        oldTexture?.release()
      }
    }
  }

  override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
    synchronized(lock) {
      viewWidth = width
      viewHeight = height
    }
  }

  override fun onDrawFrame(gl: GL10?) {
    synchronized(lock) {
      if (released) return
      val texture = surfaceTexture ?: return
      try {
        drawFrame(texture)
      } catch (e: RuntimeException) {
        // updateTexImage throws when the surface is abandoned; keep the app alive and try again next frame
        Log.e(TAG, "Spatial frame failed", e)
      }
    }
  }

  private fun drawFrame(texture: SurfaceTexture) {
    val now = System.nanoTime()
    frameCount++
    framesInWindow++
    val cpuTiming = !timerSupported && frameCount % CPU_TIMING_PERIOD == 0L
    if (cpuTiming) {
      GLES30.glFinish()
      cpuTimingStart = System.nanoTime()
    }
    beginGpuTimer()
    try {
      renderPasses(texture, now)
    } finally {
      endGpuTimer()
      if (cpuTiming) {
        GLES30.glFinish()
        addTimingSample((System.nanoTime() - cpuTimingStart) / 1_000_000f)
      }
      updateStatistics(now)
    }
  }

  private fun renderPasses(texture: SurfaceTexture, now: Long) {
    var newFrame = false
    if (frameAvailable.getAndSet(false)) {
      texture.updateTexImage()
      texture.getTransformMatrix(texMatrix)
      hasVideoFrame = true
      newFrame = true
    }
    if (!hasVideoFrame || viewWidth <= 0 || viewHeight <= 0) {
      beginScreen()
      return
    }

    val layout = this.layout
    val projection = this.projection
    val halfSphere = this.halfSphere
    val quality = this.quality
    val yaw = yawDegrees
    val pitch = pitchDegrees
    val fov = fieldOfViewDegrees.coerceIn(20f, 140f)
    val eyesRecreated = updateGeometry(layout, projection)
    val left = leftEye
    val right = rightEye
    if (left == null || right == null) {
      drawEyeDirect(layout, projection, halfSphere, yaw, pitch, fov)
      return
    }

    // Pass 1: the eyes only change with a new frame, a new layout or coverage, or a new view direction for a 360 video
    val sourceChanged = layout != lastLayout || projection != lastProjection || halfSphere != lastHalfSphere
    val viewMoved = projection == Projection.EQUIRECTANGULAR &&
      (yaw != lastYaw || pitch != lastPitch || fov != lastFov)
    val eyesChanged = newFrame || sourceChanged || viewMoved || eyesRecreated || !eyesValid
    val stereo = layout != EyeLayout.NONE && spatialReady && !disparityFailed
    if (eyesChanged) {
      if (!renderEyes(left, right, layout, projection, halfSphere, yaw, pitch, fov, stereo)) {
        drawEyeDirect(layout, projection, halfSphere, yaw, pitch, fov)
        return
      }
      eyesValid = true
      lastLayout = layout
      lastProjection = projection
      lastHalfSphere = halfSphere
      lastYaw = yaw
      lastPitch = pitch
      lastFov = fov
    }
    if (sourceChanged || eyesRecreated) mapReset = true

    // A video that is not stereoscopic gives a flat result: show the eye as is
    if (!stereo || !ensureDisparityTargets(quality)) {
      drawCopy(left)
      return
    }
    spatialFramesInWindow++

    // Passes 2 to 4, every few changed frames, then a few more times once the eyes stop changing
    if (eyesChanged) {
      changesSinceDisparity++
      lastEyeChangeNs = now
      settleRuns = 0
    }
    val tier = tierOf(quality)
    val settle = now - lastEyeChangeNs > SETTLE_DELAY_NS && settleRuns < SETTLE_RUNS
    if (mapReset || mapEmpty || changesSinceDisparity >= tier.interval || settle) {
      if (settle) settleRuns++
      computeDisparity(left, right, tier, viewChangedSinceMap(projection))
      changesSinceDisparity = 0
    }

    // Pass 5
    val map = blurred
    if (map == null || mapEmpty) {
      drawCopy(left)
      return
    }
    if (showDisparity) drawDisparity(map) else drawSynthesis(left, right, map, tier)
  }

  /** Binds the screen, clears it to black and returns with the viewport on the output rectangle */
  private fun beginScreen() {
    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
    GLES30.glViewport(0, 0, viewWidth, viewHeight)
    GLES30.glClearColor(0f, 0f, 0f, 1f)
    GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
    GLES30.glViewport(outX, outY, outWidth, outHeight)
  }

  private fun drawTriangle() {
    GLES30.glBindVertexArray(vertexArray)
    GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)
  }

  private fun bindTexture(unit: Int, texture: Int, target: Int = GLES30.GL_TEXTURE_2D) {
    GLES30.glActiveTexture(GLES30.GL_TEXTURE0 + unit)
    GLES30.glBindTexture(target, texture)
  }

  // Geometry

  /**
   * Displayed aspect ratio of one eye. A frame shaped like an ordinary picture (about 4:3 to 2:1) holding two
   * eyes stores them squeezed (half side by side, half top and bottom): each eye shows at the frame's aspect.
   */
  private fun eyeDisplayAspect(layout: EyeLayout): Float {
    val width = videoWidth
    val height = videoHeight
    if (width <= 0 || height <= 0) return 16f / 9f
    val frameAspect = width.toFloat() / height
    val squeezed = frameAspect in 1.3f..1.95f
    return when (layout) {
      EyeLayout.SIDE_BY_SIDE, EyeLayout.SIDE_BY_SIDE_SWAPPED -> if (squeezed) frameAspect else frameAspect / 2f
      EyeLayout.TOP_BOTTOM, EyeLayout.TOP_BOTTOM_SWAPPED -> if (squeezed) frameAspect else frameAspect * 2f
      EyeLayout.NONE -> frameAspect
    }
  }

  /**
   * Longitude covered by each eye of an equirectangular video: half the circle for a half sphere (VR180), the whole
   * circle otherwise. Only the explicit [halfSphere] flag decides, never the shape of the eyes: side by side 360
   * files squeezed into a 2:1 frame (3840x1920 and the like) have square eyes like VR180 files.
   */
  private fun longitudeSpan(halfSphere: Boolean): Float =
    if (halfSphere) Math.PI.toFloat() else (2.0 * Math.PI).toFloat()

  private fun eyeRects(layout: EyeLayout): Pair<FloatArray, FloatArray> = when (layout) {
    EyeLayout.SIDE_BY_SIDE -> LEFT_HALF to RIGHT_HALF
    EyeLayout.SIDE_BY_SIDE_SWAPPED -> RIGHT_HALF to LEFT_HALF
    EyeLayout.TOP_BOTTOM -> TOP_HALF to BOTTOM_HALF
    EyeLayout.TOP_BOTTOM_SWAPPED -> BOTTOM_HALF to TOP_HALF
    EyeLayout.NONE -> WHOLE_FRAME to WHOLE_FRAME
  }

  /**
   * Computes the output rectangle (letterboxed for a flat video, the whole view for a 360 video) and makes sure
   * the eye textures match it. Returns true when the eye textures were recreated.
   */
  private fun updateGeometry(layout: EyeLayout, projection: Projection): Boolean {
    if (projection == Projection.EQUIRECTANGULAR) {
      outX = 0
      outY = 0
      outWidth = viewWidth
      outHeight = viewHeight
    } else {
      val aspect = eyeDisplayAspect(layout)
      if (viewWidth.toFloat() / viewHeight > aspect) {
        outHeight = viewHeight
        outWidth = (viewHeight * aspect).roundToInt().coerceIn(1, viewWidth)
      } else {
        outWidth = viewWidth
        outHeight = (viewWidth / aspect).roundToInt().coerceIn(1, viewHeight)
      }
      outX = (viewWidth - outWidth) / 2
      outY = (viewHeight - outHeight) / 2
    }

    val scale = sqrt(MAX_EYE_PIXELS.toFloat() / (outWidth.toFloat() * outHeight)).coerceAtMost(1f)
    val eyeWidth = max(1, (outWidth * scale).roundToInt())
    val eyeHeight = max(1, (outHeight * scale).roundToInt())
    val current = leftEye
    if (current != null && current.width == eyeWidth && current.height == eyeHeight) return false
    if (current == null && eyeTargetsFailed) return false

    releaseEyeTargets()
    val left = SpatialGl.createTarget(eyeWidth, eyeHeight, TargetFormat.RGBA8, GLES30.GL_LINEAR)
    val right = SpatialGl.createTarget(eyeWidth, eyeHeight, TargetFormat.RGBA8, GLES30.GL_LINEAR)
    if (left == null || right == null) {
      Log.e(TAG, "Cannot create the $eyeWidth x $eyeHeight eye textures, showing the video directly")
      left?.release()
      right?.release()
      eyeTargetsFailed = true
      return false
    }
    leftEye = left
    rightEye = right
    eyesValid = false
    return true
  }

  // Pass 1

  /** Camera axes for the 360 view, as the columns right, up and forward of a 3x3 matrix */
  private fun rotationColumns(yawDegrees: Float, pitchDegrees: Float): FloatArray {
    val yaw = Math.toRadians(yawDegrees.toDouble())
    val pitch = Math.toRadians(pitchDegrees.toDouble().coerceIn(-89.0, 89.0))
    val fx = sin(yaw) * cos(pitch)
    val fy = sin(pitch)
    val fz = -cos(yaw) * cos(pitch)
    val rx = cos(yaw)
    val rz = sin(yaw)
    // up = right x forward, with right.y = 0
    val ux = -rz * fy
    val uy = rz * fx - rx * fz
    val uz = rx * fy
    return floatArrayOf(
      rx.toFloat(), 0f, rz.toFloat(),
      ux.toFloat(), uy.toFloat(), uz.toFloat(),
      fx.toFloat(), fy.toFloat(), fz.toFloat(),
    )
  }

  /** Selects and sets up the program that reads the video for [projection], or null when it failed to build */
  private fun useEyeProgram(
    projection: Projection,
    halfSphere: Boolean,
    yaw: Float,
    pitch: Float,
    fov: Float,
    aspect: Float,
  ): GlProgram? {
    val program = (if (projection == Projection.EQUIRECTANGULAR) eyeEquirectProgram else eyeFlatProgram)
      ?: return null
    program.use()
    bindTexture(0, videoTexture, GLES11Ext.GL_TEXTURE_EXTERNAL_OES)
    program.setInt("u_video", 0)
    program.setMat4("u_texMatrix", texMatrix)
    if (projection == Projection.EQUIRECTANGULAR) {
      val tanX = tan(Math.toRadians(fov / 2.0)).toFloat()
      program.setMat3("u_rotation", rotationColumns(yaw, pitch))
      program.setVec2("u_tanHalfFov", tanX, tanX / aspect)
      program.setFloat("u_longitudeSpan", longitudeSpan(halfSphere))
    }
    return program
  }

  private fun setRect(program: GlProgram, rect: FloatArray) {
    program.setVec4("u_rect", rect[0], rect[1], rect[2], rect[3])
    if (program === eyeFlatProgram) setSeamInset(program, rect)
  }

  /**
   * Flat eyes: moves the sides of [rect] that touch the other eye one video texel inwards, in eye units, so that
   * bilinear filtering never reads across the seam. A whole texel rather than a half one, like the crop of
   * SurfaceTexture, because the chroma of 4:2:0 video has half the resolution.
   */
  private fun setSeamInset(program: GlProgram, rect: FloatArray) {
    val width = videoWidth
    val height = videoHeight
    val texelX = if (width > 0) 1f / (width * rect[2]) else 0f
    val texelY = if (height > 0) 1f / (height * rect[3]) else 0f
    program.setVec4(
      "u_inset",
      if (rect[0] > 0f) texelX else 0f,
      if (rect[1] > 0f) texelY else 0f,
      if (rect[0] + rect[2] < 1f) texelX else 0f,
      if (rect[1] + rect[3] < 1f) texelY else 0f,
    )
  }

  /** Draws the left eye (or the right one too when [stereo]) into the eye textures */
  private fun renderEyes(
    left: GlTarget,
    right: GlTarget,
    layout: EyeLayout,
    projection: Projection,
    halfSphere: Boolean,
    yaw: Float,
    pitch: Float,
    fov: Float,
    stereo: Boolean,
  ): Boolean {
    val aspect = left.width.toFloat() / left.height
    val program = useEyeProgram(projection, halfSphere, yaw, pitch, fov, aspect) ?: return false
    val (leftRect, rightRect) = eyeRects(layout)
    left.bind()
    setRect(program, leftRect)
    drawTriangle()
    if (stereo) {
      right.bind()
      setRect(program, rightRect)
      drawTriangle()
    }
    return true
  }

  /** Safe fallback: the left eye straight from the video to the screen */
  private fun drawEyeDirect(
    layout: EyeLayout,
    projection: Projection,
    halfSphere: Boolean,
    yaw: Float,
    pitch: Float,
    fov: Float,
  ) {
    beginScreen()
    val aspect = outWidth.toFloat() / max(1, outHeight)
    val program = useEyeProgram(projection, halfSphere, yaw, pitch, fov, aspect) ?: return
    setRect(program, eyeRects(layout).first)
    drawTriangle()
  }

  private fun drawCopy(eye: GlTarget) {
    beginScreen()
    val program = copyProgram ?: return
    program.use()
    bindTexture(0, eye.texture)
    program.setInt("u_texture", 0)
    drawTriangle()
  }

  // Passes 2 to 4

  private fun searchRange(): Int = max(2, (disparityWidth * SEARCH_FRACTION).roundToInt())

  /** Converts a disparity in disparity pixels to its encoded offset from 0.5 */
  private fun encodeScale(): Float = 1f / (disparityWidth * 2f * DISPARITY_RANGE)

  /** Makes sure the disparity targets match [quality] and the eye aspect ratio; false when they cannot exist */
  private fun ensureDisparityTargets(quality: Quality): Boolean {
    val eye = leftEye ?: return false
    val tier = tierOf(quality)
    // Same pixel count as the tier, with the aspect ratio of the eye
    val aspect = eye.width.toFloat() / eye.height
    val height = sqrt(tier.width * tier.height / aspect).roundToInt().coerceAtLeast(16)
    val width = (height * aspect).roundToInt().coerceAtLeast(16)
    if (quality == activeQuality && width == disparityWidth && height == disparityHeight && blurred != null) {
      return true
    }

    releaseDisparityTargets()
    val gray = TargetFormat.RGBA8
    val nearest = GLES30.GL_NEAREST
    grayLeft = SpatialGl.createTarget(width, height, gray, nearest)
    grayRight = SpatialGl.createTarget(width, height, gray, nearest)
    rawLeft = SpatialGl.createTarget(width, height, mapFormat, nearest)
    rawRight = SpatialGl.createTarget(width, height, mapFormat, nearest)
    maps[0] = SpatialGl.createTarget(width, height, mapFormat, nearest)
    maps[1] = SpatialGl.createTarget(width, height, mapFormat, nearest)
    blurTemp = SpatialGl.createTarget(width, height, mapFormat, nearest)
    blurred = SpatialGl.createTarget(width, height, mapFormat, GLES30.GL_LINEAR)
    val all = listOf(grayLeft, grayRight, rawLeft, rawRight, maps[0], maps[1], blurTemp, blurred)
    if (all.any { it == null }) {
      releaseDisparityTargets()
      if (quality != Quality.LOW) {
        // Keep the spatial view: the next frame retries at the lowest tier, and this one is never tried again
        Log.w(TAG, "Cannot create the $width x $height disparity textures, quality down to ${Quality.LOW}")
        blockStepUp(quality, Long.MAX_VALUE)
        this.quality = Quality.LOW
        fastSeconds = 0
        warmupWindows = 1
        return false
      }
      Log.e(TAG, "Cannot create the $width x $height disparity textures, showing the left eye")
      disparityFailed = true
      return false
    }
    activeQuality = quality
    disparityWidth = width
    disparityHeight = height
    currentMap = 0
    mapEmpty = true
    mapReset = true
    // The second that allocates the targets and first runs the passes is not representative (a Galaxy S24 measured
    // 15 ms there and 6 to 12 ms afterwards at the same tier)
    warmupWindows = max(warmupWindows, 1)
    Log.i(TAG, "Spatial disparity at $width x $height, quality $quality, ${mapFormat.name} maps")
    return true
  }

  /**
   * 360 only: true when the eyes show another viewport than the one the current map was computed for. The maps
   * live in viewport space, so blending the old one in would trail the depth edges behind the image while the view
   * turns or zooms. Changes under a threshold (sensor noise) keep the temporal blend.
   */
  private fun viewChangedSinceMap(projection: Projection): Boolean {
    if (projection != Projection.EQUIRECTANGULAR || mapFov.isNaN()) return false
    var yawChange = abs(lastYaw - mapYaw) % 360f
    if (yawChange > 180f) yawChange = 360f - yawChange
    return yawChange > MAP_RESET_DEGREES || abs(lastPitch - mapPitch) > MAP_RESET_DEGREES ||
      abs(lastFov - mapFov) > MAP_RESET_FOV_DEGREES
  }

  /** [freshView] drops the temporal history: the new map gets the full weight */
  private fun computeDisparity(left: GlTarget, right: GlTarget, tier: Tier, freshView: Boolean) {
    val gray = grayProgram ?: return
    val disparity = disparityProgram ?: return
    val blend = blendProgram ?: return
    val blur = blurProgram ?: return
    val grayL = grayLeft ?: return
    val grayR = grayRight ?: return
    val rawL = rawLeft ?: return
    val rawR = rawRight ?: return
    val temp = blurTemp ?: return
    val output = blurred ?: return
    val previous = maps[currentMap] ?: return
    val next = maps[1 - currentMap] ?: return
    val encode = encodeScale()

    // Pass 2: packed grayscale of both eyes
    gray.use()
    gray.setInt("u_eye", 0)
    gray.setVec2("u_texel", 1f / disparityWidth, 1f / disparityHeight)
    grayL.bind()
    bindTexture(0, left.texture)
    drawTriangle()
    grayR.bind()
    bindTexture(0, right.texture)
    drawTriangle()

    // Pass 3: block matching from the left eye, and from the right eye for the consistency check
    disparity.use()
    disparity.setInt("u_reference", 0)
    disparity.setInt("u_other", 1)
    disparity.setInt("u_searchRange", searchRange())
    disparity.setFloat("u_encode", encode)
    rawL.bind()
    disparity.setInt("u_direction", 1)
    bindTexture(0, grayL.texture)
    bindTexture(1, grayR.texture)
    drawTriangle()
    if (tier.consistencyCheck) {
      rawR.bind()
      disparity.setInt("u_direction", -1)
      bindTexture(0, grayR.texture)
      bindTexture(1, grayL.texture)
      drawTriangle()
    }

    // Consistency check and temporal blend into the other map of the pair
    if (mapReset) {
      previous.bind()
      GLES30.glClearColor(0.5f, 0f, 0.5f, 0f)
      GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
    }
    blend.use()
    blend.setInt("u_rawLeft", 0)
    blend.setInt("u_rawRight", 1)
    blend.setInt("u_previous", 2)
    blend.setInt("u_check", if (tier.consistencyCheck) 1 else 0)
    blend.setFloat("u_newWeight", if (mapReset || freshView) 1f else NEW_DISPARITY_WEIGHT)
    blend.setFloat("u_encode", encode)
    blend.setFloat("u_tolerance", CONSISTENCY_TOLERANCE)
    next.bind()
    bindTexture(0, rawL.texture)
    bindTexture(1, rawR.texture)
    bindTexture(2, previous.texture)
    drawTriangle()
    currentMap = 1 - currentMap

    // Pass 4: separable blur, horizontal then vertical
    blur.use()
    blur.setInt("u_map", 0)
    temp.bind()
    blur.setIVec2("u_direction", 1, 0)
    bindTexture(0, next.texture)
    drawTriangle()
    output.bind()
    blur.setIVec2("u_direction", 0, 1)
    bindTexture(0, temp.texture)
    drawTriangle()

    // Leave the units clean for the next passes
    bindTexture(2, 0)
    bindTexture(1, 0)
    mapReset = false
    mapEmpty = false
    mapYaw = lastYaw
    mapPitch = lastPitch
    mapFov = lastFov
    disparityRunsInWindow++
  }

  // Pass 5

  private fun drawSynthesis(left: GlTarget, right: GlTarget, map: GlTarget, tier: Tier) {
    beginScreen()
    val program = synthesisProgram ?: return drawCopyAfterClear(left)
    program.use()
    program.setInt("u_left", 0)
    program.setInt("u_right", 1)
    program.setInt("u_map", 2)
    program.setFloat("u_viewpoint", viewpoint.coerceIn(0f, 1f))
    program.setFloat("u_decode", 2f * DISPARITY_RANGE)
    program.setFloat("u_threshold", 1f / disparityWidth)
    program.setFloat("u_searchStep", 2f / disparityWidth)
    program.setInt("u_hasRightMap", if (tier.consistencyCheck) 1 else 0)
    bindTexture(0, left.texture)
    bindTexture(1, right.texture)
    bindTexture(2, map.texture)
    drawTriangle()
  }

  private fun drawDisparity(map: GlTarget) {
    beginScreen()
    val program = showDisparityProgram ?: return
    program.use()
    program.setInt("u_map", 0)
    program.setFloat("u_gain", 0.5f / (max(1, searchRange()) * encodeScale()))
    bindTexture(0, map.texture)
    drawTriangle()
  }

  private fun drawCopyAfterClear(eye: GlTarget) {
    val program = copyProgram ?: return
    program.use()
    bindTexture(0, eye.texture)
    program.setInt("u_texture", 0)
    drawTriangle()
  }

  // Programs and formats

  private fun createPrograms() {
    val vertex = SpatialShaders.VERTEX
    eyeFlatProgram = linkEyeProgram(SpatialShaders::eyeFlat, "eye flat")
    eyeEquirectProgram = linkEyeProgram(SpatialShaders::eyeEquirect, "eye equirectangular")
    copyProgram = SpatialGl.linkProgram(vertex, SpatialShaders.COPY, "copy")
    grayProgram = SpatialGl.linkProgram(vertex, SpatialShaders.GRAY_PACK, "gray")
    disparityProgram = SpatialGl.linkProgram(vertex, SpatialShaders.DISPARITY, "disparity")
    blendProgram = SpatialGl.linkProgram(vertex, SpatialShaders.BLEND, "blend")
    blurProgram = SpatialGl.linkProgram(vertex, SpatialShaders.BLUR, "blur")
    synthesisProgram = SpatialGl.linkProgram(vertex, SpatialShaders.SYNTHESIS, "synthesis")
    showDisparityProgram = SpatialGl.linkProgram(vertex, SpatialShaders.SHOW_DISPARITY, "show disparity")
    spatialReady = copyProgram != null && grayProgram != null && disparityProgram != null &&
      blendProgram != null && blurProgram != null && synthesisProgram != null
    if (!spatialReady) Log.e(TAG, "Spatial programs unavailable, showing the left eye only")
  }

  /**
   * Links an eye program from [source] (true for GLSL ES 3.00), or from its GLSL ES 1.00 variant on the drivers that
   * only sample the video in GLSL ES 1.00 (GL_OES_EGL_image_external without its essl3 version). Null when neither
   * builds.
   */
  private fun linkEyeProgram(source: (Boolean) -> String, name: String): GlProgram? {
    SpatialGl.linkProgram(SpatialShaders.VERTEX, source(true), name)?.let { return it }
    val program = SpatialGl.linkProgram(
      SpatialShaders.VERTEX_ESSL1,
      source(false),
      "$name (GLSL ES 1.00)",
      SpatialShaders.VERTEX_ESSL1_ATTRIBUTES,
    ) ?: return null
    if (!createCornerBuffer()) {
      program.release()
      return null
    }
    Log.w(TAG, "Program $name built in GLSL ES 1.00")
    return program
  }

  /** Feeds the triangle corners to attribute 0 of the vertex array, for the GLSL ES 1.00 vertex shader */
  private fun createCornerBuffer(): Boolean {
    if (cornerBuffer != 0) return true
    val ids = IntArray(1)
    GLES30.glGenBuffers(1, ids, 0)
    if (ids[0] == 0) return false
    // Same corners as the GLSL ES 3.00 vertex shader: (0, 0), (2, 0) and (0, 2)
    val corners = floatArrayOf(0f, 0f, 2f, 0f, 0f, 2f)
    val data = ByteBuffer.allocateDirect(corners.size * Float.SIZE_BYTES).order(ByteOrder.nativeOrder()).asFloatBuffer()
    data.put(corners)
    data.position(0)
    GLES30.glBindVertexArray(vertexArray)
    GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, ids[0])
    GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, corners.size * Float.SIZE_BYTES, data, GLES30.GL_STATIC_DRAW)
    GLES30.glVertexAttribPointer(0, 2, GLES30.GL_FLOAT, false, 0, 0)
    GLES30.glEnableVertexAttribArray(0)
    GLES30.glBindVertexArray(0)
    GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, 0)
    if (SpatialGl.checkError("create the corner buffer")) {
      GLES30.glDeleteBuffers(1, ids, 0)
      return false
    }
    cornerBuffer = ids[0]
    return true
  }

  /** Half float maps when the driver can render into them, 8 bit maps otherwise */
  private fun pickMapFormat(): TargetFormat {
    val halfFloat = SpatialGl.hasExtension("GL_EXT_color_buffer_half_float") ||
      SpatialGl.hasExtension("GL_EXT_color_buffer_float")
    if (halfFloat) {
      val probe = SpatialGl.createTarget(4, 4, TargetFormat.RGBA16F, GLES30.GL_NEAREST)
      if (probe != null) {
        probe.release()
        return TargetFormat.RGBA16F
      }
    }
    SpatialGl.clearErrors()
    return TargetFormat.RGBA8
  }

  // Timing and adaptive quality

  private fun beginGpuTimer() {
    activeQuery = -1
    if (!timerSupported) return
    collectGpuTimers()
    val slot = nextQuery
    if (queryPending[slot]) return
    if (!timerChecked) SpatialGl.clearErrors()
    GLES30.glBeginQuery(GL_TIME_ELAPSED_EXT, queries[slot])
    if (!timerChecked) {
      timerChecked = true
      if (GLES30.glGetError() != GLES30.GL_NO_ERROR) {
        Log.w(TAG, "GPU timer queries refused, timing on the CPU")
        timerSupported = false
        return
      }
    }
    activeQuery = slot
  }

  private fun endGpuTimer() {
    val slot = activeQuery
    if (slot < 0) return
    GLES30.glEndQuery(GL_TIME_ELAPSED_EXT)
    queryPending[slot] = true
    nextQuery = (slot + 1) % queries.size
    activeQuery = -1
  }

  /** Reads the finished timer queries; a disjoint event (frequency change, context switch) voids them */
  private fun collectGpuTimers() {
    GLES30.glGetIntegerv(GL_GPU_DISJOINT_EXT, queryResult, 0)
    val disjoint = queryResult[0] != 0
    for (slot in queries.indices) {
      if (!queryPending[slot]) continue
      GLES30.glGetQueryObjectuiv(queries[slot], GLES30.GL_QUERY_RESULT_AVAILABLE, queryResult, 0)
      if (queryResult[0] == 0) continue
      GLES30.glGetQueryObjectuiv(queries[slot], GLES30.GL_QUERY_RESULT, queryResult, 0)
      queryPending[slot] = false
      if (!disjoint) addTimingSample((queryResult[0].toLong() and 0xffffffffL) / 1_000_000f)
    }
  }

  private fun addTimingSample(milliseconds: Float) {
    timingSum += milliseconds
    timingCount++
  }

  /** Once per second: publishes the statistics and applies the adaptive quality rule */
  private fun updateStatistics(now: Long) {
    if (windowStart == 0L) {
      windowStart = now
      return
    }
    val elapsed = now - windowStart
    if (elapsed < NANOS_PER_SECOND) return
    val seconds = elapsed.toFloat() / NANOS_PER_SECOND
    statRenderFps = framesInWindow / seconds
    statDisparityFps = disparityRunsInWindow / seconds
    val measured = timingCount > 0
    val averageMs = if (measured) timingSum / timingCount else statRenderMs
    statRenderMs = averageMs
    // Only judge seconds that ran the spatial passes, and only step up on seconds that estimated disparity
    if (adaptiveQuality && measured && spatialFramesInWindow > 0) adapt(averageMs, disparityRunsInWindow > 0, now)
    windowStart = now
    framesInWindow = 0
    disparityRunsInWindow = 0
    spatialFramesInWindow = 0
    timingSum = 0f
    timingCount = 0
  }

  /**
   * Steps down after a slow second, and up after [FAST_SECONDS_TO_STEP_UP] fast ones. A tier left for being slow
   * stays out of reach for [STEP_UP_BLOCK_NS], so that a device fast at one tier but slow at the next one does not
   * switch back and forth (each switch restarts the disparity maps).
   */
  private fun adapt(averageMs: Float, estimated: Boolean, now: Long) {
    if (warmupWindows > 0) {
      // The first second after a change mixes both tiers
      warmupWindows--
      return
    }
    val current = quality
    when {
      averageMs > SLOW_MS -> {
        fastSeconds = 0
        if (current != Quality.LOW) {
          blockStepUp(current, now + STEP_UP_BLOCK_NS)
          quality = lower(current)
          warmupWindows = 1
          Log.i(TAG, "Spatial render at $averageMs ms, quality down to $quality")
        }
      }
      averageMs < FAST_MS && estimated -> {
        fastSeconds++
        if (fastSeconds >= FAST_SECONDS_TO_STEP_UP && current != Quality.HIGH &&
          now >= stepUpBlockedUntil[higher(current).ordinal]
        ) {
          quality = higher(current)
          fastSeconds = 0
          warmupWindows = 1
          Log.i(TAG, "Spatial render at $averageMs ms, quality up to $quality")
        }
      }
      else -> fastSeconds = 0
    }
  }

  private fun lower(quality: Quality): Quality = if (quality == Quality.HIGH) Quality.MEDIUM else Quality.LOW

  private fun higher(quality: Quality): Quality = if (quality == Quality.LOW) Quality.MEDIUM else Quality.HIGH

  /** Keeps the adaptive rule from stepping up to [quality] before [until], without shortening an earlier block */
  private fun blockStepUp(quality: Quality, until: Long) {
    stepUpBlockedUntil[quality.ordinal] = max(stepUpBlockedUntil[quality.ordinal], until)
  }

  // Cleanup

  private fun releaseEyeTargets() {
    leftEye?.release()
    rightEye?.release()
    leftEye = null
    rightEye = null
    eyesValid = false
  }

  private fun releaseDisparityTargets() {
    for (target in listOf(grayLeft, grayRight, rawLeft, rawRight, maps[0], maps[1], blurTemp, blurred)) {
      target?.release()
    }
    grayLeft = null
    grayRight = null
    rawLeft = null
    rawRight = null
    maps[0] = null
    maps[1] = null
    blurTemp = null
    blurred = null
    activeQuality = null
    mapEmpty = true
    mapReset = true
  }

  /** Deletes every GL object; the renderer's context must be current */
  private fun releaseGlObjects() {
    releaseEyeTargets()
    releaseDisparityTargets()
    val programs = listOf(
      eyeFlatProgram, eyeEquirectProgram, copyProgram, grayProgram, disparityProgram, blendProgram, blurProgram,
      synthesisProgram, showDisparityProgram,
    )
    for (program in programs) program?.release()
    SpatialGl.deleteTexture(videoTexture)
    if (vertexArray != 0) GLES30.glDeleteVertexArrays(1, intArrayOf(vertexArray), 0)
    if (cornerBuffer != 0) GLES30.glDeleteBuffers(1, intArrayOf(cornerBuffer), 0)
    if (timerSupported) GLES30.glDeleteQueries(queries.size, queries, 0)
  }

  /** Drops the handles without deleting them, for a context that is already gone */
  private fun forgetGlObjects() {
    eyeFlatProgram = null
    eyeEquirectProgram = null
    copyProgram = null
    grayProgram = null
    disparityProgram = null
    blendProgram = null
    blurProgram = null
    synthesisProgram = null
    showDisparityProgram = null
    spatialReady = false
    videoTexture = 0
    vertexArray = 0
    cornerBuffer = 0
    leftEye = null
    rightEye = null
    eyeTargetsFailed = false
    eyesValid = false
    grayLeft = null
    grayRight = null
    rawLeft = null
    rawRight = null
    maps[0] = null
    maps[1] = null
    blurTemp = null
    blurred = null
    activeQuality = null
    disparityWidth = 0
    disparityHeight = 0
    disparityFailed = false
    mapEmpty = true
    mapReset = true
    mapFov = Float.NaN
    stepUpBlockedUntil.fill(Long.MIN_VALUE)
    hasVideoFrame = false
    queryPending.fill(false)
    activeQuery = -1
    nextQuery = 0
  }
}
