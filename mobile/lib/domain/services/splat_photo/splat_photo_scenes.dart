// The scenes of the splat photos kept on this device (plan of 3 November 2026, section 5.3): in the splat viewer's cache
// folder, server-<asset>-<first 16 hex of SplatSha256>.spz, the last 5 within 1 GiB (4 GiB on a computer) apart from the
// reduced copies (SplatViewerCache.prune). A scene there of exactly SplatLength bytes opens at once, offline too: its
// sum was checked when it was written. Else it is taken out of the copy on the device first, then of the original on
// the server, the copy that fails a check (a gallery that wrote a trailer after it) giving way to the server.

import 'dart:io';

import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_tail_fetch.dart';
import 'package:immich_mobile/domain/services/splat_viewer_files.dart';
import 'package:logging/logging.dart';

final _log = Logger('SplatPhotoScenes');

/// A scene of a splat photo ready to open: its [file], its head as the SPZ says it, and how it came (null: kept from an
/// earlier viewing, nothing read)
class SplatPhotoScene {
  const SplatPhotoScene({required this.file, required this.head, this.fetched});

  final File file;
  final SplatHead head;
  final SplatTailFetched? fetched;

  bool get fromCache => fetched == null;
}

/// See the top of this file
class SplatPhotoScenes {
  SplatPhotoScenes(this._cache);

  final SplatViewerCache _cache;

  /// The name of the scene of the asset [assetId] whose packet sums it to [sha256]
  static String nameOf(String assetId, String sha256) =>
      '${SplatViewerCache.serverPrefix}${assetId.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '_')}-${sha256.substring(0, 16)}.spz';

  /// The scene of [assetId] kept on this device, null when there is none of the length [xmp] says
  Future<SplatPhotoScene?> kept(String assetId, SplatPhotoXmp xmp) async {
    final file = await _cache.find(nameOf(assetId, xmp.splatSha256!));
    if (file == null) {
      return null;
    }
    if (file.lengthSync() != xmp.splatLength) {
      _log.warning('The kept scene of $assetId has ${file.lengthSync()} bytes of ${xmp.splatLength}: taken again');
      try {
        await file.delete();
      } on FileSystemException {
        // Pruned later
      }
      return null;
    }
    final handle = await file.open();
    try {
      final probe = probeSplatHead(await handle.read(splatHeadBytes), xmp.splatLength);
      return probe is SplatHead ? SplatPhotoScene(file: file, head: probe) : null;
    } finally {
      await handle.close();
    }
  }

  /// The scene of [assetId], kept or taken out of [sources] in their order (see the top of this file). [onSource] is
  /// told each source tried, [onProgress] the bytes done of it and expected (0 when unknown). Throws the problem of the
  /// last source when none gives the scene.
  Future<SplatPhotoScene> obtain(
    String assetId,
    SplatPhotoXmp xmp, {
    required List<SplatTailSource> sources,
    void Function(SplatTailSource source)? onSource,
    void Function(int done, int total)? onProgress,
    SplatPrepareCancel? cancel,
  }) async {
    final kept = await this.kept(assetId, xmp);
    if (kept != null) {
      _log.info('The scene of $assetId is kept on this device: nothing read');
      return kept;
    }
    final out = await _cache.fileFor(nameOf(assetId, xmp.splatSha256!));
    SplatTailFetchException? last;
    for (final source in sources) {
      onSource?.call(source);
      try {
        final watch = Stopwatch()..start();
        final fetched = await fetchSplatTail(
          source: source,
          xmp: xmp,
          out: out,
          onProgress: onProgress,
          cancel: cancel,
        );
        _log.info(
          'The scene of $assetId taken out of $source (${fetched.route.name}): ${xmp.splatLength} bytes, '
          '${fetched.received} received, ${watch.elapsedMilliseconds} ms',
        );
        if (!_sameHead(fetched.head, xmp)) {
          _log.warning('The packet of $assetId says ${xmp.head}, its SPZ ${fetched.head}: the SPZ wins');
        }
        return SplatPhotoScene(file: fetched.file, head: fetched.head, fetched: fetched);
      } on SplatTailFetchException catch (error) {
        if (error.problem == SplatTailFetchProblem.cancelled) {
          rethrow;
        }
        _log.warning('The scene of $assetId could not be taken out of $source: $error');
        last = error;
      }
    }
    throw last ?? const SplatTailFetchException(SplatTailFetchProblem.network, 'no source');
  }

  bool _sameHead(SplatHead head, SplatPhotoXmp xmp) =>
      head.formatVersion == xmp.splatVersion &&
      head.gaussians == xmp.splatGaussians &&
      head.shDegree == xmp.splatShDegree;
}
