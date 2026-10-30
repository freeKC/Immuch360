package app.alextran.immich.immersive

import app.alextran.immich.immersive.KioskSession.Command
import app.alextran.immich.immersive.KioskSession.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KioskSessionTest {
  private fun film() = KioskSession(isVideo = true).also { it.start() }

  private fun photo() = KioskSession(isVideo = false).also { it.start() }

  // Start

  @Test
  fun `the start shows how to leave, and the media is watched`() {
    val kiosk = KioskSession(isVideo = true)
    assertEquals(listOf(Command.SHOW_EXIT_NOTICE), kiosk.start())
    assertEquals(State.WATCHING, kiosk.state)
  }

  @Test
  fun `a second start says nothing again`() {
    val kiosk = film()
    assertEquals(emptyList<Command>(), kiosk.start())
  }

  // Headset off and on

  @Test
  fun `a film pauses and lets its player go when the headset comes off`() {
    val kiosk = film()
    assertEquals(listOf(Command.RELEASE_PLAYER), kiosk.onUnmounted())
    assertEquals(State.UNWORN, kiosk.state)
  }

  @Test
  fun `the next visitor gets the film from the start on a new player`() {
    val kiosk = film()
    kiosk.onUnmounted()
    assertEquals(listOf(Command.RESTART), kiosk.onMounted())
    assertEquals(State.WATCHING, kiosk.state)
  }

  @Test
  fun `a headset put on without a removal first restarts nothing`() {
    val kiosk = film()
    assertEquals(emptyList<Command>(), kiosk.onMounted())
    assertEquals(State.WATCHING, kiosk.state)
  }

  @Test
  fun `a second removal in a row releases nothing more`() {
    val kiosk = film()
    kiosk.onUnmounted()
    assertEquals(emptyList<Command>(), kiosk.onUnmounted())
    assertEquals(listOf(Command.RESTART), kiosk.onMounted())
    assertEquals(emptyList<Command>(), kiosk.onMounted())
  }

  @Test
  fun `a photo stays as it is when the headset comes off and on`() {
    val kiosk = photo()
    assertEquals(emptyList<Command>(), kiosk.onUnmounted())
    assertEquals(State.UNWORN, kiosk.state)
    assertEquals(emptyList<Command>(), kiosk.onMounted())
    assertEquals(State.WATCHING, kiosk.state)
  }

  // End of the film

  @Test
  fun `the end of the film shows the card and lets the player go`() {
    val kiosk = film()
    assertEquals(listOf(Command.RELEASE_PLAYER, Command.SHOW_END_CARD), kiosk.onEnded())
    assertEquals(State.ENDED, kiosk.state)
  }

  @Test
  fun `the card stays for the visitor who keeps the headset on`() {
    val kiosk = film()
    kiosk.onEnded()
    assertEquals(emptyList<Command>(), kiosk.onMounted())
    assertEquals(State.ENDED, kiosk.state)
  }

  @Test
  fun `the card stays while nobody wears the headset, the next visitor gets the film from the start`() {
    val kiosk = film()
    kiosk.onEnded()
    assertEquals(emptyList<Command>(), kiosk.onUnmounted())
    assertEquals(State.ENDED, kiosk.state)
    assertEquals(listOf(Command.RESTART), kiosk.onMounted())
    assertEquals(State.WATCHING, kiosk.state)
  }

  @Test
  fun `an end reported twice, or after the headset came off, changes nothing`() {
    val kiosk = film()
    kiosk.onEnded()
    assertEquals(emptyList<Command>(), kiosk.onEnded())
    val other = film()
    other.onUnmounted()
    assertEquals(emptyList<Command>(), other.onEnded())
    assertEquals(State.UNWORN, other.state)
  }

  @Test
  fun `a photo never ends`() {
    val kiosk = photo()
    assertEquals(emptyList<Command>(), kiosk.onEnded())
    assertEquals(State.WATCHING, kiosk.state)
  }

  // Failures

  @Test
  fun `a playback failure in the last 15 seconds shows the end card`() {
    val kiosk = film()
    assertEquals(
      listOf(Command.RELEASE_PLAYER, Command.SHOW_END_CARD),
      kiosk.onPlaybackFailure(positionMs = 440_000, durationMs = 450_000),
    )
    assertEquals(State.ENDED, kiosk.state)
  }

  @Test
  fun `a failure right on the 15 second mark counts as the end, one before it does not`() {
    assertEquals(State.ENDED, film().also { it.onPlaybackFailure(85_000, 100_000) }.state)
    val earlier = film()
    assertEquals(emptyList<Command>(), earlier.onPlaybackFailure(84_999, 100_000))
    assertEquals(State.WATCHING, earlier.state)
  }

  @Test
  fun `a failure earlier in the film is left to the fallbacks of the viewer`() {
    val kiosk = film()
    assertEquals(emptyList<Command>(), kiosk.onPlaybackFailure(positionMs = 60_000, durationMs = 450_000))
    assertEquals(State.WATCHING, kiosk.state)
  }

  @Test
  fun `a film shorter than 30 seconds, or of unknown length, never takes the end for a failure`() {
    assertEquals(emptyList<Command>(), film().onPlaybackFailure(positionMs = 20_000, durationMs = 25_000))
    assertEquals(emptyList<Command>(), film().onPlaybackFailure(positionMs = 20_000, durationMs = -1))
    assertEquals(emptyList<Command>(), film().onPlaybackFailure(positionMs = 0, durationMs = 0))
  }

  @Test
  fun `the end rule itself`() {
    assertTrue(KioskSession.isPracticallyFinished(positionMs = 30_000, durationMs = 30_000))
    assertTrue(KioskSession.isPracticallyFinished(positionMs = 15_000, durationMs = 30_000))
    assertFalse(KioskSession.isPracticallyFinished(positionMs = 14_999, durationMs = 30_000))
    assertFalse(KioskSession.isPracticallyFinished(positionMs = 29_000, durationMs = 29_999))
  }

  @Test
  fun `an error left once the fallbacks are spent shows the error card and lets the player go`() {
    val kiosk = film()
    assertEquals(listOf(Command.RELEASE_PLAYER, Command.SHOW_ERROR_CARD), kiosk.onError())
    assertEquals(State.FAILED, kiosk.state)
  }

  @Test
  fun `after an error, the next visitor gets a new try from the start`() {
    val kiosk = film()
    kiosk.onError()
    assertEquals(emptyList<Command>(), kiosk.onMounted())
    kiosk.onUnmounted()
    assertEquals(listOf(Command.RESTART), kiosk.onMounted())
    assertEquals(State.WATCHING, kiosk.state)
  }

  @Test
  fun `an error while nobody wears the headset is tried again at the next mount`() {
    val kiosk = film()
    kiosk.onUnmounted()
    assertEquals(listOf(Command.SHOW_ERROR_CARD), kiosk.onError())
    assertEquals(State.FAILED, kiosk.state)
    assertEquals(listOf(Command.RESTART), kiosk.onMounted())
  }

  @Test
  fun `a photo that fails shows the error card, and loads again for the next visitor`() {
    val kiosk = photo()
    assertEquals(listOf(Command.SHOW_ERROR_CARD), kiosk.onError())
    kiosk.onUnmounted()
    assertEquals(listOf(Command.RESTART), kiosk.onMounted())
  }

  @Test
  fun `failures after the end or a second error change nothing`() {
    val kiosk = film()
    kiosk.onEnded()
    assertEquals(emptyList<Command>(), kiosk.onPlaybackFailure(440_000, 450_000))
    assertEquals(emptyList<Command>(), kiosk.onError())
    assertEquals(State.ENDED, kiosk.state)
    val failed = film()
    failed.onError()
    assertEquals(emptyList<Command>(), failed.onError())
  }

  // Exit

  @Test
  fun `B or Y held one second leaves, from any state`() {
    for (prepare in listOf<(KioskSession) -> Unit>({}, { it.onUnmounted() }, { it.onEnded() }, { it.onError() })) {
      val kiosk = film()
      prepare(kiosk)
      assertEquals(emptyList<Command>(), kiosk.onExitButtons(held = false, nowMs = 0))
      assertEquals(emptyList<Command>(), kiosk.onExitButtons(held = true, nowMs = 100))
      assertEquals(emptyList<Command>(), kiosk.onExitButtons(held = true, nowMs = 1_099))
      assertEquals(listOf(Command.EXIT), kiosk.onExitButtons(held = true, nowMs = 1_100))
      assertEquals(State.EXITED, kiosk.state)
    }
  }

  @Test
  fun `a press shorter than a second leaves nothing, and the count starts again`() {
    val kiosk = film()
    kiosk.onExitButtons(held = false, nowMs = 0)
    kiosk.onExitButtons(held = true, nowMs = 100)
    kiosk.onExitButtons(held = true, nowMs = 900)
    assertEquals(emptyList<Command>(), kiosk.onExitButtons(held = false, nowMs = 950))
    assertEquals(emptyList<Command>(), kiosk.onExitButtons(held = true, nowMs = 1_000))
    assertEquals(emptyList<Command>(), kiosk.onExitButtons(held = true, nowMs = 1_999))
    assertEquals(listOf(Command.EXIT), kiosk.onExitButtons(held = true, nowMs = 2_000))
  }

  @Test
  fun `a button already held when the kiosk starts never counts until it was let go`() {
    val kiosk = film()
    assertEquals(emptyList<Command>(), kiosk.onExitButtons(held = true, nowMs = 0))
    assertEquals(emptyList<Command>(), kiosk.onExitButtons(held = true, nowMs = 5_000))
    assertEquals(State.WATCHING, kiosk.state)
    kiosk.onExitButtons(held = false, nowMs = 5_100)
    kiosk.onExitButtons(held = true, nowMs = 5_200)
    assertEquals(listOf(Command.EXIT), kiosk.onExitButtons(held = true, nowMs = 6_200))
  }

  @Test
  fun `once left, nothing else happens`() {
    val kiosk = film()
    kiosk.onExitButtons(held = false, nowMs = 0)
    kiosk.onExitButtons(held = true, nowMs = 10)
    kiosk.onExitButtons(held = true, nowMs = 1_010)
    assertEquals(emptyList<Command>(), kiosk.onExitButtons(held = true, nowMs = 3_000))
    assertEquals(emptyList<Command>(), kiosk.onUnmounted())
    assertEquals(emptyList<Command>(), kiosk.onMounted())
    assertEquals(emptyList<Command>(), kiosk.onEnded())
    assertEquals(emptyList<Command>(), kiosk.onError())
    assertEquals(State.EXITED, kiosk.state)
  }

  // Options

  // Recreation

  @Test
  fun `a recreated viewer starts a kiosk from the start, any other opening where it was`() {
    // The headset came off at 4 min 12 s of the film, or the end card showed after its last seconds
    assertEquals(0L, KioskSession.savedStartPositionMs(isKiosk = true, positionMs = 252_000L))
    assertEquals(0L, KioskSession.savedStartPositionMs(isKiosk = true, positionMs = 599_400L))
    assertEquals(252_000L, KioskSession.savedStartPositionMs(isKiosk = false, positionMs = 252_000L))
  }

  @Test
  fun `the options read the end text and the exit notice`() {
    val options = KioskOptions.parse("""{"endText":"Merci pour le voyage","exitHint":"Maintenez B ou Y"}""")!!
    assertEquals("Merci pour le voyage", options.endText)
    assertEquals("Maintenez B ou Y", options.exitHint)
  }

  @Test
  fun `options without texts still make a kiosk, with empty texts`() {
    val options = KioskOptions.parse("{}")!!
    assertEquals("", options.endText)
    assertEquals("", options.exitHint)
  }

  @Test
  fun `no options, or options that do not read, make no kiosk`() {
    assertNull(KioskOptions.parse(null))
    assertNull(KioskOptions.parse(""))
    assertNull(KioskOptions.parse("not json"))
    assertNull(KioskOptions.parse("[1, 2]"))
  }
}
