package app.alextran.immich.relief

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The path of the depth model on a headset (design 3.2 point 4): at the first relief the model runs on the CPU and on
 * the GPU with the same input, the two maps normalised by relief-v1 are compared (mean difference 0.01 at most, 99th
 * percentile 0.05 at most), and the GPU is kept only within both. The decision holds for the system build, the engine
 * and the model; a GPU that will not load or fails its first pass means the CPU. Fake engines, no LiteRT.
 */
class GpuParityCheckTest {
  private val folder: File = Files.createTempDirectory("gpu-parity").toFile()
  private val model = File(folder, "depth_anything_v2_small.tflite").apply { writeBytes(byteArrayOf(1, 2, 3)) }
  private val modelId = "depth-anything-v2-small@651415f1"
  private val store = MapStore()
  private val logs = mutableListOf<String>()
  private var nowNs = 0L

  private val width = ReliefPreprocess.INPUT_WIDTH
  private val height = ReliefPreprocess.INPUT_HEIGHT
  private val wholeFrame = ReliefFrame(0, 0, width, height)

  @After
  fun cleanUp() {
    folder.deleteRecursively()
  }

  /** The preferences of the app, in memory */
  private class MapStore : DepthPathStore {
    val values = mutableMapOf<String, String>()

    override fun read(key: String): String? = values[key]

    override fun write(key: String, value: String?) {
      if (value == null) values.remove(key) else values[key] = value
    }
  }

  /** A depth map of the model: a ramp, nearer to the right and to the bottom, as the CPU gives it */
  private fun ramp(): FloatArray = FloatArray(width * height) { i -> (i % width + 2 * (i / width)).toFloat() }

  /** An input tensor whose values differ from one place to the next, so that another array is told apart */
  private fun input(frame: ReliefFrame = wholeFrame) =
    ReliefInput(FloatArray(ReliefPreprocess.TENSOR_SIZE) { (it % 997) / 997f }, frame)

  /** A fake engine: what each path gives, and what fails */
  private inner class FakeEngine(
    var cpuDepth: () -> FloatArray = { ramp() },
    var gpuDepth: () -> FloatArray = { ramp() },
  ) : DepthEngine {
    override val available = true
    override var engine = "litert-2.3.0"

    /** Why the GPU will not open the model, null when it opens */
    var gpuOpenFailure: DepthFailure? = null
    var cpuOpenFails: DepthFailure? = null

    /** Why the failing GPU passes fail */
    var gpuRunFailure = DepthFailure.RUN_FAILED

    /** The input array each pass received, with its path, in order */
    val inputs = mutableListOf<Pair<DepthPath, FloatArray>>()

    /** The GPU passes that fail, counted from 1 over the whole test */
    val gpuRunsFailing = mutableSetOf<Int>()
    var gpuRuns = 0
    var cpuRuns = 0
    val opened = mutableListOf<DepthPath>()
    var openNow = 0
    var mostOpen = 0

    override fun open(model: File, path: DepthPath): DepthEstimator {
      if (path == DepthPath.GPU) {
        gpuOpenFailure?.let { throw DepthEstimatorException(it, path, "no OpenGL ES 3.1 context") }
      }
      if (path == DepthPath.CPU) {
        cpuOpenFails?.let { throw DepthEstimatorException(it, path, "not the model") }
      }
      opened += path
      openNow += 1
      mostOpen = maxOf(mostOpen, openNow)
      return object : DepthEstimator {
        override val path = path
        private var closed = false

        override fun estimate(input: FloatArray): FloatArray {
          check(!closed)
          nowNs += if (path == DepthPath.GPU) 700_000_000L else 2_500_000_000L
          inputs += path to input
          if (path == DepthPath.GPU) {
            gpuRuns += 1
            if (gpuRuns in gpuRunsFailing) {
              throw DepthEstimatorException(gpuRunFailure, path, "the GPU pass failed")
            }
            return gpuDepth()
          }
          cpuRuns += 1
          return cpuDepth()
        }

        override fun close() {
          if (!closed) {
            closed = true
            openNow -= 1
          }
        }
      }
    }
  }

