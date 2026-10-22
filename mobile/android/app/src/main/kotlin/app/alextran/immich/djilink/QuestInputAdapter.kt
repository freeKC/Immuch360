package app.alextran.immich.djilink

/**
 * One way of reading sticks, whatever the hardware is.
 *
 * The Spatial SDK this application uses carries no analog thumbstick value at all: its controller component has
 * button bits and four direction bits and nothing else. Analog Touch thumbsticks therefore need an activity of our
 * own with an OpenXR action set, which is a later stage. So the interface comes first and the implementations arrive
 * in the order that lets the safety machinery be built and tested on hardware that exists today:
 *
 * 1. a gamepad over Bluetooth, which is analog now ([GamepadStickSource]);
 * 2. the controller pose, which is analog in the Spatial SDK, as a fallback and as a motion style option;
 * 3. the native OpenXR action set, which gives the Touch thumbsticks, built once there is a reason to send anything.
 */
interface QuestInputAdapter {
  /** Shown on the page so the pilot knows what is being read */
  val kind: String

  /** The newest reading, or null when none arrived */
  fun latest(): StickSample?
}

/**
 * A gamepad, in DJI mode 2: left stick is throttle and yaw, right stick is pitch and roll, both triggers are the dead
 * man switch. Values are fed in by whoever receives the motion events, so this class needs no Android type.
 */
class GamepadStickSource(
  private val deadZone: Double = StickShaping.DEAD_ZONE,
  private val expo: Double = 0.0,
) : QuestInputAdapter {
  override val kind: String = "gamepad"

  private var sample: StickSample? = null
  private var sequence = 0L

  /** Raw axes, each between minus one and one, with up positive on both sticks */
  fun offer(
    leftHorizontal: Double,
    leftVertical: Double,
    rightHorizontal: Double,
    rightVertical: Double,
    triggersHeld: Boolean,
    nowMs: Long,
  ): StickSample {
    sequence += 1
    val next = StickSample(
      throttle = StickShaping.shape(leftVertical, deadZone, expo),
      yaw = StickShaping.shape(leftHorizontal, deadZone, expo),
      pitch = StickShaping.shape(rightVertical, deadZone, expo),
      roll = StickShaping.shape(rightHorizontal, deadZone, expo),
      triggersHeld = triggersHeld,
      atMs = nowMs,
      sequence = sequence,
    )
    sample = next
    return next
  }

  override fun latest(): StickSample? = sample

  fun reset() {
    sample = null
  }
}
