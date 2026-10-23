package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The owners of the link: it starts with the first and stops with the last (design 3.1) */
class LinkOwnersTest {
  @Test
  fun theLinkStopsWithTheLastOwnerOnly() {
    val owners = LinkOwners()
    assertTrue("the page starts the link", owners.take(LinkOwner.PAGE))
    assertFalse("the relay joins it", owners.take(LinkOwner.RELAY))
    assertFalse("the page leaves while the relay sends", owners.release(LinkOwner.PAGE))
    assertTrue(owners.holds(LinkOwner.RELAY))
    assertFalse("the page opened again joins the running link", owners.take(LinkOwner.PAGE))
    assertFalse(owners.release(LinkOwner.RELAY))
    assertTrue("the last owner stops it", owners.release(LinkOwner.PAGE))
    assertTrue(owners.isEmpty)
  }

  @Test
  fun theFlightViewKeepsTheReceiverWhileThePageIsAway() {
    val owners = LinkOwners()
    owners.take(LinkOwner.PAGE)
    owners.take(LinkOwner.FLIGHT_VIEW)
    assertFalse(owners.release(LinkOwner.PAGE))
    assertEquals(setOf(LinkOwner.FLIGHT_VIEW), owners.owners)
    assertTrue(owners.release(LinkOwner.FLIGHT_VIEW))
  }

  @Test
  fun releasingAnOwnerNotHeldOrTwiceChangesNothing() {
    val owners = LinkOwners()
    assertTrue("nothing held: the link is stopped", owners.release(LinkOwner.PAGE))
    owners.take(LinkOwner.RELAY)
    owners.take(LinkOwner.RELAY)
    assertFalse(owners.release(LinkOwner.FLIGHT_VIEW))
    assertTrue(owners.release(LinkOwner.RELAY))
    assertTrue(owners.release(LinkOwner.RELAY))
  }
}
