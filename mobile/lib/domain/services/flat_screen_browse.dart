// Previous and next on the flat screen of the immersive viewer of the Meta Quest (GitHub issue 19, point 1): what a
// photo of the timeline becomes when the user reaches it from a photo opened on the big screen, in 3D or with an AI
// relief. The rules are those of the buttons of the top bar of the asset viewer (viewer_top_app_bar.widget.dart):
//
// * skipped: a video (the flat video screen keeps its own opening), a splat, a photo that carries a 3D scene, and a
//   media the viewer shows as 360° (the navigator leaves those out before asking here, with the query of the server's
//   flags a chunk at a time);
// * an Apple spatial photo goes on the quad with its two eyes, a side by side photo too, and so does a photo whose
//   name says its eyes are one above the other while "3D told by the file name" is on;
// * any other photo is a relief when the opening was one and the headset may make it (the gate of the AI features and
//   the depth model installed and intact), at the strength and first view of the settings read at that photo, else
//   one picture on the big screen.
//
// A read of a file (the pair of a HEIF photo, the head of a side by side candidate, the packet of a scene or a splat)
// waits [flatScreenReadTimeout] at most: a photo whose read fails or is slow goes on the big screen as one picture
// rather than holding the search. Pure: what it reads comes through [FlatScreenBrowseFacts].

import 'dart:async';

import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/flat_stereo.dart';
import 'package:immich_mobile/domain/services/ai_immersive/scene_photo_probe.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_probe.dart';
import 'package:logging/logging.dart';

final _log = Logger('FlatScreenBrowse');

/// Longest read of a file for one photo during a search (see [flatScreenRequestOf])
const flatScreenReadTimeout = Duration(seconds: 5);

/// Photos of a chunk classified at once, nearest first (see [classifyNearestFirst])
const flatScreenClassifyBatch = 4;

/// What a photo reached by previous or next becomes on the flat screen
sealed class FlatScreenChoice {
  const FlatScreenChoice();

  /// Shown on the flat screen (any choice but [FlatScreenSkip])
  bool get shows => this is! FlatScreenSkip;
}

/// Left out: the search goes on past it
final class FlatScreenSkip extends FlatScreenChoice {
  const FlatScreenSkip(this.reason);

  final String reason;

  @override
  String toString() => 'skip ($reason)';
}

/// An Apple spatial photo, both eyes
final class FlatScreenHeic extends FlatScreenChoice {
  const FlatScreenHeic(this.pair);

  final HeicStereoPair pair;

  @override
  String toString() => 'spatial photo';
}

/// A photo of two eyes side by side
final class FlatScreenSbs extends FlatScreenChoice {
  const FlatScreenSbs(this.request);

  final SbsPhotoRequest request;

  @override
  String toString() => 'side by side';
}

/// A photo of two eyes one above the other, told by its file name
final class FlatScreenFlat3d extends FlatScreenChoice {
  const FlatScreenFlat3d(this.request);

  final Flat3dRequest request;

  @override
  String toString() => 'flat 3D by name';
}

/// A flat photo whose relief the headset makes
final class FlatScreenRelief extends FlatScreenChoice {
  const FlatScreenRelief(this.request);

  final DepthReliefRequest request;

  @override
  String toString() => 'relief (parallax ${request.parallax}, ${request.mode.json})';
}

/// One picture, whole, on the big screen
final class FlatScreenBigScreen extends FlatScreenChoice {
  const FlatScreenBigScreen();

  @override
  String toString() => 'big screen';
}

/// What [flatScreenRequestOf] reads, from the providers of the asset viewer the viewer was opened from (see
/// FlatScreenImmersiveNavigator), or from the fakes of a test
abstract interface class FlatScreenBrowseFacts {
  /// The two eyes of a HEIF photo, null when it is not a spatial photo
  Future<HeicStereoPair?> spatialPair(BaseAsset asset);

