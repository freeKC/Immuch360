package app.alextran.immich.spherical

/**
 * The stabilisation of a raw 360° video turned inside its stitch (issue 14, lot d3, the immersive viewer of the Meta
 * Quest): the stitch shaders ([app.alextran.immich.core.raw.RawStitchShaders]) look each output pixel up through the
 * mat3 uniform uStabilization, which [matrixAt] gives for each frame from its presentation time. The frame is
 * stitched with its own rotation, so the picture and the correction never part, seeks included, and the sphere of the
 * viewer stays where it is. The phone's player turns its sphere instead (Media3's CameraMotionListener, see
 * [StabilizedFrames]); its stitch keeps the identity.
 *
 * Read by the stitch on its GL thread: the side by side effect (DualFisheyeEffect.drawFrame, with the times of its
 * video graph, [timeBaseUs] early) and the lens compositor (TwoLensCompositor.drawNow, with the times of the timeline).
 * [table] and [timeBaseUs] are set on the main thread. Pure Kotlin: the unit tests run without a device.
 */
class StabilizedStitch(private val onFirstStabilizedFrame: () -> Unit = {}) {
  /**
   * The table the frames get, null for none (the switch off, no track, a frame that is not the stitched sphere). A new
   * table reports its first stabilised frame again.
   */
  @Volatile
  var table: StabilizationTable? = null
    set(value) {
      if (value !== field) reported = false
      field = value
    }

  /**
   * What to add to the presentation time the stitch gets to find the frame on the timeline of the video: the start
   * position for the side by side effect, zero for the lens compositor, see [StabilizedFrames.timeBaseUs]
   */
  @Volatile var timeBaseUs: Long = 0L

  // The first frame drawn with the current table was reported
  @Volatile private var reported = false

  /**
   * The uniform of the frame at [presentationTimeUs] (the time the stitch got): the transpose of its correction (see
   * [StabilizationTable.stitchMatrixAt]), or the identity without a table. The first frame drawn with a table calls
   * the listener, on the thread of the stitch.
   */
  fun matrixAt(presentationTimeUs: Long): FloatArray {
    val current = table ?: return identity()
    val matrix = current.stitchMatrixAt(presentationTimeUs + timeBaseUs)
    if (!reported) {
      reported = true
      onFirstStabilizedFrame()
    }
    return matrix
  }

  companion object {
    /** The identity uniform, a new array each time: what a stitch without a stabilisation sets */
    fun identity(): FloatArray = floatArrayOf(1f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 1f)

    /** The uniform of [stitch] at [presentationTimeUs], the identity without one */
    fun matrixOf(stitch: StabilizedStitch?, presentationTimeUs: Long): FloatArray =
      stitch?.matrixAt(presentationTimeUs) ?: identity()
  }
}
