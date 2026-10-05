// How a raw 360° video opens: which decoded tracks the native player reads (one side by side frame, two tracks of one
// file, or the two files of a split Insta360 pair), which lens or cube face each holds, and the calibration that maps
// them on the sphere, written as the rawProjection JSON version 2 that the native players of Android, the Meta Quest
// and iOS draw from (docs/18-design-projections-and-parsers.md, section 3).
//
// The name of a file tells the camera (see rawMediaKindOfName); the layout is settled here, when the video opens, from
// the tracks its probe lists: a raw video may need the other file of a pair, or two decoders at once, and only then
// can a message say why it does not open (RawVideoUnsupportedException).
//
// Dart computes every rotation (each lens carries the 3 x 3 matrix from the view to its frame, leveling included): the
// native renderers only multiply.

import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/gopro_eac.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/raw/raw_sampler.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:logging/logging.dart';

final _log = Logger('RawVideoPlan');

/// The version of the rawProjection JSON this app writes
const rawProjectionVersion = 2;

/// How the lenses of a raw video are stored: side by side in one frame, one per video track of one file, or one per
/// file of a split pair
enum RawVideoLayout { sideBySide, twoTracks, twoFiles }

/// Why a raw video does not open in 360°: the other file of its split pair is not found, or its tracks have no layout
/// this device plays
enum RawUnsupportedReason { siblingMissing, unknownLayout }

/// A raw 360° video that does not open in 360°, and why: the viewers tell the user (see rawVideoUnsupportedMessage)
class RawVideoUnsupportedException implements Exception {
  const RawVideoUnsupportedException(this.name, this.reason, {this.siblingName, this.detail});

  /// Name of the file opened
  final String name;

  final RawUnsupportedReason reason;

  /// The name of the other file of the pair that was looked for, with [RawUnsupportedReason.siblingMissing]
  final String? siblingName;

  /// What did not fit, for the logs
  final String? detail;

  @override
  String toString() =>
      'RawVideoUnsupportedException: $name, ${reason.name}'
      '${siblingName == null ? '' : ' ($siblingName)'}${detail == null ? '' : ': $detail'}';
}

/// A file read by ranges: its size (null when unknown: its end cannot be read), its reader, and [close] to release it
/// once read
typedef RawFileReader = ({int? size, ByteRangeReader read, Future<void> Function() close});

/// A raw video to open, as the caller found it
class RawVideoInput {
  const RawVideoInput({
    required this.name,
    required this.key,
    required this.url,
    this.originalUrl,
    this.fallbackUrl,
    required this.open,
    this.probe,
    this.width,
    this.height,
  });

  /// Name of the file: the layout rules and the name of the other file of a pair
  final String name;

  /// Unique to the file and its version, for the cache of the calibrations: `asset:` then the spatial layout key and
  /// the update time in milliseconds for an asset, rawShareKey for a file of a share
  final String key;

  /// What the player would open: the file on the device, the original or the transcoded stream of the server, or the
  /// media bridge URL of a file of a share
  final String url;

  /// The original on the server when [url] is its transcoded stream; null otherwise
  final String? originalUrl;

  /// The transcoded stream of the server offered as fallback; null when there is none
  final String? fallbackUrl;

  /// Range reads of the file itself, never of a transcoded stream; null when it cannot be read
  final Future<RawFileReader?> Function() open;

  /// What the file declares, read already; read again when it lists no track
  final SphericalProbe? probe;

  /// Size of the frames the server or the device gives, for when the probe is missing
  final int? width;
  final int? height;

  @override
  String toString() => 'RawVideoInput($name, url: $url, originalUrl: $originalUrl, fallbackUrl: $fallbackUrl)';
}

/// Finds the other file of a split pair named [siblingName], shaped like the opened one (same kind of source, the
/// same choice of original or transcoded stream); null when it is not found
typedef RawSiblingFinder = Future<RawVideoInput?> Function(String siblingName);

/// A decoded input of the native player: a video track of the file opened ([file] 0) or of the other file of a pair
/// ([file] 1)
class RawVideoTrack {
  const RawVideoTrack({
    required this.file,
    required this.videoTrack,
    this.trackId,
    this.width,
    this.height,
    this.codec,
    this.codecs,
    this.bitDepth,
    this.frameRate,
  });

  /// The track [track] of its file, the [videoTrack]-th of its video tracks
  factory RawVideoTrack.of(ProbedTrack track, {required int file, required int videoTrack}) => RawVideoTrack(
    file: file,
    videoTrack: videoTrack,
    trackId: track.trackId,
    width: track.codedWidth,
    height: track.codedHeight,
    codec: track.codec,
    codecs: track.codecs,
    bitDepth: track.bitDepth,
    frameRate: track.frameRate,
  );

  /// 0 for the URL the player opens, 1 for the other file of a pair
  final int file;

  /// Index among the video tracks of its file (handler "vide", in moov order)
  final int videoTrack;

  /// The track_ID of its tkhd box, which the players select it by first
  final int? trackId;

  /// Coded size the sample entry declares
  final int? width;
  final int? height;

  /// Four character code of the sample entry, its RFC 6381 string and its bit depth: for the logs and the decoder
  /// checks
  final String? codec;
  final String? codecs;
  final int? bitDepth;

