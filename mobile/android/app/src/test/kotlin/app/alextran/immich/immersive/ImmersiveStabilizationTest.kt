package app.alextran.immich.immersive

import app.alextran.immich.spherical.StabilizationInbox
import app.alextran.immich.spherical.StabilizationSwitch
import app.alextran.immich.spherical.StabilizationTable
import app.alextran.immich.spherical.StabilizedStitch
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The stabilisation of the immersive viewer of the Meta Quest (issue 14, lot d3): the messages of Flutter keyed by
 * URL, the switch of each media, what the stitch gets, the notices and the presses of the user.
 */
class ImmersiveStabilizationTest {
  private val notices = mutableListOf<StabilizationSwitch.Notice>()
  private val toggles = mutableListOf<Boolean>()
  private var changes = 0
  private val posted = mutableListOf<() -> Unit>()

  private val table: StabilizationTable =
    StabilizationTable.of(longArrayOf(0, 33_367), doubleArrayOf(1.0, 0.0, 0.0, 0.0, 0.9998, 0.0, 0.0209, 0.0))!!

  private lateinit var stabilization: ImmersiveStabilization

  @Before
  fun setUp() {
    ImmersiveStabilizationInbox.clear()
    stabilization =
      ImmersiveStabilization(
        postToMain = { posted += it },
        onChanged = { changes++ },
        onNotice = { notices += it },
        onToggled = { toggles += it },
      )
    stabilization.listen()
  }

  @After
  fun tearDown() = ImmersiveStabilizationInbox.clear()

  private fun message(url: String, enabled: Boolean = true, hasTrack: Boolean = true, table: StabilizationTable? = null) =
    StabilizationInbox.Message(url, enabled, hasTrack, table, null)

  private fun isIdentity(stitch: StabilizedStitch) =
    stitch.matrixAt(33_367).contentEquals(StabilizedStitch.identity())

  @Test
  fun aRawVideoGetsItsTableInsideTheStitchOnceItsFrameIsStitched() {
    // Flutter announces the video before the viewer shows it, then sends the table while it plays
    ImmersiveStabilizationInbox.post(message("a"))
    stabilization.onMedia("a", rawVideo = true)
    assertFalse("no player yet", stabilization.buttonVisible)
    stabilization.onPlay(sideBySide = true, stitchedFrame = true, startPositionMs = 1_500)
    assertTrue("the track is read: the button shows", stabilization.buttonVisible)
    assertTrue(stabilization.enabled)
    assertEquals(1_500_000L, stabilization.stitch.timeBaseUs)
    assertTrue("no table yet", isIdentity(stabilization.stitch))
    ImmersiveStabilizationInbox.post(message("a", table = table))
    assertSame(table, stabilization.stitch.table)
    // The first frame drawn with it tells the user, once, on the main thread
    stabilization.stitch.matrixAt(0)
    stabilization.stitch.matrixAt(33_367)
    assertEquals(1, posted.size)
    posted.single().invoke()
    assertEquals(listOf(StabilizationSwitch.Notice.STABILIZED), notices)
    // The lens compositor gets the times of the timeline
    stabilization.onPlay(sideBySide = false, stitchedFrame = true, startPositionMs = 1_500)
    assertEquals(0L, stabilization.stitch.timeBaseUs)
  }

  @Test
  fun aMessageAboutAnotherMediaWaitsForIt() {
    stabilization.onMedia("a", rawVideo = true)
    stabilization.onPlay(sideBySide = false, stitchedFrame = true, startPositionMs = 0)
    // Flutter announces the next media while the viewer still shows this one
    ImmersiveStabilizationInbox.post(message("b", table = table))
    assertFalse(stabilization.buttonVisible)
    assertNull(stabilization.stitch.table)
    // Shown next: its table is there at once
    stabilization.onMedia("b", rawVideo = true)
    stabilization.onPlay(sideBySide = false, stitchedFrame = true, startPositionMs = 0)
    assertTrue(stabilization.buttonVisible)
    assertSame(table, stabilization.stitch.table)
  }

