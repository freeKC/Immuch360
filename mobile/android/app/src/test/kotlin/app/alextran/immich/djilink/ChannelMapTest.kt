package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The arithmetic of the 13 byte body. Nothing sends one at this stage; the packing is pinned now so that the day a
 * capture says which channel is which axis, one table changes and the test says whether the packing still holds.
 */
class ChannelMapTest {
  @Test
  fun neutralIsTenTwentyFourAndTheClampsAreTheOnesInTheNotes() {
    assertEquals(ChannelMap.NEUTRAL, ChannelMap.toChannel(0.0))
    assertEquals(ChannelMap.MAXIMUM, ChannelMap.toChannel(1.0))
    assertEquals(ChannelMap.MINIMUM, ChannelMap.toChannel(-1.0))
    assertEquals(ChannelMap.MAXIMUM, ChannelMap.toChannel(4.0))
    assertEquals(ChannelMap.MINIMUM, ChannelMap.toChannel(-4.0))
  }

  @Test
  fun theConversionTruncatesTowardZero() {
    // 1024 + 660 * 0.5 is 1354, and 1024 - 660 * 0.5 is 694; a half way value never rounds away from zero
    assertEquals(1354, ChannelMap.toChannel(0.5))
    assertEquals(694, ChannelMap.toChannel(-0.5))
    assertEquals(1024, ChannelMap.toChannel(0.001))
  }

  /** An order made up for the test only: the packing is checked, not which axis is which */
  private val testOrder = mapOf(0 to Axis.THROTTLE, 1 to Axis.YAW, 2 to Axis.PITCH, 3 to Axis.ROLL)

  @Test
  fun aBodyIsThirteenBytesAndTheChannelsReadBackOut() {
    val sample = StickSample(throttle = 1.0, yaw = -1.0, pitch = 0.5, roll = 0.0)
    val body = ChannelMap.body(sample, order = testOrder)
    assertEquals(ChannelMap.BODY_SIZE, body.size)
    for ((channel, axis) in testOrder) {
      assertEquals(ChannelMap.toChannel(sample.axis(axis)), ChannelMap.readChannel(body, channel))
    }
  }

  @Test
  fun theChannelsTheOrderDoesNotNameStayNeutral() {
    val body = ChannelMap.body(StickSample(throttle = 1.0), order = testOrder)
    for (channel in testOrder.size until ChannelMap.channelBitOffsets.size) {
      assertEquals(ChannelMap.NEUTRAL, ChannelMap.readChannel(body, channel))
    }
  }

  @Test
  fun noAxisIsAssignedUntilACaptureShowsIt() {
    assertTrue(ChannelMap.axisOrder.isEmpty())
    val body = ChannelMap.body(StickSample(throttle = 1.0, yaw = -1.0, pitch = 1.0, roll = -1.0))
    for (channel in ChannelMap.channelBitOffsets.indices) {
      assertEquals(ChannelMap.NEUTRAL, ChannelMap.readChannel(body, channel))
    }
  }

  @Test
  fun theFocusBitAndTheModeSwitchAreWhereTheNotesPutThem() {
    val body = ChannelMap.body(StickSample(), focus = true, modeSwitch = ChannelMap.MODE_MIDDLE)
    assertEquals(1, ChannelMap.readBits(body, ChannelMap.FOCUS_BIT, 1))
    assertEquals(ChannelMap.MODE_MIDDLE, ChannelMap.readBits(body, ChannelMap.MODE_BIT, 2))
    val without = ChannelMap.body(StickSample(), focus = false, modeSwitch = 0)
    assertEquals(0, ChannelMap.readBits(without, ChannelMap.FOCUS_BIT, 1))
  }

  @Test
  fun shapingHasADeadZoneAndNeverLeavesTheRange() {
    assertEquals(0.0, StickShaping.shape(0.03), 0.0)
    assertEquals(1.0, StickShaping.shape(1.4), 1e-9)
    assertEquals(-1.0, StickShaping.shape(-1.4), 1e-9)
    assertEquals(0.0, StickShaping.shape(0.0), 0.0)
  }
}
