package app.alextran.immich.spherical

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** The stabilisation switch of the 360° player: the button, the table the frames get, the CAMM track, the notices */
class StabilizationSwitchTest {
  private val table =
    StabilizationTable.of(longArrayOf(0, 33_367), doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0))!!

  @Test
  fun aRawVideoWithATrackIsStabilisedOnceTheTableComes() {
    val switch = StabilizationSwitch(enabled = true)
    assertFalse("nothing known yet: no button", switch.buttonVisible)

    // Flutter reads the track: the button shows, the frames turn once the table is there
    assertNull(switch.onTrack(hasTrack = true, table = null))
    assertEquals(StabilizationSwitch.Track.PENDING, switch.track)
    assertTrue(switch.buttonVisible)
    assertNull(switch.activeTable())

    assertNull(switch.onTrack(hasTrack = true, table = table))
    assertEquals(StabilizationSwitch.Track.READY, switch.track)
    assertSame(table, switch.activeTable())
    assertTrue("one rotation: a CAMM track would stay off", switch.cammDisabled)

    // The first stabilised frame says so, once
    assertEquals(StabilizationSwitch.Notice.STABILIZED, switch.onStabilizedFrame())
    assertNull(switch.onStabilizedFrame())
  }

  @Test
  fun offGivesTheRawVideoForEveryFile() {
    val switch = StabilizationSwitch(enabled = true)
    switch.onTrack(hasTrack = true, table = table)
    assertNull("turned off: no notice", switch.toggle())
    assertFalse(switch.enabled)
    assertNull(switch.activeTable())
    assertTrue(switch.cammDisabled)
    assertTrue("the button stays, dimmed", switch.buttonVisible)

    // Back on: the notice tells it at once
    assertEquals(StabilizationSwitch.Notice.STABILIZED, switch.toggle())
    assertSame(table, switch.activeTable())
    assertNull("told already", switch.onStabilizedFrame())
  }

  @Test
  fun aCammTrackShowsTheButtonAndMedia3AppliesItWhileOn() {
    val switch = StabilizationSwitch(enabled = true)
    switch.hasCamm = true
    assertTrue(switch.buttonVisible)
    assertFalse("on without a table: Media3 applies the CAMM track", switch.cammDisabled)
    switch.stitched = false
    assertNull(switch.activeTable())
    assertTrue("a CAMM track turns any frame", switch.buttonVisible)
    switch.toggle()
    assertTrue("off: the CAMM track is disabled", switch.cammDisabled)
    assertEquals(StabilizationSwitch.Notice.STABILIZED, switch.toggle())
    assertFalse(switch.cammDisabled)
  }

  @Test
  fun aFileWithoutATrackSaysSoOnlyWhenTheUserTurnedItOn() {
    // On by default, then the file has no track after all: the button hides, nothing is said
    val quiet = StabilizationSwitch(enabled = true)
    quiet.onTrack(hasTrack = true, table = null)
    assertNull(quiet.onTrack(hasTrack = false, table = null))
    assertEquals(StabilizationSwitch.Track.NONE, quiet.track)
    assertFalse(quiet.buttonVisible)

    // Off in the settings, turned on in the player while the track is read, and none comes
    val asked = StabilizationSwitch(enabled = false)
    asked.onTrack(hasTrack = true, table = null)
    assertNull("nothing to say while the track is read", asked.toggle())
    assertEquals(StabilizationSwitch.Notice.NO_TRACK, asked.onTrack(hasTrack = false, table = null))
    assertFalse(asked.buttonVisible)

    // Turned on and off again: nothing either
    val changed = StabilizationSwitch(enabled = false)
    changed.onTrack(hasTrack = true, table = null)
    changed.toggle()
    changed.toggle()
    assertNull(changed.onTrack(hasTrack = false, table = null))
  }

  @Test
  fun theSettingMovesTheSwitchUntilTheUserPressesIt() {
    val switch = StabilizationSwitch(enabled = true)
    switch.onSetting(false)
    assertFalse(switch.enabled)
    switch.onSetting(true)
    assertTrue(switch.enabled)
    // The user turns it off while the table is built: the table, sent with the setting read before, keeps it off
    switch.toggle()
    switch.onSetting(true)
    assertFalse(switch.enabled)
    assertTrue(switch.wasTouched)
  }

  @Test
  fun aRecreatedPlayerKeepsTheSwitchAndTheNoticeShown() {
    val switch = StabilizationSwitch(enabled = true)
    switch.restore(enabled = false, touched = true, turnedOnByUser = true, stabilizedNoticeShown = true)
    switch.onSetting(true)
    assertFalse(switch.enabled)
    switch.onTrack(hasTrack = true, table = table)
    assertNull(switch.activeTable())
    assertEquals(StabilizationSwitch.Notice.STABILIZED, switch.toggle())
    assertNull(switch.onStabilizedFrame())
  }

  @Test
  fun anUnstitchedFrameHidesTheButtonOfTheTable() {
    // The stitch fell back to the frame as the camera recorded it: the table describes nothing there
    val switch = StabilizationSwitch(enabled = true)
    switch.onTrack(hasTrack = true, table = table)
    assertTrue(switch.buttonVisible)
    switch.stitched = false
    assertFalse("a button that would do nothing hides", switch.buttonVisible)
    assertNull(switch.activeTable())
    // Stitched again (a new player of the stitched plan): back
    switch.stitched = true
    assertTrue(switch.buttonVisible)
    assertSame(table, switch.activeTable())
  }

  @Test
  fun theSettingOffKeepsTheCammTrackOfAPlainVideoOff() {
    // Flutter tells the setting before every video opens, with no track of its own for a plain 360 video
    val switch = StabilizationSwitch(enabled = true)
    switch.onSetting(false)
    assertNull(switch.onTrack(hasTrack = false, table = null))
    switch.hasCamm = true
    assertTrue("the CAMM track shows the button", switch.buttonVisible)
    assertFalse(switch.enabled)
    assertTrue("off: Media3 does not apply the CAMM track", switch.cammDisabled)
    // On in the setting: Media3 applies it
    val on = StabilizationSwitch(enabled = true)
    on.onSetting(true)
    on.onTrack(hasTrack = false, table = null)
    on.hasCamm = true
    assertFalse(on.cammDisabled)
  }

  @Test
  fun theInboxKeepsTheLastMessageOfEachUrlApart() {
    try {
      val a = StabilizationInbox.Message("file:///a.insv", true, true, table, "a")
      val b = StabilizationInbox.Message("file:///b.insv", true, false, null, null)
      StabilizationInbox.post(a)
      // A late message about another video does not take the place of the one of the video that plays
      StabilizationInbox.post(b)
      assertEquals(a, StabilizationInbox.latestFor("file:///a.insv"))
      assertEquals(b, StabilizationInbox.latestFor("file:///b.insv"))
      // The last few URLs only: the oldest goes
      for (n in 0 until StabilizationInbox.MAX_URLS) {
        StabilizationInbox.post(b.copy(url = "file:///c$n.insv"))
      }
      assertNull(StabilizationInbox.latestFor("file:///a.insv"))
      assertNull(StabilizationInbox.latestFor("file:///b.insv"))
      assertEquals("file:///c0.insv", StabilizationInbox.latestFor("file:///c0.insv")?.url)
      assertNull(StabilizationInbox.latestFor(null))
    } finally {
      for (n in 0 until StabilizationInbox.MAX_URLS) StabilizationInbox.forget("file:///c$n.insv")
    }
  }

  @Test
  fun theInboxKeepsTheLastMessageForThePlayerOfItsUrl() {
    val got = mutableListOf<StabilizationInbox.Message>()
    StabilizationInbox.listen { got += it }
    try {
      val pending = StabilizationInbox.Message("file:///a.insv", true, true, null, null)
      StabilizationInbox.post(pending)
      assertEquals(pending, StabilizationInbox.latestFor("file:///a.insv"))
      assertNull(StabilizationInbox.latestFor("file:///b.insv"))
      val ready = pending.copy(table = table, summary = "2 frames")
      StabilizationInbox.post(ready)
      assertEquals(listOf(pending, ready), got)
      StabilizationInbox.forget("file:///b.insv")
      assertEquals(ready, StabilizationInbox.latestFor("file:///a.insv"))
      StabilizationInbox.forget("file:///a.insv")
      assertNull(StabilizationInbox.latestFor("file:///a.insv"))

      // A player that closes after the next one opened leaves the new one listening
      val next = mutableListOf<StabilizationInbox.Message>()
      val nextListener: (StabilizationInbox.Message) -> Unit = { next += it }
      val closing: (StabilizationInbox.Message) -> Unit = {}
      StabilizationInbox.listen(nextListener)
      StabilizationInbox.stopListening(closing)
      StabilizationInbox.post(pending)
      assertEquals(listOf(pending), next)
      StabilizationInbox.stopListening(nextListener)
      StabilizationInbox.post(ready)
      assertEquals(listOf(pending), next)
    } finally {
      StabilizationInbox.listen(null)
    }
  }
}