  @Test
  fun offOrUnstitchedTheStitchGetsTheIdentity() {
    ImmersiveStabilizationInbox.post(message("a", enabled = false, table = table))
    stabilization.onMedia("a", rawVideo = true)
    stabilization.onPlay(sideBySide = true, stitchedFrame = true, startPositionMs = 0)
    assertTrue("off: the button still shows, to turn it on", stabilization.buttonVisible)
    assertFalse(stabilization.enabled)
    assertTrue(isIdentity(stabilization.stitch))
    stabilization.toggle()
    assertEquals(listOf(true), toggles)
    assertEquals(listOf(StabilizationSwitch.Notice.STABILIZED), notices)
    assertSame(table, stabilization.stitch.table)
    assertFalse(isIdentity(stabilization.stitch))
    // The stitching failed: the raw frame plays as it is, the button hides, the stitch (if any) gets nothing
    stabilization.onPlay(sideBySide = false, stitchedFrame = false, startPositionMs = 0)
    assertFalse(stabilization.buttonVisible)
    assertNull(stabilization.stitch.table)
  }

  @Test
  fun thePressOfTheUserCarriesToTheNextMediaOverTheSetting() {
    ImmersiveStabilizationInbox.post(message("a", table = table))
    stabilization.onMedia("a", rawVideo = true)
    stabilization.onPlay(sideBySide = false, stitchedFrame = true, startPositionMs = 0)
    stabilization.toggle()
    assertEquals(listOf(false), toggles)
    assertNull(stabilization.stitch.table)
    // The next media was resolved with the setting read when the viewer opened, still on
    ImmersiveStabilizationInbox.post(message("b", enabled = true, table = table))
    stabilization.onMedia("b", rawVideo = true)
    stabilization.onPlay(sideBySide = false, stitchedFrame = true, startPositionMs = 0)
    assertFalse("the user's choice wins", stabilization.enabled)
    assertNull(stabilization.stitch.table)
    ImmersiveStabilizationInbox.post(message("b", enabled = true, table = table))
    assertFalse(stabilization.enabled)
  }

  @Test
  fun aFileWithoutATrackHidesTheButtonAndSaysSoOnlyWhenTurnedOn() {
    ImmersiveStabilizationInbox.post(message("a"))
    stabilization.onMedia("a", rawVideo = true)
    stabilization.onPlay(sideBySide = false, stitchedFrame = true, startPositionMs = 0)
    assertTrue(stabilization.buttonVisible)
    ImmersiveStabilizationInbox.post(message("a", hasTrack = false))
    assertFalse(stabilization.buttonVisible)
    assertTrue(notices.isEmpty())
    assertNull(stabilization.stitch.table)
  }

  @Test
  fun photosAndPlainVideosGetNoSwitchAndAClosedViewerHearsNothing() {
    ImmersiveStabilizationInbox.post(message("p", table = table))
    stabilization.onMedia("p", rawVideo = false)
    stabilization.onPlay(sideBySide = false, stitchedFrame = false, startPositionMs = 0)
    assertFalse(stabilization.buttonVisible)
    assertNull(stabilization.stitch.table)
    stabilization.toggle()
    assertTrue(toggles.isEmpty())
    // Closed: the stitch gets nothing, a late message changes nothing
    stabilization.onMedia("a", rawVideo = true)
    stabilization.release()
    val before = changes
    ImmersiveStabilizationInbox.post(message("a", table = table))
    assertEquals(before, changes)
    assertNull(stabilization.stitch.table)
    assertArrayEquals(StabilizedStitch.identity(), stabilization.stitch.matrixAt(0), 0f)
  }

  @Test
  fun theInboxKeepsTheLastMessagesOfThreeUrls() {
    for (url in listOf("a", "b", "c", "d")) ImmersiveStabilizationInbox.post(message(url))
    assertNull(ImmersiveStabilizationInbox.latestFor("a"))
    assertNotEquals(null, ImmersiveStabilizationInbox.latestFor("d"))
    ImmersiveStabilizationInbox.post(message("b", enabled = false))
    assertFalse(ImmersiveStabilizationInbox.latestFor("b")!!.enabled)
  }
}
