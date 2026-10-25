package app.alextran.immich.djilink

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The phone's own codecs for the steady stream (p2/relay-bandwidth-2026-10-25.md, 7.2 and 7.3), written from the public
 * MediaCodec, MediaFormat, SurfaceTexture and EGL14 reference documentation: decoder 2 ([DjiRelayDec]) renders the
 * pictures the core keeps into a SurfaceTexture of the GL stage ([DjiRelayGl]), which draws one quad into the input
 * surface of the hardware H.265 encoder ([DjiRelayEnc]). Each has its own thread; none is the pilot's.
 */
class AndroidRelayCodecs(private val clockNs: () -> Long = { SystemClock.elapsedRealtimeNanos() }) : RelayCodecs {
  companion object {
    const val MIME = "video/hevc"
    const val TAG = "DjiRelayCodecs"

    /** The drone's size first, so that a receiver's decoder need not be configured again at a switch */
    val SIZES = listOf(1920 to 1080, 1280 to 720)
    const val PER_SECOND = 30
    const val KEY_INTERVAL_S = 2

    fun log(message: String) {
      runCatching { Log.i(TAG, message) }
    }
  }

  override fun findEncoder(): RelayEncoderInfo? {
    val infos = runCatching { MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.toList() }
      .getOrDefault(emptyList())
    for (info in infos) {
      if (!info.isEncoder || info.supportedTypes.none { it.equals(MIME, ignoreCase = true) }) {
        continue
      }
      val hardware = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        !info.isAlias && info.isHardwareAccelerated && !info.isSoftwareOnly
      } else {
        !HevcDecoders.isSoftwareName(info.name)
      }
      if (!hardware) {
        continue
      }
      val capabilities = runCatching { info.getCapabilitiesForType(MIME) }.getOrNull() ?: continue
      val surface = capabilities.colorFormats.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
      val video = capabilities.videoCapabilities ?: continue
      val fits = SIZES.any { (width, height) ->
        runCatching { video.areSizeAndRateSupported(width, height, PER_SECOND.toDouble()) }.getOrDefault(false)
      }
      if (!surface || !fits) {
        continue
      }
      val cbr = runCatching {
        capabilities.encoderCapabilities?.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
      }.getOrNull() == true
      return RelayEncoderInfo(info.name, hardware = true, cbr = cbr)
    }
    return null
  }

  override fun openDecoder(description: StreamDescription, core: RelayTranscoder): RelayDecoderPort? {
    val gl = DjiRelayGl.make(description.info.width, description.info.height, core, clockNs) ?: run {
      log("the GL stage could not be made")
      return null
    }
    return DjiRelayDec.make(description, gl, core, clockNs) ?: run {
      gl.release()
      null
    }
  }

  override fun openEncoder(
    info: RelayEncoderInfo,
    bitrateBps: Int,
    decoder: RelayDecoderPort,
    core: RelayTranscoder,
  ): RelayEncoderPort? {
    val gl = (decoder as? DjiRelayDec)?.gl ?: return null
    return DjiRelayEnc.make(info, bitrateBps, gl, core, clockNs)
  }
}

/**
 * Decoder 2 (p2/relay-bandwidth-2026-10-25.md, 7.2 DjiRelayDec): a hardware H.265 decoder of its own, asynchronous on
 * the thread "DjiRelayDec", at priority 1 (best effort, after the pilot's decoder at 0). Every unit goes in, in order;
 * each picture is released rendered (into the GL stage's SurfaceTexture) only when the core keeps it.
 */
