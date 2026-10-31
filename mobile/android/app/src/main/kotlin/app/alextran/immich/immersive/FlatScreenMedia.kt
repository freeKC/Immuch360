package app.alextran.immich.immersive

/**
 * What the viewer makes of a media from its request alone: whether it is a video, the rawProjection JSON of a raw 360°
 * video, the stereoPair JSON of a photo of the stereo quad or of a video of the flat video screen, and the Sharper flat
 * screens setting. It says where the media shows (a sphere, the stereo quad, the flat video screen), whether its flat
 * screen moves and resizes with the grips, whether its photo goes on the photo layer, and the widths that screen takes.
 * The MediaRequest of the viewer reads it, so that these rules are tested here rather than in the activity. Pure, unit
 * tested.
 */
internal class FlatScreenMedia(
  private val isVideo: Boolean,
  private val rawProjection: String?,
  private val stereoPairJson: String?,
  private val sharpFlatScreens: Boolean = true,
) {
  /** A raw 360° video, drawn as a mono 360° video whatever the 3D layout and the field of view say. */
  val isRawVideo: Boolean
    get() = isVideo && rawProjection != null

  /** A photo of the stereo quad: in 3D when its JSON reads and both eyes decode, flat otherwise. */
  val isStereoPhoto: Boolean
    get() = !isVideo && stereoPairJson != null

  /** What the quad shows, null when the JSON does not read (the photo then shows flat on the quad). */
  val stereoKind: StereoPhotoKind? by lazy { if (isStereoPhoto) StereoPhotoKind.parse(stereoPairJson) else null }

  /**
   * A flat 3D video told by its file name: the flat3d JSON of a video (see [FlatStereoSpec]), on the flat video screen
   * in front of the user rather than on a sphere. Null for any other media, a raw 360° video included.
   */
  val flatVideo: FlatStereoSpec? by lazy {
    if (isVideo && rawProjection == null) FlatStereoSpec.parse(stereoPairJson) else null
  }

  /**
   * An ordinary video opened with "View on a big screen" (the bigScreen JSON, see [BigScreenSpec]): on the flat video
   * screen, whole, its frame for both eyes.
   */
  val isBigScreenVideo: Boolean by lazy { isVideo && rawProjection == null && BigScreenSpec.isRequest(stereoPairJson) }

  /** A video of the flat video screen: a flat 3D video (see [flatVideo]), or an ordinary one on the big screen. */
  val isFlatVideo: Boolean
    get() = flatVideo != null || isBigScreenVideo

  /** A media opened with "View on a big screen": a photo of the stereo quad, or a video of the flat video screen. */
  val isBigScreen: Boolean
    get() = isBigScreenVideo || stereoKind == StereoPhotoKind.BigScreen

  /** A media told 3D by its file name: a video of the flat video screen, or a photo of the stereo quad. */
  val isFlat3d: Boolean
    get() = flatVideo != null || stereoKind is StereoPhotoKind.Flat

  /** A Gaussian splat file of another tool (lot S5): on no screen, fixed in the world by the splat module of the SDK. */
  val isSplat: Boolean
    get() = stereoKind is StereoPhotoKind.GaussianSplat

  /**
   * A media on a flat screen the user may move and resize (see [ScreenPlace]): a video of the flat video screen, or a
   * photo of the stereo quad but a relief made in the headset, whose 2.5D mesh stands on the quad where it was placed,
   * a 3D scene, and a Gaussian splat, which has no screen.
   */
  val isMovableScreen: Boolean
    get() =
      isFlatVideo ||
        (isStereoPhoto &&
          stereoKind !is StereoPhotoKind.DepthRelief &&
          stereoKind !is StereoPhotoKind.VolumetricScene &&
          stereoKind !is StereoPhotoKind.GaussianSplat)

  /** A photo of a movable flat screen drawn on the photo layer, see [FlatScreenLayer.showsOnLayer]; else the mesh. */
  val photoOnLayer: Boolean
    get() = isStereoPhoto && isMovableScreen && FlatScreenLayer.showsOnLayer(stereoKind, sharpFlatScreens)

  /**
   * A photo of the stereo quad whose kind holds two eyes (an Apple spatial photo, a side by side photo, a flat 3D
   * photo, a relief, the preview of a scene), even while it shows in 2D; not an ordinary photo on the big screen, nor
   * one whose JSON does not read, which are one picture.
   */
  val holdsTwoEyes: Boolean
    get() = isStereoPhoto && stereoKind != null && stereoKind != StereoPhotoKind.BigScreen && !isSplat

  /**
   * The angular widths the screen of this media takes, for the Size buttons, the thumbstick, the stretch of both grips,
   * a change of distance and the angle a recreation restores: see [FlatScreenGeometry.angleBounds].
   */
  val angleBounds: ClosedFloatingPointRange<Float>
    get() = FlatScreenGeometry.angleBounds(holdsTwoEyes, stereoKind?.isEstimatedRelief == true)
}
