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

  private val osmo = RawProjection.parse(RawFixtures.D)

  /** Example C with lens 1 in the second file. */
  private val swapped =
    RawProjection.parse(
      RawFixtures.C.replace("\"trackOrder\":[1,0]", "\"trackOrder\":[0,1]")
        .replace("{\"file\":0,\"videoTrack\":0", "{\"file\":2,\"videoTrack\":0")
        .replace("{\"file\":1,\"videoTrack\":0", "{\"file\":0,\"videoTrack\":0")
        .replace("{\"file\":2,\"videoTrack\":0", "{\"file\":1,\"videoTrack\":0"),
    )

  /** A refusal for the size or the rate, where the decoder list may be pessimistic. */
  private val tooLarge =
    RawDecoderVerdict.Refused("c2.qti.hevc.decoder has no performance point for 2 x 3840x3840 at 30.0 fps", false)

  /** The refusal of an emulator whose HEVC decoder lacks Main 10, for one stream as for two. */
  private val lacksMain10 = RawDecoderVerdict.Refused("c2.android.hevc.decoder lacks profile Main 10", true)

  private val all: RawDecoderCheck = { _, _ -> RawDecoderVerdict.Decodable }
  private val oneOnly: RawDecoderCheck = { _, instances ->
    if (instances == 1) RawDecoderVerdict.Decodable else tooLarge
  }
  private val none: RawDecoderCheck = { _, _ -> tooLarge }
  private val noProfile: RawDecoderCheck = { _, _ -> lacksMain10 }

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
        tooLarge
      })
    assertEquals(listOf(0, 1), plan.streams)
    assertFalse(asked)
  }

  @Test
  fun `the decoders ask about the largest track twice, then the primary one alone`() {
    val questions = mutableListOf<Pair<Int, Int>>()
    initial(b, { track, instances ->
      questions += track.width to instances
      oneOnly(track, instances)
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
  fun `one refused for its size without any fallback tries the primary lens anyway, without the one lens message`() {
    val plan = initial(b, none)
    assertEquals(RawMode.LENSES, plan.mode)
    assertEquals(listOf(0), plan.streams)
    assertEquals(listOf(url), plan.urls)
    assertFalse(plan.fromFallback)
    // The decoder list says even one lens is too much: the one lens message waits for the first frame of that lens
    assertNull(plan.message)
    assertEquals(RawMessage.ONE_LENS_DECODER, plan.firstFrameMessage)
    // A pair with one fallback only gets none
    val pair = initial(c, none, fallbackUrl = fallback)
    assertEquals(listOf(0), pair.streams)
    assertNull(pair.message)
    assertEquals(RawMessage.ONE_LENS_DECODER, pair.firstFrameMessage)
    // The DJI front lens, stream 1
    val dji = initial(osmo, none)
    assertEquals(RawMode.LENSES, dji.mode)
    assertEquals(listOf(1), dji.streams)
    assertNull(dji.message)
    assertEquals(RawMessage.ONE_LENS_DECODER, dji.firstFrameMessage)
  }

  @Test
  fun `only the lens tried against the decoder list tells its message on its first frame`() {
    val tried = initial(b, none)
    // The activities drop the message once shown: the same player still plays the plan
    assertEquals(tried.key, tried.copy(firstFrameMessage = null).key)
    // Every other plan tells its message at once, or has none
    val others =
      listOf(
        initial(null, all, json = false),
        initial(null, all),
        initial(RawProjection.parse(RawFixtures.A), all),
        initial(b, all),
        initial(b, oneOnly),
        initial(b, none, fallbackUrl = fallback),
        initial(cWithFallbacks, none, fallbackUrl = fallback),
        initial(osmo, noProfile),
        initial(osmo, noProfile, fallbackUrl = fallback),
        RawPlaybackPlanner.afterDecoderFailure(initial(b, all), b, url, null)!!,
        RawPlaybackPlanner.afterDecoderFailure(tried, b, url, null)!!,
        RawPlaybackPlanner.afterSourceError(initial(c, all), c, url)!!,
        RawPlaybackPlanner.afterSourceFailure(tried, b, url, fallback)!!,
        RawPlaybackPlanner.afterStitchFailure(tried)!!,
      )
    for (plan in others) assertNull(plan.reason, plan.firstFrameMessage)
  }

  @Test
  fun `a missing profile or no decoder at all is a certain refusal, a refused size or rate is not`() {
    assertEquals(RawDecoderVerdict.Decodable, RawDecoderVerdict.of(true, "c2.qti.hevc.decoder (hardware)", null))
    assertEquals(lacksMain10, RawDecoderVerdict.of(false, lacksMain10.reason, "Main 10"))
    val noDecoder = RawDecoderVerdict.of(false, "no decoder for video/hevc", null)
    assertEquals(RawDecoderVerdict.Refused("no decoder for video/hevc", true), noDecoder)
    assertEquals(tooLarge, RawDecoderVerdict.of(false, tooLarge.reason, null))
    // A device without any HEVC decoder skips the lens player, as for a missing profile
    val plan = initial(osmo, { _, _ -> noDecoder })
    assertEquals(RawMode.UNSTITCHED, plan.mode)
    assertEquals(listOf(url), plan.urls)
    assertNull(plan.message)
    assertTrue(plan.reason, plan.reason.contains("no decoder for video/hevc"))
    assertEquals(listOf(fallback), initial(osmo, { _, _ -> noDecoder }, fallbackUrl = fallback).urls)
  }

  @Test
  fun `a missing profile without any fallback plays the original in the plain player, without a raw message`() {
    // The DJI Osmo 360 opened from a network share on a device whose HEVC decoder lacks Main 10: no lens can play, and
    // the plain player's own decoder check and fallback take over
    val plan = initial(osmo, noProfile)
    assertEquals(RawMode.UNSTITCHED, plan.mode)
    assertEquals(emptyList<Int>(), plan.streams)
    assertEquals(listOf(url), plan.urls)
    assertFalse(plan.fromFallback)
    assertNull(plan.message)
    assertTrue(plan.reason, plan.reason.contains("lacks profile Main 10"))
    // A pair with one transcoded stream only: the original too, whose plain player can switch to that stream
    val pair = initial(c, noProfile, fallbackUrl = fallback)
    assertEquals(RawMode.UNSTITCHED, pair.mode)
    assertEquals(listOf(url), pair.urls)
    assertNull(pair.message)
    // The original as its own fallback is no fallback
    assertEquals(listOf(url), initial(osmo, noProfile, fallbackUrl = url).urls)
  }

  @Test
  fun `a missing profile with the transcoded streams plays them`() {
    // A two track file: the transcoded stream holds one lens and plays unstitched
    val tracks = initial(osmo, noProfile, fallbackUrl = fallback)
    assertEquals(RawMode.UNSTITCHED, tracks.mode)
    assertEquals(listOf(fallback), tracks.urls)
    assertTrue(tracks.fromFallback)
    assertEquals(RawMessage.UNSTITCHED, tracks.message)
    // A split pair: the transcoded streams of both files, stitched
    val pair = initial(cWithFallbacks, noProfile, fallbackUrl = fallback)
    assertEquals(RawMode.LENSES, pair.mode)
    assertEquals(listOf(0, 1), pair.streams)
    assertEquals(listOf(fallback, secondFallback), pair.urls)
    assertTrue(pair.fromFallback)
    assertNull(pair.message)
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
    // Without fallbacks, one lens goes on to the original unstitched, the last step
    val bOne = RawPlaybackPlanner.afterDecoderFailure(initial(b, all), b, url, null)!!
    val bUnstitched = RawPlaybackPlanner.afterDecoderFailure(bOne, b, url, null)!!
    assertEquals(RawMode.UNSTITCHED, bUnstitched.mode)
    assertNull(RawPlaybackPlanner.afterDecoderFailure(bUnstitched, b, url, null))
    // Other modes are not the ladder's
    assertNull(RawPlaybackPlanner.afterDecoderFailure(initial(null, all, json = false), b, url, null))
  }

  @Test
  fun `a lens decoder that fails without the transcoded streams plays the original unstitched`() {
    // The lens tried anyway on a pessimistic list, then refused by its decoder
    val tried = initial(osmo, none)
    val plan = RawPlaybackPlanner.afterDecoderFailure(tried, osmo, url, null)!!
    assertEquals(RawMode.UNSTITCHED, plan.mode)
    assertEquals(emptyList<Int>(), plan.streams)
    assertEquals(listOf(url), plan.urls)
    assertFalse(plan.fromFallback)
    assertEquals(RawMessage.UNSTITCHED, plan.message)
    // The original as its own fallback, or a pair with one transcoded stream only: the original too
    assertEquals(plan, RawPlaybackPlanner.afterDecoderFailure(tried, osmo, url, url))
    val pairOne = initial(c, none, fallbackUrl = fallback)
    assertEquals(listOf(url), RawPlaybackPlanner.afterDecoderFailure(pairOne, c, url, fallback)!!.urls)
    // The lens of the second file of a pair failed: the opened file plays, where the plain player has its fallback
    val second = initial(swapped, none)
    assertEquals(listOf(RawFixtures.C_SECOND_URL), second.urls)
    assertEquals(listOf(url), RawPlaybackPlanner.afterDecoderFailure(second, swapped, url, null)!!.urls)
    // Unstitched already: the error shows
    assertNull(RawPlaybackPlanner.afterDecoderFailure(plan, osmo, url, null))
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
