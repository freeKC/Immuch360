// Which assets are Apple spatial media (see AppleSpatialInfo), read from their files: the server tells nothing about
// them. A photo is read once, its head only (see probeHeicStereoPair), and what was found is kept on the device, in
// the Store; a video is what its spherical probe says (see SphericalProbe.multiview), which every video gets anyway.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/apple_spatial/heic_stereo_probe.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:logging/logging.dart';

final _log = Logger('AppleSpatialService');

/// Key of [asset] in the cache: its id on the server and its checksum, which change together with the file, else its
/// id on the device and the time it last changed
String appleSpatialCacheKey(BaseAsset asset) {
  final remoteId = asset.remoteId;
  if (remoteId != null) {
    return 'r:$remoteId:${asset.checksum ?? ''}';
  }
  return 'l:${asset.localId ?? asset.id}:${asset.updatedAt.millisecondsSinceEpoch}';
}

/// What the cache keeps of a media: a spatial photo with its pair, a spatial video with its layers, or nothing spatial
/// ("none"). Null for an entry it does not read: the media is read again.
({AppleSpatialInfo? info})? decodeAppleSpatialEntry(Object? entry) {
  if (entry is! Map) {
    return null;
  }
  switch (entry['k']) {
    case 'none':
      return (info: null);
    case 'photo':
      final pair = HeicStereoPair.fromImmersiveMap(entry['p']);
      return pair == null ? null : (info: AppleSpatialInfo.photo(pair));
    case 'video':
      final video = entry['v'];
      if (video is! Map) {
        return null;
      }
      int? integer(String key) => switch (video[key]) {
        final int value => value,
        _ => null,
      };
      final fov = video['fov'];
      return (
        info: AppleSpatialInfo.video(
          MultiviewInfo(
            heroEye: integer('hero') ?? 0,
            baselineMicrometres: integer('baseline'),
            disparityAdjustment: integer('disparity'),
            horizontalFovDegrees: fov is num ? fov.toDouble() : null,
            eyesReversed: video['reversed'] == true,
          ),
        ),
      );
  }
  return null;
}

/// The JSON form of what [decodeAppleSpatialEntry] reads
Map<String, Object> encodeAppleSpatialEntry(AppleSpatialInfo? info) {
  final photo = info?.photo;
  final video = info?.video;
  if (photo != null) {
    return {'k': 'photo', 'p': photo.toImmersiveMap()};
  }
  if (video != null) {
    final baseline = video.baselineMicrometres;
    final disparity = video.disparityAdjustment;
    final fov = video.horizontalFovDegrees;
    return {
      'k': 'video',
      'v': {
        'hero': video.heroEye,
        'baseline': ?baseline,
        'disparity': ?disparity,
        'fov': ?fov,
        if (video.eyesReversed) 'reversed': true,
      },
    };
  }
  return {'k': 'none'};
}

/// Tells which assets are Apple spatial media, see [detect]
class AppleSpatialService {
  AppleSpatialService({
    required this._localFile,
    required this._serverReader,
    required this._probeVideo,
    required this._readCache,
    required this._writeCache,
    this.maxEntries = 2000,
    this.photoTimeout = const Duration(seconds: 15),
  });

  /// The copy on the device of the asset with this local id, null when there is none
  final Future<File?> Function(String localId) _localFile;

  /// Reads the original on the server of the asset with this remote id, null without a server
  final ByteRangeReader? Function(String remoteId) _serverReader;

  /// What the file of a video declares (see SphericalProbeService.probe), null when it could not be read
  final Future<SphericalProbe?> Function(BaseAsset asset) _probeVideo;

  /// The JSON the cache was kept as, null when there is none
  final String? Function() _readCache;
  final Future<void> Function(String json) _writeCache;

  /// Past this many media, the ones read first are forgotten
  final int maxEntries;

  /// Longest wait for the head of a photo
  final Duration photoTimeout;

  // What was found per media (see appleSpatialCacheKey), the latest last; read from the Store on the first use
  Map<String, AppleSpatialInfo?>? _cache;
  final _pending = <String, Future<AppleSpatialInfo?>>{};
  // The videos the 2D notice was shown for, in this session
  final _noticed = <String>{};

  Map<String, AppleSpatialInfo?> get _entries => _cache ??= _load();

