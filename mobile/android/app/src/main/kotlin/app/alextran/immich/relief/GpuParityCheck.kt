package app.alextran.immich.relief

import java.io.File
import java.util.Locale
import kotlin.math.abs

// Which path the depth model of the Meta Quest takes on this headset (design-final 2026-10-26, section 3.2 points 3 and
// 4). The model card of the LiteRT export asks to check the GPU against the CPU on the target device, so the first
// relief runs the model on both with the same input and compares the two maps: the GPU is kept only when they agree.
// The decision is kept in the app's preferences against the system build, the engine and the model, on the model of
// DecoderMemory (djilink/DecoderPolicy.kt): a system update, a new engine or a new model checks again. A GPU that will
// not load or fails its first pass means the CPU: design 3.2 point 3 asks for the CPU whenever the accelerator fails.
// Plain JVM code, without Android.

/** How far apart two normalised depth maps are: the mean of the differences and their 99th percentile */
class DepthComparison(val meanError: Double, val p99Error: Double) {
  /** Within both thresholds of the design */
  val matches: Boolean
    get() = meanError <= GpuParityCheck.MAX_MEAN_ERROR && p99Error <= GpuParityCheck.MAX_P99_ERROR

  override fun toString(): String = "mean %.4f, 99th percentile %.4f".format(Locale.ROOT, meanError, p99Error)
}

/** What the parity check found */
enum class ParityVerdict {
  /** The two maps agree: the GPU is kept */
  SAME,

  /** The two maps differ: the CPU is kept */
  DIFFERENT,

  /**
   * The GPU would not load the model, refused it or failed its first pass, after the CPU took the same file: the CPU
   * is kept
   */
  GPU_FAILED,
}

/** The parity check that ran during a pass: what it found, the path it chose, and the comparison when there was one */
class ParityResult(val verdict: ParityVerdict, val chosen: DepthPath, val comparison: DepthComparison?)

/**
 * A depth map of the model: [depth] as the engine gave it ([ReliefPreprocess.INPUT_WIDTH] x
 * [ReliefPreprocess.INPUT_HEIGHT], to cut back with [ReliefPreprocess.cropDepth]), the [path] it came from, the time
 * of that pass, and the parity check when it ran during this pass
 */
class DepthPass(val depth: FloatArray, val path: DepthPath, val elapsedMs: Long, val parity: ParityResult?)

/** The app's own preferences, behind an interface so that the tests keep them in memory */
interface DepthPathStore {
  fun read(key: String): String?

  fun write(key: String, value: String?)
}

/**
 * The path the parity check chose for each model, kept in the app's preferences. An entry holds for the [system] build
 * it was written under (`Build.FINGERPRINT`) and the [engine] ("litert-2.3.0"): a system update or another engine gets
 * a new check, since either may change what the GPU computes. The model is the key: its identifier carries the start of
 * its SHA-256 ("depth-anything-v2-small@651415f1"), so another model file is checked on its own.
 */
class DepthPathMemory(
  private val store: DepthPathStore,
  private val system: String,
  private val engine: String,
  private val wallMs: () -> Long = { System.currentTimeMillis() },
) {
  companion object {
    const val KEY_PREFIX = "relief.depthPath."

    /** The name of the app's preferences file the headset keeps them in */
    const val PREFERENCES = "ai_relief"

    /** A character neither a build fingerprint nor an engine name holds */
    private const val SEPARATOR = "\u001f"
  }

  /** The path chosen for [modelId] on this system build and engine, null when there is none yet */
  fun path(modelId: String): DepthPath? {
    val fields = store.read(KEY_PREFIX + modelId)?.split(SEPARATOR) ?: return null
    if (fields.size < 3 || fields[0] != system || fields[1] != engine) {
      return null
    }
    return DepthPath.entries.firstOrNull { it.name == fields[2] }
  }

  fun remember(modelId: String, path: DepthPath) {
    store.write(KEY_PREFIX + modelId, listOf(system, engine, path.name, wallMs().toString()).joinToString(SEPARATOR))
  }

  fun forget(modelId: String) {
    store.write(KEY_PREFIX + modelId, null)
  }
}