  /// Frames per second, for the decoder check of two streams; not in the JSON
  final double? frameRate;

  Map<String, Object?> toJson() => {
    'file': file,
    'videoTrack': videoTrack,
    'trackId': trackId,
    'width': width,
    'height': height,
    'codec': codec,
    'codecs': codecs,
    'bitDepth': bitDepth,
  };

  @override
  String toString() =>
      'RawVideoTrack(file $file, video track $videoTrack, id $trackId, $width x $height, $codecs, $bitDepth bit)';
}

/// How a raw video opens: [tracks] for the player, the [calibration] of a fisheye pair (lens i in
/// tracks[[textureOfLens][i]]) or the EAC geometry of a GoPro ([eac]), and the URLs to open
class RawVideoPlan {
  const RawVideoPlan({
    required this.kind,
    required this.layout,
    this.camera,
    required this.tracks,
    this.calibration,
    this.textureOfLens,
    this.eac,
    this.viewToCamera,
    required this.url,
    this.fallbackUrl,
    this.secondUrl,
    this.secondFallbackUrl,
    required this.trackOrderSource,
  });

  final RawMediaKind kind;
  final RawVideoLayout layout;

  /// The camera, for the logs: "Insta360 X3", "Osmo 360", "GoPro MAX 2"
  final String? camera;

  final List<RawVideoTrack> tracks;

  /// The lenses of a fisheye pair (Insta360, DJI); null for a GoPro
  final DualFisheyeCalibration? calibration;

  /// For a fisheye pair: the index in [tracks] of the texture that holds lens i
  final List<int>? textureOfLens;

  /// For a GoPro: the layout of its two EAC tracks
  final GoProEacGeometry? eac;

  /// For a GoPro: the rotation from the view to the camera frame of the face table, row major (see
  /// [goProViewToCamera] by default)
  final List<double>? viewToCamera;

  /// What the player opens
  final String url;

  /// The stream the player switches to when it cannot play [url]; null when a switch would break the stitch (the
  /// server transcodes the first video track only)
  final String? fallbackUrl;

  /// [RawVideoLayout.twoFiles]: the other file of the pair, and its transcoded stream, which the player switches to
  /// together with [fallbackUrl]
  final String? secondUrl;
  final String? secondFallbackUrl;

  /// What said which lens each track holds: "single", "field80", "field131", "default", "fileName", "dji", "goPro"
  final String trackOrderSource;

  /// The size of the stitched equirect picture worth drawing: the frame of a side by side video, 2 H x H for fisheye
  /// tracks of H, 4 F x 2 F for EAC faces of F
  ({int width, int height}) get outputSize {
    final eac = this.eac;
    if (eac != null) {
      return (width: 4 * eac.face, height: 2 * eac.face);
    }
    final first = tracks.firstOrNull;
    final square = calibration?.canvasSquare.round() ?? 0;
    if (layout == RawVideoLayout.sideBySide) {
      final width = first?.width;
      final height = first?.height;
      return width != null && height != null && width > 0 && height > 0
          ? (width: width, height: height)
          : (width: 2 * square, height: square);
    }
    final height = first?.height ?? square;
    return (width: 2 * height, height: height);
  }

  /// The lens each track holds, for a fisheye pair of two tracks or files; null otherwise
  List<int>? get trackOrder {
    final textureOfLens = this.textureOfLens;
    if (layout == RawVideoLayout.sideBySide || textureOfLens == null || textureOfLens.length != 2) {
      return null;
    }
    return [for (var track = 0; track < tracks.length; track++) textureOfLens.indexOf(track)];
  }

  /// The rawProjection JSON as a map, keys in the order of section 3.5 of the design
  Map<String, Object?> toNativeMap() {
    final (:width, :height) = outputSize;
    final calibration = this.calibration;
    final eac = this.eac;
    return {
      'version': rawProjectionVersion,
      'kind': eac != null ? 'eacGoPro' : 'dualFisheye',
      'layout': layout.name,
      'camera': camera,
      'frameWidth': width,
      'frameHeight': height,
      'tracks': [for (final track in tracks) track.toJson()],
      'secondUrl': secondUrl,
      'secondFallbackUrl': secondFallbackUrl,
      'trackOrder': trackOrder,
      'trackOrderSource': trackOrderSource,
      'calibrationSource': eac != null ? 'trackGeometry' : calibration?.source.name,
      'gravitySource': eac != null ? GravitySource.none.name : calibration?.gravity.name,
      if (eac != null) ..._eacJson(eac) else if (calibration != null) ..._fisheyeJson(calibration),
    };
  }