class DjiRelayDec private constructor(
  private val codec: MediaCodec,
  override val name: String,
  val gl: DjiRelayGl,
  private val thread: HandlerThread,
  private val handler: Handler,
  private val core: RelayTranscoder,
  private val clockNs: () -> Long,
) : RelayDecoderPort {
  companion object {
    private const val MAX_INPUT_BYTES = 4 * 1024 * 1024

    fun make(description: StreamDescription, gl: DjiRelayGl, core: RelayTranscoder, clockNs: () -> Long): DjiRelayDec? {
      val width = description.info.codedWidth
      val height = description.info.codedHeight
      // Hardware only: a software decoder at 60 a second would only stop on the "too slow" rule
      val candidates = HevcDecoders.list(width, height).filter { it.hardware }
      val thread = HandlerThread("DjiRelayDec").apply { start() }
      val handler = Handler(thread.looper)
      for (candidate in candidates) {
        // 0: priority 1 and low latency when reported; 1: priority 1; 2: plain
        for (level in 0..2) {
          val format = MediaFormat.createVideoFormat(AndroidRelayCodecs.MIME, width, height)
          format.setByteBuffer("csd-0", ByteBuffer.wrap(description.configuration()))
          format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, MAX_INPUT_BYTES)
          if (level <= 1) {
            format.setInteger(MediaFormat.KEY_PRIORITY, 1)
          }
          if (level == 0 && candidate.lowLatencyFeature && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
          }
          val created = runCatching { MediaCodec.createByCodecName(candidate.name) }.getOrNull() ?: break
          val port = DjiRelayDec(created, candidate.name, gl, thread, handler, core, clockNs)
          val started = runCatching {
            created.setCallback(port.callback, handler)
            created.configure(format, gl.decoderSurface, null, 0)
            created.start()
          }.isSuccess
          if (started) {
            AndroidRelayCodecs.log("decoder 2 ${candidate.name} started, level $level")
            return port
          }
          runCatching { created.release() }
        }
      }
      thread.quitSafely()
      return null
    }
  }

  /** Input buffers free, on the decoder's thread only */
  private val free = ArrayDeque<Int>()

  @Volatile
  private var released = false
  private val drain = Runnable { drainNow() }

  override fun wake() {
    if (!released) {
      handler.removeCallbacks(drain)
      handler.post(drain)
    }
  }

  private fun drainNow() {
    while (!released) {
      val index = free.firstOrNull() ?: return
      val input = core.nextInput(clockNs()) ?: return
      free.removeFirst()
      val unit = input.unit
      val buffer = runCatching { codec.getInputBuffer(index) }.getOrNull()
      if (buffer == null || buffer.capacity() < unit.size) {
        // The buffer cannot hold it: the index goes back empty and the chain repairs over seconds
        runCatching { codec.queueInputBuffer(index, 0, 0, input.ptsUs, 0) }
        continue
      }
      buffer.clear()
      buffer.put(unit.bytes)
      val flags = if (unit.isKey) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
      val queued = runCatching { codec.queueInputBuffer(index, 0, unit.size, input.ptsUs, flags) }
      if (queued.isFailure) {
        core.onDecoderError("queueInputBuffer ${queued.exceptionOrNull()?.javaClass?.simpleName}", recoverable = true)
        return
      }
    }
  }

  private val callback = object : MediaCodec.Callback() {
    override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
      if (released) {
        return
      }
      free.addLast(index)
      drainNow()
    }

    override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
      if (released) {
        return
      }
      val render = core.onDecoded(info.presentationTimeUs, clockNs())
      // Rendered, the SurfaceTexture's timestamp is this presentation time in nanoseconds
      runCatching { codec.releaseOutputBuffer(index, render) }
    }

    override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
      if (!released) {
        core.onDecoderError(error.diagnosticInfo ?: "error", error.isRecoverable || error.isTransient)
      }
    }

    override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) = Unit
  }

  /** Stopped and released on a thread of its own: never inside a callback of the codec, never on the caller's */
  override fun release() {
    if (released) {
      return
    }
    released = true
    handler.removeCallbacks(drain)
    Thread({
      runCatching { codec.stop() }
      runCatching { codec.release() }
      gl.release()
      thread.quitSafely()
    }, "DjiRelayDecClose").apply { isDaemon = true }.start()
  }
}

