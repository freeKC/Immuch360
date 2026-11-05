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
    assertNull(switch.activeTable(stitched = true))

    assertNull(switch.onTrack(hasTrack = true, table = table))
    assertEquals(StabilizationSwitch.Track.READY, switch.track)
    assertSame(table, switch.activeTable(stitched = true))
    assertNull("an unstitched frame is not the picture of the table", switch.activeTable(stitched = false))
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
    assertNull(switch.activeTable(stitched = true))
    assertTrue(switch.cammDisabled)
    assertTrue("the button stays, dimmed", switch.buttonVisible)

    // Back on: the notice tells it at once
    assertEquals(StabilizationSwitch.Notice.STABILIZED, switch.toggle())
    assertSame(table, switch.activeTable(stitched = true))
    assertNull("told already", switch.onStabilizedFrame())
  }

  @Test
  fun aCammTrackShowsTheButtonAndMedia3AppliesItWhileOn() {
    val switch = StabilizationSwitch(enabled = true)
    switch.hasCamm = true
    assertTrue(switch.buttonVisible)
    assertFalse("on without a table: Media3 applies the CAMM track", switch.cammDisabled)
    assertNull(switch.activeTable(stitched = false))
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
    assertNull(switch.activeTable(stitched = true))
    assertEquals(StabilizationSwitch.Notice.STABILIZED, switch.toggle())
    assertNull(switch.onStabilizedFrame())
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