  Map<String, Object?> _fisheyeJson(DualFisheyeCalibration calibration) {
    final rotations = viewToLens(calibration);
    final textureOfLens = this.textureOfLens ?? const [0, 0];
    final model = calibration.model;
    return {
      'model': model.name,
      'canvasSquare': calibration.canvasSquare,
      'downBody': calibration.downBody,
      'maxTheta': calibration.maxTheta,
      'blendStart': calibration.blendStart,
      'blendEnd': calibration.blendEnd,
      'lenses': [
        for (final (i, lens) in calibration.lenses.indexed)
          {
            'texture': i < textureOfLens.length ? textureOfLens[i] : 0,
            'region': layout == RawVideoLayout.sideBySide ? [0.5 * i, 0.0, 0.5, 1.0] : const [0.0, 0.0, 1.0, 1.0],
            'cx': lens.cx,
            'cy': lens.cy,
            if (model != DualFisheyeModel.equidistant) ...{'fx': lens.fx, 'fy': lens.fy},
            if (model == DualFisheyeModel.mei) 'xi': lens.xi,
            'k1': lens.k1,
            'k2': lens.k2,
            'k3': lens.k3,
            'k4': lens.k4,
            'k5': lens.k5,
            'p1': lens.p1,
            'p2': lens.p2,
            if (model == DualFisheyeModel.equidistant) ...{
              'radius': lens.radius,
              'radiusTheta': equidistantRadiusDegrees,
            },
            'yaw': lens.yaw,
            'pitch': lens.pitch,
            'roll': lens.roll,
            'viewToLens': rotations[i].values,
          },
      ],
    };
  }

  Map<String, Object?> _eacJson(GoProEacGeometry eac) => {
    'face': eac.face,
    'overlap': eac.overlap,
    'half': eac.half,
    'middle': eac.middle,
    'right': eac.right,
    'viewToCamera': viewToCamera ?? goProViewToCamera(eac),
    'faces': [
      for (final face in GoProEacGeometry.faces)
        {
          'texture': face.texture,
          'slot': face.slot,
          'forward': _axis(face.forward),
          'right': _axis(face.right),
          'down': _axis(face.down),
        },
    ],
  };

  // The axes of the face table are whole numbers, written as such
  static List<int> _axis(Vec3 v) => [v.x.round(), v.y.round(), v.z.round()];

  /// What a native player draws with this plan, as the CPU reference stitches it (section 4): the lenses in the regions
  /// of their textures, or the six cube faces of the EAC tracks, the textures at the sizes [tracks] declare (the frame
  /// of [outputSize] for a side by side file of unknown size). For the tests and the golden pictures of the devices.
  RawSampler get sampler {
    final eac = this.eac;
    if (eac != null) {
      return GoProEacSampler(eac, viewToCamera: viewToCamera);
    }
    final calibration = this.calibration;
    if (calibration == null) {
      throw StateError('A fisheye plan without calibration');
    }
    final sideBySide = layout == RawVideoLayout.sideBySide;
    final (:width, :height) = outputSize;
    return FisheyePairSampler(
      calibration,
      regions: sideBySide
          ? FisheyePairSampler.sideBySideRegions()
          : FisheyePairSampler.wholeTextureRegions(textureOfLens ?? const [0, 1]),
      textureSizes: [
        for (final track in tracks)
          (width: track.width ?? (sideBySide ? width : height), height: track.height ?? height),
      ],
    );
  }

  /// The first rule of section 3.4 that [toNativeMap] breaks, null when it breaks none
  String? get violation => rawProjectionViolation(toNativeMap());

  /// The rawProjection JSON of section 3, numbers written with at most 8 decimals. Throws a [StateError] for a plan that
  /// breaks a rule of section 3.4: no player gets a JSON it would refuse (the resolver checks [violation] first).
  String toNativeJson() {
    final json = toNativeMap();
    final violation = rawProjectionViolation(json);
    if (violation != null) {
      throw StateError('rawProjection rejected: $violation');
    }
    return encodeRawProjection(json);
  }

  @override
  String toString() =>
      'RawVideoPlan(${kind.name}, ${layout.name}, $camera, tracks: $tracks, lens textures: $textureOfLens, '
      'order from $trackOrderSource, calibration: ${calibration?.source.name ?? 'track geometry'}, '
      'gravity: ${calibration?.gravity.name ?? 'none'}, url: $url, fallbackUrl: $fallbackUrl, secondUrl: $secondUrl, '
      'secondFallbackUrl: $secondFallbackUrl)';
}

/// [json] written compactly, its keys in their order, doubles with at most 8 decimals (and at least one: "5952.0"),
/// whole numbers as they are: what [RawVideoPlan.toNativeJson] sends
String encodeRawProjection(Object? json) {
  final out = StringBuffer();
  void write(Object? value) {
    switch (value) {
      case null:
        out.write('null');
      case final bool flag:
        out.write(flag);
      case final int number:
        out.write(number);
      case final double number:
        out.write(formatRawProjectionNumber(number));
      case final String text:
        out.write(jsonEncode(text));
      case final Map<String, Object?> map:
        out.write('{');
        var first = true;
        for (final MapEntry(:key, value: item) in map.entries) {
          if (!first) {
            out.write(',');
          }
          first = false;
          out
            ..write(jsonEncode(key))
            ..write(':');
          write(item);
        }
        out.write('}');
      case final Iterable<Object?> list:
        out.write('[');
        var first = true;
        for (final item in list) {
          if (!first) {
            out.write(',');
          }
          first = false;
          write(item);
        }
        out.write(']');
      default:
        throw ArgumentError.value(value, 'json', 'not a JSON value');
    }
  }

  write(json);
  return out.toString();
}

