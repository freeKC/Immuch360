package app.alextran.immich.core.raw

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Every step of the fallback ladder (section 11 of the Android two track design), with a fake decoder check. */
class RawPlaybackPlannerTest {
  private val url = "https://server/api/assets/a/original"
  private val fallback = "https://server/api/assets/a/video/playback"
  private val secondFallback = "https://server/api/assets/b/video/playback"

  private val b = RawProjection.parse(RawFixtures.B)
  private val c = RawProjection.parse(RawFixtures.C)
  private val cWithFallbacks =
    RawProjection.parse(
      RawFixtures.C.replace("\"secondFallbackUrl\":null", "\"secondFallbackUrl\":\"$secondFallback\""),
    )

  private val all: RawDecoderCheck = { _, _ -> true }
  private val oneOnly: RawDecoderCheck = { _, instances -> instances == 1 }
  private val none: RawDecoderCheck = { _, _ -> false }

  private fun initial(
    projection: RawProjection?,
    check: RawDecoderCheck,
    fallbackUrl: String? = null,
    json: Boolean = true,
  ) = RawPlaybackPlanner.initial(json, projection, url, fallbackUrl, false, check)

  @Test
  fun `no JSON plays plain, a refused JSON unstitched with its message`() {
    assertEquals(RawMode.PLAIN, initial(null, all, json = false).mode)
    val refused = initial(null, all)
    assertEquals(RawMode.UNSTITCHED, refused.mode)
    assertEquals(listOf(url), refused.urls)
    assertEquals(RawMessage.UNSTITCHED, refused.message)
  }

  @Test
  fun `a stitching that failed before plays unstitched without telling again`() {
    val plan = RawPlaybackPlanner.initial(true, b, url, null, true, all)
    assertEquals(RawMode.UNSTITCHED, plan.mode)
    assertNull(plan.message)
  }

  @Test
  fun `side by side goes through the effect`() {
    val plan = initial(RawProjection.parse(RawFixtures.A), none)
    assertEquals(RawMode.EFFECT_SIDE_BY_SIDE, plan.mode)
    assertEquals(listOf(url), plan.urls)
  }

  @Test
  fun `two decodable streams play both lenses, from one file or from both files in file order`() {
    val tracks = initial(b, all)
    assertEquals(RawMode.LENSES, tracks.mode)
    assertEquals(listOf(0, 1), tracks.streams)
    assertEquals(listOf(url), tracks.urls)
    assertNull(tracks.message)
    val files = initial(c, all)
    assertEquals(listOf(url, RawFixtures.C_SECOND_URL), files.urls)
  }

  @Test
  fun `an unknown size or codec counts as decodable`() {
    var asked = false
    val unknown =
      RawProjection.parse(RawFixtures.B.replace("\"width\":3840,\"height\":3840", "\"width\":0,\"height\":0"))
    val plan =
      initial(unknown, { _, _ ->
        asked = true
        false
      })
    assertEquals(listOf(0, 1), plan.streams)
    assertFalse(asked)
  }

  @Test
  fun `the decoders ask about the largest track twice, then the primary one alone`() {
    val questions = mutableListOf<Pair<Int, Int>>()
    initial(b, { track, instances ->
      questions += track.width to instances
      instances == 1
    })
    assertEquals(listOf(3840 to 2, 3840 to 1), questions)
  }

  @Test
  fun `two refused and one decodable keep the primary lens with the decoder message`() {
    val plan = initial(b, oneOnly)
    assertEquals(RawMode.LENSES, plan.mode)
    // Example B: lens 1 (forward) is in track 0
    assertEquals(listOf(0), plan.streams)
    assertEquals(listOf(url), plan.urls)
    assertEquals(RawMessage.ONE_LENS_DECODER, plan.message)
    // Example C: lens 1 in texture 0, the opened file
    assertEquals(listOf(url), initial(c, oneOnly).urls)
    // The DJI front lens is stream 1
    assertEquals(listOf(1), initial(RawProjection.parse(RawFixtures.D), oneOnly).streams)
  }