  private val quest3 = "oculus/eureka/eureka:14/UP1A.231005.007.A1/1:user/release-keys"

  private fun memory(system: String = quest3, engine: String) =
    DepthPathMemory(store, system = system, engine = engine, wallMs = { 1_800_000_000_000L })

  private fun check(
    engine: DepthEngine,
    system: String = quest3,
    preferred: DepthPath = DepthPath.GPU,
  ) = GpuParityCheck(engine, memory(system, engine.engine), preferred, log = { logs += it }, nanoTime = { nowNs })

  // The comparison

  @Test
  fun `two maps that differ by scale and offset only are the same once normalised`() {
    val cpu = DoubleArray(100 * 100) { it.toDouble() }
    val gpu = DoubleArray(cpu.size) { cpu[it] * 2.5 + 3.0 }
    val same = GpuParityCheck.compare(gpu.toFloats(), cpu.toFloats(), 100, 100)
    assertEquals(0.0, same.meanError, 1e-6)
    assertEquals(0.0, same.p99Error, 1e-6)
    assertTrue(same.matches)
  }

  @Test
  fun `a little noise everywhere stays within the thresholds`() {
    val cpu = DoubleArray(100 * 100) { it.toDouble() }
    // 0.2 % of the relief, one pixel up, the next one down
    val gpu = DoubleArray(cpu.size) { cpu[it] + if (it % 2 == 0) 19.2 else -19.2 }
    val result = GpuParityCheck.compare(gpu.toFloats(), cpu.toFloats(), 100, 100)
    assertTrue("${result.meanError}", result.meanError in 0.001..0.003)
    assertTrue(result.matches)
  }

  @Test
  fun `a mean difference over 0_01 is not the same, even with a small 99th percentile`() {
    val cpu = DoubleArray(100 * 100) { it.toDouble() }
    // 2 % of the relief everywhere
    val gpu = DoubleArray(cpu.size) { cpu[it] + if (it % 2 == 0) 192.0 else -192.0 }
    val result = GpuParityCheck.compare(gpu.toFloats(), cpu.toFloats(), 100, 100)
    assertTrue("${result.meanError}", result.meanError > GpuParityCheck.MAX_MEAN_ERROR)
    assertTrue("${result.p99Error}", result.p99Error <= GpuParityCheck.MAX_P99_ERROR)
    assertFalse(result.matches)
  }

  @Test
  fun `a few pixels far off fail the 99th percentile although the mean is small`() {
    val cpu = DoubleArray(100 * 100) { it.toDouble() }
    val gpu = cpu.copyOf()
    // 150 pixels of the middle swap their depths with 150 others: the same values, so the same percentiles
    for (k in 0 until 75) {
      gpu[2000 + k] = cpu[7000 + k]
      gpu[7000 + k] = cpu[2000 + k]
    }
    val result = GpuParityCheck.compare(gpu.toFloats(), cpu.toFloats(), 100, 100)
    assertTrue("${result.meanError}", result.meanError <= GpuParityCheck.MAX_MEAN_ERROR)
    assertTrue("${result.p99Error}", result.p99Error > 0.5)
    assertFalse(result.matches)
  }

  @Test
  fun `the thresholds are inclusive`() {
    assertTrue(DepthComparison(0.01, 0.05).matches)
    assertFalse(DepthComparison(0.010001, 0.05).matches)
    assertFalse(DepthComparison(0.01, 0.050001).matches)
    assertEquals(0.01, GpuParityCheck.MAX_MEAN_ERROR, 0.0)
    assertEquals(0.05, GpuParityCheck.MAX_P99_ERROR, 0.0)
  }

