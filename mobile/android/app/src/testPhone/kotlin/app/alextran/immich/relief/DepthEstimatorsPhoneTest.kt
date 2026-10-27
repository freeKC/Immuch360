package app.alextran.immich.relief

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

/**
 * The phone flavour has no depth engine (design 3.2 point 2, table of 3.5: "Not in this version of the app"): it says
 * so, for every path, and the parity check stops at once without remembering anything
 */
class DepthEstimatorsPhoneTest {
  @Test
  fun `the phone flavour has no engine`() {
    assertFalse(DepthEstimators.available)
    assertEquals("none", DepthEstimators.engine)
  }

  @Test
  fun `opening the model says it is not in this version, on both paths`() {
    for (path in DepthPath.entries) {
      try {
        DepthEstimators.open(File("depth_anything_v2_small.tflite"), path)
        fail()
      } catch (e: DepthEstimatorException) {
        assertEquals(DepthFailure.NOT_IN_THIS_VERSION, e.failure)
        assertEquals(path, e.path)
      }
    }
  }

  @Test
  fun `a relief on the phone flavour stops before the model and keeps nothing`() {
    val values = mutableMapOf<String, String>()
    val store =
      object : DepthPathStore {
        override fun read(key: String): String? = values[key]

        override fun write(key: String, value: String?) {
          if (value == null) values.remove(key) else values[key] = value
        }
      }
    val folder = Files.createTempDirectory("depth-phone").toFile()
    try {
      val model = File(folder, "depth_anything_v2_small.tflite").apply { writeBytes(byteArrayOf(1)) }
      val memory = DepthPathMemory(store, system = "phone", engine = DepthEstimators.engine)
      val check = GpuParityCheck(DepthEstimators, memory)
      try {
        check.estimate(
          model,
          "depth-anything-v2-small@651415f1",
          ReliefInput(FloatArray(ReliefPreprocess.TENSOR_SIZE), ReliefPreprocess.frameFor(4, 3)),
        )
        fail()
      } catch (e: DepthEstimatorException) {
        assertEquals(DepthFailure.NOT_IN_THIS_VERSION, e.failure)
      }
      assertNull(check.openPath)
      assertEquals(emptyMap<String, String>(), values)
    } finally {
      folder.deleteRecursively()
    }
  }
}