/// [value] rounded to 8 decimals, its trailing zeros left out but one: 0.38808271, -0.08083, 5952.0, 1920.85339355.
/// Zero is never negative.
String formatRawProjectionNumber(double value) {
  var text = value.toStringAsFixed(8);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    if (text.endsWith('.')) {
      text = '${text}0';
    }
  }
  return text == '-0.0' ? '0.0' : text;
}

/// The first rule of section 3.4 of the design that the rawProjection [json] breaks, as a native player checks it on
/// receipt; null when it breaks none
String? rawProjectionViolation(Map<String, Object?> json) {
  if (json['version'] != rawProjectionVersion) {
    return 'version ${json['version']}';
  }
  final kind = json['kind'];
  final layout = json['layout'];
  if (kind != 'dualFisheye' && kind != 'eacGoPro') {
    return 'kind $kind';
  }
  if (!RawVideoLayout.values.any((known) => known.name == layout)) {
    return 'layout $layout';
  }
  final tracks = json['tracks'];
  if (tracks is! List || tracks.length != (layout == RawVideoLayout.sideBySide.name ? 1 : 2)) {
    return '${tracks is List ? tracks.length : 'no'} tracks for $layout';
  }
  final secondUrl = json['secondUrl'];
  for (final track in tracks) {
    final file = track is Map ? track['file'] : null;
    if (file != 0 && file != 1) {
      return 'track of file $file';
    }
    if (file == 1 && (layout != RawVideoLayout.twoFiles.name || secondUrl is! String || secondUrl.isEmpty)) {
      return 'a track of the second file without a second URL in $layout';
    }
    if (track is! Map || track['videoTrack'] is! int || (track['videoTrack'] as int) < 0) {
      return 'track without a video track index';
    }
  }
  if (kind == 'eacGoPro') {
    if (layout != RawVideoLayout.twoTracks.name) {
      return 'eacGoPro in $layout';
    }
    return _eacViolation(json, tracks);
  }
  return _fisheyeViolation(json, tracks.length);
}

String? _fisheyeViolation(Map<String, Object?> json, int trackCount) {
  final square = _numberOf(json['canvasSquare']);
  if (square == null || square <= 0) {
    return 'canvasSquare ${json['canvasSquare']}';
  }
  final maxTheta = _numberOf(json['maxTheta']);
  final blendStart = _numberOf(json['blendStart']);
  final blendEnd = _numberOf(json['blendEnd']);
  if (maxTheta == null ||
      blendStart == null ||
      blendEnd == null ||
      !(0 < blendStart && blendStart < blendEnd && blendEnd <= maxTheta && maxTheta <= 180)) {
    return 'angles $blendStart, $blendEnd, $maxTheta';
  }
  final model = json['model'];
  if (!DualFisheyeModel.values.any((known) => known.name == model)) {
    return 'model $model';
  }
  final lenses = json['lenses'];
  if (lenses is! List || lenses.length != 2) {
    return '${lenses is List ? lenses.length : 'no'} lenses';
  }
  for (final (i, lens) in lenses.indexed) {
    if (lens is! Map) {
      return 'lens $i';
    }
    final texture = lens['texture'];
    if (texture is! int || texture < 0 || texture >= trackCount) {
      return 'lens $i in texture $texture';
    }
    final region = lens['region'];
    final values = region is List ? [for (final value in region) _numberOf(value)] : const <double?>[];
    if (values.length != 4 || values.contains(null)) {
      return 'lens $i region $region';
    }
    final [x!, y!, w!, h!] = values;
    if (x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > 1 || y + h > 1) {
      return 'lens $i region $region';
    }
    for (final key in ['cx', 'cy', 'k1', 'k2', 'k3', 'k4', 'k5', 'p1', 'p2']) {
      if (_numberOf(lens[key]) == null) {
        return 'lens $i $key ${lens[key]}';
      }
    }
    final fx = _numberOf(lens['fx']);
    final fy = _numberOf(lens['fy']);
    switch (model) {
      case 'mei':
        final xi = _numberOf(lens['xi']);
        if (fx == null || fy == null || fx <= 0 || fy <= 0 || xi == null || xi < 0) {
          return 'lens $i Mei intrinsics fx $fx, fy $fy, xi $xi';
        }
      case 'kannalaBrandt':
        if (fx == null || fy == null || fx <= 0 || fy <= 0) {
          return 'lens $i focal lengths $fx, $fy';
        }
      case 'equidistant':
        final radius = _numberOf(lens['radius']);
        if (radius == null || radius <= 0) {
          return 'lens $i radius $radius';
        }
    }
    final matrix = lens['viewToLens'];
    final m = matrix is List ? [for (final value in matrix) _numberOf(value)] : const <double?>[];
    if (m.length != 9 || m.contains(null)) {
      return 'lens $i viewToLens $matrix';
    }
    final det =
        m[0]! * (m[4]! * m[8]! - m[5]! * m[7]!) -
        m[1]! * (m[3]! * m[8]! - m[5]! * m[6]!) +
        m[2]! * (m[3]! * m[7]! - m[4]! * m[6]!);
    if ((det - 1).abs() >= 1e-3) {
      return 'lens $i viewToLens of determinant $det';
    }
  }
  return null;
}