  @Test
  fun `a GPU that gives no number is not the same`() {
    val cpu = DoubleArray(100 * 100) { it.toDouble() }
    val result = GpuParityCheck.compare(FloatArray(cpu.size) { Float.NaN }, cpu.toFloats(), 100, 100)
    assertFalse(result.matches)
  }

  @Test
  fun `maps of two sizes are refused`() {
    try {
      GpuParityCheck.compare(FloatArray(10), FloatArray(12), 2, 5)
      fail()
    } catch (expected: IllegalArgumentException) {}
  }

  // The first relief on a headset

  @Test
  fun `within the thresholds the GPU is kept, remembered, and stays open for the next photo`() {
    val engine = FakeEngine(gpuDepth = { ramp().map { it * 3f + 7f }.toFloatArray() })
    val parityCheck = check(engine)
    val photo = input()
    val pass = parityCheck.estimate(model, modelId, photo)
    assertEquals(DepthPath.GPU, pass.path)
    val parity = pass.parity!!
    assertEquals(ParityVerdict.SAME, parity.verdict)
    assertEquals(DepthPath.GPU, parity.chosen)
    assertTrue(parity.comparison!!.matches)
    // The map given is the GPU's
    assertEquals(7f, pass.depth[0], 0f)
    // One CPU pass and one GPU pass with the same input, never two models open at once
    assertEquals(listOf(DepthPath.CPU, DepthPath.GPU), engine.opened)
    assertEquals(listOf(DepthPath.CPU, DepthPath.GPU), engine.inputs.map { it.first })
    assertSame(photo.tensor, engine.inputs[0].second)
    assertSame(photo.tensor, engine.inputs[1].second)
    assertEquals(1, engine.cpuRuns)
    assertEquals(1, engine.gpuRuns)
    assertEquals(1, engine.mostOpen)
    assertEquals(DepthPath.GPU, parityCheck.openPath)
    assertEquals(DepthPath.GPU, memory(engine = engine.engine).path(modelId))
    // The next photo: the GPU model already open, nothing compared
    val next = parityCheck.estimate(model, modelId, input())
    assertEquals(DepthPath.GPU, next.path)
    assertNull(next.parity)
    assertEquals(listOf(DepthPath.CPU, DepthPath.GPU), engine.opened)
    assertEquals(1, engine.cpuRuns)
    assertEquals(2, engine.gpuRuns)
    parityCheck.close()
    assertEquals(0, engine.openNow)
    assertNull(parityCheck.openPath)
  }

  @Test
  fun `out of the thresholds the CPU is kept and remembered, and its map is the one given`() {
    val engine = FakeEngine(gpuDepth = { FloatArray(width * height) { i -> ((i * 7919) % 1000).toFloat() } })
    val parity = check(engine)
    val pass = parity.estimate(model, modelId, input())
    assertEquals(DepthPath.CPU, pass.path)
    assertEquals(ParityVerdict.DIFFERENT, pass.parity?.verdict)
    assertEquals(DepthPath.CPU, pass.parity?.chosen)
    assertEquals(false, pass.parity?.comparison?.matches)
    assertArrayEquals(ramp(), pass.depth, 0f)
    assertEquals(DepthPath.CPU, memory(engine = engine.engine).path(modelId))
    assertEquals(0, engine.openNow)
    // The next photo opens the CPU model only
    val next = parity.estimate(model, modelId, input())
    assertEquals(DepthPath.CPU, next.path)
    assertNull(next.parity)
    assertEquals(listOf(DepthPath.CPU, DepthPath.GPU, DepthPath.CPU), engine.opened)
    assertEquals(1, engine.gpuRuns)
    assertEquals(1, engine.mostOpen)
    parity.close()
  }

  @Test
  fun `the maps are compared on the photo, not on the background around a portrait`() {
    // A portrait keeps its proportions: 389 x 518 in the middle of the input, the background differs
    val frame = ReliefPreprocess.frameFor(3, 4)
    val engine =
      FakeEngine(
        gpuDepth = {
          val map = ramp()
          for (i in map.indices) {
            val x = i % width
            if (x < frame.x || x >= frame.x + frame.width) map[i] = -1000f
          }
          map
        }
      )
    val pass = check(engine).estimate(model, modelId, input(frame))
    assertEquals(ParityVerdict.SAME, pass.parity?.verdict)
    assertEquals(DepthPath.GPU, pass.path)
  }