  /// What makes a photo one of two eyes side by side, null when it is flat
  Future<FlatStereoPhoto?> sideBySide(BaseAsset asset);

  /// Whether a photo named like one carries a 3D scene
  Future<bool> carriesScene(BaseAsset asset);

  /// Whether a photo named like one is a splat photo (false while the splats are off)
  Future<bool> isSplat(BaseAsset asset);

  /// "3D told by the file name", as the settings say now
  bool get flat3dByName;

  /// The relief request of [asset] at the strength and first view of the settings now, null when the headset may not
  /// make one (the AI features off or refused, the model missing or damaged)
  Future<DepthReliefRequest?> relief(BaseAsset asset);
}

/// What [asset] becomes on the flat screen, for an opening that was a relief or not ([relief]): see the top of this
/// file. A read slower than [readTimeout], or one that fails, gives the big screen.
Future<FlatScreenChoice> flatScreenRequestOf(
  BaseAsset asset,
  FlatScreenBrowseFacts facts, {
  required bool relief,
  Duration readTimeout = flatScreenReadTimeout,
}) async {
  if (!asset.isImage) {
    return FlatScreenSkip(asset.isVideo ? 'a video' : 'not a photo');
  }
  try {
    Future<T> read<T>(Future<T> Function() reader) => reader().timeout(readTimeout);
    if (SplatPhotoService.isCandidate(asset) && await read(() => facts.isSplat(asset))) {
      return const FlatScreenSkip('a splat photo');
    }
    if (ScenePhotoService.isCandidate(asset) && await read(() => facts.carriesScene(asset))) {
      return const FlatScreenSkip('a photo that carries a 3D scene');
    }
    if (isHeifName(asset.name)) {
      final pair = await read(() => facts.spatialPair(asset));
      if (pair != null) {
        return FlatScreenHeic(pair);
      }
    }
    if (FlatStereoService.isCandidate(asset)) {
      final sbs = await read(() => facts.sideBySide(asset));
      if (sbs != null) {
        final request = sbs.request;
        // A file of a newer format keeps its greyed 3D button in the app: nothing the flat screen can show of it
        return request != null ? FlatScreenSbs(request) : const FlatScreenSkip('a 3D photo of a newer format');
      }
    }
    final stacked = facts.flat3dByName ? stackedPhotoFormatOf(asset.name) : null;
    if (stacked != null) {
      return FlatScreenFlat3d(Flat3dRequest(stacked));
    }
    if (relief) {
      final request = await read(() => facts.relief(asset));
      if (request != null) {
        return FlatScreenRelief(request);
      }
    }
    return const FlatScreenBigScreen();
  } on TimeoutException {
    _log.info('${asset.name}: a read took more than $readTimeout, shown on the big screen');
    return const FlatScreenBigScreen();
  } catch (error) {
    _log.info('${asset.name}: a read failed ($error), shown on the big screen');
    return const FlatScreenBigScreen();
  }
}

/// Classifies [assets], given nearest first, [batch] at a time with [classify], and stops after the first batch that
/// holds a photo to show: the choices, in the order of [assets], null for those never classified. A search reads the
/// files of four photos at once at most, and none past the photo it found.
Future<List<FlatScreenChoice?>> classifyNearestFirst(
  List<BaseAsset> assets,
  Future<FlatScreenChoice> Function(BaseAsset asset) classify, {
  int batch = flatScreenClassifyBatch,
  bool Function()? isCancelled,
}) async {
  final choices = List<FlatScreenChoice?>.filled(assets.length, null);
  for (var start = 0; start < assets.length; start += batch) {
    if (isCancelled?.call() ?? false) {
      break;
    }
    final end = start + batch < assets.length ? start + batch : assets.length;
    final found = await Future.wait([for (var i = start; i < end; i++) classify(assets[i])]);
    for (var i = start; i < end; i++) {
      choices[i] = found[i - start];
    }
    if (found.any((choice) => choice.shows)) {
      break;
    }
  }
  return choices;
}
