package app.alextran.immich.immersive.splat

import java.io.File
import kotlin.math.cos
import kotlin.math.sin
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The placement of the splat viewer of the computers, phones and tablets is a port of SplatPlacement
 * (mobile/assets/splat_viewer/placement.js). Both are held to mobile/test/fixtures/splat_viewer/viewer_expected.json
 * (.github/desktop/splat_viewer/make_viewer_fixtures.py): this test checks that the headset's own rules give what the
 * file says on the same positions, so that the expectations of the page come from the rules of the headset. The
 * headset's frame has z ahead and its module mirrors z: the target of the page is the headset's with z negated, its
 * pitch the headset's negated (SplatModuleFrame).
 */
class SplatPlacementViewerTest {
  private val expected: JsonObject by lazy {
    Json.parseToJsonElement(viewerFixture("viewer_expected.json").readText()).jsonObject
  }

  private fun viewerFixture(name: String): File {
    var dir: File? = File(System.getProperty("user.dir")).absoluteFile
    while (dir != null) {
      for (base in listOf("test/fixtures/splat_viewer", "mobile/test/fixtures/splat_viewer")) {
        val candidate = File(dir, "$base/$name")
        if (candidate.isFile) return candidate
      }
      dir = dir.parentFile
    }
    error("$name not found above ${System.getProperty("user.dir")}")
  }

  private fun doubles(case: JsonObject, vararg path: String): DoubleArray {
    var node: JsonObject = case
    for (key in path.dropLast(1)) node = node[key]!!.jsonObject
    return node[path.last()]!!.jsonArray.map { it.jsonPrimitive.double }.toDoubleArray()
  }

  private fun cases(): List<Pair<String, JsonObject>> =
    expected.entries.filter { it.key != "about" }.map { it.key to it.value.jsonObject }

  /** The scan of the sampled positions: the indices i * stride, as SplatReducer.scan samples them */
  private fun scanOf(case: JsonObject): SplatScan {
    val positions = doubles(case, "positions")
    val stride = case["stride"]!!.jsonPrimitive.int
    val samples = positions.size / 3
    return SplatScan(
      FloatArray(case["count"]!!.jsonPrimitive.int),
      IntArray(samples) { it * stride },
      FloatArray(positions.size) { positions[it].toFloat() },
    )
  }

  @Test
  fun `the headset's rules give the bounds, object or place and the floor rule of every case`() {
    val all = cases()
    assertTrue(all.size >= 8)
    for ((name, case) in all) {
      val bounds = SplatPlacement.boundsOf(scanOf(case), null)!!
      assertArrayEquals(name, doubles(case, "bounds", "low"), bounds.low, 1e-6)
      assertArrayEquals(name, doubles(case, "bounds", "high"), bounds.high, 1e-6)
      assertEquals(name, case["object"]!!.jsonPrimitive.boolean, SplatPlacement.isObject(bounds))
      assertEquals(name, case["size"]!!.jsonPrimitive.double, bounds.size, 1e-6)
      val floor = SplatPlacement.uprightOf(scanOf(case), null, bounds)
      assertEquals(name, case["floorUpright"]!!.jsonPrimitive.contentOrNull, floor?.key)
      assertEquals(name, case["upright"]!!.jsonPrimitive.content, (floor ?: SplatUpright.DEFAULT).key)
    }
  }

  @Test
  fun `the target of the page is the headset's with z ahead turned to -z, and its pitch the headset's negated`() {
    for ((name, case) in cases()) {
      val bounds = SplatPlacement.boundsOf(scanOf(case), null)!!
      val quest = SplatPlacement.target(bounds)
      assertArrayEquals(name, doubles(case, "questTarget"), quest, 1e-6)
      val upright = SplatUpright.of(case["upright"]!!.jsonPrimitive.content)!!
      val pitch = case["view"]!!.jsonObject["pitch"]!!.jsonPrimitive.double
      assertEquals(name, -Math.toRadians(upright.pitchDegrees.toDouble()), normalised(pitch, upright), 1e-9)
      // A place: the centre 0.3 m under the eyes where the user stands, the same on both
      if (!SplatPlacement.isObject(bounds)) {
        val page = doubles(case, "view", "target")
        assertEquals(name, quest[1], page[1] - 1.6, 1e-9)
        assertEquals(name, quest[2], -page[2], 1e-9)
      }
      // The centre as the module shows it, turned by the headset's pitch, lands on the headset's target; the page's
      // position turned the same way lands on the page's target
      val centre = bounds.center
      val position = doubles(case, "view", "position")
      val target = doubles(case, "view", "target")
      val turned = rotate(pitch, centre)
      for (axis in 0 until 3) assertEquals(name, target[axis], position[axis] + turned[axis], 1e-9)
    }
  }

  /** The pitch of the page for [upright]: Y down is pi or -pi, the same turn */
  private fun normalised(pitch: Double, upright: SplatUpright): Double =
    if (upright == SplatUpright.Y_DOWN && pitch > 0) -pitch else pitch

  private fun rotate(angle: Double, v: DoubleArray): DoubleArray =
    doubleArrayOf(v[0], v[1] * cos(angle) - v[2] * sin(angle), v[1] * sin(angle) + v[2] * cos(angle))
}