/**
 * The depth model of the headset, on the path this headset should take, at most one model open at a time.
 *
 * 1. **First relief** (no decision in [memory]): the model runs on the CPU, is closed, then runs on the GPU with the
 *    same input. The two maps, cut back to the photo and normalised by relief-v1 step 1, are compared: mean difference
 *    [MAX_MEAN_ERROR] at most and 99th percentile [MAX_P99_ERROR] at most keep the GPU, open for the next photos;
 *    otherwise the CPU is kept. The CPU goes first so that the model kept is the one left open, and so that two
 *    models (about 375 MB each on the CPU, q0-measures 2) are never loaded together. This first relief costs one CPU
 *    pass more, once per system build.
 * 2. **GPU remembered**: the GPU model opens; if it will not load or fails before a first good pass in this session,
 *    the photo and the rest of the session go to the CPU and the decision is forgotten, so that the next session
 *    runs the parity check again: a passing failure (the GPU memory held by the immersive scene, an OpenGL context
 *    refused for a moment) does not put the headset on the CPU until the next system update, and a GPU that fails
 *    again at that check means the CPU, remembered. A GPU that fails after good passes gives that photo and the rest
 *    of the session to the CPU without changing the decision.
 * 3. **CPU remembered**, or [preferred] CPU: the GPU is never opened.
 *
 * On the GPU path any [DepthEstimatorException] is a failure of the accelerator, [DepthFailure.WRONG_MODEL] included:
 * the CPU took the same file. A failure of the CPU path, or a CPU map of another size, stops the pass with
 * [DepthEstimatorException] and keeps no decision. The path taken and the time of each pass go to [log] (the app's log
 * on the headset). One thread only: the one that runs the relief (the OpenGL context of the GPU path belongs to it).
 * [close] frees the model; the next [estimate] opens it again.
 */