  // In the order they were found, the latest last: a map literal keeps the order of its keys
  Map<String, AppleSpatialInfo?> _load() {
    final entries = <String, AppleSpatialInfo?>{};
    String? json;
    try {
      json = _readCache();
    } catch (error) {
      // No store (tests, or before it opened): nothing was read yet
      _log.fine('No cache of the spatial media: $error');
    }
    if (json == null || json.isEmpty) {
      return entries;
    }
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map) {
        for (final MapEntry(:key, :value) in decoded.entries) {
          final entry = decodeAppleSpatialEntry(value);
          if (key is String && entry != null) {
            entries[key] = entry.info;
          }
        }
      }
    } on FormatException catch (error) {
      _log.warning('Damaged cache of the spatial media, read again: $error');
    }
    return entries;
  }

  /// Whether [asset] may be a spatial media at all: a HEIF photo, or any video
  static bool isCandidate(BaseAsset asset) => asset.isVideo || (asset.isImage && isHeifName(asset.name));

  /// What an earlier [detect] found for [asset], without reading anything: null when it is not spatial or unknown
  AppleSpatialInfo? cached(BaseAsset asset) => _entries[appleSpatialCacheKey(asset)];

  /// What makes [asset] an Apple spatial media, null when it is none, or when its file could not be read (it is read
  /// again next time). A HEIF photo is read from its copy on the device when there is one, else from the original on
  /// the server, its head only; a video is what its spherical probe says. Never throws.
  Future<AppleSpatialInfo?> detect(BaseAsset asset) async {
    if (!isCandidate(asset)) {
      return null;
    }
    final key = appleSpatialCacheKey(asset);
    final entries = _entries;
    if (entries.containsKey(key)) {
      return entries[key];
    }
    final pending = _pending[key] ??= _read(asset, key);
    try {
      return await pending;
    } finally {
      unawaited(_pending.remove(key));
    }
  }

  /// True the first time it is asked for [asset] in this session: the notice that a spatial video plays in 2D shows
  /// once per video
  bool takeVideoNotice(BaseAsset asset) => _noticed.add(appleSpatialCacheKey(asset));

  Future<AppleSpatialInfo?> _read(BaseAsset asset, String key) async {
    try {
      if (asset.isVideo) {
        final probe = await _probeVideo(asset);
        if (probe == null) {
          return null;
        }
        final multiview = probe.multiview;
        final info = multiview == null ? null : AppleSpatialInfo.video(multiview);
        await _remember(key, info);
        return info;
      }
      final pair = await _readPhoto(asset);
      if (pair == null) {
        return null;
      }
      final found = pair.$1;
      final info = found == null ? null : AppleSpatialInfo.photo(found);
      if (info != null) {
        _log.info('${asset.name} is an Apple spatial photo: ${info.photo}');
      }
      await _remember(key, info);
      return info;
    } catch (error, stackTrace) {
      _log.warning('Could not tell whether ${asset.name} is a spatial media', error, stackTrace);
      return null;
    }
  }

  // The pair of a photo, in a record so that "read, no pair" and "could not read" stay apart (null)
  Future<(HeicStereoPair?,)?> _readPhoto(BaseAsset asset) async {
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
          return (await _probeFile(file),);
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
      return (await probeHeicStereoPair(read).timeout(photoTimeout),);
    } catch (error) {
      _log.info('Could not read the head of ${asset.name} on the server: $error');
      return null;
    }
  }

  Future<HeicStereoPair?> _probeFile(File file) async {
    final handle = await file.open();
    try {
      return await probeHeicStereoPair((offset, length) async {
        await handle.setPosition(offset);
        return handle.read(length);
      }).timeout(photoTimeout);
    } finally {
      await handle.close();
    }
  }

  Future<void> _remember(String key, AppleSpatialInfo? info) async {
    final entries = _entries;
    // Removed first, so that the media goes last, as the latest
    entries
      ..remove(key)
      ..[key] = info;
    while (entries.length > maxEntries) {
      entries.remove(entries.keys.first);
    }
    try {
      await _writeCache(
        jsonEncode({for (final MapEntry(:key, :value) in entries.entries) key: encodeAppleSpatialEntry(value)}),
      );
    } catch (error) {
      // Kept in memory until the app restarts
      _log.fine('Could not keep the spatial media in the store: $error');
    }
  }
}
