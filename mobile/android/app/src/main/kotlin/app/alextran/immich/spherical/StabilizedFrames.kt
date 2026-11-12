package app.alextran.immich.spherical

import androidx.media3.exoplayer.video.spherical.CameraMotionListener
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.round
import kotlin.math.sin

/**
 * The rotation each frame of the 360° player gets from the stabilisation table (issue 14), as the frame listener of
 * the spherical view hands the frames on (SphericalVideoActivity.CoverageFrameListener): for each frame, the rotation
 * at its time on the timeline of the video goes to the camera motion listener of the renderer first, keyed on the
 * presentation time the listener got, then the frame itself ([onFrame]). Media3's renderer keeps the rotations in a
 * queue keyed on that time (FrameRotationQueue, cleared when the time goes back at a seek) and polls it with the time
 * of the frame it draws, so the frame gets its own rotation. Without a table any more (the switch off, a frame that is
 * no longer the stitched sphere), one reset brings the frames back as they are, from the next one on.
 *
 * Media3 also recentres the view on the heading of the first rotation it draws after a reset
 * (FrameRotationQueue.computeRecenterMatrix): a turn about the vertical of the display that it applies to every later
 * frame, so the stabilised view would start that far from the heading of the table (49 degrees on the X5 file of lot
 * c, 19 on the GoPro one). No rotation sent after that draw can undo it, and the first drawn rotation always loses its
 * heading, so the frames start without it instead ([HeadingFade]): for [holdUs] after each reset (at least
 * [minHoldFrames] frames) each frame gets its correction less its own heading, so whichever of them Media3 draws
 * first, its recentre is the identity; then the heading of the table comes back over [fadeUs], and from there on each
 * frame shows exactly the correction of the table. The level is right from the first frame. A reset of the queue by
 * Media3 itself (its camera motion renderer, for a file with a CAMM track) goes through [forwardingResets], so that the
 * frames start again the same way.
 *
 * One per player activity, shared by the frame listeners of its players: a player replaced after a failure leaves a
 * rotation in the renderer, which the first frame of the next one without a table resets. [table] and [timeBaseUs]
 * are set on the main thread, [onFrame] runs on the playback thread or on the compositor's thread of a lens player.
 * Pure Kotlin but for Media3's listener interface: the unit tests run without a device.
 */
