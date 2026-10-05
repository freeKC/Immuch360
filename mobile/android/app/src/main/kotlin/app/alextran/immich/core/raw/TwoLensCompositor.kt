package app.alextran.immich.core.raw

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.util.Log
import android.view.Surface
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.video.VideoFrameMetadataListener
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReferenceArray
import kotlin.math.max
import kotlin.math.min

/** The compositor cannot start or draw (no OpenGL ES 3 context, a shader the driver refuses, an EGL failure). */
class RawStitchException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * Stitches the decoded streams of a raw 360° video into the equirectangular frame of the destination Surface, on a
 * GL thread of its own. Each [LensVideoRenderer] decodes into one of [inputSurface] (a SurfaceTexture on an external
 * texture) and tells its frames to [metadataListener]; [LensFramePairer] decides when both textures hold the same
 * moment, and the stitch shader of [RawStitchShaders] draws them at their release time minus [LEAD_NS], presented at
 * the release time, the downstream listener told first (the phone's spherical view finds the projection of a frame
 * by that time, as for decoded frames).
 *
 * Frames keep being acquired without a destination (the phone's view surface is recreated, the Quest's panel not
 * there yet): the decoders never stall on a full queue. A failure while drawing is reported once to
 * [Callbacks.onStitchError] and the frames are then only acquired; a destination that goes away (abandoned Surface)
 * is not a failure.
 *
 * Public calls are safe from any thread: they post to the GL thread; [clearOutput] and [release] wait for it.
 */