/**
 * The GL stage (p2/relay-bandwidth-2026-10-25.md, 7.2 DjiRelayGl), on the thread "DjiRelayGl": an EGL context, an
 * external texture and its SurfaceTexture that decoder 2 renders into; each picture rendered is drawn as one quad into
 * the encoder's input surface (an EGL window surface) with its presentation time (eglPresentationTimeANDROID).
 */
class DjiRelayGl private constructor(
  private val width: Int,
  private val height: Int,
  private val core: RelayTranscoder,
  private val clockNs: () -> Long,
) {
  companion object {
    /** EGL_RECORDABLE_ANDROID, which EGL14 does not name: a surface an encoder can take */
    private const val EGL_RECORDABLE_ANDROID = 0x3142
    private const val WAIT_MS = 2_000L

    private const val VERTEX = """
      uniform mat4 uTexMatrix;
      attribute vec4 aPosition;
      attribute vec4 aTexCoord;
      varying vec2 vTexCoord;
      void main() {
        gl_Position = aPosition;
        vTexCoord = (uTexMatrix * aTexCoord).xy;
      }
    """

    private const val FRAGMENT = """
      #extension GL_OES_EGL_image_external : require
      precision mediump float;
      varying vec2 vTexCoord;
      uniform samplerExternalOES sTexture;
      void main() {
        gl_FragColor = texture2D(sTexture, vTexCoord);
      }
    """

    /** Two triangles over the whole surface, with their texture corners */
    private val QUAD = floatArrayOf(
      -1f, -1f, 0f, 0f,
      1f, -1f, 1f, 0f,
      -1f, 1f, 0f, 1f,
      1f, 1f, 1f, 1f,
    )

    fun make(width: Int, height: Int, core: RelayTranscoder, clockNs: () -> Long): DjiRelayGl? {
      val gl = DjiRelayGl(width, height, core, clockNs)
      if (gl.runOn { gl.setUp() } == true) {
        return gl
      }
      gl.release()
      return null
    }
  }

  private val thread = HandlerThread("DjiRelayGl").apply { start() }
  private val handler = Handler(thread.looper)
  private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
  private var context: EGLContext = EGL14.EGL_NO_CONTEXT
  private var config: EGLConfig? = null
  private var pbuffer: EGLSurface = EGL14.EGL_NO_SURFACE
  private var encoderSurface: EGLSurface = EGL14.EGL_NO_SURFACE
  private var encoderWidth = 0
  private var encoderHeight = 0
  private var program = 0
  private var texture = 0
  private var positionAt = 0
  private var texCoordAt = 0
  private var matrixAt = 0
  private val matrix = FloatArray(16)
  private val quad: FloatBuffer = ByteBuffer.allocateDirect(QUAD.size * 4).order(ByteOrder.nativeOrder())
    .asFloatBuffer()
    .apply {
      put(QUAD)
      position(0)
    }
  private var surfaceTexture: SurfaceTexture? = null

  @Volatile
  private var released = false

  /** The surface decoder 2 renders into */
  lateinit var decoderSurface: Surface
    private set

  /** Runs [block] on the GL thread and waits for it (at once when already there); null when it did not finish */
  private fun <T> runOn(block: () -> T): T? {
    if (Looper.myLooper() == thread.looper) {
      return runCatching(block).getOrNull()
    }
    var result: T? = null
    val done = CountDownLatch(1)
    val posted = handler.post {
      result = runCatching(block).getOrNull()
      done.countDown()
    }
    if (!posted || !done.await(WAIT_MS, TimeUnit.MILLISECONDS)) {
      return null
    }
    return result
  }

  private fun setUp(): Boolean {
    display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    val version = IntArray(2)
    if (display == EGL14.EGL_NO_DISPLAY || !EGL14.eglInitialize(display, version, 0, version, 1)) {
      return false
    }
    val attributes = intArrayOf(
      EGL14.EGL_RED_SIZE, 8,
      EGL14.EGL_GREEN_SIZE, 8,
      EGL14.EGL_BLUE_SIZE, 8,
      EGL14.EGL_ALPHA_SIZE, 8,
      EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
      EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
      EGL_RECORDABLE_ANDROID, 1,
      EGL14.EGL_NONE,
    )
    val configs = arrayOfNulls<EGLConfig>(1)
    val count = IntArray(1)
    if (!EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) || count[0] == 0) {
      return false
    }
    config = configs[0]
    context = EGL14.eglCreateContext(
      display,
      config,
      EGL14.EGL_NO_CONTEXT,
      intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE),
      0,
    )
    if (context == EGL14.EGL_NO_CONTEXT) {
      return false
    }
    val size = intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE)
    pbuffer = EGL14.eglCreatePbufferSurface(display, config, size, 0)
    if (pbuffer == EGL14.EGL_NO_SURFACE || !EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)) {
      return false
    }
    program = buildProgram() ?: return false
    positionAt = GLES20.glGetAttribLocation(program, "aPosition")
    texCoordAt = GLES20.glGetAttribLocation(program, "aTexCoord")
    matrixAt = GLES20.glGetUniformLocation(program, "uTexMatrix")
    val textures = IntArray(1)
    GLES20.glGenTextures(1, textures, 0)
    texture = textures[0]
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
    val made = SurfaceTexture(texture)
    made.setDefaultBufferSize(width, height)
    made.setOnFrameAvailableListener({ onFrame() }, handler)
    surfaceTexture = made
    decoderSurface = Surface(made)
    return true
  }

  private fun buildProgram(): Int? {
    val vertex = shader(GLES20.GL_VERTEX_SHADER, VERTEX) ?: return null
    val fragment = shader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT) ?: return null
    val made = GLES20.glCreateProgram()
    GLES20.glAttachShader(made, vertex)
    GLES20.glAttachShader(made, fragment)
    GLES20.glLinkProgram(made)
    val linked = IntArray(1)
    GLES20.glGetProgramiv(made, GLES20.GL_LINK_STATUS, linked, 0)
    return if (linked[0] == GLES20.GL_TRUE) made else null
  }

  private fun shader(type: Int, source: String): Int? {
    val made = GLES20.glCreateShader(type)
    GLES20.glShaderSource(made, source)
    GLES20.glCompileShader(made)
    val compiled = IntArray(1)
    GLES20.glGetShaderiv(made, GLES20.GL_COMPILE_STATUS, compiled, 0)
    return if (compiled[0] != 0) made else null
  }

  /** The encoder's input surface, [width] by [height]: every picture rendered from now on is drawn into it */
  fun attachEncoder(surface: Surface, width: Int, height: Int): Boolean = runOn {
    val made = EGL14.eglCreateWindowSurface(display, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
    if (made == EGL14.EGL_NO_SURFACE) {
      false
    } else {
      encoderSurface = made
      encoderWidth = width
      encoderHeight = height
      true
    }
  } == true

  /** Before the encoder goes: its EGL surface goes first, so that no swap reaches a released surface */
  fun detachEncoder() {
    runOn {
      val current = encoderSurface
      if (current != EGL14.EGL_NO_SURFACE) {
        EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)
        EGL14.eglDestroySurface(display, current)
        encoderSurface = EGL14.EGL_NO_SURFACE
      }
    }
  }

  private fun onFrame() {
    val texture = surfaceTexture ?: return
    if (released) {
      return
    }
    try {
      val target = encoderSurface
      val surface = if (target != EGL14.EGL_NO_SURFACE) target else pbuffer
      if (!EGL14.eglMakeCurrent(display, surface, surface, context)) {
        core.onGlError("eglMakeCurrent 0x%x".format(EGL14.eglGetError()))
        return
      }
      texture.updateTexImage()
      if (target == EGL14.EGL_NO_SURFACE) {
        return
      }
      texture.getTransformMatrix(matrix)
      val ptsNs = texture.timestamp
      GLES20.glViewport(0, 0, encoderWidth, encoderHeight)
      GLES20.glUseProgram(program)
      GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
      GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, this.texture)
      GLES20.glUniformMatrix4fv(matrixAt, 1, false, matrix, 0)
      quad.position(0)
      GLES20.glVertexAttribPointer(positionAt, 2, GLES20.GL_FLOAT, false, 16, quad)
      GLES20.glEnableVertexAttribArray(positionAt)
      quad.position(2)
      GLES20.glVertexAttribPointer(texCoordAt, 2, GLES20.GL_FLOAT, false, 16, quad)
      GLES20.glEnableVertexAttribArray(texCoordAt)
      GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
      EGLExt.eglPresentationTimeANDROID(display, target, ptsNs)
      val start = clockNs()
      // Waits only when the encoder's input queue is full: this thread waits, never the pilot's
      val swapped = EGL14.eglSwapBuffers(display, target)
      val waited = clockNs() - start
      if (!swapped) {
        core.onGlError("eglSwapBuffers 0x%x".format(EGL14.eglGetError()))
        return
      }
      core.onDrawn(ptsNs / 1_000, clockNs(), waited)
    } catch (error: RuntimeException) {
      // A surface abandoned under the stage
      core.onGlError(error.javaClass.simpleName)
    }
  }

  fun release() {
    if (released) {
      return
    }
    released = true
    handler.post {
      runCatching { surfaceTexture?.setOnFrameAvailableListener(null) }
      runCatching { surfaceTexture?.release() }
      if (::decoderSurface.isInitialized) {
        runCatching { decoderSurface.release() }
      }
      if (display != EGL14.EGL_NO_DISPLAY) {
        runCatching {
          EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
          if (encoderSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, encoderSurface)
          if (pbuffer != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, pbuffer)
          if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
          EGL14.eglReleaseThread()
          EGL14.eglTerminate(display)
        }
      }
      encoderSurface = EGL14.EGL_NO_SURFACE
      thread.quitSafely()
    }
  }
}

