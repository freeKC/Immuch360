// What Flutter asks the immersive viewer of the Meta Quest for a flat 3D photo, through the stereoPair field that
// ImmersiveApi.open already carries (design-final 2026-10-26, section 4.1). Two kinds: sbsPhoto, a side by side file
// shown on the stereo quad as it is, and depthRelief, a flat photo whose right eye the headset makes with relief-v1.
// A kind the viewer does not know shows the photo flat, so nothing breaks across versions. The contract is frozen in
// test/fixtures/ai_immersive/stereo_pair_contract_v1.json, which the Dart tests write against and the Kotlin tests
// read.
//
// The key of the relief cache of the headset is made here too: one place decides what makes two reliefs the same.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The kind and version of the side by side request
const sbsPhotoKind = 'sbsPhoto';
const sbsPhotoVersion = 1;

/// The kind and version of the relief request
const depthReliefKind = 'depthRelief';
const depthReliefVersion = 1;

/// A side by side photo for the stereo quad: which eye is on the left, full or half width, and what the file says of
/// itself (our XMP: the relief was estimated and the left eye is the original; another tool's file: unknown)
class SbsPhotoRequest {
  const SbsPhotoRequest({
    this.layout = EyeOrder.leftRight,
    this.eyes = StereoEyes.full,
    this.origin = ImmersiveOrigin.unknown,
    this.leftEye = LeftEyeSource.unknown,
  });

  final EyeOrder layout;
  final StereoEyes eyes;
  final ImmersiveOrigin origin;
  final LeftEyeSource leftEye;

  Map<String, Object> toJson() => {
    'kind': sbsPhotoKind,
    'version': sbsPhotoVersion,
    'layout': layout.json,
    'eyes': eyes.json,
    'origin': origin.json,
    'leftEye': leftEye.json,
  };

  /// The stereoPair JSON of ImmersiveApi.open
  String toJsonString() => jsonEncode(toJson());