  @Test
  fun `a GPU that will not load means the CPU, remembered`() {
    val engine = FakeEngine().apply { gpuOpenFailure = DepthFailure.OPEN_FAILED }
    val pass = check(engine).estimate(model, modelId, input())
    assertEquals(DepthPath.CPU, pass.path)
    assertEquals(ParityVerdict.GPU_FAILED, pass.parity?.verdict)
    assertNull(pass.parity?.comparison)
    assertArrayEquals(ramp(), pass.depth, 0f)
    assertEquals(DepthPath.CPU, memory(engine = engine.engine).path(modelId))
    assertTrue(logs.joinToString("\n"), logs.any { it.contains("no OpenGL ES 3.1 context") })
  }

  @Test
  fun `a GPU whose first pass fails means the CPU, remembered`() {
    val engine = FakeEngine().apply { gpuRunsFailing += 1 }
    val parity = check(engine)
    val pass = parity.estimate(model, modelId, input())
    assertEquals(DepthPath.CPU, pass.path)
    assertEquals(ParityVerdict.GPU_FAILED, pass.parity?.verdict)
    assertEquals(DepthPath.CPU, memory(engine = engine.engine).path(modelId))
    assertEquals(0, engine.openNow)
    parity.close()
  }

  @Test
  fun `a GPU that says the model is wrong after the CPU took it means the CPU, remembered`() {
    // The CPU opened the same file with the right shapes: a refusal on the GPU comes from the accelerator
    val engine = FakeEngine().apply { gpuOpenFailure = DepthFailure.WRONG_MODEL }
    val parity = check(engine)
    val pass = parity.estimate(model, modelId, input())
    assertEquals(DepthPath.CPU, pass.path)
    assertEquals(ParityVerdict.GPU_FAILED, pass.parity?.verdict)
    assertArrayEquals(ramp(), pass.depth, 0f)
    assertEquals(DepthPath.CPU, memory(engine = engine.engine).path(modelId))
    // The next photo goes to the CPU without trying the GPU again
    val next = parity.estimate(model, modelId, input())
    assertEquals(DepthPath.CPU, next.path)
    assertNull(next.parity)
    assertEquals(listOf(DepthPath.CPU, DepthPath.CPU), engine.opened)
    assertEquals(2, engine.cpuRuns)
    parity.close()
    assertEquals(0, engine.openNow)
  }

  @Test
  fun `a first GPU pass that says the model is wrong means the CPU, remembered`() {
    val engine =
      FakeEngine().apply {
        gpuRunsFailing += 1
        gpuRunFailure = DepthFailure.WRONG_MODEL
      }
    val pass = check(engine).estimate(model, modelId, input())
    assertEquals(DepthPath.CPU, pass.path)
    assertEquals(ParityVerdict.GPU_FAILED, pass.parity?.verdict)
    assertEquals(DepthPath.CPU, memory(engine = engine.engine).path(modelId))
    assertEquals(0, engine.openNow)
  }

  @Test
  fun `a GPU map of another size than the CPU one means the CPU, remembered`() {
    val engine = FakeEngine(gpuDepth = { FloatArray(10) })
    val pass = check(engine).estimate(model, modelId, input())
    assertEquals(DepthPath.CPU, pass.path)
    assertEquals(ParityVerdict.GPU_FAILED, pass.parity?.verdict)
    assertArrayEquals(ramp(), pass.depth, 0f)
    assertEquals(DepthPath.CPU, memory(engine = engine.engine).path(modelId))
    assertEquals(0, engine.openNow)
  }

