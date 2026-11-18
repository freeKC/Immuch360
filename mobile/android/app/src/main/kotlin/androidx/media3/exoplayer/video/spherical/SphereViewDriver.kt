// In Media3's package on purpose: its touch tracker and orientation listener, whose interfaces the renderer of
// SphericalGLSurfaceView implements, are package private (issue 20, see SphereLookController of the app)
package androidx.media3.exoplayer.video.spherical

import android.graphics.PointF
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi

private const val TAG = "SphereViewDriver"

/**
 * Sets the whole view of a [SphericalGLSurfaceView] from the app, for the controls of the 360° photo viewer in the 360°
 * video player (issue 20). Media3 1.10.0 has no API for it: its renderer builds the view as touch pitch · device
 * orientation · touch yaw, from its own touch tracker (which stops the pitch at 45 degrees) and its own orientation
 * sensor (the attitude of the phone, which drags cannot leave), with a fixed field of view of 90 degrees.
 *
 * The renderer takes both through two interfaces of this package, the only way in: [TouchTracker.Listener] for the
 * touch offsets, set to zero once here, and [OrientationListener.Listener] for the device orientation, a 4x4 matrix it
 * copies as it is, which becomes the whole view the app computes (with the zoom in it, see
 * app.alextran.immich.spherical.SphereLookMath.viewMatrix). The app stops Media3's sensor
 * ([SphericalGLSurfaceView.setUseSensorRotation]) and replaces its touch listener, so nothing else writes them.
 *
 * The renderer is reached through the touch tracker the view keeps, found by the types of the fields, so that a renamed
 * field still matches; proguard-rules.pro keeps those fields and interfaces. A Media3 laid out otherwise gives null,
 * and the player keeps Media3's own touch and sensor. The frames of the video (the stabilisation of a raw video turns
 * each one, see StabilizedFrames) keep going through Media3's scene renderer, under this view.
 */
@OptIn(UnstableApi::class)
class SphereViewDriver private constructor(private val setOrientation: (FloatArray) -> Unit) {
  /**
   * Makes [viewMatrix] (column major, as android.opengl.Matrix) the view of the renderer from its next frame. The
   * renderer copies it under its own lock, so any thread may call this.
   */
  fun setView(viewMatrix: FloatArray) = setOrientation(viewMatrix)

  companion object {
    /** The driver of [view], or null when its renderer cannot be reached in this Media3 */
    fun of(view: SphericalGLSurfaceView): SphereViewDriver? {
      return try {
        val trackerField =
          SphericalGLSurfaceView::class.java.declaredFields.firstOrNull { it.type == TouchTracker::class.java }
            ?: return refused("no touch tracker")
        trackerField.isAccessible = true
        val tracker = trackerField.get(view) ?: return refused("no touch tracker set")
        val listenerField =
          TouchTracker::class.java.declaredFields.firstOrNull { it.type == TouchTracker.Listener::class.java }
            ?: return refused("no listener in the touch tracker")
        listenerField.isAccessible = true
        val renderer = listenerField.get(tracker)
        val touch = renderer as? TouchTracker.Listener ?: return refused("the listener takes no touch")
        val orientation = renderer as? OrientationListener.Listener ?: return refused("the listener takes no orientation")
        // The touch offsets stay at zero: the view comes whole through the orientation
        touch.onScrollChange(PointF(0f, 0f))
        // The roll the renderer keeps is the upright one, as before any sensor reading: with a touch pitch of zero it
        // does not change the view anyway
        SphereViewDriver { matrix -> orientation.onOrientationChange(matrix, -SphericalGLSurfaceView.UPRIGHT_ROLL) }
      } catch (e: Exception) {
        Log.w(TAG, "The spherical view cannot be driven, Media3's touch and sensor stay", e)
        null
      } catch (e: LinkageError) {
        Log.w(TAG, "The spherical view cannot be driven in this Media3, its touch and sensor stay", e)
        null
      }
    }

    private fun refused(reason: String): SphereViewDriver? {
      Log.w(TAG, "The spherical view cannot be driven ($reason), Media3's touch and sensor stay")
      return null
    }
  }
}