String? _eacViolation(Map<String, Object?> json, List<Object?> tracks) {
  final face = json['face'];
  final half = json['half'];
  final middle = json['middle'];
  final right = json['right'];
  final overlap = json['overlap'];
  if (face is! int || face <= 0 || half is! int || middle is! int || right is! int || overlap is! int) {
    return 'EAC geometry $face, $half, $middle, $right';
  }
  if (middle != 2 * half || right != middle + face) {
    return 'EAC middle $middle and right $right for faces of $face and halves of $half';
  }
  for (final track in tracks) {
    if (track is! Map || track['width'] != right + 2 * half || track['height'] != face) {
      return 'EAC track of ${track is Map ? '${track['width']} x ${track['height']}' : track}';
    }
  }
  final viewToCamera = json['viewToCamera'];
  if (viewToCamera is! List || viewToCamera.length != 9 || viewToCamera.any((value) => _numberOf(value) == null)) {
    return 'viewToCamera $viewToCamera';
  }
  final faces = json['faces'];
  if (faces is! List || faces.length != 6) {
    return '${faces is List ? faces.length : 'no'} faces';
  }
  final slots = <(Object?, Object?)>{
    for (final face in faces)
      if (face is Map) (face['texture'], face['slot']),
  };
  for (var texture = 0; texture < 2; texture++) {
    for (var slot = 0; slot < 3; slot++) {
      if (!slots.contains((texture, slot))) {
        return 'no face in slot $slot of texture $texture';
      }
    }
  }
  return null;
}

double? _numberOf(Object? value) => value is num && value.isFinite ? value.toDouble() : null;

/// Which layouts of two streams the native players of this platform play: two tracks of one file, two files, the
/// GoPro EAC tracks
class RawVideoPlaybackSupport {
  const RawVideoPlaybackSupport({required this.twoStreams});

  final bool twoStreams;

  @override
  String toString() => 'RawVideoPlaybackSupport(twoStreams: $twoStreams)';
}

/// What the resolver needs of the calibration service (DualFisheyeCalibrationService)
abstract interface class RawVideoCalibrations {
  /// The calibration of an Insta360 video, from its trailer, else the calibration kept for its camera or its model,
  /// else the nominal values for squares of [frameSquare] pixels; with the layout hints of its trailer
  Future<DualFisheyeCalibration> forInput(RawVideoInput input, {int? frameSquare});

  /// The calibration of a DJI .osv video, from its camd box, else the nominal values of the Osmo 360
  Future<DualFisheyeCalibration> forDji(RawVideoInput input);
}

/// Settles how a raw video opens (see [resolve])
class RawVideoResolver {
  RawVideoResolver({
    required this.calibrations,
    required this.support,
    this.probeFile = probeSphericalMetadata,
    this.probeTimeout = const Duration(seconds: 15),
  });

  final RawVideoCalibrations calibrations;
  final RawVideoPlaybackSupport support;

  /// Reads what a file declares, its tracks included, when the input comes without
  final Future<SphericalProbe> Function(ByteRangeReader read) probeFile;

  /// Longest wait for a probe
  final Duration probeTimeout;

  /// The plan of [input], a raw video of [kind]: by the tracks its probe lists (read when the input lists none), side
  /// by side frames, two square tracks or one square track of a split pair (whose other file [findSibling] finds) for
  /// an Insta360; two EAC tracks for a GoPro; two square tracks for a DJI. Throws a [RawVideoUnsupportedException] for
  /// what does not open: another layout, a pair without its other file, or two streams on a platform whose players do
  /// not play them ([support]). Photos never come here: an [ArgumentError].
  Future<RawVideoPlan> resolve({
    required RawMediaKind kind,
    required RawVideoInput input,
    required RawSiblingFinder findSibling,
  }) async {
    final plan = switch (kind) {
      RawMediaKind.insta360Photo => throw ArgumentError.value(kind, 'kind', 'a raw photo is stitched, not played'),
      RawMediaKind.insta360Video => await _insta360(input, findSibling),
      RawMediaKind.goProVideo => await _goPro(input),
      RawMediaKind.djiVideo => await _dji(input),
    };
    final violation = plan.violation;
    if (violation != null) {
      throw RawVideoUnsupportedException(
        input.name,
        RawUnsupportedReason.unknownLayout,
        detail: 'rawProjection rejected: $violation',
      );
    }
    _log.info('${input.name}: $plan');
    return plan;
  }

