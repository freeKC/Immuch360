package app.alextran.immich.djilink

/**
 * The sticks packed into the 13 byte body described in the format notes (p2/protocol.md, section 5.2 and 5.3): seven
 * eleven bit channels, neutral 1024, and the conversion
 *
 *   channel = clamp(truncate toward zero(1024 + 660 * input), 364, 1684)
 *
 * Nothing in stages 1 to 3 sends a body built here. It exists now because it is pure arithmetic that can be pinned by
 * unit tests long before any question of authority is answered, and because having one place for it means a capture
 * can correct one table instead of a scattering of shifts.
 *
 * [axisOrder] is empty: the notes do not establish which channel carries which axis, so no axis is assigned to any
 * channel until a capture of the remote's own sticks shows it. A body built today carries neutral on every channel.
 */
object ChannelMap {
  const val NEUTRAL = 1024
  const val MINIMUM = 364
  const val MAXIMUM = 1684
  const val SPAN = 660
  const val BODY_SIZE = 13

  /** Bit offset of each of the seven channels inside the body, lowest bit first */
  val channelBitOffsets = intArrayOf(8, 19, 30, 41, 52, 63, 74)

  /** Bit of the focus field, which the controller application sets to one */
  const val FOCUS_BIT = 97

  /** The two bits of the flight mode switch; the middle position is the application's own default */
  const val MODE_BIT = 98
  const val MODE_MIDDLE = 1

  /**
   * Which channel carries which axis, by channel index. Unassigned: it is filled from a capture of the remote's own
   * sticks moved one at a time, with that capture named beside it, and never from a reading of anyone's code.
   */
  val axisOrder: Map<Int, Axis> = emptyMap()

  fun toChannel(input: Double): Int {
    val value = (NEUTRAL + SPAN * input.coerceIn(-1.0, 1.0)).toInt()
    return value.coerceIn(MINIMUM, MAXIMUM)
  }

  /**
   * The 13 byte body for one reading, every channel [order] does not name left at neutral. The tests hand in an
   * order of their own to check the packing; the default order names nothing.
   */
  fun body(
    sample: StickSample,
    focus: Boolean = true,
    modeSwitch: Int = MODE_MIDDLE,
    order: Map<Int, Axis> = axisOrder,
  ): ByteArray {
    val out = ByteArray(BODY_SIZE)
    val values = IntArray(channelBitOffsets.size) { NEUTRAL }
    for ((channel, axis) in order) {
      require(channel in values.indices) { "no channel $channel in the body" }
      values[channel] = toChannel(sample.axis(axis))
    }
    channelBitOffsets.forEachIndexed { index, offset -> writeBits(out, offset, 11, values[index]) }
    if (focus) {
      writeBits(out, FOCUS_BIT, 1, 1)
    }
    writeBits(out, MODE_BIT, 2, modeSwitch and 0x03)
    return out
  }

  /** Reads a channel back out of a body, which is what the tests check the packing with */
  fun readChannel(body: ByteArray, channel: Int): Int = readBits(body, channelBitOffsets[channel], 11)

  fun writeBits(out: ByteArray, bitOffset: Int, bits: Int, value: Int) {
    for (index in 0 until bits) {
      val bit = (value ushr index) and 1
      if (bit == 0) {
        continue
      }
      val position = bitOffset + index
      out[position / 8] = (out[position / 8].toInt() or (1 shl (position % 8))).toByte()
    }
  }

  fun readBits(data: ByteArray, bitOffset: Int, bits: Int): Int {
    var value = 0
    for (index in 0 until bits) {
      val position = bitOffset + index
      val bit = (data[position / 8].toInt() ushr (position % 8)) and 1
      value = value or (bit shl index)
    }
    return value
  }
}
