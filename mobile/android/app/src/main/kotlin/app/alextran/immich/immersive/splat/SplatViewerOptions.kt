package app.alextran.immich.immersive.splat

import app.alextran.immich.immersive.integer
import app.alextran.immich.immersive.string
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/**
 * Options a session of measures in the headset may push as splat-options.json into the external files folder of the
 * app (adb push, as scene-options.json for the scenes), read when a splat opens; the defaults otherwise. [move] says
 * how the glide, Reset and Turn upright move the splat once it is made: through its Transform (the documented way),
 * through the system of the module (SplatSystem.updateSplatTransform, public in the module), or both, should the
 * splat not follow its Transform in the headset. [revealDelayMs] is the pause between the load event and the splat
 * shown (500 ms in Meta's SplatSample). Pure JVM, tested by SplatStageTest.
 */
internal data class SplatViewerOptions(val move: Move = Move.TRANSFORM, val revealDelayMs: Long = 500) {
  enum class Move(val key: String) {
    TRANSFORM("transform"),
    SYSTEM("system"),
    BOTH("both"),
  }

  companion object {
    const val FILE_NAME = "splat-options.json"

    private val json = Json { ignoreUnknownKeys = true }

    /** The options of [text]; a value missing or wrong keeps its default */
    fun parse(text: String?): SplatViewerOptions {
      val root =
        try {
          text?.let { json.parseToJsonElement(it) as? JsonObject }
        } catch (e: Exception) {
          null
        } ?: return SplatViewerOptions()
      val defaults = SplatViewerOptions()
      return SplatViewerOptions(
        move = Move.entries.firstOrNull { it.key == root.string("move") } ?: defaults.move,
        revealDelayMs = root.integer("revealDelayMs")?.takeIf { it in 0..10_000 }?.toLong() ?: defaults.revealDelayMs,
      )
    }
  }
}