  Future<RawVideoPlan> _insta360(RawVideoInput input, RawSiblingFinder findSibling) async {
    final probe = await _probeOf(input);
    final videos = probe?.videoTracks ?? const <ProbedTrack>[];
    final first = videos.firstOrNull;

    if (_areTwoLensTracks(videos)) {
      _requireTwoStreams(input, 'two square video tracks');
      final calibration = await calibrations.forInput(input, frameSquare: first!.codedHeight);
      final hints = calibration.layoutHints;
      final (:lensOfTrack0, :source) = insta360TrackOrder(
        Insta360Trailer(trackOrder: hints?.trackOrder, streamLayout: hints?.streamLayout),
      );
      if (hints?.fileLayout == 1) {
        _log.info('${input.name}: its trailer says one file per lens (field 79), yet the file has two video tracks');
      }
      return RawVideoPlan(
        kind: RawMediaKind.insta360Video,
        layout: RawVideoLayout.twoTracks,
        camera: calibration.cameraModel,
        tracks: [
          RawVideoTrack.of(videos[0], file: 0, videoTrack: 0),
          RawVideoTrack.of(videos[1], file: 0, videoTrack: 1),
        ],
        calibration: calibrationInVideoWindow(calibration),
        textureOfLens: lensOfTrack0 == 0 ? const [0, 1] : const [1, 0],
        // The server transcodes the first video track only: one lens, which would be drawn as both
        url: input.originalUrl ?? input.url,
        trackOrderSource: source,
      );
    }

    // Without a listed track, the frame the probe found (a probe of before the tracks were listed), else the size the
    // server or the device gives
    final frameWidth = first != null ? first.codedWidth : probe?.codedWidth ?? input.width;
    final frameHeight = first != null ? first.codedHeight : probe?.codedHeight ?? input.height;
    final sideBySide = first != null
        ? isSideBySideFrame(frameWidth, frameHeight) == true
        : isSideBySideFrame(frameWidth, frameHeight) != false;
    if (sideBySide) {
      final width = frameWidth;
      final height = frameHeight;
      final calibration = await calibrations.forInput(input, frameSquare: height);
      return RawVideoPlan(
        kind: RawMediaKind.insta360Video,
        layout: RawVideoLayout.sideBySide,
        camera: calibration.cameraModel,
        tracks: [
          if (first != null)
            RawVideoTrack.of(first, file: 0, videoTrack: 0)
          else
            RawVideoTrack(file: 0, videoTrack: 0, width: width, height: height),
        ],
        calibration: calibrationInVideoWindow(calibration),
        textureOfLens: const [0, 0],
        // The transcoded stream keeps the frame of both lenses side by side
        url: input.url,
        fallbackUrl: input.fallbackUrl,
        trackOrderSource: 'single',
      );
    }

    final oneLens = first != null ? videos.length == 1 && _isSquareTrack(first) : _isSquare(frameWidth, frameHeight);
    if (!oneLens) {
      throw RawVideoUnsupportedException(
        input.name,
        RawUnsupportedReason.unknownLayout,
        detail: 'video tracks ${_describe(videos)}',
      );
    }
    return _splitPair(input, probe, findSibling);
  }

  Future<RawVideoPlan> _splitPair(RawVideoInput input, SphericalProbe? probe, RawSiblingFinder findSibling) async {
    final pair = splitPairOf(input.name);
    if (pair == null) {
      throw RawVideoUnsupportedException(
        input.name,
        RawUnsupportedReason.unknownLayout,
        detail: 'one square video track, and not the name of a file of a split pair',
      );
    }
    _requireTwoStreams(input, 'a split pair');
    final sibling = await findSibling(pair.siblingName);
    if (sibling == null) {
      throw RawVideoUnsupportedException(
        input.name,
        RawUnsupportedReason.siblingMissing,
        siblingName: pair.siblingName,
        detail: 'not found',
      );
    }
    final siblingProbe = await _probeOf(sibling);
    RawVideoUnsupportedException missing(String detail) {
      _log.info('${input.name}: ${sibling.name} is not its other lens: $detail');
      return RawVideoUnsupportedException(
        input.name,
        RawUnsupportedReason.siblingMissing,
        siblingName: pair.siblingName,
        detail: detail,
      );
    }

    final mismatch = splitSiblingMismatch(probe: probe, siblingProbe: siblingProbe);
    if (mismatch != null) {
      throw missing(mismatch);
    }

    // The first lens file holds the calibration of both lenses (the camera writes no trailer in the other one)
    final opened = probe?.videoTracks.firstOrNull;
    final frameSquare = opened?.codedHeight ?? probe?.codedHeight ?? input.height;
    final primary = pair.lens == 0 ? input : sibling;
    final other = pair.lens == 0 ? sibling : input;
    final primaryCalibration = await calibrations.forInput(primary, frameSquare: frameSquare);
    final identity = primaryCalibration.layoutHints?.groupIdentity;
    // The other file is read only when it may tell more: a calibration of its own, or the recording it belongs to
    final otherCalibration = primaryCalibration.source == DualFisheyeSource.nominal || identity != null
        ? await calibrations.forInput(other, frameSquare: frameSquare)
        : null;
    final otherIdentity = otherCalibration?.layoutHints?.groupIdentity;
    if (identity != null &&
        otherIdentity != null &&
        splitRecordingIdentity(identity) != splitRecordingIdentity(otherIdentity)) {
      throw missing('recordings $identity and $otherIdentity');
    }
    final calibration =
        primaryCalibration.source == DualFisheyeSource.nominal &&
            otherCalibration != null &&
            otherCalibration.source != DualFisheyeSource.nominal
        ? otherCalibration
        : primaryCalibration;

    final siblingTrack = siblingProbe!.videoTracks.first;
    // Both files fall back together, or neither: one lens transcoded and the other original would not stitch
    final fallbacks = input.fallbackUrl != null && sibling.fallbackUrl != null;
    if (input.fallbackUrl != null && sibling.fallbackUrl == null) {
      _log.info('${input.name}: no transcoded stream of ${sibling.name}, so no fallback for the pair');
    }
    return RawVideoPlan(
      kind: RawMediaKind.insta360Video,
      layout: RawVideoLayout.twoFiles,
      camera: calibration.cameraModel,
      tracks: [
        if (opened != null)
          RawVideoTrack.of(opened, file: 0, videoTrack: 0)
        else
          RawVideoTrack(
            file: 0,
            videoTrack: 0,
            width: probe?.codedWidth ?? input.width,
            height: probe?.codedHeight ?? input.height,
          ),
        RawVideoTrack.of(siblingTrack, file: 1, videoTrack: 0),
      ],
      calibration: calibrationInVideoWindow(calibration),
      textureOfLens: pair.lens == 0 ? const [0, 1] : const [1, 0],
      url: input.url,
      fallbackUrl: fallbacks ? input.fallbackUrl : null,
      secondUrl: sibling.url,
      secondFallbackUrl: fallbacks ? sibling.fallbackUrl : null,
      trackOrderSource: 'fileName',
    );
  }

