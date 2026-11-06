package app.alextran.immich.spherical

import androidx.media3.exoplayer.video.spherical.CameraMotionListener

/**
 * The rotation each frame of the 360° player gets from the stabilisation table (issue 14), as the frame listener of
 * the spherical view hands the frames on (SphericalVideoActivity.CoverageFrameListener): for each frame, the rotation
 * at its time on the timeline of the video goes to the camera motion listener of the renderer first, keyed on the
 * presentation time the listener got, then the frame itself ([onFrame]). Media3's renderer keeps the rotations in a
 * queue keyed on that time (FrameRotationQueue, cleared when the time goes back at a seek) and polls it with the time
 * of the frame it draws, so the frame gets its own rotation. Without a table any more (the switch off, a frame that is
 * no longer the stitched sphere), one reset brings the frames back as they are, from the next one on.
 *
 * Media3 also recentres the view on the yaw of the first rotation it gets after a reset
 * (FrameRotationQueue.computeRecenterMatrix): a turn about the vertical of the display only, so the level stays, but
 * the stabilised view starts that far from the heading of the table (49 degrees on the X5 sample, 19 on the GoPro one,
 * under 9 on the X3, X4 and DJI ones), taken again each time the switch turns on.
 *
 * One per player activity, shared by the frame listeners of its players: a player replaced after a failure leaves a
 * rotation in the renderer, which the first frame of the next one without a table resets. [table] and [timeBaseUs]
 * are set on the main thread, [onFrame] runs on the playback thread or on the compositor's thread of a lens player.
 * Pure Kotlin but for Media3's listener interface: the unit tests run without a device.
 */
internal class StabilizedFrames(private val onFirstStabilizedFrame: () -> Unit = {}) {
  /** The table the frames get, null for none */
  @Volatile var table: StabilizationTable? = null

  /**
   * What to add to the presentation time a frame listener gets to find the frame on the timeline of the video, see
   * [timeBaseUs]
   */
  @Volatile var timeBaseUs: Long = 0L

  // A rotation went to the camera motion listener since its last reset
  @Volatile private var turning = false

  // The first stabilised frame was reported
  @Volatile private var reported = false

  /**
   * The frame at [presentationTimeUs] (the time the frame listener got) is about to be drawn: its rotation goes to
   * [motion] at that time, or a reset once the table is gone, then [render] hands the frame on to the scene
   */
  fun onFrame(presentationTimeUs: Long, motion: CameraMotionListener, render: () -> Unit) {
    val table = table
    if (table != null) {
      motion.onCameraMotion(presentationTimeUs, table.angleAxisAt(presentationTimeUs + timeBaseUs))
      turning = true
      if (!reported) {
        reported = true
        onFirstStabilizedFrame()
      }
    } else if (turning) {
      motion.onCameraMotionReset()
      turning = false
    }
    render()
  }

  companion object {
    /**
     * The time base of the frames of a player started at [startPositionMs]: the start position with the effect that
     * stitches a side by side frame ([sideBySideEffect]), zero otherwise. Media3 1.10.0 runs the frames of a player
     * with video effects through its video graph on the times of their buffers less the start position of the stream
     * (MediaCodecVideoRenderer.getBufferTimestampAdjustmentUs, -startPositionUs, set in onProcessedStreamChange and
     * cleared by onReset), and its frame listener gets those, so a player started at p gives frame times p early.
     * Without effects (a plain player, the lens player) the listener gets the time of the frame on the timeline of the
     * video. Pinned by StabilizedFramesTest, to be checked again at each Media3 upgrade.
     */
    fun timeBaseUs(sideBySideEffect: Boolean, startPositionMs: Long): Long =
      if (sideBySideEffect) startPositionMs.coerceAtLeast(0L) * 1000L else 0L
  }
}