  @Test
  fun `one lens of the second file opens that file alone`() {
    // Lens 1 moved to the second file: the primary stream is texture 1, in file 1
    val swapped =
      RawProjection.parse(
        RawFixtures.C.replace("\"trackOrder\":[1,0]", "\"trackOrder\":[0,1]")
          .replace("{\"file\":0,\"videoTrack\":0", "{\"file\":2,\"videoTrack\":0")
          .replace("{\"file\":1,\"videoTrack\":0", "{\"file\":0,\"videoTrack\":0")
          .replace("{\"file\":2,\"videoTrack\":0", "{\"file\":1,\"videoTrack\":0"),
      )
    val plan = initial(swapped, oneOnly)
    assertEquals(listOf(0), plan.streams)
    assertEquals(listOf(RawFixtures.C_SECOND_URL), plan.urls)
  }

  @Test
  fun `one refused falls back to the transcoded streams of both files`() {
    val plan = initial(cWithFallbacks, none, fallbackUrl = fallback)
    assertEquals(RawMode.LENSES, plan.mode)
    assertEquals(listOf(0, 1), plan.streams)
    assertEquals(listOf(fallback, secondFallback), plan.urls)
    assertTrue(plan.fromFallback)
  }

  @Test
  fun `one refused with the transcoded stream of a two track file plays it unstitched`() {
    val plan = initial(b, none, fallbackUrl = fallback)
    assertEquals(RawMode.UNSTITCHED, plan.mode)
    assertEquals(listOf(fallback), plan.urls)
    assertEquals(RawMessage.UNSTITCHED, plan.message)
  }

  @Test
  fun `one refused without any fallback tries the primary lens anyway`() {
    val plan = initial(b, none)
    assertEquals(RawMode.LENSES, plan.mode)
    assertEquals(listOf(0), plan.streams)
    assertEquals(RawMessage.ONE_LENS_DECODER, plan.message)
    // A pair with one fallback only gets none
    assertEquals(listOf(0), initial(c, none, fallbackUrl = fallback).streams)
  }

  @Test
  fun `decoder failures go from two lenses to one, to the transcoded streams, to the error`() {
    val two = initial(cWithFallbacks, all, fallbackUrl = fallback)
    val one = RawPlaybackPlanner.afterDecoderFailure(two, cWithFallbacks, url, fallback)!!
    assertEquals(listOf(0), one.streams)
    assertEquals(listOf(url), one.urls)
    assertEquals(RawMessage.ONE_LENS_DECODER, one.message)
    val transcoded = RawPlaybackPlanner.afterDecoderFailure(one, cWithFallbacks, url, fallback)!!
    assertTrue(transcoded.fromFallback)
    assertEquals(listOf(fallback, secondFallback), transcoded.urls)
    assertNull(RawPlaybackPlanner.afterDecoderFailure(transcoded, cWithFallbacks, url, fallback))
    // Without fallbacks, one lens is the last step
    val bOne = RawPlaybackPlanner.afterDecoderFailure(initial(b, all), b, url, null)!!
    assertNull(RawPlaybackPlanner.afterDecoderFailure(bOne, b, url, null))
    // Other modes are not the ladder's
    assertNull(RawPlaybackPlanner.afterDecoderFailure(initial(null, all, json = false), b, url, null))
  }

  @Test
  fun `a read error of a split pair keeps the lens of the opened file`() {
    val plan = RawPlaybackPlanner.afterSourceError(initial(c, all), c, url)!!
    assertEquals(RawMode.LENSES, plan.mode)
    // Example C: texture 0 is in file 0, the url
    assertEquals(listOf(0), plan.streams)
    assertEquals(listOf(url), plan.urls)
    assertEquals(RawMessage.ONE_LENS_FILE, plan.message)
    // One file: the activity's own handling
    assertNull(RawPlaybackPlanner.afterSourceError(initial(b, all), b, url))
    assertNull(RawPlaybackPlanner.afterSourceError(plan, c, url))
  }