  /// The request [json] holds, null for another kind or version or a value this build does not know
  static SbsPhotoRequest? fromJson(Object? json) {
    if (json is! Map || json['kind'] != sbsPhotoKind || json['version'] != sbsPhotoVersion) {
      return null;
    }
    final layout = EyeOrder.fromJson(json['layout']);
    final eyes = StereoEyes.fromJson(json['eyes']);
    if (layout == null || eyes == null) {
      return null;
    }
    return SbsPhotoRequest(
      layout: layout,
      eyes: eyes,
      origin: ImmersiveOrigin.fromJson(json['origin']) ?? ImmersiveOrigin.unknown,
      leftEye: LeftEyeSource.fromJson(json['leftEye']) ?? LeftEyeSource.unknown,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SbsPhotoRequest &&
      other.layout == layout &&
      other.eyes == eyes &&
      other.origin == origin &&
      other.leftEye == leftEye;

  @override
  int get hashCode => Object.hash(layout, eyes, origin, leftEye);
}

/// A flat photo whose relief the headset estimates: the model file on the headset, its size (checked before loading),
/// its identifier, the key of the cached depth map, the settings of relief-v1 and the quarter turns applied to the photo
class DepthReliefRequest {
  const DepthReliefRequest({
    required this.model,
    required this.modelSize,
    required this.modelId,
    required this.cacheKey,
    this.parallax = ReliefV1.parallax,
    this.convergence = ReliefV1.convergence,
    this.quarterTurns = 0,
  });

  /// Absolute path of the model file on the headset
  final String model;
  final int modelSize;

  /// "depth-anything-v2-small@651415f1" (see [depthModelId])
  final String modelId;

  /// See [reliefCacheKey]
  final String cacheKey;
  final double parallax;
  final double convergence;

  /// Clockwise, 0 to 3
  final int quarterTurns;

  Map<String, Object> toJson() => {
    'kind': depthReliefKind,
    'version': depthReliefVersion,
    'model': model,
    'modelSize': modelSize,
    'modelId': modelId,
    'cacheKey': cacheKey,
    'parallax': parallax,
    'convergence': convergence,
    'quarterTurns': quarterTurns,
  };

  /// The stereoPair JSON of ImmersiveApi.open
  String toJsonString() => jsonEncode(toJson());

  /// The request [json] holds, null for another kind or version or a missing field
  static DepthReliefRequest? fromJson(Object? json) {
    if (json is! Map || json['kind'] != depthReliefKind || json['version'] != depthReliefVersion) {
      return null;
    }
    final model = json['model'];
    final modelSize = json['modelSize'];
    final modelId = json['modelId'];
    final cacheKey = json['cacheKey'];
    final parallax = json['parallax'];
    final convergence = json['convergence'];
    final quarterTurns = json['quarterTurns'];
    if (model is! String ||
        modelSize is! int ||
        modelId is! String ||
        cacheKey is! String ||
        parallax is! num ||
        convergence is! num ||
        quarterTurns is! int) {
      return null;
    }
    return DepthReliefRequest(
      model: model,
      modelSize: modelSize,
      modelId: modelId,
      cacheKey: cacheKey,
      parallax: parallax.toDouble(),
      convergence: convergence.toDouble(),
      quarterTurns: quarterTurns & 3,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DepthReliefRequest &&
      other.model == model &&
      other.modelSize == modelSize &&
      other.modelId == modelId &&
      other.cacheKey == cacheKey &&
      other.parallax == parallax &&
      other.convergence == convergence &&
      other.quarterTurns == quarterTurns;

  @override
  int get hashCode => Object.hash(model, modelSize, modelId, cacheKey, parallax, convergence, quarterTurns);
}

/// The folder of the relief cache of the headset in the cache folder of the app (Context.getCacheDir() on Android,
/// getTemporaryDirectory() in Flutter): one `<key>.u16` file per photo, written by the immersive viewer
/// (ReliefCache.FOLDER in Kotlin), sized and cleared by the advanced settings
const reliefCacheFolderName = 'ai-relief';

/// Who a photo is, for the relief cache: its SHA-1 when the asset has one (server, device), otherwise its place on a
/// share
abstract final class ReliefSourceIdentity {
  /// `sha1:<base64>`
  static String sha1(String base64) => 'sha1:$base64';

  /// `share:<source>:<path>:<size>:<date>`, the date in milliseconds since the epoch, UTC
  static String share({required String source, required String path, required int size, required DateTime modified}) =>
      'share:$source:$path:$size:${modified.toUtc().millisecondsSinceEpoch}';
}

/// The text the relief cache key hashes, `<identity>|<model id>|<pipeline>|<parallax>|<convergence>|<quarter turns>`,
/// the doubles in their shortest form ("0.02", "0.5"), the quarter turns from 0 to 3
String reliefCacheKeyText({
  required String identity,
  required String modelId,
  String pipeline = ReliefV1.pipeline,
  double parallax = ReliefV1.parallax,
  double convergence = ReliefV1.convergence,
  int quarterTurns = 0,
}) => '$identity|$modelId|$pipeline|$parallax|$convergence|${quarterTurns & 3}';

/// The key of the depth map of a photo in the cache of the headset, SHA-256 in hexadecimal of [reliefCacheKeyText]: a
/// new model or a new setting misses the cache by itself
String reliefCacheKey({
  required String identity,
  required String modelId,
  String pipeline = ReliefV1.pipeline,
  double parallax = ReliefV1.parallax,
  double convergence = ReliefV1.convergence,
  int quarterTurns = 0,
}) => sha256
    .convert(
      utf8.encode(
        reliefCacheKeyText(
          identity: identity,
          modelId: modelId,
          pipeline: pipeline,
          parallax: parallax,
          convergence: convergence,
          quarterTurns: quarterTurns,
        ),
      ),
    )
    .toString();
