package app.alextran.immich.djilink

/** Who keeps the link running: the page in front of the pilot, the relay while it sends, the flight view while it shows */
enum class LinkOwner { PAGE, RELAY, FLIGHT_VIEW }

/**
 * The owners of the link (p2/design-stage2b.md, 3.1). The link, the receiver, the player and the decoder start with the
 * first owner and stop only when the last one is gone: a pilot who leaves the page while the phone sends to a headset
 * does not cut the headset's picture, and a page opened again joins the running link without resetting its counters.
 * Pure, so that it is unit tested; the controller holds it under its own lock.
 */
class LinkOwners {
  private val held = mutableSetOf<LinkOwner>()

  /** Takes [owner]; true when it is the first one, so that the link starts */
  fun take(owner: LinkOwner): Boolean {
    val first = held.isEmpty()
    held.add(owner)
    return first
  }

  /** Releases [owner]; true when no owner is left, so that the link stops. Releasing an owner not held changes nothing. */
  fun release(owner: LinkOwner): Boolean {
    held.remove(owner)
    return held.isEmpty()
  }

  fun holds(owner: LinkOwner): Boolean = owner in held

  val isEmpty: Boolean get() = held.isEmpty()

  val owners: Set<LinkOwner> get() = held.toSet()

  fun clear() = held.clear()
}