  Future<RawVideoPlan> _goPro(RawVideoInput input) async {
    final probe = await _probeOf(input);
    final eac = probe == null ? null : goProEacGeometryOf(probe);
    if (probe == null || eac == null) {
      throw RawVideoUnsupportedException(
        input.name,
        RawUnsupportedReason.unknownLayout,
        detail: 'no two EAC tracks among ${_describe(probe?.videoTracks ?? const [])}',
      );
    }
    _requireTwoStreams(input, 'two EAC tracks');
    final [first, second, ...] = probe.videoTracks;
    _log.fine('${input.name}: EAC tracks "${first.handlerName}" and "${second.handlerName}"');
    return RawVideoPlan(
      kind: RawMediaKind.goProVideo,
      layout: RawVideoLayout.twoTracks,
      camera: goProCameraName(eac),
      tracks: [RawVideoTrack.of(first, file: 0, videoTrack: 0), RawVideoTrack.of(second, file: 0, videoTrack: 1)],
      eac: eac,
      viewToCamera: goProViewToCamera(eac),
      url: input.originalUrl ?? input.url,
      trackOrderSource: 'goPro',
    );
  }

  Future<RawVideoPlan> _dji(RawVideoInput input) async {
    final probe = await _probeOf(input);
    final videos = probe?.videoTracks ?? const <ProbedTrack>[];
    if (!_areTwoLensTracks(videos)) {
      throw RawVideoUnsupportedException(
        input.name,
        RawUnsupportedReason.unknownLayout,
        detail: 'video tracks ${_describe(videos)}',
      );
    }
    _requireTwoStreams(input, 'two square video tracks');
    final calibration = await calibrations.forDji(input);
    return RawVideoPlan(
      kind: RawMediaKind.djiVideo,
      layout: RawVideoLayout.twoTracks,
      camera: calibration.cameraModel ?? 'Osmo 360',
      tracks: [
        RawVideoTrack.of(videos[0], file: 0, videoTrack: 0),
        RawVideoTrack.of(videos[1], file: 0, videoTrack: 1),
      ],
      calibration: calibration,
      // Video stream 0 is the rear lens, stream 1 the front one, as the calibration slots
      textureOfLens: const [0, 1],
      url: input.originalUrl ?? input.url,
      trackOrderSource: 'dji',
    );
  }

  void _requireTwoStreams(RawVideoInput input, String layout) {
    if (!support.twoStreams) {
      throw RawVideoUnsupportedException(
        input.name,
        RawUnsupportedReason.unknownLayout,
        detail: '$layout, which the players of this platform do not play yet',
      );
    }
  }

  // What [input] declares: its probe when it lists tracks, else read from its file; null when that fails
  Future<SphericalProbe?> _probeOf(RawVideoInput input) async {
    final given = input.probe;
    if (given != null && given.tracks.isNotEmpty) {
      return given;
    }
    RawFileReader? file;
    try {
      file = await input.open();
      if (file == null) {
        _log.info('${input.name}: no file to probe');
        return given;
      }
      return await probeFile(file.read).timeout(probeTimeout);
    } catch (error) {
      _log.info('${input.name}: could not probe its tracks: $error');
      return given;
    } finally {
      try {
        await file?.close();
      } catch (error) {
        _log.fine('${input.name}: could not close the file: $error');
      }
    }
  }
}

/// The recording that [identity], the field 26.3 of the trailer of a file of a split Insta360 pair, names, in one form
/// for both files of the pair. The X4 writes the path of the file itself there ("/DCIM/Camera01/VID_..._00_027.insv"
/// on the real files), which the other file of a pair would write with its own lens marker (_10_): the last part of a
/// path takes the name of the first lens file when it is the name of a file of a split pair (see [splitPairOf]). Case
/// aside, any other identity stays as it is.
String splitRecordingIdentity(String identity) {
  final separator = identity.lastIndexOf(RegExp(r'[/\\]'));
  final folder = identity.substring(0, separator + 1);
  final name = identity.substring(separator + 1);
  final pair = splitPairOf(name);
  return '$folder${pair == null || pair.lens == 0 ? name : pair.siblingName}'.toLowerCase();
}

// Whether a frame of [width] x [height] is a square (within 1 percent)
bool _isSquare(int? width, int? height) =>
    width != null && height != null && isSideBySideFrame(2 * width, height) == true;