internal class StabilizedFrames(
  private val holdUs: Long = HOLD_US,
  private val minHoldFrames: Int = MIN_HOLD_FRAMES,
  private val fadeUs: Long = FADE_US,
  private val onFirstStabilizedFrame: () -> Unit = {},
) {
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

  // Rotations sent since the queue of the renderer was last reset (or since it was made), see HeadingFade
  @Volatile private var sentSinceReset = 0

  // The heading of the last rotation sent, unwrapped, in radians
  private var lastHeading = 0.0

  /**
   * Sets the table the frames get, as [table] does, and says whether that changes what the frames get: a paused frame
   * is then drawn again (SphericalVideoActivity.redrawPausedFrame)
   */
  fun changeTable(next: StabilizationTable?): Boolean {
    val changed = table !== next
    table = next
    return changed
  }

  /**
   * The frame at [presentationTimeUs] (the time the frame listener got) is about to be drawn: its rotation goes to
   * [motion] at that time, or a reset once the table is gone, then [render] hands the frame on to the scene
   */
  fun onFrame(presentationTimeUs: Long, motion: CameraMotionListener, render: () -> Unit) {
    val table = table
    if (table != null) {
      val correction = table.quaternionAt(presentationTimeUs + timeBaseUs)
      val sent = sentSinceReset
      val heading = HeadingFade.unwrap(HeadingFade.heading(correction), if (sent == 0) null else lastHeading)
      lastHeading = heading
      val stepUs = HeadingFade.frameStepUs(table)
      val share =
        HeadingFade.share(
          sent,
          holdFrames = max(minHoldFrames, HeadingFade.frames(holdUs, stepUs)),
          fadeFrames = HeadingFade.frames(fadeUs, stepUs),
        )
      val shown = HeadingFade.shown(correction, heading, share)
      motion.onCameraMotion(presentationTimeUs, StabilizationMath.angleAxis(shown))
      if (sent < Int.MAX_VALUE) sentSinceReset = sent + 1
      turning = true
      if (!reported) {
        reported = true
        onFirstStabilizedFrame()
      }
    } else if (turning) {
      motion.onCameraMotionReset()
      turning = false
      sentSinceReset = 0
    }
    render()
  }

  /**
   * [scene], the camera motion listener of the renderer, as the player gets it for the CAMM track of a file: the same,
   * but a reset of its queue by Media3 (its camera motion renderer at a seek or when the track goes) makes the frames
   * of the table start again without their heading, as after a reset of ours
   */
  fun forwardingResets(scene: CameraMotionListener): CameraMotionListener =
    object : CameraMotionListener {
      override fun onCameraMotion(timeUs: Long, rotation: FloatArray) = scene.onCameraMotion(timeUs, rotation)

      override fun onCameraMotionReset() {
        sentSinceReset = 0
        scene.onCameraMotionReset()
      }
    }

  companion object {
    /** How long the frames go without their heading after a reset: Media3 has drawn one of them by then */
    const val HOLD_US = 300_000L

    /** And at least that many frames */
    const val MIN_HOLD_FRAMES = 8

    /** How long the heading of the table takes to come back after that */
    const val FADE_US = 1_000_000L

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

/**
 * The heading of a correction as Media3's recentre sees it, and the correction shown with part of its heading taken
 * off (see [StabilizedFrames]). In the view frame of the stitch (x to the right, y down, z forward): the heading of a
 * correction K is the angle about the vertical y of K z, the direction the front of the picture is shown at, from z
 * towards x. Media3 turns its sphere by F K F (F = diag(1, -1, -1)), whose z column is -F K z, and recentres with the
 * turn about its y that brings that column back into its y z plane: the turn about y that takes the heading of K off.
 * Quaternions (w, x, y, z), Hamilton product.
 */
internal object HeadingFade {
  /** The heading of [q] in radians, in (-pi, pi]; 0 for a correction that shows the front straight up or down */
  fun heading(q: DoubleArray): Double {
    return atan2(2 * (q[1] * q[3] + q[0] * q[2]), 1 - 2 * (q[1] * q[1] + q[2] * q[2]))
  }

  /** [heading] moved by whole turns to the nearest of [previous], so that a blend of it moves smoothly */
  fun unwrap(heading: Double, previous: Double?): Double {
    if (previous == null) return heading
    return heading + 2 * PI * round((previous - heading) / (2 * PI))
  }

  /**
   * [q] with the share 1 - [share] of its [heading] taken off: the turn by -(1 - share) heading about y, then q. 0
   * gives a correction with no heading (the level only, the front where the camera points), 1 gives q itself.
   */
  fun shown(q: DoubleArray, heading: Double, share: Double): DoubleArray {
    if (share >= 1.0) return q
    val half = -(1 - share) * heading / 2
    val pw = cos(half)
    val py = sin(half)
    return doubleArrayOf(
      pw * q[0] - py * q[2],
      pw * q[1] + py * q[3],
      pw * q[2] + py * q[0],
      pw * q[3] - py * q[1],
    )
  }

  /**
   * How much of the heading the frame gets after [sent] rotations since the last reset: none for [holdFrames] frames,
   * then a smooth step up to all of it over [fadeFrames] frames
   */
  fun share(sent: Int, holdFrames: Int, fadeFrames: Int): Double {
    if (sent < holdFrames) return 0.0
    if (fadeFrames <= 0) return 1.0
    val t = ((sent - holdFrames + 1).toDouble() / fadeFrames).coerceIn(0.0, 1.0)
    return t * t * (3 - 2 * t)
  }

  /** Frames of [stepUs] in [durationUs], rounded up */
  fun frames(durationUs: Long, stepUs: Long): Int =
    if (durationUs <= 0) 0 else ceil(durationUs.toDouble() / stepUs.coerceAtLeast(1L)).toInt()

  /** The mean time between two frames of [table], a 30 frames a second step for a table of one frame */
  fun frameStepUs(table: StabilizationTable): Long =
    if (table.size < 2) 33_333L else ((table.lastTimeUs - table.firstTimeUs) / (table.size - 1)).coerceAtLeast(1L)
}