  @Test
  fun `a CPU that refuses the model stops the check, and nothing is remembered`() {
    val engine = FakeEngine().apply { cpuOpenFails = DepthFailure.WRONG_MODEL }
    try {
      check(engine).estimate(model, modelId, input())
      fail()
    } catch (e: DepthEstimatorException) {
      assertEquals(DepthFailure.WRONG_MODEL, e.failure)
    }
    assertNull(memory(engine = engine.engine).path(modelId))
    assertEquals(emptyList<DepthPath>(), engine.opened)
    assertEquals(0, engine.gpuRuns)
  }

  @Test
  fun `a model of another size is refused before any comparison`() {
    val engine = FakeEngine(cpuDepth = { FloatArray(10) })
    try {
      check(engine).estimate(model, modelId, input())
      fail()
    } catch (e: DepthEstimatorException) {
      assertEquals(DepthFailure.WRONG_MODEL, e.failure)
    }
    assertNull(memory(engine = engine.engine).path(modelId))
    assertEquals(0, engine.openNow)
  }

  // What the headset remembers

  @Test
  fun `a remembered GPU skips the CPU pass, in a later session too`() {
    val first = FakeEngine()
    check(first).estimate(model, modelId, input())
    val engine = FakeEngine()
    val pass = check(engine).estimate(model, modelId, input())
    assertEquals(DepthPath.GPU, pass.path)
    assertNull(pass.parity)
    assertEquals(listOf(DepthPath.GPU), engine.opened)
    assertEquals(0, engine.cpuRuns)
  }

  @Test
  fun `a remembered CPU never opens the GPU`() {
    check(FakeEngine().apply { gpuOpenFailure = DepthFailure.OPEN_FAILED }).estimate(model, modelId, input())
    val engine = FakeEngine()
    val pass = check(engine).estimate(model, modelId, input())
    assertEquals(DepthPath.CPU, pass.path)
    assertNull(pass.parity)
    assertEquals(listOf(DepthPath.CPU), engine.opened)
  }

  @Test
  fun `a system update checks again`() {
    check(FakeEngine().apply { gpuOpenFailure = DepthFailure.OPEN_FAILED }).estimate(model, modelId, input())
    val engine = FakeEngine()
    val updated = "oculus/eureka/eureka:14/UP1A.231005.007.A1/2:user/release-keys"
    val pass = check(engine, system = updated).estimate(model, modelId, input())
    assertEquals(ParityVerdict.SAME, pass.parity?.verdict)
    assertEquals(DepthPath.GPU, pass.path)
    assertEquals(listOf(DepthPath.CPU, DepthPath.GPU), engine.opened)
    assertEquals(DepthPath.GPU, memory(system = updated, engine = engine.engine).path(modelId))
    // The old build's decision is not read by the new one, and the new one's not by the old
    assertNull(memory(engine = engine.engine).path(modelId))
  }

  @Test
  fun `another model or another engine checks again`() {
    check(FakeEngine().apply { gpuOpenFailure = DepthFailure.OPEN_FAILED }).estimate(model, modelId, input())
    val otherModel = check(FakeEngine()).estimate(model, "depth-anything-v2-small@0badc0de", input())
    assertEquals(ParityVerdict.SAME, otherModel.parity?.verdict)
    // The first model keeps its own decision
    assertEquals(DepthPath.CPU, memory(engine = "litert-2.3.0").path(modelId))
    // An app update with another engine checks again, and its decision replaces the old one
    val newEngine = check(FakeEngine().apply { engine = "litert-2.4.0" }).estimate(model, modelId, input())
    assertEquals(ParityVerdict.SAME, newEngine.parity?.verdict)
    assertEquals(DepthPath.GPU, memory(engine = "litert-2.4.0").path(modelId))
    assertNull(memory(engine = "litert-2.3.0").path(modelId))
  }

