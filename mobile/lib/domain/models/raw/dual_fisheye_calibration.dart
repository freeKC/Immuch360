/// The lens model of a dual fisheye calibration: the unified camera model of Mei (Insta360 V3 and V6 strings), a plain
/// equidistant fisheye (V1 strings, or nominal values when the file carries no calibration), or the polynomial fisheye
/// of Kannala and Brandt (DJI Osmo 360).
enum DualFisheyeModel { mei, equidistant, kannalaBrandt }

/// One lens of a dual fisheye camera, in canvas pixels (one square per lens side by side, see
/// [DualFisheyeCalibration.canvasSquare]) and degrees. [radius] is the image circle radius of an equidistant lens
/// (about 100 degrees off axis on an Insta360 X3); the Mei fields are null then.
class DualFisheyeLens {
  const DualFisheyeLens({
    required this.cx,
    required this.cy,
    required this.yaw,
    required this.pitch,
    required this.roll,
    this.xi,
    this.fx,
    this.fy,
    this.k1 = 0,
    this.k2 = 0,
    this.k3 = 0,
    this.k4 = 0,
    this.k5 = 0,
    this.p1 = 0,
    this.p2 = 0,
    this.radius,
    this.viewToLens,
  });

  final double cx;
  final double cy;
  final double yaw;
  final double pitch;
  final double roll;
  final double? xi;
  final double? fx;
  final double? fy;
  final double k1;
  final double k2;
  final double k3;

  /// The radial terms past k3: r^8 and r^10 of the Mei model (V6 strings), theta^8 and theta^10 of the Kannala-Brandt
  /// one; 0 when the calibration has none
  final double k4;
  final double k5;

  final double p1;
  final double p2;
  final double? radius;

  /// The rotation from the view to the frame of this lens, 9 numbers row major, when the calibration gives it whole
  /// (DJI): it then stands for the pose of the lens and the leveling of the body
  final List<double>? viewToLens;

  Map<String, Object?> toJson() => {
    'cx': cx,
    'cy': cy,
    'yaw': yaw,
    'pitch': pitch,
    'roll': roll,
    if (xi != null) 'xi': xi,
    if (fx != null) 'fx': fx,
    if (fy != null) 'fy': fy,
    'k1': k1,
    'k2': k2,
    'k3': k3,
    'k4': k4,
    'k5': k5,
    'p1': p1,
    'p2': p2,
    if (radius != null) 'radius': radius,
    if (viewToLens != null) 'viewToLens': viewToLens,
  };

  factory DualFisheyeLens.fromJson(Map<String, Object?> json) => DualFisheyeLens(
    cx: (json['cx']! as num).toDouble(),
    cy: (json['cy']! as num).toDouble(),
    yaw: (json['yaw'] as num? ?? 0).toDouble(),
    pitch: (json['pitch'] as num? ?? 0).toDouble(),
    roll: (json['roll'] as num? ?? 0).toDouble(),
    xi: (json['xi'] as num?)?.toDouble(),
    fx: (json['fx'] as num?)?.toDouble(),
    fy: (json['fy'] as num?)?.toDouble(),
    k1: (json['k1'] as num? ?? 0).toDouble(),
    k2: (json['k2'] as num? ?? 0).toDouble(),
    k3: (json['k3'] as num? ?? 0).toDouble(),
    k4: (json['k4'] as num? ?? 0).toDouble(),
    k5: (json['k5'] as num? ?? 0).toDouble(),
    p1: (json['p1'] as num? ?? 0).toDouble(),
    p2: (json['p2'] as num? ?? 0).toDouble(),
    radius: (json['radius'] as num?)?.toDouble(),
    viewToLens: (json['viewToLens'] as List?)?.map((v) => (v as num).toDouble()).toList(),
  );
}

/// Where the direction of gravity that levels a picture came from: the accelerometer of an Insta360 trailer, the IMU
/// sample of the MakerNote of a photo, or nowhere (the camera taken as upright)
enum GravitySource { imu, makerNote, none }

/// The window of the sensor the frames of a video show (field 27 of an Insta360 trailer), in canvas pixels: a window of
/// [width] x [height] cut from the area of [areaWidth] x [areaHeight] each lens owns on the canvas, centred in it and
/// moved by [offsetX] and [offsetY]. "5952 5952 5760 5760" on the X3, "8000 6000 5632 5632 0 0" on the X4.
typedef Insta360VideoWindow = ({int areaWidth, int areaHeight, int width, int height, int offsetX, int offsetY});

