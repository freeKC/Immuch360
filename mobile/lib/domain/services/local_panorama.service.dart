// Finds the 360° photos and videos of this device by reading their files. Without a server nothing else tells: the
// server flags 360° assets from their exif (see hasEquirectangularExifProvider), and the database of the device has
// no exif. The rules are the server's: a photo is 360° when its GPano XMP declares an equirectangular projection, a
// video when it declares a spherical projection (see probeSphericalMetadata). The raw files of 360° cameras, which the
// app stitches itself, are 360° too: an Insta360 photo named .insp or ending with the trailer of the camera, a video
// named .insv, .360 (GoPro) or .osv (DJI), whose layout is settled when it opens (see raw_360_detection.dart). So are
// the equirect photos a 360° camera stitched itself without GPano tags: a GoPro .36p, or a 2:1 photo whose EXIF names
// a 360° camera (see isEquirectCameraPhoto).
//
// Reading a file costs a 128 KiB window or two, but there may be thousands of them: only the assets whose shape or
// name hints at 360° are read (see isLocalPanoramaCandidate), the newest first, a few hundred per run, and what was
// read is remembered so that no file is read twice unless it changed, or the rules changed since in a way that may
// tell otherwise of it (see LocalPanoramaRecord.version).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/exif_head.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('LocalPanoramaService');

/// What reading the file of an asset of the device told about its projection
class LocalPanoramaRecord {
  const LocalPanoramaRecord({
    required this.isPanorama,
    this.halfSphere,
    this.raw360 = false,
    required this.checkedAt,
    this.version = currentVersion,
  });

  /// The rules the scan reads the files with now, see [version]
  static const currentVersion = 2;

  /// Whether the file declares a 360° projection, is a raw file of a 360° camera the app stitches, or an equirect photo
  /// a 360° camera stitched itself
  final bool isPanorama;

  /// Whether it covers the front half of the sphere only (VR180), as the file declares it: null when it does not say
  final bool? halfSphere;

  /// Whether it is the raw file of a 360° camera, which the app stitches (see raw_360_detection.dart)
  final bool raw360;

  /// When the file was read, or its modification date when that is later (a clock set wrong): it is read again
  /// once it changed after that
  final DateTime checkedAt;

  /// The rules the file was read with: 0 for the records written before the raw files of Insta360 cameras were told,
  /// 1 since, 2 since the raw videos of every camera are told by their name and the equirect photos of 360° cameras
  /// by their name or their EXIF. A record of older rules is read again once when the current ones may tell otherwise
  /// of its file (see [LocalPanoramaService.scan]).
  final int version;

  /// The record as kept in the store: a small JSON object, the half sphere left out when the file does not say, the raw
  /// flag when it is not set and the version when it is 0 (the records written before them read the same)
  Map<String, Object> toJson() => {
    'p': isPanorama,
    'h': ?halfSphere,
    if (raw360) 'r': true,
    't': checkedAt.millisecondsSinceEpoch,
    if (version > 0) 'v': version,
  };