@OptIn(UnstableApi::class)
class TwoLensCompositor(
  private val projection: RawProjection,
  /** The decoded streams, texture indices of `projection.tracks`: [0, 1], or one of them in one lens mode. */
  private val streams: List<Int>,
  private val callbacks: Callbacks,
) {
  /** Called on the GL thread. */
  interface Callbacks {
    fun onFirstFrameDrawn()

    fun onStitchError(error: Exception)
  }

  private val thread = HandlerThread(TAG, Process.THREAD_PRIORITY_DISPLAY)
  private lateinit var handler: Handler

  // GL thread state
  private var display: EGLDisplay? = null
  private var context: EGLContext? = null
  private var placeholder: EGLSurface? = null
  private var window: EGLSurface? = null
  private var outputWidth = 0
  private var outputHeight = 0
  /** Bumped by every setOutput and clearOutput, so that a retry for an older Surface gives up. */
  private var outputGeneration = 0
  private val textureIds = IntArray(2)
  private val surfaceTextures = arrayOfNulls<SurfaceTexture>(2)
  private val inputSurfaces = arrayOfNulls<Surface>(2)
  private val texTransforms = Array(2) { FloatArray(16).also { GlUtil.setToIdentity(it) } }
  private val lastTimestamps = LongArray(2) { Long.MIN_VALUE }
  private var program: GlProgram? = null
  private var programColor: RawStitchShaders.Color? = null
  private var essl3External = true
  private var yuvTarget = false
  /** The YUV variant failed to build once: HDR goes through the driver's RGB conversion from then on. */
  private var yuvFailed = false
  private var pendingDraw: LensFramePairer.Draw<Format>? = null
  private var lastDraw: LensFramePairer.Draw<Format>? = null
  private var firstFrameDrawn = false
  private var failed = false
  private var mismatchLogged = false

  // Stats since the last stats line
  private var drawn = 0L
  private var noOutput = 0L
  private var leadSumNs = 0L
  private var drawSumNs = 0L

  /** The last format of each stream (playback thread to GL thread): colour, decoded size. */
  private val formats = AtomicReferenceArray<Format?>(2)
  private val pairer =
    LensFramePairer<Format>(streams, projection.tracks.maxOfOrNull { it.frameRate }?.takeIf { it > 0 } ?: 30.0)

  @Volatile private var downstream: VideoFrameMetadataListener? = null
  @Volatile private var released = false

  /** The largest output the GPU draws: the viewport and texture limits, read when the context starts. */
  @Volatile
  var maxOutputSize = Size(DEFAULT_MAX_OUTPUT, DEFAULT_MAX_OUTPUT)
    private set

  private val drawPending = Runnable { pendingDraw?.let { guarded { drawNow(it) } } }
  private val timeout = Runnable { guarded { handle(pairer.onTimeout(System.nanoTime())) } }
  private val statsLine =
    object : Runnable {
      override fun run() {
        if (released) return
        logStats()
        handler.postDelayed(this, STATS_INTERVAL_MS)
      }
    }

  /**
   * Starts the GL thread: EGL ES 3 context, the external textures and the input Surfaces, the SDR program of this
   * projection (so that a driver that refuses the shader fails here, before playback). Throws [RawStitchException]
   * when any of it fails or takes more than [START_TIMEOUT_MS].
   */
  fun start() {
    thread.start()
    handler = Handler(thread.looper)
    val done = CountDownLatch(1)
    var error: Exception? = null
    handler.post {
      try {
        setUpGl()
      } catch (e: Exception) {
        error = e
      } finally {
        done.countDown()
      }
    }
    if (!done.await(START_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
      release()
      throw RawStitchException("the compositor did not start within $START_TIMEOUT_MS ms")
    }
    error?.let {
      release()
      throw RawStitchException("cannot start the compositor: ${it.message}", it)
    }
    handler.postDelayed(statsLine, STATS_INTERVAL_MS)
  }

  /** The Surface the renderer of [stream] decodes into. */
  fun inputSurface(stream: Int): Surface =
    inputSurfaces[stream] ?: throw IllegalStateException("stream $stream is not decoded by this compositor")

  /** What the renderer of [stream] tells its frames to, on the playback thread. */
  fun metadataListener(stream: Int): VideoFrameMetadataListener =
    VideoFrameMetadataListener { presentationTimeUs, releaseTimeNs, format, _ ->
      formats.set(stream, format)
      pairer.onMetadata(stream, releaseTimeNs, presentationTimeUs, format, format.frameRate)
    }

  /**
   * Reports the next drawn frame to [Callbacks.onFirstFrameDrawn] again: a new media on the same player (the Quest
   * shows the same video again), whose panel waits for its first stitched frame.
   */
  fun expectFirstFrame() {
    if (released) return
    handler.post { firstFrameDrawn = false }
  }

  /** Told about each drawn frame before it is presented (the phone's spherical view), or nothing. */
  fun setDownstream(listener: VideoFrameMetadataListener?) {
    downstream = listener
  }

  /**
   * Draws into [surface] of [width] x [height] from now on (asynchronous). A decoder of the previous player may not
   * have left that Surface yet: creating the EGL surface is retried a few times. The pair drawn last, if any, is
   * drawn again at once, so that a paused video shows on a new destination.
   */
  fun setOutput(surface: Surface, width: Int, height: Int) {
    if (released) return
    handler.post {
      outputGeneration++
      attachOutput(surface, width, height, outputGeneration, 0)
    }
  }

  /** Stops drawing into the destination (synchronous, at most 500 ms): its owner is about to release it. */
  fun clearOutput() {
    if (released) return
    runAndWait(CLEAR_TIMEOUT_MS) {
      outputGeneration++
      detachOutput()
    }
  }

  /** Releases everything (at most 1 s). Release the player first, so that the decoders leave the input Surfaces. */
  fun release() {
    if (released) return
    released = true
    if (!thread.isAlive) return
    runAndWait(RELEASE_TIMEOUT_MS) { tearDownGl() }
    thread.quitSafely()
  }

  private fun runAndWait(timeoutMs: Long, block: () -> Unit) {
    if (Looper.myLooper() == thread.looper) {
      block()
      return
    }
    val done = CountDownLatch(1)
    val posted =
      handler.post {
        try {
          guarded(block)
        } finally {
          done.countDown()
        }
      }
    if (posted && !done.await(timeoutMs, TimeUnit.MILLISECONDS)) {
      Log.w(TAG, "the GL thread did not answer within $timeoutMs ms")
    }
  }

  private fun setUpGl() {
    val display = GlUtil.getDefaultEglDisplay()
    this.display = display
    // No ES 2 compositor: without an ES 3 context the video plays unstitched
    val context = GlUtil.createEglContext(EGL14.EGL_NO_CONTEXT, display, 3, GlUtil.EGL_CONFIG_ATTRIBUTES_RGBA_8888)
    this.context = context
    // Keeps the context current while there is no destination: updateTexImage needs one
    placeholder = GlUtil.createFocusedPlaceholderEglSurface(context, display)
    val extensions = GLES20.glGetString(GLES20.GL_EXTENSIONS).orEmpty()
    essl3External = extensions.contains("GL_OES_EGL_image_external_essl3")
    yuvTarget = GlUtil.isYuvTargetExtensionSupported()
    val viewport = IntArray(2)
    GLES20.glGetIntegerv(GLES20.GL_MAX_VIEWPORT_DIMS, viewport, 0)
    val texture = IntArray(1)
    GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, texture, 0)
    maxOutputSize =
      Size(
        min(viewport[0].takeIf { it > 0 } ?: DEFAULT_MAX_OUTPUT, texture[0].takeIf { it > 0 } ?: DEFAULT_MAX_OUTPUT),
        min(viewport[1].takeIf { it > 0 } ?: DEFAULT_MAX_OUTPUT, texture[0].takeIf { it > 0 } ?: DEFAULT_MAX_OUTPUT),
      )
    for (stream in streams) {
      val id = GlUtil.createExternalTexture()
      textureIds[stream] = id
      val surfaceTexture = SurfaceTexture(id)
      surfaceTexture.setOnFrameAvailableListener({ onFrameAvailable(stream) }, handler)
      surfaceTextures[stream] = surfaceTexture
      inputSurfaces[stream] = Surface(surfaceTexture)
    }
    useProgram(RawStitchShaders.Color.SDR, null)
    Log.i(
      TAG,
      "started: ES 3 context, essl3 external $essl3External, YUV target $yuvTarget, max output $maxOutputSize, " +
        "streams $streams, ${projection.summary()}",
    )
  }

  private fun tearDownGl() {
    handler.removeCallbacksAndMessages(null)
    pendingDraw = null
    for (stream in streams) {
      surfaceTextures[stream]?.let {
        it.setOnFrameAvailableListener(null)
        it.release()
      }
      surfaceTextures[stream] = null
      inputSurfaces[stream]?.release()
      inputSurfaces[stream] = null
    }
    val display = display ?: return
    val context = context ?: return
    try {
      program?.delete()
      program = null
      for (stream in streams) if (textureIds[stream] != 0) GlUtil.deleteTexture(textureIds[stream])
      detachOutput()
      placeholder?.let { GlUtil.destroyEglSurface(display, it) }
      placeholder = null
      GlUtil.destroyEglContext(display, context)
    } catch (e: Exception) {
      Log.w(TAG, "release: ${e.message}")
    }
    this.context = null
    logStats()
    Log.i(TAG, "released")
  }

  private fun attachOutput(surface: Surface, width: Int, height: Int, generation: Int, attempt: Int) {
    if (released || generation != outputGeneration) return
    val display = display ?: return
    detachOutput()
    try {
      window = GlUtil.createEglSurface(display, surface, C.COLOR_TRANSFER_SDR, /* isEncoderInputSurface= */ false)
    } catch (e: GlUtil.GlException) {
      if (attempt + 1 < OUTPUT_ATTEMPTS) {
        // The decoder of the previous player may still be connected to this Surface
        handler.postDelayed({ attachOutput(surface, width, height, generation, attempt + 1) }, OUTPUT_RETRY_MS)
      } else {
        fail(RawStitchException("cannot draw into the destination after $OUTPUT_ATTEMPTS attempts", e))
      }
      return
    }
    outputWidth = width
    outputHeight = height
    Log.i(TAG, "output ${width}x$height${if (attempt > 0) " after ${attempt + 1} attempts" else ""}")
    lastDraw?.let { last -> guarded { drawNow(last.copy(releaseNs = System.nanoTime())) } }
  }

  private fun detachOutput() {
    val display = display ?: return
    val context = context ?: return
    val current = window ?: return
    window = null
    // The window surface must not be current when it is destroyed: the placeholder takes over
    placeholder?.let { GlUtil.focusEglSurface(display, context, it, 1, 1) }
    GlUtil.destroyEglSurface(display, current)
  }

  private fun onFrameAvailable(stream: Int) {
    if (released) return
    guarded {
      // A newer frame must not replace a texture whose pair is still to be shown
      pendingDraw?.let { drawNow(it) }
      val surfaceTexture = surfaceTextures[stream] ?: return@guarded
      surfaceTexture.updateTexImage()
      surfaceTexture.getTransformMatrix(texTransforms[stream])
      val timestamp = surfaceTexture.timestamp
      // Nothing new latched (an extra callback): pairing it again would read as a frame without metadata
      if (timestamp == lastTimestamps[stream]) return@guarded
      lastTimestamps[stream] = timestamp
      if (failed) return@guarded
      val decision = pairer.onAcquired(stream, timestamp, System.nanoTime())
      if (pairer.releaseTimePairing && !mismatchLogged) {
        mismatchLogged = true
        Log.w(TAG, "texture timestamps differ from release times, pairing by release time")
      }
      handle(decision)
    }
  }

  private fun handle(decision: LensFramePairer.Decision) {
    when (decision) {
      is LensFramePairer.Draw<*> -> {
        @Suppress("UNCHECKED_CAST") val draw = decision as LensFramePairer.Draw<Format>
        handler.removeCallbacks(timeout)
        pendingDraw?.let { drawNow(it) }
        if (window == null) {
          noOutput++
          lastDraw = draw
          return
        }
        val delayNs = draw.releaseNs - LEAD_NS - System.nanoTime()
        if (delayNs <= 0) {
          drawNow(draw)
        } else {
          pendingDraw = draw
          handler.postDelayed(drawPending, max(1L, delayNs / 1_000_000))
        }
      }
      is LensFramePairer.Wait -> {
        handler.removeCallbacks(timeout)
        decision.deadlineNs?.let { deadline ->
          handler.postDelayed(timeout, max(1L, (deadline - System.nanoTime()) / 1_000_000))
        }
      }
      LensFramePairer.Idle -> Unit
    }
  }

  private fun drawNow(draw: LensFramePairer.Draw<Format>) {
    if (pendingDraw != null) {
      pendingDraw = null
      handler.removeCallbacks(drawPending)
    }
    lastDraw = draw
    if (failed) return
    val display = display ?: return
    val context = context ?: return
    val window = window
    if (window == null) {
      noOutput++
      return
    }
    val start = System.nanoTime()
    val program = useProgram(colorOf(draw.format ?: formats.get(streams[0])), draw.format)
    GlUtil.focusEglSurface(display, context, window, outputWidth, outputHeight)
    program.use()
    for (index in 0..1) {
      // One lens mode: the sampler of the missing stream reads the decoded one, which uEnabled leaves out
      val stream = if (index in streams) index else streams[0]
      if (program.getUniformLocation("uTex$index") >= 0) {
        program.setSamplerTexIdUniform("uTex$index", textureIds[stream], index)
      }
      program.setFloatsUniformIfPresent("uTexTransform$index", texTransforms[stream])
    }
    program.setFloatsUniformIfPresent("uEnabled", RawStitchUniforms.enabled(streams))
    if (projection.kind == RawKind.DUAL_FISHEYE) {
      val sizes = (0..1).map { stream -> formats.get(stream)?.takeIf { it.width > 0 }?.let { it.width to it.height } }
      for ((name, value) in RawStitchUniforms.halfTexels(projection, sizes)) {
        program.setFloatsUniformIfPresent(name, value)
      }
    }
    if (RawStitchShaders.SUPERSAMPLE) {
      program.setFloatsUniformIfPresent(
        RawStitchShaders.OUTPUT_SIZE_UNIFORM,
        floatArrayOf(outputWidth.toFloat(), outputHeight.toFloat()),
      )
    }
    program.bindAttributesAndUniforms()
    // The four vertex triangle strip forms the quad
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    GlUtil.checkGlError()
    // Before the frame reaches the destination: the spherical view looks the projection up by this release time
    val format = draw.format ?: formats.get(streams[0])
    if (format != null) downstream?.onVideoFrameAboutToBeRendered(draw.ptsUs, draw.releaseNs, format, null)
    EGLExt.eglPresentationTimeANDROID(display, window, draw.releaseNs)
    if (!EGL14.eglSwapBuffers(display, window)) {
      val error = EGL14.eglGetError()
      if (error == EGL14.EGL_BAD_SURFACE || error == EGL14.EGL_BAD_NATIVE_WINDOW) {
        // The destination is gone (an abandoned Surface): not a stitching failure, the next setOutput draws again
        Log.w(TAG, "destination gone (EGL error 0x${Integer.toHexString(error)}), waiting for a new one")
        detachOutput()
        return
      }
      throw RawStitchException("eglSwapBuffers failed: EGL error 0x${Integer.toHexString(error)}")
    }
    drawn++
    leadSumNs += draw.releaseNs - start
    drawSumNs += System.nanoTime() - start
    if (!firstFrameDrawn) {
      firstFrameDrawn = true
      Log.i(TAG, "first frame drawn (${programColor?.label})")
      callbacks.onFirstFrameDrawn()
    }
  }

  /** The colour variant of the streams of [format]: SDR, or the tone map of an HLG or PQ stream. */
  private fun colorOf(format: Format?): RawStitchShaders.Color {
    val toneMap =
      when (format?.colorInfo?.colorTransfer) {
        C.COLOR_TRANSFER_HLG -> RawStitchShaders.ToneMap.HLG
        C.COLOR_TRANSFER_ST2084 -> RawStitchShaders.ToneMap.PQ
        else -> RawStitchShaders.ToneMap.NONE
      }
    if (toneMap == RawStitchShaders.ToneMap.NONE) return RawStitchShaders.Color.SDR
    return RawStitchShaders.Color(yuv = yuvTarget && !yuvFailed, toneMap = toneMap)
  }

  /**
   * The program of [color], built when the variant changes (the first HDR frame). A YUV variant the driver refuses is
   * retried with the driver's RGB conversion; any other failure is a stitching failure.
   */
  private fun useProgram(color: RawStitchShaders.Color, format: Format?): GlProgram {
    val current = program
    if (current != null && programColor == color) return current
    val built =
      try {
        buildProgram(color)
      } catch (e: GlUtil.GlException) {
        if (!color.yuv) throw e
        Log.w(TAG, "the YUV program failed (${e.message}), reading HDR through the driver's RGB conversion")
        yuvFailed = true
        return useProgram(color.copy(yuv = false), format)
      }
    current?.delete()
    program = built
    programColor = color
    if (color.yuv) {
      val full = format?.colorInfo?.colorRange == C.COLOR_RANGE_FULL
      built.setFloatsUniformIfPresent(
        "uYuvToRgb",
        if (full) RawStitchShaders.BT2020_FULL_YUV_TO_RGB else RawStitchShaders.BT2020_LIMITED_YUV_TO_RGB,
      )
      built.setFloatsUniformIfPresent(
        "uYuvOffset",
        if (full) RawStitchShaders.FULL_YUV_OFFSET else RawStitchShaders.LIMITED_YUV_OFFSET,
      )
    }
    Log.i(TAG, "program ${projection.kind} ${color.label}")
    return built
  }

  private fun buildProgram(color: RawStitchShaders.Color): GlProgram {
    val program =
      GlProgram(RawStitchShaders.vertexEs3(), RawStitchShaders.fragmentEs3(projection.kind, color, essl3External))
    program.setBufferAttribute(
      "aFramePosition",
      GlUtil.getNormalizedCoordinateBounds(),
      GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
    )
    val values =
      if (projection.kind == RawKind.EAC_GOPRO) RawStitchUniforms.eac(projection)
      else RawStitchUniforms.fisheye(projection)
    for ((name, value) in values) program.setFloatsUniformIfPresent(name, value)
    return program
  }

  /** Runs [block] on the GL thread; a failure becomes the one stitching error. */
  private inline fun guarded(block: () -> Unit) {
    try {
      block()
    } catch (e: Exception) {
      fail(e)
    }
  }

  private fun fail(error: Exception) {
    if (failed || released) return
    failed = true
    pendingDraw = null
    Log.e(TAG, "stitching failed", error)
    callbacks.onStitchError(error)
  }

  private fun logStats() {
    val stats = pairer.stats
    val meanLeadMs = if (drawn > 0) leadSumNs / drawn / 1e6 else 0.0
    val meanDrawMs = if (drawn > 0) drawSumNs / drawn / 1e6 else 0.0
    Log.i(
      TAG,
      "stats: drawn $drawn, paired ${stats.paired}, unpaired ${stats.unpaired}, replaced ${stats.replaced}, " +
        "dropped without output $noOutput, max |dpts| ${stats.maxDeltaUs} us, " +
        "mean lead ${String.format(Locale.ROOT, "%.1f", meanLeadMs)} ms, " +
        "mean draw ${String.format(Locale.ROOT, "%.2f", meanDrawMs)} ms" +
        if (pairer.releaseTimePairing) ", pairing by release time" else "",
    )
    drawn = 0
    noOutput = 0
    leadSumNs = 0
    drawSumNs = 0
  }

  companion object {
    private const val TAG = "TwoLensCompositor"

    /**
     * Media3 releases frames up to 50 ms before their time: drawing at the release time minus this keeps the picture
     * within one display frame of the sound on destinations that show what they receive (the spherical view's
     * SurfaceTexture), while eglPresentationTimeANDROID serves those that honour timestamps. Tuned on a device.
     */
    const val LEAD_NS = 10_000_000L

    private const val START_TIMEOUT_MS = 2000L
    private const val CLEAR_TIMEOUT_MS = 500L
    private const val RELEASE_TIMEOUT_MS = 1000L
    private const val OUTPUT_ATTEMPTS = 5
    private const val OUTPUT_RETRY_MS = 50L
    private const val STATS_INTERVAL_MS = 10_000L

    /** Output limit assumed until the GPU tells its own. */
    private const val DEFAULT_MAX_OUTPUT = 4096
  }
}