/// Insta360 trailer fields about the layout of a video (docs/18-design-projections-and-parsers.md, section 5.3); never
/// persisted
class Insta360LayoutHints {
  const Insta360LayoutHints({
    this.fileLayout,
    this.trackOrder,
    this.streamLayout,
    this.imageCategory,
    this.groupIdentity,
    this.videoWindow,
  });

  /// Field 79: 0 unknown, 1 one file per lens, 2 one track per lens
  final int? fileLayout;

  /// Field 80: 0 unknown, 1 track 0 holds lens 1, 2 track 0 holds lens 0
  final int? trackOrder;

  /// Field 131: 1 one stream, 2 separate files, 3 two tracks, 4 two tracks reversed
  final int? streamLayout;

  /// Field 129: 2 a double fisheye, 6 an equirect stitched in the camera
  final int? imageCategory;

  /// Field 26.3: the recording the file belongs to, the same in both files of a split pair
  final String? groupIdentity;

  /// Field 27: the window of the sensor the video frames show, smaller than the canvas square on the X3 and the X4
  /// (docs/18-test-media.md, F1 and F2); null when the trailer does not give it
  final Insta360VideoWindow? videoWindow;

  @override
  String toString() =>
      'Insta360LayoutHints(fileLayout: $fileLayout, trackOrder: $trackOrder, streamLayout: $streamLayout, '
      'imageCategory: $imageCategory, groupIdentity: $groupIdentity, videoWindow: $videoWindow)';
}

/// What a dual fisheye frame needs to be drawn on a sphere: the two lenses, the calibration canvas (one square of
/// [canvasSquare] pixels per lens; frame pixels are canvas pixels times frameHeight / canvasSquare), the direction
/// of gravity in the body frame (x right, y down, z along lens 0) that levels the picture, and where it came from.
/// The native players get it inside the rawProjection JSON of a raw video (see RawVideoPlan.toNativeJson); the JSON
/// form of [toJson] is the one the calibration store keeps.
class DualFisheyeCalibration {
  const DualFisheyeCalibration({
    required this.model,
    required this.lenses,
    required this.canvasSquare,
    this.downBody = const [1, 0, 0],
    this.serial,
    this.cameraModel,
    this.source = DualFisheyeSource.file,
    this.maxTheta = 100,
    this.blendStart = 85,
    this.blendEnd = 95,
    this.gravity = GravitySource.none,
    this.layoutHints,
  });

  final DualFisheyeModel model;
  final List<DualFisheyeLens> lenses;
  final double canvasSquare;
  final List<double> downBody;
  final String? serial;
  final String? cameraModel;
  final DualFisheyeSource source;

  /// Largest angle off its axis, in degrees, a lens is read at: 100 on the Insta360 cameras, 94 on the Osmo 360
  final double maxTheta;

  /// The blend of the two lenses runs between these angles off axis, in degrees: 85 to 95 on the Insta360 cameras, 87
  /// to 93 on the Osmo 360
  final double blendStart;
  final double blendEnd;

  /// Where [downBody] came from; not persisted
  final GravitySource gravity;

  /// What the Insta360 trailer says of the layout of a video; not persisted
  final Insta360LayoutHints? layoutHints;

  factory DualFisheyeCalibration.fromJson(Map<String, Object?> json) => DualFisheyeCalibration(
    model: DualFisheyeModel.values.byName(json['model']! as String),
    lenses: [for (final lens in json['lenses']! as List) DualFisheyeLens.fromJson((lens! as Map).cast())],
    canvasSquare: (json['canvasSquare']! as num).toDouble(),
    downBody: [
      for (final v in json['downBody'] as List? ?? const [1, 0, 0]) (v as num).toDouble(),
    ],
    serial: json['serial'] as String?,
    cameraModel: json['cameraModel'] as String?,
    source: DualFisheyeSource.values.byName(json['source'] as String? ?? 'file'),
    maxTheta: (json['maxTheta'] as num? ?? 100).toDouble(),
    blendStart: (json['blendStart'] as num? ?? 85).toDouble(),
    blendEnd: (json['blendEnd'] as num? ?? 95).toDouble(),
  );

  Map<String, Object?> toJson() => {
    'model': model.name,
    'lenses': [for (final lens in lenses) lens.toJson()],
    'canvasSquare': canvasSquare,
    'downBody': downBody,
    if (serial != null) 'serial': serial,
    if (cameraModel != null) 'cameraModel': cameraModel,
    'source': source.name,
    'maxTheta': maxTheta,
    'blendStart': blendStart,
    'blendEnd': blendEnd,
  };
}

/// Where a calibration came from: the file's own trailer, the cache of another file of the same camera, or the
/// nominal values of the model (seams of a few pixels then)
enum DualFisheyeSource { file, cachedSerial, nominal }
