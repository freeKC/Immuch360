package app.alextran.immich.relief

import java.io.File

// The depth model of the Meta Quest behind one interface (design-final 2026-10-26, section 3.2), so that the relief of
// the immersive view, the parity check of the GPU and their tests do not depend on the engine. LiteRT runs the model in
// the quest flavour (src/quest/kotlin/.../relief/DepthEstimators.kt); the phone flavour ships no engine and says so
// (src/phone/kotlin/.../relief/DepthEstimators.kt). Both define the object DepthEstimators, so that the code of main
// calls the same name whatever the flavour. Plain JVM code, without Android.

/** Where a pass of the model runs: the GPU of the headset (OpenGL ES, fp32) or its CPU (XNNPACK, 4 threads) */
enum class DepthPath {
  GPU,
  CPU,
}

/** Why there is no depth map */
enum class DepthFailure {
  /** This version of the app has no depth engine (the phone flavour) */
  NOT_IN_THIS_VERSION,

  /** The model file is missing or cannot be read */
  MODEL_MISSING,

  /** The file is not the model this version runs: its input or its output has another shape */
  WRONG_MODEL,

  /** The engine would not load the model on this path (the accelerator, the compilation) */
  OPEN_FAILED,

  /** A pass of the model failed */
  RUN_FAILED,
}

class DepthEstimatorException(
  val failure: DepthFailure,
  /** The path that failed, null when the failure is not tied to one */
  val path: DepthPath?,
  message: String,
  cause: Throwable? = null,
) : Exception(message, cause)

/**
 * The depth model open on one [path]. One pass at a time, always from the thread that opened it: the OpenGL context of
 * the GPU path belongs to that thread. [close] frees the model (about 375 MB on the CPU path, q0-measures 2).
 */
interface DepthEstimator : AutoCloseable {
  val path: DepthPath

  /**
   * The depth of [input], the NCHW float32 tensor of [ReliefPreprocess] ([ReliefPreprocess.TENSOR_SIZE] values): the
   * raw output of the model, [ReliefPreprocess.INPUT_WIDTH] x [ReliefPreprocess.INPUT_HEIGHT] values row after row, a
   * larger value nearer. Throws [DepthEstimatorException] with [DepthFailure.RUN_FAILED] or
   * [DepthFailure.WRONG_MODEL].
   */
  fun estimate(input: FloatArray): FloatArray

  override fun close()
}

/** What opens the depth model: LiteRT in the quest flavour, nothing in the phone flavour */
interface DepthEngine {
  /** Whether this version of the app has a depth engine */
  val available: Boolean

  /** The engine and its version ("litert-2.3.0"): another engine gets a new parity check */
  val engine: String

  /** The [model] open on [path]; throws [DepthEstimatorException] */
  fun open(model: File, path: DepthPath): DepthEstimator
}