/**
 * The phone's hardware H.265 encoder (p2/relay-bandwidth-2026-10-25.md, 7.3 DjiRelayEnc), asynchronous on the thread
 * "DjiRelayEnc", with surface input from the GL stage. Configured at 1920x1080, else 1280x720, at 30 a second and the
 * rate asked, in this order of fallback, each refused key dropped: CBR when it takes it (VBR otherwise), VPS, SPS and
 * PPS before every key picture, no B pictures, a latency of one picture, priority 1, an operating rate of 30; then
 * without the latency, the priority and the operating rate; then without the headers and the B pictures; then plain.
 * A key picture every 2 s, profile Main. Each output is copied once and handed to the core.
 */
class DjiRelayEnc private constructor(
  private val codec: MediaCodec,
  override val name: String,
  initial: RelayEncoderSetup,
  private val gl: DjiRelayGl,
  private val thread: HandlerThread,
  private val handler: Handler,
  private val core: RelayTranscoder,
  private val clockNs: () -> Long,
) : RelayEncoderPort {
  companion object {
    fun make(
      info: RelayEncoderInfo,
      bitrateBps: Int,
      gl: DjiRelayGl,
      core: RelayTranscoder,
      clockNs: () -> Long,
    ): DjiRelayEnc? {
      val thread = HandlerThread("DjiRelayEnc").apply { start() }
      val handler = Handler(thread.looper)
      for ((width, height) in AndroidRelayCodecs.SIZES) {
        for (level in 0..3) {
          val format = MediaFormat.createVideoFormat(AndroidRelayCodecs.MIME, width, height)
          format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
          format.setInteger(MediaFormat.KEY_FRAME_RATE, AndroidRelayCodecs.PER_SECOND)
          format.setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
          format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, AndroidRelayCodecs.KEY_INTERVAL_S)
          format.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.HEVCProfileMain)
          val mode = if (info.cbr) {
            MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
          } else {
            MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR
          }
          format.setInteger(MediaFormat.KEY_BITRATE_MODE, mode)
          val headers = level <= 1 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
          if (headers) {
            format.setInteger(MediaFormat.KEY_PREPEND_HEADER_TO_SYNC_FRAMES, 1)
            format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
          }
          val latency = level == 0 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
          if (level == 0) {
            if (latency) {
              format.setInteger(MediaFormat.KEY_LATENCY, 1)
            }
            format.setInteger(MediaFormat.KEY_PRIORITY, 1)
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, AndroidRelayCodecs.PER_SECOND)
          }
          if (level == 3) {
            format.removeKey(MediaFormat.KEY_BITRATE_MODE)
            format.removeKey(MediaFormat.KEY_PROFILE)
          }
          val created = runCatching { MediaCodec.createByCodecName(info.name) }.getOrNull() ?: break
          val setup = RelayEncoderSetup(
            width = width,
            height = height,
            perSecond = AndroidRelayCodecs.PER_SECOND,
            bitrateMode = if (level == 3) "default" else if (info.cbr) "cbr" else "vbr",
            latencyAccepted = null,
            headersOnKeys = headers,
            keyIntervalS = AndroidRelayCodecs.KEY_INTERVAL_S,
            level = level,
          )
          val port = DjiRelayEnc(created, info.name, setup, gl, thread, handler, core, clockNs)
          var surface: Surface? = null
          try {
            // Asynchronous: the callback before the configuration, as MediaCodec asks
            created.setCallback(port.callback, handler)
            created.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            surface = created.createInputSurface()
            port.inputSurface = surface
            if (!gl.attachEncoder(surface, width, height)) {
              throw IllegalStateException("no EGL surface")
            }
            created.start()
            AndroidRelayCodecs.log("encoder ${info.name} ${width}x$height at level $level, $bitrateBps bit/s")
            return port
          } catch (error: Exception) {
            gl.detachEncoder()
            runCatching { surface?.release() }
            runCatching { created.release() }
          }
        }
      }
      thread.quitSafely()
      return null
    }
  }

  @Volatile
  private var current: RelayEncoderSetup = initial

  /** The encoder's input surface, which the GL stage draws into; made after the configuration */
  @Volatile
  private var inputSurface: Surface? = null

  override val setup: RelayEncoderSetup get() = current

  @Volatile
  private var released = false

  private val callback = object : MediaCodec.Callback() {
    override fun onInputBufferAvailable(codec: MediaCodec, index: Int) = Unit

    override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
      if (released) {
        return
      }
      val buffer = runCatching { codec.getOutputBuffer(index) }.getOrNull()
      if (buffer != null && info.size > 0) {
        // The one copy of the output: an AccessUnit holds it from here
        val bytes = ByteArray(info.size)
        buffer.position(info.offset)
        buffer.limit(info.offset + info.size)
        buffer.get(bytes)
        core.onEncoded(
          bytes,
          info.presentationTimeUs,
          config = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0,
          key = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0,
          nowNs = clockNs(),
        )
      }
      runCatching { codec.releaseOutputBuffer(index, false) }
    }

    override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
      if (!released) {
        core.onEncoderError(error.diagnosticInfo ?: "error", error.isRecoverable || error.isTransient)
      }
    }

    override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
      // The latency the encoder took, said in its output format (Android 11 and later)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && format.containsKey(MediaFormat.KEY_LATENCY)) {
        val taken = runCatching { format.getInteger(MediaFormat.KEY_LATENCY) <= 1 }.getOrNull()
        current = current.copy(latencyAccepted = taken)
      }
      AndroidRelayCodecs.log("encoder output format $format")
    }
  }

  override fun requestKey() {
    if (released) {
      return
    }
    handler.post {
      runCatching {
        codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
      }
    }
  }

  override fun setBitrate(bps: Int) {
    if (released) {
      return
    }
    handler.post {
      runCatching { codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bps) }) }
    }
  }

  /** Its EGL surface goes first, then the codec and its input surface, on a thread of their own */
  override fun release() {
    if (released) {
      return
    }
    released = true
    Thread({
      gl.detachEncoder()
      runCatching { codec.stop() }
      runCatching { codec.release() }
      runCatching { inputSurface?.release() }
      thread.quitSafely()
    }, "DjiRelayEncClose").apply { isDaemon = true }.start()
  }
}
