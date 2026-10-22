package app.alextran.immich.djilink

/**
 * The sticks as this application reads them, with our own axis names.
 *
 * The names here are ours on purpose. The format notes describe a 13 byte body with seven eleven bit channels and
 * give the conversion from a float to a channel value, but they do not establish which channel is which axis, and the
 * only place that order appears is a set of structure offsets with no call site. Turning an offset into an axis name
 * would be a guess with an aircraft at the other end, so the order lives in one place ([ChannelMap.axisOrder]), is
 * empty, and is filled only from a capture.
 */
enum class Axis {
  /** Up is a climb */
  THROTTLE,

  /** Right is clockwise seen from above */
  YAW,

  /** Up is forward */
  PITCH,

  /** Right is right */
  ROLL,
}

/** One reading of the sticks: four axes between minus one and one, with the time it was taken */
data class StickSample(
  val throttle: Double = 0.0,
  val yaw: Double = 0.0,
  val pitch: Double = 0.0,
  val roll: Double = 0.0,
  /** Both triggers held, which is the dead man switch of the later stages */
  val triggersHeld: Boolean = false,
  val atMs: Long = 0,
  val sequence: Long = 0,
) {
  fun axis(axis: Axis): Double = when (axis) {
    Axis.THROTTLE -> throttle
    Axis.YAW -> yaw
    Axis.PITCH -> pitch
    Axis.ROLL -> roll
  }

  companion object {
    fun neutral(atMs: Long = 0, sequence: Long = 0): StickSample = StickSample(atMs = atMs, sequence = sequence)
  }
}

/** Shaping of a raw axis: a dead zone, an optional curve, and a clamp. No aircraft is involved. */
object StickShaping {
  const val DEAD_ZONE = 0.05

  fun shape(raw: Double, deadZone: Double = DEAD_ZONE, expo: Double = 0.0): Double {
    val clamped = raw.coerceIn(-1.0, 1.0)
    val magnitude = Math.abs(clamped)
    if (magnitude <= deadZone) {
      return 0.0
    }
    val scaled = (magnitude - deadZone) / (1.0 - deadZone)
    val curved = if (expo <= 0.0) scaled else (1.0 - expo) * scaled + expo * scaled * scaled * scaled
    return if (clamped < 0) -curved else curved
  }
}