class GpuParityCheck(
  private val engine: DepthEngine,
  private val memory: DepthPathMemory,
  private val preferred: DepthPath = PREFERRED_PATH,
  private val log: (String) -> Unit = {},
  private val nanoTime: () -> Long = { System.nanoTime() },
) : AutoCloseable {
  companion object {
    const val MAX_MEAN_ERROR = 0.01
    const val MAX_P99_ERROR = 0.05

    /**
     * The path tried first. Provisional: Q0 could not measure the Quest 3 (q0-measures-2026-10-26.md, section 4 point
     * 4). If the GPU through OpenGL takes more than 1.5 s and the CPU less than 5 s, this becomes CPU.
     */
    val PREFERRED_PATH = DepthPath.GPU

    private const val DEPTH_SIZE = ReliefPreprocess.INPUT_WIDTH * ReliefPreprocess.INPUT_HEIGHT

    /**
     * How far apart the maps [gpu] and [cpu] of [width] x [height] are once each is normalised by relief-v1 step 1:
     * the mean of the absolute differences and their 99th percentile (nearest rank, as the percentiles of relief-v1).
     * Normalising first leaves out a change of scale or offset, which relief-v1 ignores anyway.
     */
    fun compare(gpu: FloatArray, cpu: FloatArray, width: Int, height: Int): DepthComparison {
      require(gpu.size == width * height && cpu.size == width * height) { "two maps of $width x $height" }
      val a = ReliefSynthesizer.normalize(gpu, width, height).values
      val b = ReliefSynthesizer.normalize(cpu, width, height).values
      val differences = DoubleArray(a.size) { abs(a[it] - b[it]) }
      val mean = differences.sum() / differences.size
      differences.sort()
      return DepthComparison(mean, ReliefSynthesizer.percentile(differences, 99))
    }
  }

  private var open: DepthEstimator? = null
  private var openModel: File? = null

  /** The model of this session that gave a good GPU pass, so a later GPU failure does not change the decision */
  private var gpuPassedFor: String? = null

  /** The model of this session whose GPU failed after good passes: the rest of the session is on the CPU */
  private var gpuDroppedFor: String? = null

  /** The path of the open model, null when none is open */
  val openPath: DepthPath?
    get() = open?.path

  /** The depth of [input] by the [model] whose identifier is [modelId]; throws [DepthEstimatorException] */
  fun estimate(model: File, modelId: String, input: ReliefInput): DepthPass {
    require(input.tensor.size == ReliefPreprocess.TENSOR_SIZE) { "an input of ${ReliefPreprocess.TENSOR_SIZE} values" }
    if (!engine.available) {
      throw DepthEstimatorException(DepthFailure.NOT_IN_THIS_VERSION, null, "no depth engine in this version")
    }
    if (!model.isFile) {
      throw DepthEstimatorException(DepthFailure.MODEL_MISSING, null, "no model at ${model.path}")
    }
    if (openModel != null && openModel != model) {
      closeOpen()
    }
    if (preferred == DepthPath.CPU || gpuDroppedFor == modelId) {
      return pass(model, DepthPath.CPU, input)
    }
    return when (memory.path(modelId)) {
      DepthPath.CPU -> pass(model, DepthPath.CPU, input)
      DepthPath.GPU -> rememberedGpu(model, modelId, input)
      null -> firstRelief(model, modelId, input)
    }
  }

  /** Frees the model; what this session learnt of the GPU stays until the object goes */
  override fun close() {
    closeOpen()
  }

  private fun rememberedGpu(model: File, modelId: String, input: ReliefInput): DepthPass {
    val failure =
      try {
        val gpu = pass(model, DepthPath.GPU, input)
        gpuPassedFor = modelId
        return gpu
      } catch (e: DepthEstimatorException) {
        e
      }
    closeOpen()
    gpuDroppedFor = modelId
    if (gpuPassedFor == modelId) {
      log("depth model: the GPU failed after good passes (${failure.message}), the CPU takes this session")
    } else {
      log("depth model: the GPU failed (${failure.message}), the CPU takes this session, the next one checks again")
      memory.forget(modelId)
    }
    return pass(model, DepthPath.CPU, input)
  }

  private fun firstRelief(model: File, modelId: String, input: ReliefInput): DepthPass {
    log("depth model: first relief with $modelId on ${engine.engine}, the GPU is checked against the CPU")
    // Opening the GPU model closes the CPU one first
    val cpu = pass(model, DepthPath.CPU, input)
    val gpu =
      try {
        pass(model, DepthPath.GPU, input)
      } catch (e: DepthEstimatorException) {
        // The CPU took the same file: whatever the GPU says, the accelerator failed
        closeOpen()
        log("depth model: the GPU failed (${e.message}), the CPU is kept for $modelId")
        memory.remember(modelId, DepthPath.CPU)
        return cpu.withParity(ParityVerdict.GPU_FAILED, null)
      }
    val frame = input.frame
    val comparison =
      compare(
        ReliefPreprocess.cropDepth(gpu.depth, frame),
        ReliefPreprocess.cropDepth(cpu.depth, frame),
        frame.width,
        frame.height,
      )
    if (comparison.matches) {
      log("depth model: GPU kept for $modelId, $comparison")
      memory.remember(modelId, DepthPath.GPU)
      gpuPassedFor = modelId
      return gpu.withParity(ParityVerdict.SAME, comparison)
    }
    closeOpen()
    log("depth model: the GPU map differs from the CPU map ($comparison), the CPU is kept for $modelId")
    memory.remember(modelId, DepthPath.CPU)
    return cpu.withParity(ParityVerdict.DIFFERENT, comparison)
  }

  /** One pass on [path], the model of that path opened first unless it is the open one */
  private fun pass(model: File, path: DepthPath, input: ReliefInput): DepthPass {
    val estimator = open?.takeIf { it.path == path } ?: openOn(model, path)
    val start = nanoTime()
    val depth =
      try {
        estimator.estimate(input.tensor)
      } catch (e: DepthEstimatorException) {
        closeOpen()
        throw e
      }
    val elapsedMs = (nanoTime() - start) / 1_000_000
    if (depth.size != DEPTH_SIZE) {
      closeOpen()
      throw DepthEstimatorException(DepthFailure.WRONG_MODEL, path, "a map of ${depth.size} values, not $DEPTH_SIZE")
    }
    log("depth model: $path pass in $elapsedMs ms")
    return DepthPass(depth, path, elapsedMs, null)
  }

  private fun openOn(model: File, path: DepthPath): DepthEstimator {
    closeOpen()
    val start = nanoTime()
    val estimator = engine.open(model, path)
    log("depth model: open on $path (${engine.engine}) in ${(nanoTime() - start) / 1_000_000} ms")
    open = estimator
    openModel = model
    return estimator
  }

  /** This pass, chosen by the parity check */
  private fun DepthPass.withParity(verdict: ParityVerdict, comparison: DepthComparison?) =
    DepthPass(depth, path, elapsedMs, ParityResult(verdict, path, comparison))

  private fun closeOpen() {
    val estimator = open
    open = null
    openModel = null
    estimator?.close()
  }
}
