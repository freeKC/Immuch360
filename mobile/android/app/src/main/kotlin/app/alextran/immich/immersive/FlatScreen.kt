package app.alextran.immich.immersive

import com.meta.spatial.runtime.ButtonBits

/**
 * The grip of one hand, and its bit in the buttons a controller holds: the left controller holds ButtonSqueezeL, the
 * right one ButtonSqueezeR.
 */
internal enum class GripSide(val bit: Int) {
  LEFT(ButtonBits.ButtonSqueezeL),
  RIGHT(ButtonBits.ButtonSqueezeR),
}

/**
 * The grips on a flat screen of the viewer (a photo on the stereo quad or its compositor layer, a video on the flat
 * video screen), read from the buttons held at every frame. The idea of moving and resizing the flat screens with the
 * grips is Gaurav Mukherjee's (gmfun/Immuch360, branch quest/flat-3d); the mapping is ours, decided by FreeKC on 29
 * October so that the grip keeps showing the info panel:
 * - a short press of either grip, released before [HOLD_MS], shows or hides the info panel, on its release;
 * - a grip held [HOLD_MS] or more while its ray points at the screen grabs it ([Event.GrabStart]): the viewer moves the
 *   screen with that ray until the grip is released ([Event.GrabEnd]); held away from the screen it does nothing until
 *   the ray reaches the screen, and its release does nothing either;
 * - both grips held stretch the screen ([Event.StretchStart]), its width following the spread of the hands (see
 *   [ScreenStretch]), until either is released ([Event.StretchEnd]); a grab in progress becomes the stretch;
 * - a grip that took part in a grab or a stretch does nothing more until it is released.
 * Pure: the viewer gives the time, the buttons held and which ray points at the screen. Unit tested.
 */
internal class ScreenGrip(private val holdMs: Long = HOLD_MS) {
  sealed interface Event {
    data object TogglePanel : Event

    data class GrabStart(val side: GripSide) : Event

    data class GrabEnd(val side: GripSide) : Event

    data object StretchStart : Event

    data object StretchEnd : Event
  }

  private class Grip {
    /** When the grip went down (uptime ms), null while it is up. */
    var downAt: Long? = null

    /** The press went into a grab or a stretch, or was cut by [cancel]: its release does nothing. */
    var spent = false
  }

  private val grips = GripSide.entries.associateWith { Grip() }

  /** The grip that holds the screen now, null when none does. */
  var grabbing: GripSide? = null
    private set

  /** Both grips stretch the screen now. */
  var stretching = false
    private set

  /**
   * What the grips held at [nowMs] (uptime ms) start or end, given the buttons [heldBits] held by all the controllers
   * and whether the ray of each side points at the screen now ([pointsAtScreen], asked only when a grab may start).
   */
  fun update(nowMs: Long, heldBits: Int, pointsAtScreen: (GripSide) -> Boolean): List<Event> {
    val events = mutableListOf<Event>()
    for ((side, grip) in grips) {
      val held = (heldBits and side.bit) != 0
      val downAt = grip.downAt
      if (held && downAt == null) {
        grip.downAt = nowMs
        grip.spent = false
      } else if (!held && downAt != null) {
        events += release(side, grip, nowMs - downAt)
      }
    }
    val bothDown = grips.values.all { it.downAt != null }
    if (bothDown && !stretching) {
      grabbing?.let { events += Event.GrabEnd(it) }
      grabbing = null
      stretching = true
      grips.values.forEach { it.spent = true }
      events += Event.StretchStart
    }
    if (!stretching && grabbing == null) {
      for ((side, grip) in grips) {
        val downAt = grip.downAt ?: continue
        if (grip.spent || nowMs - downAt < holdMs || !pointsAtScreen(side)) continue
        grip.spent = true
        grabbing = side
        events += Event.GrabStart(side)
        break
      }
    }
    return events
  }

  /** What the release of [side], down [heldMs], ends: a stretch, its grab, or a short press. */
  private fun release(side: GripSide, grip: Grip, heldMs: Long): List<Event> {
    val spent = grip.spent
    grip.downAt = null
    grip.spent = false
    return when {
      stretching -> {
        stretching = false
        listOf(Event.StretchEnd)
      }
      grabbing == side -> {
        grabbing = null
        listOf(Event.GrabEnd(side))
      }
      !spent && heldMs < holdMs -> listOf(Event.TogglePanel)
      else -> emptyList()
    }
  }

  /**
   * The flat screen went away (another media, the viewer closing): a grab or a stretch ends, and the grips still held
   * do nothing until they are released.
   */
  fun cancel(): List<Event> {
    val events = mutableListOf<Event>()
    grabbing?.let { events += Event.GrabEnd(it) }
    if (stretching) events += Event.StretchEnd
    grabbing = null
    stretching = false
    grips.values.forEach { if (it.downAt != null) it.spent = true }
    return events
  }

  companion object {
    /** A grip held this long or more is no short press: it grabs the screen it points at. */
    const val HOLD_MS = 300L
  }
}
