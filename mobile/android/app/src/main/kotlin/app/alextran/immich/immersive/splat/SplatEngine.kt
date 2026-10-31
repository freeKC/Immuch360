package app.alextran.immich.immersive.splat

import android.net.Uri
import com.meta.spatial.core.Entity
import com.meta.spatial.core.Pose
import com.meta.spatial.core.SpatialContext
import com.meta.spatial.core.SpatialFeature
import com.meta.spatial.core.SystemManager

// The splat module of the Meta Spatial SDK (com.meta.spatial:meta-spatial-sdk-splat 0.14.0, under the Meta Platform
// Technologies SDK License, the licence of the SDK the APK already ships, whose article 1.6 on Experimental Features
// applies to this module: see licenses/meta-spatial-sdk/README.md) behind one interface, lot S5: the module is
// in the quest flavour only (questImplementation in android/app/build.gradle), so that the phone APKs keep their size.
// src/quest/kotlin/.../immersive/splat/SplatEngines.kt holds the object of the module, src/phone/... one that has
// none; both are named SplatEngines, so that the code of main compiles in both flavours (the pattern of
// relief/DepthEstimators).

/** The splat module, or its absence */
internal interface SplatEngine {
  /** Whether this APK has the module */
  val available: Boolean

  /**
   * The feature of the module for registerFeatures() of the viewer, which must come before any splat entity is made
   * (Meta's SplatSample); null without the module
   */
  fun feature(context: SpatialContext, systems: SystemManager): SpatialFeature?

  /**
   * The entity of the splat of [uri] (a file:// URI whose name ends with .spz or .ply) at [pose], hidden, its scale 1,
   * out of the reach of the controller rays; [onLoaded] comes once its load ended, [success] or not, with the message
   * of the module, on whichever thread the module calls it
   */
  fun create(uri: Uri, pose: Pose, onLoaded: (success: Boolean, error: String?) -> Unit): Entity

  /**
   * Moves the splat of [entity] to [pose] through the system of the module rather than its Transform (the fallback
   * of SplatViewerOptions.move); false when the module or its system is not there
   */
  fun moveBySystem(systems: SystemManager, entity: Entity, pose: Pose): Boolean
}
