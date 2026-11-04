// Tells a photo of the library that carries a Gaussian splat scene (plan of 3 November 2026, section 4): our packet,
// Immuch360:Kind="GaussianSplat", in the head of its file. Only a photo named like one is read ("salon_splat.jpg", the
// word "splat" of its name): an ordinary library costs no read. Its first 128 KiB, from the copy on the device first,
// else from the original on the server without the edited parameter (an edit of the server is a copy without the
// scene); a server that ignores the range is cut after those bytes. One read per photo per session, the last 2,000
// remembered; a read that failed is tried again next time.
//
// The splat check decides before the 360°, 180° and 3D name rules of the app: "PANO_360_salon_splat.jpg" is a scene, not
// a panorama. Each device then gates the scene on the packet alone (SplatPhotoXmp.head), before any byte of it is read.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/asset_head.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:logging/logging.dart';

final _log = Logger('SplatPhotoProbe');

/// What the head of a photo told
sealed class SplatPhotoProbe {
  const SplatPhotoProbe();
}

/// It carries a splat scene, told by [xmp]
final class SplatPhotoFound extends SplatPhotoProbe {
  const SplatPhotoFound(this.xmp);

  final SplatPhotoXmp xmp;
}

/// Its head was read and holds no packet of a splat photo
final class SplatPhotoNone extends SplatPhotoProbe {
  const SplatPhotoNone();
}

/// Its head could not be read: told again next time
final class SplatPhotoUnread extends SplatPhotoProbe {
  const SplatPhotoUnread();
}

/// The original of the asset [remoteId] on the server of [endpoint] (its API, ".../api"), never with the edited
/// parameter: an edit of the server is a copy without the scene, and the original keeps it
Uri splatPhotoOriginalUri(String endpoint, String remoteId) => Uri.parse('$endpoint/assets/$remoteId/original');

/// See the top of this file
class SplatPhotoService {
  SplatPhotoService({
    required this._localFile,
    required this._serverReader,
    this.maxEntries = 2000,
    this.timeout = const Duration(seconds: 15),
  });

  /// The copy on the device of the asset with this local id, null when there is none
  final Future<File?> Function(String localId) _localFile;

  /// Reads the original on the server of the asset with this remote id, null without a server
  final ByteRangeReader? Function(String remoteId) _serverReader;

  /// Past this many photos, the ones read first are forgotten
  final int maxEntries;

  /// Longest wait for the head of a photo
  final Duration timeout;

  final _results = <String, SplatPhotoXmp?>{};
  final _pending = <String, Future<SplatPhotoProbe>>{};

  /// Whether [asset] may be a splat photo, so that its file is read (see isSplatPhotoCandidate)
  static bool isCandidate(BaseAsset asset) => asset.isImage && isSplatPhotoCandidate(asset.name);

  /// The key of [asset] among the results: its id on the server and its checksum, else its id on the device and its date
  static String keyOf(BaseAsset asset) => flatStereoKey(asset);

  /// What is known of [asset] without a read: its packet, null when it was read and holds none; [SplatPhotoUnread]
  /// when it was never read
  SplatPhotoProbe known(BaseAsset asset) {
    final key = keyOf(asset);
    if (!_results.containsKey(key)) {
      return const SplatPhotoUnread();
    }
    final xmp = _results[key];
    return xmp == null ? const SplatPhotoNone() : SplatPhotoFound(xmp);
  }

  /// What the head of [asset] tells: read once per session, from its copy on the device when there is one, else from
  /// its original on the server. Never throws.
  Future<SplatPhotoProbe> detect(BaseAsset asset) async {
    if (!isCandidate(asset)) {
      return const SplatPhotoNone();
    }
    final known = this.known(asset);
    if (known is! SplatPhotoUnread) {
      return known;
    }
    final key = keyOf(asset);
    final pending = _pending[key] ??= _read(asset, key);
    try {
      return await pending;
    } finally {
      unawaited(_pending.remove(key));
    }
  }

  Future<SplatPhotoProbe> _read(BaseAsset asset, String key) async {
    try {
      final head = await readAssetHead(
        asset,
        localFile: _localFile,
        serverReader: _serverReader,
        length: splatPhotoHeadBytes,
        timeout: timeout,
        log: _log,
      );
      if (head == null) {
        return const SplatPhotoUnread();
      }
      final found = splatPhotoXmpOfHead(head);
      if (found != null) {
        _log.info(
          '${asset.name} carries a splat scene: ${found.splatGaussians} gaussians, ${found.splatLength} bytes, '
          '${found.splatFormat} ${found.splatVersion}${found.isNewer ? ', of a newer version' : ''}',
        );
      }
      _remember(key, found);
      return found == null ? const SplatPhotoNone() : SplatPhotoFound(found);
    } catch (error, stackTrace) {
      _log.warning('Could not tell whether ${asset.name} carries a splat scene', error, stackTrace);
      return const SplatPhotoUnread();
    }
  }

  void _remember(String key, SplatPhotoXmp? found) {
    // Removed first, so that the photo goes last, as the latest
    _results
      ..remove(key)
      ..[key] = found;
    while (_results.length > maxEntries) {
      _results.remove(_results.keys.first);
    }
  }
}

/// The packet of a splat photo in [head], the start of a file; null when it holds none
SplatPhotoXmp? splatPhotoXmpOfHead(Uint8List head) => holdsImmuch360Xmp(head) ? SplatPhotoXmp.findIn(head) : null;
