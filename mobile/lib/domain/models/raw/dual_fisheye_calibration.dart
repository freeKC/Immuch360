import 'dart:convert';

/// The lens model of a dual fisheye calibration: the unified camera model of Mei (Insta360 V3 strings) or a plain
/// equidistant fisheye (V1 strings, or nominal values when the file carries no calibration).
enum DualFisheyeModel { mei, equidistant }

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
    this.p1 = 0,
    this.p2 = 0,
    this.radius,
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
  final double p1;
  final double p2;
  final double? radius;

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
    'p1': p1,
    'p2': p2,
    if (radius != null) 'radius': radius,
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
    p1: (json['p1'] as num? ?? 0).toDouble(),
    p2: (json['p2'] as num? ?? 0).toDouble(),
    radius: (json['radius'] as num?)?.toDouble(),
  );
}

/// What a dual fisheye frame needs to be drawn on a sphere: the two lenses, the calibration canvas (one square of
/// [canvasSquare] pixels per lens; frame pixels are canvas pixels times frameHeight / canvasSquare), the direction
/// of gravity in the body frame (x right, y down, z along lens 0) that levels the picture, and where it came from.
/// The JSON form travels to the native players (see docs/16-dual-fisheye-spec.md, section 5).
class DualFisheyeCalibration {
  const DualFisheyeCalibration({
    required this.model,
    required this.lenses,
    required this.canvasSquare,
    this.downBody = const [1, 0, 0],
    this.serial,
    this.cameraModel,
    this.source = DualFisheyeSource.file,
  });

  final DualFisheyeModel model;
  final List<DualFisheyeLens> lenses;
  final double canvasSquare;
  final List<double> downBody;
  final String? serial;
  final String? cameraModel;
  final DualFisheyeSource source;

  /// The JSON string for the native players, for a frame of [frameWidth] x [frameHeight] pixels
  String toNativeJson({required int frameWidth, required int frameHeight}) => jsonEncode({
    'kind': 'dualFisheye',
    'model': model.name,
    'frameWidth': frameWidth,
    'frameHeight': frameHeight,
    'canvasSquare': canvasSquare,
    'downBody': downBody,
    'lenses': [for (final lens in lenses) lens.toJson()],
  });

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
  );

  Map<String, Object?> toJson() => {
    'model': model.name,
    'lenses': [for (final lens in lenses) lens.toJson()],
    'canvasSquare': canvasSquare,
    'downBody': downBody,
    if (serial != null) 'serial': serial,
    if (cameraModel != null) 'cameraModel': cameraModel,
    'source': source.name,
  };
}

/// Where a calibration came from: the file's own trailer, the cache of another file of the same camera, or the
/// nominal values of the model (seams of a few pixels then)
enum DualFisheyeSource { file, cachedSerial, nominal }
