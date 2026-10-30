package app.alextran.immich.immersive.splat

import android.net.Uri
import com.meta.spatial.core.Entity
import com.meta.spatial.core.Pose
import com.meta.spatial.core.SpatialContext
import com.meta.spatial.core.SpatialFeature
import com.meta.spatial.core.SystemManager
import com.meta.spatial.core.Vector3
import com.meta.spatial.splat.SpatialSDKExperimentalSplatAPI
import com.meta.spatial.splat.Splat
import com.meta.spatial.splat.SplatFeature
import com.meta.spatial.splat.SplatLoadEventArgs
import com.meta.spatial.splat.SplatSystem
import com.meta.spatial.toolkit.Hittable
import com.meta.spatial.toolkit.MeshCollision
import com.meta.spatial.toolkit.Scale
import com.meta.spatial.toolkit.Transform
import com.meta.spatial.toolkit.Visible

// The splat module of the Meta Spatial SDK in the quest flavour (lot S5), used as Meta's SplatSample (MIT,
// Meta-Spatial-SDK-Samples/SplatSample) and the documentation of the splats
// (https://developers.meta.com/horizon/documentation/spatial-sdk/spatial-sdk-splats/) show it: SplatFeature
// registered with the other features, an entity with the Splat component of a file URI, its Transform, Scale(1) and
// Visible(false), shown after the load event (SplatLoadEventArgs). Hittable(NoCollision) keeps the controller rays
// for the panels ("Hit detection can be inconsistent" on a splat). The API is marked experimental by the module: its
// opt-in is here and nowhere else. It is an Experimental Feature in the sense of article 1.6 of the licence of the SDK,
// which keeps such a feature out of a production build unless Meta released it or permits it in writing: FreeKC's
// decision of 30 October 2026 (licenses/meta-spatial-sdk/README.md) ships it in the GitHub builds, labelled
// experimental, and the build of the Meta Horizon Store never registers it (SplatBuild).

/** The splat module of the Meta Spatial SDK 0.14.0 */
@OptIn(SpatialSDKExperimentalSplatAPI::class)
internal object SplatEngines : SplatEngine {
  override val available = true

  override fun feature(context: SpatialContext, systems: SystemManager): SpatialFeature = SplatFeature(context, systems)

  override fun create(uri: Uri, pose: Pose, onLoaded: (success: Boolean, error: String?) -> Unit): Entity {
    val entity =
      Entity.create(
        listOf(
          Splat(uri),
          Transform(pose),
          Scale(Vector3(1f)),
          Visible(false),
          Hittable(MeshCollision.NoCollision),
        )
      )
    entity.registerEventListener<SplatLoadEventArgs>(SplatLoadEventArgs.EVENT_NAME) { _, args ->
      onLoaded(args.success, args.errorMessage)
    }
    return entity
  }

  override fun moveBySystem(systems: SystemManager, entity: Entity, pose: Pose): Boolean {
    val system = systems.tryFindSystem<SplatSystem>() ?: return false
    system.updateSplatTransform(entity.id, pose, Vector3(1f))
    return true
  }
}
