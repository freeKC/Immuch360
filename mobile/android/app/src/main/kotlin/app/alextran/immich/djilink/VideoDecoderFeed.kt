package app.alextran.immich.djilink

import android.media.MediaCodec
import android.media.MediaCodecInfo.CodecCapabilities
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The decoder, asleep until a video payload has actually been seen.
 *
 * It is a hardware decoder fed by hand, not a player: there is no extractor for a raw elementary stream that arrives
 * in fragments over a USB cable, and there is no audio clock to follow, so every output buffer is rendered as soon as
 * it arrives. The configuration asks for low latency when the device says it has it, and falls back to a plain codec
 * when a vendor key is refused.
 *
 * Stage 1 never creates it: nothing instantiates this class yet, so it reports nothing on the page. It is written now
 * so that the later stage that has decided what an access unit is finds the low latency configuration and its
 * fallback in one place; [lastError] and the counters will then say whether a decoder could be created at all.
 */
class VideoDecoderFeed(private val onFrameRendered: (Long) -> Unit = {}) {
  companion object {
    private const val TAG = "DjiLinkDecoder"

    /** Vendor keys of the Qualcomm decoders of this headset family; refused configurations fall back */
    private const val QTI_LOW_LATENCY = "vendor.qti-ext-dec-low-latency.enable"
    private const val QTI_PICTURE_ORDER = "vendor.qti-ext-dec-picture-order.enable"
  }

  private var codec: MediaCodec? = null
  private val started = AtomicBoolean(false)

  var framesFed = 0L
    private set
  var framesRendered = 0L
    private set
  var lastError: String? = null
    private set
  var lowLatencyRequested = false
    private set

  val isRunning: Boolean get() = started.get()

  /**
   * Creates the decoder for [mime] rendering into [surface]. Returns false and sets [lastError] when the device has
   * no such decoder, which is an answer rather than a crash.
   */
  fun start(mime: String, width: Int, height: Int, surface: Surface): Boolean {
    if (started.get()) {
      return true
    }
    val format = MediaFormat.createVideoFormat(mime, width, height)
    val created = runCatching { MediaCodec.createDecoderByType(mime) }.getOrElse { error ->
      lastError = "no decoder for $mime: ${error.javaClass.simpleName}"
      return false
    }
    val supportsLowLatency = runCatching {
      created.codecInfo.getCapabilitiesForType(mime).isFeatureSupported(CodecCapabilities.FEATURE_LowLatency)
    }.getOrDefault(false)
    if (supportsLowLatency && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
      lowLatencyRequested = true
    }
    format.setInteger(QTI_LOW_LATENCY, 1)
    format.setInteger(QTI_PICTURE_ORDER, 1)
    created.setCallback(callback)
    val configured = runCatching { created.configure(format, surface, null, 0) }.isSuccess
    if (!configured) {
      // A vendor key the decoder refuses is not a failure: the same decoder is asked again without them
      runCatching { created.release() }
      val plain = runCatching { MediaCodec.createDecoderByType(mime) }.getOrElse { error ->
        lastError = "the decoder refused both configurations: ${error.javaClass.simpleName}"
        return false
      }
      val plainFormat = MediaFormat.createVideoFormat(mime, width, height)
      plain.setCallback(callback)
      val second = runCatching { plain.configure(plainFormat, surface, null, 0) }
      if (second.isFailure) {
        lastError = "the decoder refused the plain configuration too"
        runCatching { plain.release() }
        return false
      }
      lowLatencyRequested = false
      codec = plain
      plain.start()
      started.set(true)
      return true
    }
    codec = created
    created.start()
    started.set(true)
    return true
  }

  private val pending = ArrayDeque<Pair<ByteArray, Long>>()
  private val free = ArrayDeque<Int>()

  private val callback = object : MediaCodec.Callback() {
    override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
      synchronized(pending) {
        val next = pending.removeFirstOrNull()
        if (next == null) {
          free.addLast(index)
          return
        }
        writeInput(codec, index, next.first, next.second)
      }
    }

    override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
      // No audio clock and no reordering: whatever is ready is shown now
      runCatching { codec.releaseOutputBuffer(index, true) }
      framesRendered += 1
      onFrameRendered(info.presentationTimeUs)
    }

    override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
      lastError = "decoder error ${error.errorCode}"
      Log.w(TAG, "decoder error", error)
    }

    override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
      Log.i(TAG, "output format $format")
    }
  }

  private fun writeInput(codec: MediaCodec, index: Int, bytes: ByteArray, presentationUs: Long) {
    val buffer = runCatching { codec.getInputBuffer(index) }.getOrNull() ?: return
    buffer.clear()
    buffer.put(bytes)
    runCatching { codec.queueInputBuffer(index, 0, bytes.size, presentationUs, 0) }
    framesFed += 1
  }

  /** One access unit. The caller decides what an access unit is; this only hands it over. */
  fun feed(bytes: ByteArray, presentationUs: Long) {
    val current = codec ?: return
    synchronized(pending) {
      val index = free.removeFirstOrNull()
      if (index != null) {
        writeInput(current, index, bytes, presentationUs)
        return
      }
      pending.addLast(bytes to presentationUs)
      // Bounded: on this path a late picture is worth nothing, so the oldest ones go
      while (pending.size > 8) {
        pending.removeFirst()
      }
    }
  }

  fun stop() {
    if (!started.compareAndSet(true, false)) {
      return
    }
    val current = codec
    codec = null
    runCatching { current?.stop() }
    runCatching { current?.release() }
    synchronized(pending) {
      pending.clear()
      free.clear()
    }
  }
}
