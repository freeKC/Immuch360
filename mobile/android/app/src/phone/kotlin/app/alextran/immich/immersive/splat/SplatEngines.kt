package app.alextran.immich.immersive.splat

import android.net.Uri
import com.meta.spatial.core.Entity
import com.meta.spatial.core.Pose
import com.meta.spatial.core.SpatialContext
import com.meta.spatial.core.SpatialFeature
import com.meta.spatial.core.SystemManager

// The phone flavour ships no splat module: it is in the quest flavour only (lot S5), so that the phone APKs keep their
// size. The APK of the phone flavour still runs on a Quest when installed by hand; there a splat says it is not in
// this version of the app (SplatGate). Same object name and shape as src/quest/kotlin/.../immersive/splat/
// SplatEngines.kt, so that the code of main compiles in both flavours.

internal object SplatEngines : SplatEngine {
  override val available = false

  override fun feature(context: SpatialContext, systems: SystemManager): SpatialFeature? = null

  override fun create(uri: Uri, pose: Pose, onLoaded: (success: Boolean, error: String?) -> Unit): Entity =
    throw UnsupportedOperationException("this version of the app has no splat module: it is in the Quest version")

  override fun moveBySystem(systems: SystemManager, entity: Entity, pose: Pose): Boolean = false
}
