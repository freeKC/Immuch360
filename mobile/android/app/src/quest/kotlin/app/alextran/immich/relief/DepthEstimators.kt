package app.alextran.immich.relief

import app.alextran.immich.BuildConfig
import com.google.ai.edge.litert.Accelerator
import com.google.ai.edge.litert.CompiledModel
import com.google.ai.edge.litert.TensorBuffer
import com.google.ai.edge.litert.TensorType
import java.io.File

// The depth model of the Meta Quest on LiteRT 2.3.0 (Apache 2.0, design-final 2026-10-26, section 3.2), in the quest
// flavour only: questImplementation of litert and litert-gpu in android/app/build.gradle. The CompiledModel API loads
// Depth Anything V2 Small, the fp32 export of litert-community, from the file the app downloaded.
//
// GPU path: ML Drift through OpenGL ES 3.1 (Horizon OS does not let an app load OpenCL since v71), with the precision
// forced to fp32: GpuOptions(precision = Precision.FP32) is the Kotlin form of GpuOptions(enforce_f32=True), the only
// configuration the model card validates ("substantially incorrect depth maps with the runtime's default GPU
// precision"). Read in the AAR by javap: CompiledModel$GpuOptions$Precision.FP32, native key PRECISION, value 2.
// CPU path: XNNPACK on 4 threads. GpuParityCheck decides which one this headset takes.
//
// LiteRT 2.3.0 is built with Kotlin 2.4 and the app with Kotlin 2.2.20, which reads class metadata up to 2.3 only: the
// Kotlin compilations of the quest flavour skip that check (-Xskip-metadata-version-check in build.gradle). Only plain
// calls are made here (constructors, named arguments, methods), which the 2.4 metadata describes as before.
//
// Every call into LiteRT goes through engineCall (relief/DepthEstimator.kt): a LiteRtException, a RuntimeException of
// its Java layer or a native library refused becomes a DepthEstimatorException, so that GpuParityCheck falls back to
// the CPU and closes the model whatever LiteRT threw.

/** LiteRT, the engine of the quest flavour */
object DepthEstimators : DepthEngine {
  /**
   * The version of LiteRT in the APK, from the version catalogue (gradle/libs.versions.toml, through a BuildConfig
   * field of the quest flavour in build.gradle), so that a LiteRT update is a new engine and gets a new parity check
   */
  val LITERT_VERSION: String = BuildConfig.LITERT_VERSION
  const val CPU_THREADS = 4

  /** The names of the input and the output of the export (serving_default signature of its model card) */
  const val INPUT_NAME = "args_0"
  const val OUTPUT_NAME = "output_0"

  private val INPUT_SHAPE = listOf(1, 3, ReliefPreprocess.INPUT_HEIGHT, ReliefPreprocess.INPUT_WIDTH)
  private val OUTPUT_SHAPE = listOf(1, ReliefPreprocess.INPUT_HEIGHT, ReliefPreprocess.INPUT_WIDTH)

  override val available = true
  override val engine = "litert-$LITERT_VERSION"

  override fun open(model: File, path: DepthPath): DepthEstimator {
    if (!model.isFile || !model.canRead()) {
      throw DepthEstimatorException(DepthFailure.MODEL_MISSING, path, "no readable model at ${model.path}")
    }
    val compiled =
      engineCall(DepthFailure.OPEN_FAILED, path, "LiteRT would not load the model") {
        CompiledModel.create(model.absolutePath, options(path))
      }
    try {
      checkShape("input", INPUT_SHAPE, path) { compiled.getInputTensorType(INPUT_NAME) }
      checkShape("output", OUTPUT_SHAPE, path) { compiled.getOutputTensorType(OUTPUT_NAME) }
      val inputs =
        engineCall(DepthFailure.OPEN_FAILED, path, "LiteRT made no input buffers") { compiled.createInputBuffers() }
      val outputs =
        try {
          engineCall(DepthFailure.OPEN_FAILED, path, "LiteRT made no output buffers") { compiled.createOutputBuffers() }
        } catch (e: DepthEstimatorException) {
          closeQuietly(inputs)
          throw e
        }
      return LiteRtEstimator(path, compiled, inputs, outputs)
    } catch (e: DepthEstimatorException) {
      closeQuietly(listOf(compiled))
      throw e
    }
  }

  private fun options(path: DepthPath): CompiledModel.Options =
    when (path) {
      DepthPath.GPU ->
        CompiledModel.Options(Accelerator.GPU).apply {
          gpuOptions =
            CompiledModel.GpuOptions(
              precision = CompiledModel.GpuOptions.Precision.FP32,
              backend = CompiledModel.GpuOptions.Backend.OPENGL,
            )
        }
      DepthPath.CPU ->
        CompiledModel.Options(Accelerator.CPU).apply { cpuOptions = CompiledModel.CpuOptions(numThreads = CPU_THREADS) }
    }

  /** The tensor [what] of the model must be float32 of [shape], else the file is not the model of this version */
  private fun checkShape(what: String, shape: List<Int>, path: DepthPath, type: () -> TensorType) {
    val found = engineCall(DepthFailure.WRONG_MODEL, path, "the model has no $what of this version", type)
    val dimensions = found.layout?.dimensions
    if (found.elementType != TensorType.ElementType.FLOAT || dimensions != shape) {
      throw DepthEstimatorException(
        DepthFailure.WRONG_MODEL,
        path,
        "the $what of the model is ${found.elementType} $dimensions, not FLOAT $shape",
      )
    }
  }
}

/** The model compiled on one path, with its input and output buffers made once */
private class LiteRtEstimator(
  override val path: DepthPath,
  private val model: CompiledModel,
  private val inputs: List<TensorBuffer>,
  private val outputs: List<TensorBuffer>,
) : DepthEstimator {
  private var closed = false

  override fun estimate(input: FloatArray): FloatArray {
    check(!closed) { "the depth model is closed" }
    require(input.size == ReliefPreprocess.TENSOR_SIZE) { "an input of ${ReliefPreprocess.TENSOR_SIZE} values" }
    val depth =
      engineCall(DepthFailure.RUN_FAILED, path, "the pass failed") {
        inputs[0].writeFloat(input)
        model.run(inputs, outputs)
        outputs[0].readFloat()
      }
    if (depth.size != ReliefPreprocess.INPUT_WIDTH * ReliefPreprocess.INPUT_HEIGHT) {
      throw DepthEstimatorException(DepthFailure.WRONG_MODEL, path, "a map of ${depth.size} values")
    }
    return depth
  }

  override fun close() {
    if (closed) return
    closed = true
    closeQuietly(inputs + outputs + model)
  }
}

/** Closes each of [natives], the next ones too when one fails: a buffer that will not close must not keep the model */
private fun closeQuietly(natives: List<AutoCloseable>) {
  for (native in natives) {
    try {
      native.close()
    } catch (e: Exception) {
      // Nothing more to free from it
    }
  }
}
