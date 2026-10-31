package app.alextran.immich.immersive.splat

/**
 * The frame the splat module of the Meta Spatial SDK 0.14.0 draws its file in, as measured on a Quest 3 on 31 October
 * 2026 (store/m2/quest-splats-device-2026-10-31/bench-2026-10-31.md of the research notes, reference cubes of meshes
 * around the splat): the frame of the Spatial SDK with its z axis mirrored, M = diag(1, 1, -1). A point p of the file,
 * on an entity whose pose is (t, q), shows in the world of the SDK at M (t + q p): handed over as it is, a pose in
 * front of the head draws the splat at the mirror image of that point across the plane z = 0 of the world, out of
 * sight or behind the user (the black of build 38).
 *
 * The viewer computes every pose of the splat in the frame of the SDK, as for its meshes and panels, and hands the
 * module that pose converted, once, at each of its three entry points (the Transform of the entity as it is made, a
 * later Transform, SplatSystem.updateSplatTransform): position (x, y, -z), quaternion (w, x, y, z) as (w, -x, -y, z),
 * scale positive. The splat then shows at t + q (M p): the file true to life (a right handed file, no mirror), its +z
 * towards -z of the SDK, which is what [filePoint] gives for the placement. The same frame holds for a PLY and an
 * SPZ. Pure JVM, tested by SplatModuleFrameTest.
 */
internal object SplatModuleFrame {
  /** The pose (x, y, z, w, qx, qy, qz) meant in the frame of the SDK, as the module must receive it */
  fun toModule(pose: FloatArray): FloatArray {
    require(pose.size == 7) { "a pose is x, y, z, w, qx, qy, qz" }
    return floatArrayOf(pose[0], pose[1], -pose[2], pose[3], -pose[4], -pose[5], pose[6])
  }

  /** A point of the file as the module shows it in the frame of its entity, before the rotation: z mirrored */
  fun filePoint(point: DoubleArray): DoubleArray = doubleArrayOf(point[0], point[1], -point[2])
}
