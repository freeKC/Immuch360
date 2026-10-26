package app.alextran.immich.relief

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * The fixtures of the AI relief that the Dart and the Kotlin tests share, in mobile/test/fixtures/ai_immersive. Found
 * by walking up from the working directory: Gradle runs the unit tests from mobile/android/app, the tests compiled
 * without Gradle may run from elsewhere in the repository.
 */
object ReliefFixtures {
  fun file(name: String): File {
    var dir: File? = File(System.getProperty("user.dir")).absoluteFile
    while (dir != null) {
      for (base in listOf("test/fixtures/ai_immersive", "mobile/test/fixtures/ai_immersive")) {
        val candidate = File(dir, "$base/$name")
        if (candidate.isFile) return candidate
      }
      dir = dir.parentFile
    }
    error("$name not found above ${System.getProperty("user.dir")}")
  }

  fun json(name: String): JsonObject = Json.parseToJsonElement(file(name).readText()).jsonObject
}

/** One case of relief_golden_v1.json, the fixture written by .github/desktop/ai/make_relief_golden.py */
class GoldenCase(json: JsonObject, val eyeWidth: Int, val eyeHeight: Int, val mapWidth: Int, val mapHeight: Int) {
  val name = json.string("name")
  val parallax = json.number("parallax")
  val convergence = json.number("convergence")

  /** The photo as ARGB pixels, opaque, row after row */
  val image: IntArray =
    json.rows("image").let { rows ->
      IntArray(eyeWidth * eyeHeight) { i ->
        val row = rows[i / eyeWidth]
        val x = i % eyeWidth
        argb(row[3 * x].toInt(), row[3 * x + 1].toInt(), row[3 * x + 2].toInt())
      }
    }
  val depth: DoubleArray = json.flat("depth")
  val p2 = json.number("p2")
  val p98 = json.number("p98")
  val normalized: DoubleArray = json.flat("normalized")
  val dilated: DoubleArray = json.flat("dilated")
  val eyeDepth: DoubleArray = json.flat("eyeDepth")

  /** R, G, B bytes of each row of the right eye */
  val rightEye: List<DoubleArray> = json.rows("rightEye")
  val holes: List<String> = json.getValue("holes").jsonArray.map { it.jsonPrimitive.content }
  val filledPixels = json.getValue("filledPixels").jsonPrimitive.int
  val meanLuma = json.number("meanLuma")
  val flags: List<String> = json.getValue("flags").jsonArray.map { it.jsonPrimitive.content }

  companion object {
    fun all(): List<GoldenCase> {
      val fixture = ReliefFixtures.json("relief_golden_v1.json")
      val eyeWidth = fixture.getValue("eyeWidth").jsonPrimitive.int
      val eyeHeight = fixture.getValue("eyeHeight").jsonPrimitive.int
      val mapWidth = fixture.getValue("mapWidth").jsonPrimitive.int
      val mapHeight = fixture.getValue("mapHeight").jsonPrimitive.int
      return fixture.getValue("cases").jsonArray.map {
        GoldenCase(it.jsonObject, eyeWidth, eyeHeight, mapWidth, mapHeight)
      }
    }

    fun argb(r: Int, g: Int, b: Int) = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
  }
}

private fun JsonObject.string(key: String) = getValue(key).jsonPrimitive.content

private fun JsonObject.number(key: String) = getValue(key).jsonPrimitive.double

private fun JsonObject.rows(key: String): List<DoubleArray> =
  getValue(key).jsonArray.map { row -> (row as JsonArray).map { it.jsonPrimitive.double }.toDoubleArray() }

private fun JsonObject.flat(key: String): DoubleArray = rows(key).flatMap { it.asIterable() }.toDoubleArray()