  @Test
  fun `any other failure of the originals plays the transcoded streams once`() {
    // A two track file, both lenses or one: the transcoded stream holds one lens and plays unstitched
    val tracks = RawPlaybackPlanner.afterSourceFailure(initial(b, all), b, url, fallback)!!
    assertEquals(RawMode.UNSTITCHED, tracks.mode)
    assertEquals(listOf(fallback), tracks.urls)
    assertTrue(tracks.fromFallback)
    assertEquals(RawMessage.UNSTITCHED, tracks.message)
    assertEquals(tracks, RawPlaybackPlanner.afterSourceFailure(initial(b, oneOnly), b, url, fallback))
    // A split pair: the transcoded streams of both files, stitched, also after the lens of the opened file failed
    val two = initial(cWithFallbacks, all)
    val pair = RawPlaybackPlanner.afterSourceFailure(two, cWithFallbacks, url, fallback)!!
    assertEquals(RawMode.LENSES, pair.mode)
    assertEquals(listOf(0, 1), pair.streams)
    assertEquals(listOf(fallback, secondFallback), pair.urls)
    assertTrue(pair.fromFallback)
    assertNull(pair.message)
    val oneFile = RawPlaybackPlanner.afterSourceError(two, cWithFallbacks, url)!!
    assertEquals(pair, RawPlaybackPlanner.afterSourceFailure(oneFile, cWithFallbacks, url, fallback))
    // On the transcoded streams already, without them (a pair needs both), or the original as its own fallback: the
    // error
    assertNull(RawPlaybackPlanner.afterSourceFailure(pair, cWithFallbacks, url, fallback))
    assertNull(RawPlaybackPlanner.afterSourceFailure(initial(b, all), b, url, null))
    assertNull(RawPlaybackPlanner.afterSourceFailure(initial(c, all), c, url, fallback))
    assertNull(RawPlaybackPlanner.afterSourceFailure(initial(b, all), b, url, url))
    // Other modes keep the activity's own fallback
    assertNull(RawPlaybackPlanner.afterSourceFailure(tracks, b, url, fallback))
    val effect = initial(RawProjection.parse(RawFixtures.A), all)
    assertNull(RawPlaybackPlanner.afterSourceFailure(effect, RawProjection.parse(RawFixtures.A), url, fallback))
  }

  @Test
  fun `a stitching failure plays the first url unstitched once`() {
    val lenses = initial(c, all)
    val unstitched = RawPlaybackPlanner.afterStitchFailure(lenses)!!
    assertEquals(RawMode.UNSTITCHED, unstitched.mode)
    assertEquals(listOf(url), unstitched.urls)
    assertEquals(RawMessage.UNSTITCHED, unstitched.message)
    val effect = initial(RawProjection.parse(RawFixtures.A), all)
    assertEquals(RawMode.UNSTITCHED, RawPlaybackPlanner.afterStitchFailure(effect)!!.mode)
    assertNull(RawPlaybackPlanner.afterStitchFailure(unstitched))
  }

  @Test
  fun `each plan says how the lens renderers find their tracks`() {
    val hevc = "video/hevc"
    val tracks = RawPlaybackPlanner.assignmentOf(initial(b, all), b)
    assertTrue(tracks.matches(0, "1", hevc) && tracks.matches(1, "2", hevc))
    val oneTrack = RawPlaybackPlanner.assignmentOf(initial(b, oneOnly), b)
    assertTrue(oneTrack.matches(0, "1", hevc))
    assertFalse(oneTrack.matches(0, "2", hevc))
    val files = RawPlaybackPlanner.assignmentOf(initial(c, all), c)
    assertTrue(files.matches(0, "0:1", hevc) && files.matches(1, "1:1", hevc))
    val oneFile = RawPlaybackPlanner.assignmentOf(initial(c, oneOnly), c)
    assertTrue(oneFile.matches(0, "1", hevc))
    val transcodedPlan = initial(cWithFallbacks, none, fallbackUrl = fallback)
    val transcoded = RawPlaybackPlanner.assignmentOf(transcodedPlan, cWithFallbacks)
    assertTrue(transcoded.matches(1, "1:3", hevc))
  }

  @Test
  fun `the key tells plans that need another player apart`() {
    val two = initial(b, all)
    assertEquals(two.key, initial(b, all).key)
    assertTrue(two.key != initial(b, oneOnly).key)
    assertTrue(two.key != initial(c, all).key)
    // Any other player is built for its mode only: a plain player plays every equirectangular video
    assertEquals(initial(null, all, json = false).key, RawPlaybackPlanner.initial(false, null, fallback, null, false, all).key)
  }
}