  /// Reads a record back from [toJson], null for anything else
  static LocalPanoramaRecord? fromJson(Object? json) {
    if (json case {'p': final bool isPanorama, 't': final int checkedAt}) {
      final halfSphere = json['h'];
      final version = json['v'];
      return LocalPanoramaRecord(
        isPanorama: isPanorama,
        halfSphere: halfSphere is bool ? halfSphere : null,
        raw360: json['r'] == true,
        checkedAt: DateTime.fromMillisecondsSinceEpoch(checkedAt),
        version: version is int && version > 0 ? version : 0,
      );
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is LocalPanoramaRecord &&
      other.isPanorama == isPanorama &&
      other.halfSphere == halfSphere &&
      other.raw360 == raw360 &&
      other.checkedAt == checkedAt &&
      other.version == version;

  @override
  int get hashCode => Object.hash(isPanorama, halfSphere, raw360, checkedAt, version);

  @override
  String toString() =>
      'LocalPanoramaRecord(isPanorama: $isPanorama, halfSphere: $halfSphere, raw360: $raw360, '
      'checkedAt: $checkedAt, version: $version)';
}

/// Whether [record], the record of [asset] read with older rules (see [LocalPanoramaRecord.version]), may say
/// otherwise once its file is read with the current ones. Version 1 tells the raw files of Insta360 cameras: a photo
/// named .insp is one, a photo found flat may end with the trailer of the camera. Version 2 tells a raw video by its
/// name, whatever its frame (a split recording or two tracks were flat in version 1, a GoPro .360 or a DJI .osv
/// unknown), and the equirect photos of 360° cameras without GPano tags: named .36p, or 2:1 with the EXIF of such a
/// camera. Any other file reads the same.
bool _mayReadOtherwise(LocalAsset asset, LocalPanoramaRecord record) {
  if (record.version >= LocalPanoramaRecord.currentVersion) {
    return false;
  }
  if (asset.isVideo) {
    return isRawVideoName(asset.name);
  }
  if (record.version < 1 && (!record.isPanorama || isRawPhotoName(asset.name))) {
    return true;
  }
  final width = asset.width;
  final height = asset.height;
  final looksEquirect = width != null && height != null && width > 0 && height > 0 && _isAbout(width / height, 2);
  return !record.isPanorama && (isEquirectCameraPhoto(name: asset.name) || looksEquirect);
}

/// Reads the records from their JSON form, a map from the id of an asset on the device to its record (see
/// [LocalPanoramaRecord.toJson]), in their order. A damaged value, and anything else in it, are skipped.
Map<String, LocalPanoramaRecord> decodeLocalPanoramaRecords(String? json) {
  final records = <String, LocalPanoramaRecord>{};
  if (json == null || json.isEmpty) {
    return records;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return records;
  }
  if (decoded is! Map<String, dynamic>) {
    return records;
  }
  for (final MapEntry(:key, :value) in decoded.entries) {
    final record = LocalPanoramaRecord.fromJson(value);
    if (record != null) {
      records[key] = record;
    }
  }
  return records;
}

/// The JSON form of [records], see [decodeLocalPanoramaRecords]
String encodeLocalPanoramaRecords(Map<String, LocalPanoramaRecord> records) =>
    jsonEncode({for (final MapEntry(:key, :value) in records.entries) key: value.toJson()});

// "360" on its own, not within a longer number ("IMG_1360.JPG", "20240613_103600.jpg"), "pano" ("PANO_0001.jpg",
// "PXL_20240101_PANO.jpg", "panorama"), "vr180", the raw files of 360° cameras (Insta360 .insp and .insv, GoPro .360,
// DJI .osv) and the equirect photos of the GoPro MAX 2 (.36p)
final _panoramaName = RegExp(r'(?<![0-9])360(?![0-9])|pano|vr180|\.(ins[pv]|osv|36p)$', caseSensitive: false);

// "3d" on its own ("trip_3D.jpg", but not "IMG_3D41.JPG") and the VR180 words: two eyes stacked or side by side
final _stereoName = RegExp(r'(?<![a-z0-9])3d(?![a-z0-9])|vr180|180x180', caseSensitive: false);

// Whether [ratio] is [target] within 2 percent
bool _isAbout(double ratio, double target) => (ratio / target - 1).abs() <= 0.02;

/// Whether [asset], a photo or a video of the device, may be 360°, so that its file is worth reading: a 2:1 frame
/// (within 2 percent), the shape of an equirectangular image, or a name that says so ("360", "pano", "vr180", the
/// .insp and .insv files of Insta360 cameras), or a square or 1:2 frame, where two 360° or VR180 eyes are stacked,
/// with a name that tells 3D or VR180. Raw .osv and .36p files too.
bool isLocalPanoramaCandidate(BaseAsset asset) {
  if (!asset.isImage && !asset.isVideo) {
    return false;
  }
  final name = asset.name;
  if (_panoramaName.hasMatch(name)) {
    return true;
  }
  final width = asset.width;
  final height = asset.height;
  if (width == null || height == null || width <= 0 || height <= 0) {
    return false;
  }
  final ratio = width / height;
  if (_isAbout(ratio, 2)) {
    return true;
  }
  return (_isAbout(ratio, 1) || _isAbout(ratio, 0.5)) && _stereoName.hasMatch(name);
}

/// What a file declares about its projection, see [LocalPanoramaRecord]
typedef LocalPanoramaProbe = ({bool isPanorama, bool? halfSphere, bool raw360});

const LocalPanoramaProbe _flat = (isPanorama: false, halfSphere: null, raw360: false);
const LocalPanoramaProbe _raw360 = (isPanorama: true, halfSphere: null, raw360: true);
// An equirect photo a 360° camera stitched itself: the whole sphere, as GoPro, DJI and Insta360 cameras stitch it
const LocalPanoramaProbe _cameraEquirect = (isPanorama: true, halfSphere: false, raw360: false);

// The GPano crop of a VR180 photo: about half the width of the full panorama, and all of its height
bool _isHalfSphereCrop(GPanoTags tags) {
  final crop = tags.crop;
  return crop != null && crop.width >= 0.45 && crop.width <= 0.55 && crop.height > 0.9;
}

/// Reads the projection a photo [length] bytes long declares in its GPano XMP, through [read] (see [readGPanoTags]).
/// The half sphere comes from its crop, unknown without one. Without GPano, a photo that ends with the trailer of an
/// Insta360 camera is a raw dual fisheye photo (see [hasInsta360Trailer]): a .insp renamed to be seen as a JPEG; unless
/// it is named otherwise than .insp and its trailer says the camera stitched it, which makes it an equirect photo (see
/// [isInsta360StitchedPhoto]). Else one whose EXIF names a 360° camera and whose frame is 2:1 is an equirect photo the
/// camera stitched itself (see [isEquirectCameraPhoto]), its frame of [width] x [height] (the size the device gives) or
/// else the one its EXIF gives. Errors of [read] are not caught.
Future<LocalPanoramaProbe> probeLocalPanoramaPhoto(
  ByteRangeReader read,
  int length, {
  String name = '',
  int? width,
  int? height,
}) async {
  final tags = await readGPanoTags(read, length);
  if (tags != null && isEquirectangularGPano(tags)) {
    return (isPanorama: true, halfSphere: tags.crop == null ? null : _isHalfSphereCrop(tags), raw360: false);
  }
  if (await hasInsta360Trailer(read, length)) {
    // Raw by its trailer only: one the camera stitched itself keeps the trailer, and is a 360° photo as it is
    return !isRawPhotoName(name) && await isInsta360StitchedPhoto(read, length) ? _cameraEquirect : _raw360;
  }
  final exif = parseExifHead(await read(0, exifHeadLength));
  final isCameraEquirect = isEquirectCameraPhoto(
    name: name,
    make: exif?.make,
    model: exif?.model,
    width: width ?? exif?.pixelWidth,
    height: height ?? exif?.pixelHeight,
  );
  return isCameraEquirect ? _cameraEquirect : _flat;
}

/// Reads the projection a file of the device declares: the GPano XMP of a photo (see [probeLocalPanoramaPhoto]),
/// the spherical metadata of a video (see [probeSphericalFile]). A video named .insv, .360 or .osv is a raw video
/// without a read: its layout is settled when it opens. A photo named .insp is a raw dual fisheye photo, one named .36p
/// an equirect photo of the GoPro MAX 2. [width] and [height] are the size of the frame the device gives. Errors are not
/// caught.
Future<LocalPanoramaProbe> probeLocalPanoramaFile(String path, {required bool isVideo, int? width, int? height}) async {
  final file = File(path);
  final name = p.basename(path);
  if (isVideo) {
    if (isRawVideoName(name)) {
      return _raw360;
    }
    final probe = await probeSphericalFile(file);
    return (
      isPanorama: probe.hasSphericalMetadata,
      halfSphere: probe.hasSphericalMetadata ? probe.halfSphere : null,
      raw360: false,
    );
  }
  if (isRawPhotoName(name)) {
    return _raw360;
  }
  if (isEquirectCameraPhoto(name: name)) {
    return _cameraEquirect;
  }
  final handle = await file.open();
  try {
    return await probeLocalPanoramaPhoto(
      (offset, length) async {
        await handle.setPosition(offset);
        return handle.read(length);
      },
      await handle.length(),
      name: name,
      width: width,
      height: height,
    );
  } finally {
    await handle.close();
  }
}

/// A file of the device to read, with the size of its frame as the device gives it, see [probeLocalPanoramaFile]
typedef LocalPanoramaFile = ({String path, bool isVideo, int? width, int? height});

/// Reads [files] (see [probeLocalPanoramaFile]) in a background isolate, so that the UI stays smooth meanwhile. A
/// file that cannot be read gives null, in its place.
typedef LocalPanoramaFileProbe = Future<List<LocalPanoramaProbe?>> Function(List<LocalPanoramaFile> files);

/// The default [LocalPanoramaFileProbe]: one background isolate for all of [files]
Future<List<LocalPanoramaProbe?>> probeLocalPanoramaFilesInBackground(List<LocalPanoramaFile> files) =>
    Isolate.run(() => _probeFiles(files));

Future<List<LocalPanoramaProbe?>> _probeFiles(List<LocalPanoramaFile> files) async {
  final probes = <LocalPanoramaProbe?>[];
  for (final file in files) {
    try {
      probes.add(
        await probeLocalPanoramaFile(file.path, isVideo: file.isVideo, width: file.width, height: file.height),
      );
    } catch (error) {
      _log.fine('Could not read ${file.path}: $error');
      probes.add(null);
    }
  }
  return probes;
}

/// Reads up to [limit] assets of the device from the [offset]-th one, the newest first
typedef LocalAssetPageReader = Future<List<LocalAsset>> Function(int offset, int limit);

/// Finds the 360° photos and videos of this device by reading their files, see [scan]
class LocalPanoramaService {
  LocalPanoramaService({
    required this._assets,
    required this._file,
    this._isLocallyAvailable,
    this._probe = probeLocalPanoramaFilesInBackground,
    this._now = DateTime.now,
    this.maxEntries = 2000,
    this.maxFilesPerRun = 300,
    this.pageSize = 500,
    this.batchSize = 20,
  });

  final LocalAssetPageReader _assets;
  final Future<File?> Function(String localId) _file;
  // Null where every file is on the device: only iOS keeps originals in the cloud, and reading those downloads them
  final Future<bool> Function(String localId)? _isLocallyAvailable;
  final LocalPanoramaFileProbe _probe;
  final DateTime Function() _now;

  /// Most records kept: the newest candidates (see [isLocalPanoramaCandidate]) past this many are left out
  final int maxEntries;

  /// Most files read in one run, the newest first: the next run goes on
  final int maxFilesPerRun;

  /// Assets of the database read at once
  final int pageSize;

  /// Files read in the background at once, between which the records are handed over
  final int batchSize;

  /// Reads the files of the assets of the device that may be 360° (see [isLocalPanoramaCandidate]), the newest
  /// first, and gives [records] (see [LocalPanoramaRecord]) updated with them, the latest last.
  ///
  /// A file is read once, and again only when the asset changed since, or when its record was read with older rules
  /// that may tell otherwise of it (see [LocalPanoramaRecord.version]); at most [maxFilesPerRun] per run. On iOS, the
  /// files only in the cloud are left for later. The records of the assets that are gone, or past the newest
  /// [maxEntries] candidates, are dropped. [onProgress] gets the records each time a batch of files was read.
  Future<Map<String, LocalPanoramaRecord>> scan(
    Map<String, LocalPanoramaRecord> records, {
    FutureOr<void> Function(Map<String, LocalPanoramaRecord> records)? onProgress,
  }) async {
    final updated = Map.of(records);
    // Ids of the newest candidates, at most maxEntries: the only ones recorded
    final candidates = <String>{};
    final batch = <(LocalAsset, File)>[];
    var budget = maxFilesPerRun;
    var sawAssets = false;

    Future<void> readBatch() async {
      if (batch.isEmpty) {
        return;
      }
      final probes = await _probe([
        for (final (asset, file) in batch)
          (path: file.path, isVideo: asset.isVideo, width: asset.width, height: asset.height),
      ]);
      final now = _now();
      for (final (index, (asset, _)) in batch.indexed) {
        final probe = index < probes.length ? probes[index] : null;
        // Unreadable for now: read again next time
        if (probe == null) {
          continue;
        }
        final checkedAt = asset.updatedAt.isAfter(now) ? asset.updatedAt : now;
        // Removed first, so that the record goes last, as the latest
        updated
          ..remove(asset.id)
          ..[asset.id] = LocalPanoramaRecord(
            isPanorama: probe.isPanorama,
            halfSphere: probe.halfSphere,
            raw360: probe.raw360,
            checkedAt: checkedAt,
          );
        if (probe.isPanorama) {
          _log.fine('${asset.name} is 360°${probe.raw360 ? ', raw' : ''}');
        }
      }
      batch.clear();
      await onProgress?.call(Map.unmodifiable(updated));
    }

    walk:
    for (var offset = 0; ; offset += pageSize) {
      final page = await _assets(offset, pageSize);
      sawAssets |= page.isNotEmpty;
      for (final asset in page) {
        if (candidates.length >= maxEntries) {
          break walk;
        }
        if (!isLocalPanoramaCandidate(asset)) {
          continue;
        }
        candidates.add(asset.id);
        final known = updated[asset.id];
        final isKnown = known != null && !asset.updatedAt.isAfter(known.checkedAt) && !_mayReadOtherwise(asset, known);
        if (isKnown || budget <= 0) {
          continue;
        }
        final file = await _fileToRead(asset);
        if (file == null) {
          continue;
        }
        budget--;
        batch.add((asset, file));
        if (batch.length >= batchSize) {
          await readBatch();
        }
      }
      if (page.length < pageSize) {
        break;
      }
    }
    await readBatch();

    // An empty database is no sign that the assets are gone: the device may not be synced yet
    if (sawAssets) {
      updated.removeWhere((id, _) => !candidates.contains(id));
    }
    while (updated.length > maxEntries) {
      updated.remove(updated.keys.first);
    }
    return updated;
  }

  // The file of [asset] when it can be read now: null when it is in the cloud only, or cannot be found
  Future<File?> _fileToRead(LocalAsset asset) async {
    try {
      final isLocallyAvailable = _isLocallyAvailable;
      if (isLocallyAvailable != null && !await isLocallyAvailable(asset.id)) {
        return null;
      }
      return await _file(asset.id);
    } catch (error) {
      _log.fine('No file to read for ${asset.name}: $error');
      return null;
    }
  }
}
