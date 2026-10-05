package app.alextran.immich.core.raw

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Which format each lens renderer takes, and which track the selector gives it. */
class LensSelectionTest {
  private val hevc = "video/hevc"

  @Test
  fun `two tracks of one file are told apart by their track ID, with or without a source prefix`() {
    // Example B: stream 0 is track 1, stream 1 is track 2
    val assignment = LensAssignment.byTrackIds(mapOf(0 to 1, 1 to 2))
    assertTrue(assignment.matches(0, "1", hevc))
    assertTrue(assignment.matches(1, "2", hevc))
    assertTrue(assignment.matches(1, "0:2", hevc))
    assertFalse(assignment.matches(0, "2", hevc))
    assertFalse(assignment.matches(1, "12", hevc))
    assertFalse(assignment.matches(0, null, hevc))
    // Audio and text formats are never a lens
    assertFalse(assignment.matches(0, "1", "audio/mp4a-latm"))
    assertFalse(assignment.matches(0, "1", null))
    // A GoPro .360: video tracks 1 and 6
    val goPro = LensAssignment.byTrackIds(mapOf(0 to 1, 1 to 6))
    assertTrue(goPro.matches(1, "6", hevc))
    assertFalse(goPro.matches(1, "1", hevc))
  }

  @Test
  fun `two merged files are told apart by their source index`() {
    // Example C: stream 0 is in file 0 (source 0), stream 1 in file 1 (source 1), both track 1
    val assignment = LensAssignment.bySource(mapOf(0 to 0, 1 to 1), mapOf(0 to 1, 1 to 1))
    assertTrue(assignment.matches(0, "0:1", hevc))
    assertTrue(assignment.matches(1, "1:1", hevc))
    assertFalse(assignment.matches(0, "1:1", hevc))
    assertFalse(assignment.matches(1, "1:2", hevc))
    assertFalse(assignment.matches(1, "1", hevc))
    assertFalse(assignment.matches(1, null, hevc))
    // Transcoded streams: their own track IDs, the source alone decides
    val transcoded = LensAssignment.bySource(mapOf(0 to 0, 1 to 1))
    assertTrue(transcoded.matches(1, "1:7", hevc))
    assertFalse(transcoded.matches(0, "1:7", hevc))
  }

  @Test
  fun `a single lens file takes any video format`() {
    val assignment = LensAssignment.anyVideo(listOf(1))
    assertTrue(assignment.matches(1, "1", hevc))
    assertTrue(assignment.matches(1, null, "video/avc"))
    assertFalse(assignment.matches(0, "1", hevc))
    assertFalse(assignment.matches(1, "2", "audio/mp4a-latm"))
  }

  private val names = listOf("LensVideoRenderer0", "LensVideoRenderer1", "MediaCodecAudioRenderer", "TextRenderer")

  /** A RendererCapabilities value: the format support in the low bits, adaptive support bits above. */
  private fun capability(support: Int) = support or (0b11 shl 3)

  @Test
  fun `each lens renderer gets the first track it handles, else one that exceeds its capabilities`() {
    val supports =
      arrayOf(
        // Lens renderer 0: its own group handled, the other lens's group mapped there as unsupported subtype
        arrayOf(intArrayOf(capability(4)), intArrayOf(capability(1))),
        // Lens renderer 1: only a track above its capabilities
        arrayOf(intArrayOf(capability(1), capability(3))),
        // Audio
        arrayOf(intArrayOf(capability(4))),
        arrayOf(),
      )
    val picks = TwoLensTrackSelector.lensSelections(names, supports, listOf(0, 1))
    assertEquals(TwoLensTrackSelector.Pick(0, 0, 0), picks[0])
    assertEquals(TwoLensTrackSelector.Pick(1, 0, 1), picks[1])
  }

  @Test
  fun `a lens without a usable track or without a renderer has no pick`() {
    val supports =
      arrayOf(
        arrayOf(intArrayOf(capability(1)), intArrayOf(capability(2))),
        arrayOf(intArrayOf(capability(4))),
        arrayOf(intArrayOf(capability(4))),
        arrayOf(),
      )
    val picks = TwoLensTrackSelector.lensSelections(names, supports, listOf(0, 1))
    assertNull(picks[0])
    assertEquals(TwoLensTrackSelector.Pick(1, 0, 0), picks[1])
    // One lens mode: only the renderer of stream 1 exists
    val single = TwoLensTrackSelector.lensSelections(listOf("LensVideoRenderer1", "MediaCodecAudioRenderer"),
      arrayOf(arrayOf(intArrayOf(capability(4))), arrayOf()), listOf(1, 0))
    assertEquals(TwoLensTrackSelector.Pick(0, 0, 0), single[1])
    assertNull(single[0])
  }

  @Test
  fun `the renderer names are the ones the selector looks for`() {
    assertEquals("LensVideoRenderer0", LensVideoRenderer.nameOf(0))
    assertEquals("LensVideoRenderer1", LensVideoRenderer.nameOf(1))
  }
}
