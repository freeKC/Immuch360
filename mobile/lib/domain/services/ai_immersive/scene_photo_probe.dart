// Tells a photo of the library that carries a 3D scene a computer made from it (design-final 2026-10-27, sections 8.2
// and 8.3): our packet, Immuch360:Kind="VolumetricScene", in the head of its file. Only a photo named like one is read
// ("salon_scene3D.jpg", the word "scene3d" of its name): an ordinary photo costs no read, as for the flat 3D photos
// (see FlatStereoService). The Quest offers "Explore the 3D scene" from what this finds, gated by the packet (see
// sceneGateOf); the phones, the tablets and the TVs say "Open it on a Meta Quest to explore it" in the details.
//
// The photos of the shares get the same answer from NetworkMediaInfo.scene, read with their GPano tags.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:logging/logging.dart';

final _log = Logger('ScenePhotoProbe');

/// How much of the head of a photo is read for its packet: the window the computers write it within (128 KiB)
const scenePhotoHeadLength = 128 * 1024;

/// Whether a photo named [name] may carry a 3D scene, so that its head is worth reading: a word "scene3d" in its name,
/// split as the probe of the side by side photos splits one (on dots, underscores, dashes and spaces, in any case)
bool isScenePhotoCandidate(String name) => name.toLowerCase().split(RegExp(r'[._\- ]+')).contains('scene3d');

/// The packet of a 3D scene in [head], the start of a file; null when it holds none, or our packet of another kind
SceneXmp? sceneXmpOfHead(Uint8List head) {
  if (!holdsImmuch360Xmp(head)) {
    return null;
  }
  final xmp = ImmersiveXmp.findIn(head);
  return xmp is SceneXmp ? xmp : null;
}

/// Tells which photos of the library carry a 3D scene (see [detect]). What it found lasts as long as the app, in
/// memory: a candidate costs one read of its head per session.
class ScenePhotoService {
  ScenePhotoService({
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

  // What was found per photo (see flatStereoKey), the latest last, photos without a scene included
  final _results = <String, SceneXmp?>{};
  final _pending = <String, Future<SceneXmp?>>{};

  /// Whether [asset] may carry a scene, so that its file is read (see [isScenePhotoCandidate])
  static bool isCandidate(BaseAsset asset) => asset.isImage && isScenePhotoCandidate(asset.name);

  /// The packet of the scene [asset] carries, null when it carries none or when its file could not be read (it is read
  /// again next time). Read from its copy on the device when there is one, else from the original on the server, its
  /// head only. Never throws.
  Future<SceneXmp?> detect(BaseAsset asset) async {
    if (!isCandidate(asset)) {
      return null;
    }
    final key = flatStereoKey(asset);
    if (_results.containsKey(key)) {
      return _results[key];
    }
    final pending = _pending[key] ??= _read(asset, key);
    try {
      return await pending;
    } finally {
      unawaited(_pending.remove(key));
    }
  }

  Future<SceneXmp?> _read(BaseAsset asset, String key) async {
    try {
      final head = await _readHead(asset);
      if (head == null) {
        return null;
      }
      final found = sceneXmpOfHead(head);
      if (found != null) {
        _log.info('${asset.name} carries a 3D scene: ${found.sceneTriangles} triangles, ${found.sceneFormat}');
      }
      _remember(key, found);
      return found;
    } catch (error, stackTrace) {
      _log.warning('Could not tell whether ${asset.name} carries a 3D scene', error, stackTrace);
      return null;
    }
  }

  /// The head of the file of [asset], null when it could not be read
  Future<Uint8List?> _readHead(BaseAsset asset) async {
    final localId = asset.localId;
    if (localId != null) {
      File? file;
      try {
        file = await _localFile(localId);
      } catch (error) {
        _log.fine('Copy on the device of ${asset.name} not found: $error');
      }
      if (file != null) {
        try {
          final handle = await file.open();
          try {
            return await handle.read(scenePhotoHeadLength).timeout(timeout);
          } finally {
            await handle.close();
          }
        } catch (error) {
          _log.fine('Copy on the device of ${asset.name} unreadable, reading the server copy: $error');
        }
      }
    }
    final remoteId = asset.remoteId;
    final read = remoteId == null ? null : _serverReader(remoteId);
    if (read == null) {
      return null;
    }
    try {
      return await read(0, scenePhotoHeadLength).timeout(timeout);
    } catch (error) {
      _log.info('Could not read the head of ${asset.name} on the server: $error');
      return null;
    }
  }

  void _remember(String key, SceneXmp? found) {
    // Removed first, so that the photo goes last, as the latest
    _results
      ..remove(key)
      ..[key] = found;
    while (_results.length > maxEntries) {
      _results.remove(_results.keys.first);
    }
  }
}
