package app.alextran.immich.immersive.splat

import org.junit.Assert.assertEquals
import org.junit.Test

/** The options a session of measures may push for the splats (lot S5): how the splat moves, and when it shows */
class SplatViewerOptionsTest {
  @Test
  fun `the defaults move the Transform and show the splat 500 ms after its load`() {
    assertEquals(SplatViewerOptions(SplatViewerOptions.Move.TRANSFORM, 500), SplatViewerOptions.parse(null))
    assertEquals(SplatViewerOptions(), SplatViewerOptions.parse("not json"))
    assertEquals(SplatViewerOptions(), SplatViewerOptions.parse("[1, 2]"))
  }

  @Test
  fun `a file of the session changes what it names, and a wrong value keeps its default`() {
    assertEquals(
      SplatViewerOptions(SplatViewerOptions.Move.BOTH, 0),
      SplatViewerOptions.parse("""{"move": "both", "revealDelayMs": 0}"""),
    )
    assertEquals(SplatViewerOptions(SplatViewerOptions.Move.SYSTEM, 500), SplatViewerOptions.parse("""{"move": "system"}"""))
    assertEquals(
      SplatViewerOptions(),
      SplatViewerOptions.parse("""{"move": "teleport", "revealDelayMs": 99999, "other": true}"""),
    )
  }
}
