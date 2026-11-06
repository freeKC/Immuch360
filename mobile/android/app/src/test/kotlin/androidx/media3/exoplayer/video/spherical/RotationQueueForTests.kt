package androidx.media3.exoplayer.video.spherical

/**
 * Media3's FrameRotationQueue, which the renderer of its spherical view polls for the rotation of each frame it draws,
 * is package private: the tests of the 360° player reach it from its own package (StabilizedFramesTest).
 */
class RotationQueueForTests {
  private val queue = FrameRotationQueue()

  /** A rotation for the frame at [timeUs], as the camera motion listener of the view gives it */
  fun setRotation(timeUs: Long, angleAxis: FloatArray) = queue.setRotation(timeUs, angleAxis)

  fun reset() = queue.reset()

  /** The matrix of the frame at [timeUs] into [matrix] (column major, 4 x 4), false when the queue has none */
  fun pollRotationMatrix(matrix: FloatArray, timeUs: Long): Boolean = queue.pollRotationMatrix(matrix, timeUs)

  companion object {
    /** The recentre Media3 takes from the first rotation of a queue */
    fun computeRecenterMatrix(recenterMatrix: FloatArray, rotationMatrix: FloatArray) =
      FrameRotationQueue.computeRecenterMatrix(recenterMatrix, rotationMatrix)
  }
}