  @Test
  fun `the memory is kept by system build, engine and model, and can be forgotten`() {
    val memory = memory(engine = "litert-2.3.0")
    assertNull(memory.path(modelId))
    memory.remember(modelId, DepthPath.CPU)
    assertEquals(DepthPath.CPU, memory.path(modelId))
    assertEquals(setOf(DepthPathMemory.KEY_PREFIX + modelId), store.values.keys)
    memory.remember(modelId, DepthPath.GPU)
    assertEquals(DepthPath.GPU, memory.path(modelId))
    assertNull(memory(system = "another build", engine = "litert-2.3.0").path(modelId))
    assertNull(memory(engine = "litert-2.3.2").path(modelId))
    memory.forget(modelId)
    assertNull(memory.path(modelId))
    assertTrue(store.values.isEmpty())
    // Whatever else the preferences hold is no decision
    store.values[DepthPathMemory.KEY_PREFIX + modelId] = "garbage"
    assertNull(memory.path(modelId))
  }

  // Later failures

  @Test
  fun `a remembered GPU that will not load gives its session to the CPU, and the next session checks again`() {
    check(FakeEngine()).estimate(model, modelId, input())
    val engine = FakeEngine().apply { gpuOpenFailure = DepthFailure.OPEN_FAILED }
    val session = check(engine)
    val pass = session.estimate(model, modelId, input())
    assertEquals(DepthPath.CPU, pass.path)
    assertNull(pass.parity)
    assertArrayEquals(ramp(), pass.depth, 0f)
    // One failure, perhaps passing, does not put the headset on the CPU until the next system update
    assertNull(memory(engine = engine.engine).path(modelId))
    // The rest of the session is on the CPU, the GPU not tried again
    assertEquals(DepthPath.CPU, session.estimate(model, modelId, input()).path)
    assertEquals(listOf(DepthPath.CPU), engine.opened)
    assertEquals(2, engine.cpuRuns)
    session.close()
    // The next session runs the parity check again; a GPU that works again is kept again
    val again = FakeEngine()
    assertEquals(ParityVerdict.SAME, check(again).estimate(model, modelId, input()).parity?.verdict)
    assertEquals(listOf(DepthPath.CPU, DepthPath.GPU), again.opened)
    assertEquals(DepthPath.GPU, memory(engine = again.engine).path(modelId))
  }

  @Test
  fun `a remembered GPU that fails again at the check of the next session means the CPU, remembered`() {
    check(FakeEngine()).estimate(model, modelId, input())
    check(FakeEngine().apply { gpuOpenFailure = DepthFailure.OPEN_FAILED }).estimate(model, modelId, input())
    val pass = check(FakeEngine().apply { gpuOpenFailure = DepthFailure.OPEN_FAILED }).estimate(model, modelId, input())
    assertEquals(DepthPath.CPU, pass.path)
    assertEquals(ParityVerdict.GPU_FAILED, pass.parity?.verdict)
    assertEquals(DepthPath.CPU, memory(engine = "litert-2.3.0").path(modelId))
  }

  @Test
  fun `a remembered GPU that says the model is wrong gives the photo to the CPU instead of failing`() {
    check(FakeEngine()).estimate(model, modelId, input())
    for (failure in listOf(DepthFailure.WRONG_MODEL, DepthFailure.RUN_FAILED)) {
      val engine =
        FakeEngine().apply {
          gpuRunsFailing += 1
          gpuRunFailure = failure
        }
      val pass = check(engine).estimate(model, modelId, input())
      assertEquals(failure.name, DepthPath.CPU, pass.path)
      assertArrayEquals(ramp(), pass.depth, 0f)
      assertEquals(listOf(DepthPath.GPU, DepthPath.CPU), engine.opened)
      // The CPU model stays open for the next photo, the GPU one is closed
      assertEquals(1, engine.openNow)
      // Put the decision back for the next round
      memory(engine = engine.engine).remember(modelId, DepthPath.GPU)
    }
  }

