package app.alextran.immich.immersive.splat

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/**
 * The splat files the Dart and the Kotlin tests share, in mobile/test/fixtures/splat, written by
 * .github/desktop/ai/make_splat_fixtures.py. Found by walking up from the working directory, as ReliefFixtures does:
 * Gradle runs the unit tests from mobile/android/app, the tests compiled without Gradle may run from elsewhere.
 */
object SplatFixtures {
  fun file(name: String): File {
    var dir: File? = File(System.getProperty("user.dir")).absoluteFile
    while (dir != null) {
      for (base in listOf("test/fixtures/splat", "mobile/test/fixtures/splat")) {
        val candidate = File(dir, "$base/$name")
        if (candidate.isFile) return candidate
      }
      dir = dir.parentFile
    }
    error("$name not found above ${System.getProperty("user.dir")}")
  }

  fun bytes(name: String): ByteArray = file(name).readBytes()

  /** What the tests compare with (expected.json) */
  val expected: JsonObject by lazy { Json.parseToJsonElement(file("expected.json").readText()).jsonObject }
}
