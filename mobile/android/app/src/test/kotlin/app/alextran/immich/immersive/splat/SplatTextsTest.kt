package app.alextran.immich.immersive.splat

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/** The texts of a splat in the headset (lot S5): the translations Flutter sends, English otherwise, with the numbers */
class SplatTextsTest {
  private val spz = SplatProbe.Spz(version = 3, gaussians = 452_451, shDegree = 0, fractionalBits = 12, flags = 0)
  private val ply = SplatProbe.Ply(19_469, 0, "Postshot", 400, 68, emptyList())

  @Test
  fun `the file line says the count and the format, the tool only when a comment names it`() {
    assertEquals("452,451 gaussians, SPZ version 3", SplatTexts.fileLine(emptyMap(), spz, Locale.US))
    assertEquals("19,469 gaussians, PLY, made with Postshot", SplatTexts.fileLine(emptyMap(), ply, Locale.US))
    assertEquals("19,469 gaussians, PLY", SplatTexts.fileLine(emptyMap(), ply.copy(tool = null), Locale.US))
    // The translation, with the grouping of its language
    val french = mapOf(SplatTexts.LABEL_SPZ to "{count} gaussiennes, SPZ version {version}")
    assertEquals("452 451 gaussiennes, SPZ version 3".replace(' ', ' ').length, SplatTexts.fileLine(french, spz, Locale.FRANCE).length)
  }

  @Test
  fun `a reduced splat says how many of how many it shows`() {
    val lines = SplatTexts.detailLines(emptyMap(), spz, SplatVerdict.Open(452_451, 50_000, large = false), Locale.US)
    assertEquals(listOf("452,451 gaussians, SPZ version 3", "Reduced to 50,000 of 452,451 gaussians"), lines)
    assertEquals(1, SplatTexts.detailLines(emptyMap(), spz, SplatVerdict.Open(40_000, null, false), Locale.US).size)
  }

  @Test
  fun `every refusal has its sentence, the memory and the heat those of the scenes`() {
    for (refusal in SplatRefusal.entries) {
      val text = SplatTexts.refusalText(emptyMap(), SplatVerdict.Refused(refusal, 5_000_000), Locale.US)
      assertNotEquals(refusal.name, "", text)
    }
    assertEquals(
      "Gaussian splats need a Meta Quest 3 or 3S",
      SplatTexts.refusalText(emptyMap(), SplatVerdict.Refused(SplatRefusal.OLDER_HEADSET), Locale.US),
    )
    assertEquals(
      "Too large for this headset (5,000,000 gaussians)",
      SplatTexts.refusalText(emptyMap(), SplatVerdict.Refused(SplatRefusal.TOO_LARGE, 5_000_000), Locale.US),
    )
    assertEquals(
      "Not enough free memory",
      SplatTexts.refusalText(emptyMap(), SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_MEMORY), Locale.US),
    )
    assertEquals(
      "Pas assez de mémoire",
      SplatTexts.refusalText(
        mapOf("sceneNoMemory" to "Pas assez de mémoire"),
        SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_MEMORY),
      ),
    )
  }

  @Test
  fun `a blank translation falls back to English`() {
    assertEquals("Turn upright", SplatTexts.label(mapOf(SplatTexts.LABEL_UPRIGHT to " "), SplatTexts.LABEL_UPRIGHT))
    assertEquals("Reset", SplatTexts.label(emptyMap(), "sceneReset"))
    assertEquals("The splat could not be shown: out of memory", SplatTexts.failedText(emptyMap(), "out of memory"))
  }

  @Test
  fun `a file found damaged while it is read says so as the probe would, in the language of the app`() {
    val cut = SplatReadException(SplatFileProblem.DAMAGED, "the file ends too early")
    assertEquals("This splat file is damaged or incomplete", SplatTexts.errorText(emptyMap(), cut, Locale.US))
    assertEquals(
      "Ce fichier splat est endommagé ou incomplet",
      SplatTexts.errorText(mapOf(SplatTexts.LABEL_DAMAGED to "Ce fichier splat est endommagé ou incomplet"), cut),
    )
    val noRows = SplatReadException(SplatFileProblem.NOT_A_SPLAT, "no opacity")
    assertEquals(
      "Not a Gaussian splat: this .ply holds a mesh or a point cloud",
      SplatTexts.errorText(emptyMap(), noRows, Locale.US),
    )
    assertEquals("Not enough free memory", SplatTexts.errorText(emptyMap(), OutOfMemoryError(), Locale.US))
    // Anything else keeps its message after "The splat could not be shown"
    assertEquals(
      "The splat could not be shown: connection reset",
      SplatTexts.errorText(emptyMap(), java.io.IOException("connection reset"), Locale.US),
    )
  }

  @Test
  fun `a cache without room and a module that did not start say so`() {
    assertEquals(
      "Not enough free space on the headset for this splat",
      SplatTexts.refusalText(emptyMap(), SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_SPACE), Locale.US),
    )
    assertEquals(
      "The splat module did not start with this viewer: close it and open the splat again",
      SplatTexts.refusalText(emptyMap(), SplatVerdict.Refused(SplatRefusal.MODULE_NOT_RUNNING), Locale.US),
    )
    assertEquals(
      "Le module des splats n'a pas démarré",
      SplatTexts.refusalText(
        mapOf(SplatTexts.LABEL_NOT_RUNNING to "Le module des splats n'a pas démarré"),
        SplatVerdict.Refused(SplatRefusal.MODULE_NOT_RUNNING),
      ),
    )
  }
}