  @Test
  fun `a GPU that fails after good passes gives this photo to the CPU without changing the decision`() {
    val engine = FakeEngine().apply { gpuRunsFailing += 3 }
    val parity = check(engine)
    assertEquals(DepthPath.GPU, parity.estimate(model, modelId, input()).path)
    assertEquals(DepthPath.GPU, parity.estimate(model, modelId, input()).path)
    val third = parity.estimate(model, modelId, input())
    assertEquals(DepthPath.CPU, third.path)
    assertNull(third.parity)
    assertArrayEquals(ramp(), third.depth, 0f)
    assertEquals(DepthPath.GPU, memory(engine = engine.engine).path(modelId))
    // The rest of this session stays on the CPU, one model open at a time
    assertEquals(DepthPath.CPU, parity.estimate(model, modelId, input()).path)
    assertEquals(3, engine.gpuRuns)
    assertEquals(3, engine.cpuRuns)
    assertEquals(1, engine.mostOpen)
    parity.close()
    assertEquals(0, engine.openNow)
  }

  @Test
  fun `the GPU that passed the check and fails at the next photo keeps the decision`() {
    val engine = FakeEngine().apply { gpuRunsFailing += 2 }
    val parity = check(engine)
    assertEquals(ParityVerdict.SAME, parity.estimate(model, modelId, input()).parity?.verdict)
    val second = parity.estimate(model, modelId, input())
    assertEquals(DepthPath.CPU, second.path)
    assertNull(second.parity)
    assertEquals(DepthPath.GPU, memory(engine = engine.engine).path(modelId))
    parity.close()
  }

  // Around the check

  @Test
  fun `with the CPU preferred the GPU is never opened and nothing is remembered`() {
    val engine = FakeEngine()
    val pass = check(engine, preferred = DepthPath.CPU).estimate(model, modelId, input())
    assertEquals(DepthPath.CPU, pass.path)
    assertNull(pass.parity)
    assertEquals(listOf(DepthPath.CPU), engine.opened)
    assertTrue(store.values.isEmpty())
  }

  @Test
  fun `a missing model is said before anything opens`() {
    val engine = FakeEngine()
    try {
      check(engine).estimate(File(folder, "missing.tflite"), modelId, input())
      fail()
    } catch (e: DepthEstimatorException) {
      assertEquals(DepthFailure.MODEL_MISSING, e.failure)
    }
    assertEquals(emptyList<DepthPath>(), engine.opened)
  }

  @Test
  fun `another model closes the open one first`() {
    val engine = FakeEngine()
    val parity = check(engine, preferred = DepthPath.CPU)
    parity.estimate(model, modelId, input())
    val other = File(folder, "other.tflite").apply { writeBytes(byteArrayOf(4)) }
    parity.estimate(other, "depth-anything-v2-small@0badc0de", input())
    assertEquals(listOf(DepthPath.CPU, DepthPath.CPU), engine.opened)
    assertEquals(1, engine.mostOpen)
    parity.close()
    assertEquals(0, engine.openNow)
  }

  @Test
  fun `the path taken and the time of each pass go to the log`() {
    val engine = FakeEngine()
    val pass = check(engine).estimate(model, modelId, input())
    assertEquals(700L, pass.elapsedMs)
    val text = logs.joinToString("\n")
    assertTrue(text, text.contains("CPU pass in 2500 ms"))
    assertTrue(text, text.contains("GPU pass in 700 ms"))
    assertTrue(text, text.contains("GPU kept"))
  }

  @Test
  fun `an input of the wrong size is refused`() {
    try {
      check(FakeEngine()).estimate(model, modelId, ReliefInput(FloatArray(12), wholeFrame))
      fail()
    } catch (expected: IllegalArgumentException) {}
  }

  @Test
  fun `the depth array given is the engine's own, not a copy`() {
    val map = ramp()
    val engine = FakeEngine(cpuDepth = { map })
    assertSame(map, check(engine, preferred = DepthPath.CPU).estimate(model, modelId, input()).depth)
  }

  private fun DoubleArray.toFloats() = FloatArray(size) { this[it].toFloat() }
}
