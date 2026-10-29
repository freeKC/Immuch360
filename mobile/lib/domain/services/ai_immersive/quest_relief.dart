// What the 2D panel of the Meta Quest needs to ask its immersive viewer for an AI relief (design-final 2026-10-26,
// sections 3.5 and 3.7): who the photo is for the relief cache, the depthRelief request naming the model installed on
// the headset, and the relief cache folder the advanced settings size and clear. The headset reads the photo and
// computes the relief itself (lots A8a, A8b and A9a); nothing here reads a pixel.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

/// Who [asset] is for the relief cache: `sha1:<base64>` of its file, the checksum the app holds when it has one (an
/// asset of the server, a photo of the headset already hashed), else the SHA-1 of [file], read here: the same sum the
/// app stores once it hashes the file, so the cached relief is found again then. Throws when there is neither.
Future<String> reliefIdentityOfAsset(BaseAsset asset, {required Future<File?> Function() file}) async {
  final checksum = asset.checksum;
  if (checksum != null && checksum.isNotEmpty) {
    return ReliefSourceIdentity.sha1(checksum);
  }
  final source = await file();
  if (source == null) {
    throw StateError('No checksum and no file for ${asset.name}');
  }
  final digest = await sha1.bind(source.openRead()).first;
  return ReliefSourceIdentity.sha1(base64Encode(digest.bytes));
}

/// Who the file at [path] of the share [sourceId] is for the relief cache: its place, its size and its date (see
/// [ReliefSourceIdentity.share]), a share giving no checksum. A size or a date the share does not tell is written -1
/// or 0: the key stays the same as long as the share tells nothing more.
String reliefIdentityOfShareFile({required String sourceId, required String path, int? size, DateTime? modified}) =>
    ReliefSourceIdentity.share(
      source: sourceId,
      path: path,
      size: size ?? -1,
      modified: modified ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );

/// The depthRelief request of a photo of [identity] that the user sees turned by [quarterTurns] clockwise from its
/// unedited file, the headset reading [model] at [modelPath]: the settings of relief-v1, the key of its depth map in
/// the cache, which a new model, a new setting or another turn misses by itself, and the view the relief first shows
/// in, [mode] (the same map for both)
DepthReliefRequest questReliefRequest({
  required String modelPath,
  AiComponent model = depthModelTfliteComponent,
  required String identity,
  required int quarterTurns,
  ReliefViewMode mode = ReliefViewMode.stereo,
}) {
  final modelId = depthModelId(model.sha256!);
  final turns = quarterTurns & 3;
  return DepthReliefRequest(
    model: modelPath,
    modelSize: model.size!,
    modelId: modelId,
    cacheKey: reliefCacheKey(identity: identity, modelId: modelId, quarterTurns: turns),
    parallax: ReliefV1.parallax,
    convergence: ReliefV1.convergence,
    quarterTurns: turns,
    mode: mode,
  );
}

/// The bytes the files of the relief cache in [folder] take, partial files included: what the immersive viewer
/// writes there (ReliefCache.sizeBytes in Kotlin). A folder inside is not the cache's and is not counted; 0 when there
/// is no cache.
Future<int> reliefCacheBytes(Directory folder) async {
  var bytes = 0;
  for (final file in await _filesOf(folder)) {
    try {
      bytes += await file.length();
    } on FileSystemException {
      // Gone meanwhile: the immersive viewer trims its cache by itself
    }
  }
  return bytes;
}

/// Deletes the files of the relief cache in [folder], partial ones included, and nothing else (ReliefCache.clear in
/// Kotlin): a folder inside, or anything outside, stays. The bytes freed.
Future<int> clearReliefCache(Directory folder) async {
  var freed = 0;
  for (final file in await _filesOf(folder)) {
    try {
      final size = await file.length();
      await file.delete();
      freed += size;
    } on FileSystemException {
      // Gone meanwhile, or held: the next Clear takes it
    }
  }
  return freed;
}

Future<List<File>> _filesOf(Directory folder) async {
  if (!folder.existsSync()) {
    return const [];
  }
  try {
    // A link is not followed: the cache holds plain files only
    return await folder.list(followLinks: false).where((entity) => entity is File).cast<File>().toList();
  } on FileSystemException {
    return const [];
  }
}