bool _isSquareTrack(ProbedTrack track) => _isSquare(track.codedWidth, track.codedHeight);

bool _sameSize(ProbedTrack a, ProbedTrack b) => a.codedWidth == b.codedWidth && a.codedHeight == b.codedHeight;

// Whether the first two of [videos] are the two lenses of a two-track file: two squares of the same size
bool _areTwoLensTracks(List<ProbedTrack> videos) =>
    videos.length >= 2 && _isSquareTrack(videos[0]) && _isSquareTrack(videos[1]) && _sameSize(videos[0], videos[1]);

String _describe(List<ProbedTrack> videos) => videos.isEmpty
    ? 'none'
    : [for (final video in videos) '${video.codec} ${video.codedWidth} x ${video.codedHeight}'].join(', ');

/// [calibration] of an Insta360 camera moved into the window of the sensor its video frames show (field 27, see
/// [Insta360LayoutHints.videoWindow]), so that the whole square of the canvas maps onto the whole frame of a lens as
/// the players map it: the canvas square becomes the window, and the centre of each lens moves by the corner of the
/// window in the area of the lens. The X3 records 5760 of its 5952 pixels, the X4 5632 of an area of 8000 x 6000;
/// read as the whole square, the lenses of a video come out about 3 percent too small, and the X4 does not stitch at
/// all (docs/18-test-media.md, F1 and F2). [calibration] as it is without a window, or with one that does not fit its
/// canvas (a calibration in frame pixels, the nominal one).
DualFisheyeCalibration calibrationInVideoWindow(DualFisheyeCalibration calibration) {
  final window = calibration.layoutHints?.videoWindow;
  if (window == null || calibration.lenses.length != 2) {
    return calibration;
  }
  final (:areaWidth, :areaHeight, :width, :height, :offsetX, :offsetY) = window;
  if (width <= 0 ||
      width != height ||
      width > areaWidth ||
      height > areaHeight ||
      (areaHeight - calibration.canvasSquare).abs() > 1 ||
      offsetX.abs() > areaWidth ||
      offsetY.abs() > areaHeight) {
    _log.info('Insta360 video window $window does not fit a canvas of ${calibration.canvasSquare}: not applied');
    return calibration;
  }
  if (offsetX != 0 || offsetY != 0) {
    _log.info('Insta360 video window moved by $offsetX, $offsetY');
  }
  final left = (areaWidth - width) / 2 + offsetX;
  final top = (areaHeight - height) / 2 + offsetY;
  final side = width.toDouble();
  return calibration.copyWith(
    canvasSquare: side,
    lenses: [
      for (final (i, lens) in calibration.lenses.indexed)
        DualFisheyeLens(
          cx: lens.cx - i * areaWidth - left + i * side,
          cy: lens.cy - top,
          yaw: lens.yaw,
          pitch: lens.pitch,
          roll: lens.roll,
          xi: lens.xi,
          fx: lens.fx,
          fy: lens.fy,
          k1: lens.k1,
          k2: lens.k2,
          k3: lens.k3,
          k4: lens.k4,
          k5: lens.k5,
          p1: lens.p1,
          p2: lens.p2,
          radius: lens.radius,
          viewToLens: lens.viewToLens,
        ),
    ],
  );
}

/// Whether the folder navigation of the immersive viewer may stop on the raw video named [name] of [kind] without the
/// work of [RawVideoResolver.resolve], which it must not fail on: false for an Insta360 file of a split pair (one
/// square video track in [probe], or no probe and the name of such a file) whose other file is not in [folderNames]
/// (lower case), or when the players lack two streams ([support]); false for a two-track Insta360, a GoPro or a DJI
/// file when they lack two streams, for a GoPro whose tracks are no EAC, and for an Insta360 file of two square tracks
/// or a DJI file whose tracks [probe] lists, unless they are two squares of the same size (the resolver refuses any
/// other); true otherwise (side by side, unknown)
bool rawVideoLikelyPlayable({
  required RawMediaKind kind,
  required String name,
  SphericalProbe? probe,
  required Set<String> folderNames,
  required RawVideoPlaybackSupport support,
}) {
  final videos = probe?.videoTracks ?? const <ProbedTrack>[];
  switch (kind) {
    case RawMediaKind.insta360Photo:
      return true;
    case RawMediaKind.goProVideo:
      return support.twoStreams && (videos.isEmpty || goProEacGeometryOf(probe!) != null);
    case RawMediaKind.djiVideo:
      // Without tracks listed, the resolver reads them from the file: every Osmo 360 video has its two lenses
      return support.twoStreams && (videos.isEmpty || _areTwoLensTracks(videos));
    case RawMediaKind.insta360Video:
      if (videos.length >= 2 && _isSquareTrack(videos[0]) && _isSquareTrack(videos[1])) {
        return support.twoStreams && _sameSize(videos[0], videos[1]);
      }
      final pair = splitPairOf(name);
      final split = videos.isEmpty ? pair != null : videos.length == 1 && _isSquareTrack(videos.first);
      if (!split) {
        return true;
      }
      return support.twoStreams && pair != null && folderNames.contains(pair.siblingName.toLowerCase());
  }
}
