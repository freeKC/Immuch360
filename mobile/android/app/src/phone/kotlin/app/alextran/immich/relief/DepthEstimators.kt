package app.alextran.immich.relief

import java.io.File

// The phone flavour ships no depth engine: LiteRT is in the quest flavour only (design-final 2026-10-26, section 3.2
// point 2), so that the phone APKs keep their size. The APK of the phone flavour still runs on a Quest when installed
// by hand; there the relief says it is not in this version of the app. Same object name and shape as
// src/quest/kotlin/.../relief/DepthEstimators.kt, so that the code of main compiles in both flavours.

object DepthEstimators : DepthEngine {
  override val available = false
  override val engine = "none"

  override fun open(model: File, path: DepthPath): DepthEstimator =
    throw DepthEstimatorException(
      DepthFailure.NOT_IN_THIS_VERSION,
      path,
      "this version of the app has no depth engine: the relief is in the Meta Horizon Store version",
    )
}
