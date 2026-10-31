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
 * shown (500 ms in Meta's SplatSample). [frame] says in which frame the poses reach the module: converted to the
 * frame the module draws in ([Frame.MODULE], SplatModuleFrame, measured on a Quest 3 on 31 October 2026), or as the
 * viewer computes them in the frame of the SDK ([Frame.SDK], what build 38 did: the splat at the mirror image of its
 * place), for a session that compares the two. Pure JVM, tested by SplatViewerOptionsTest.
 */
internal data class SplatViewerOptions(
  val move: Move = Move.TRANSFORM,
  val revealDelayMs: Long = 500,
  val frame: Frame = Frame.MODULE,
) {
  enum class Move(val key: String) {
    TRANSFORM("transform"),
    SYSTEM("system"),
    BOTH("both"),
  }

  enum class Frame(val key: String) {
    MODULE("module"),
    SDK("sdk"),
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
        frame = Frame.entries.firstOrNull { it.key == root.string("frame") } ?: defaults.frame,
      )
    }
  }
}
