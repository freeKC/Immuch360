// The calibration of the raw dual fisheye files of Insta360 cameras (.insp photos, .insv videos), which the viewers need
// to stitch them: read from the trailer of the file, on the device, on the server with a few range requests rather
// than the whole file (the head of a photo only when the server ignores them), or on a network share; else the
// calibration kept for the same camera, from another of its files; else the last one kept for the same camera model;
// else the nominal values of an X3, with seams a few pixels off. A calibration read from a file is kept for its camera
// and its model (see DualFisheyeCalibrationStore). See docs/16-dual-fisheye-spec.md, sections 2 and 4.
//
// The DJI Osmo 360 writes the calibration of its two lenses in a camd box at the end of each .osv file (see
// readDjiOsvCalibration): read the same way, never kept for the camera, the nominal values of the Osmo 360 otherwise.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/models/spatial_media.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/raw/dji_osv.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_calibration_store.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_plan.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:logging/logging.dart';

final _log = Logger('DualFisheyeCalibration');

/// Side of the frame squares the nominal values are given for when the frame is unknown: they scale with the frame,
/// so any side draws the same
const _nominalSquare = 2880;

/// A calibration, and whether reading the file failed on the way to it (a network error, a timeout): such a result is
/// not kept, the next opening tries again
typedef ResolvedDualFisheyeCalibration = ({DualFisheyeCalibration calibration, bool readFailed});

/// The calibration of a raw dual fisheye file of [fileSize] bytes that [read] reads (null for a file that cannot be
/// read; [fileSize] null leaves the trailer unread, for a server that ignores range requests, of which the head of a
/// photo only is read):
/// - the one of its trailer (see [readInsta360Trailer] and [calibrationOf]), the Mei model of V3 first, then kept in
///   [store] for the camera the trailer names and for its model;
/// - else the one [store] kept for that camera (a trailer without calibration strings), which the trailer names, or
///   the EXIF of a photo;
/// - else the last one [store] kept for its camera model, named the same way (the members _008 and _009 of an X3 HDR
///   group have no trailer, and their EXIF gives the model only);
/// - else the nominal values of an X3 (see [nominalX3]) on squares of [frameSquare] pixels.
///
/// Gravity comes from the IMU samples of the trailer, else, for a photo ([isPhoto]), from the sample of its MakerNote
/// (see [readInsta360PhotoHead]), else the camera is taken as upright; [DualFisheyeCalibration.gravity] tells which.
/// The fields of the trailer about the layout of a video go with whatever calibration is given
/// ([DualFisheyeCalibration.layoutHints]), a cached or nominal one included. An error of [read] counts as a file without
/// a trailer, and is told in [ResolvedDualFisheyeCalibration.readFailed].
Future<ResolvedDualFisheyeCalibration> resolveDualFisheyeCalibration({
  required ByteRangeReader? read,
  required int? fileSize,
  required bool isPhoto,
  required DualFisheyeCalibrationStore store,
  int? frameSquare,
}) async {
  var readFailed = false;
  Insta360Trailer? trailer;
  if (read != null && fileSize != null && fileSize > 0) {
    try {
      trailer = await readInsta360Trailer(read, fileSize);
    } catch (error) {
      _log.info('Could not read the trailer: $error');
      readFailed = true;
    }
  }
  // The EXIF of a photo levels it when the trailer has no IMU samples, and names its camera when there is no metadata
  // that does
  final wantsHead =
      trailer == null || trailer.meanAccelerometer == null || (trailer.serial == null && trailer.cameraModel == null);
  Insta360PhotoHead? head;
  if (read != null && isPhoto && wantsHead && !readFailed) {
    try {
      head = await readInsta360PhotoHead(read);
    } catch (error) {
      _log.info('Could not read the head of the photo: $error');
    }
  }

  final serial = _named(trailer?.serial) ?? _named(head?.serial);
  final cameraModel = _named(trailer?.cameraModel) ?? _named(head?.cameraModel);
  final accelerometer = head?.imu?.accelerometer;
  final gravity = trailer?.meanAccelerometer != null
      ? GravitySource.imu
      : accelerometer != null
      ? GravitySource.makerNote
      : GravitySource.none;
  final hints = insta360LayoutHintsOf(trailer);
  final fromFile = trailer == null
      ? null
      : calibrationOf(
          trailer,
          accelerometer: accelerometer,
        )?.copyWith(serial: serial, cameraModel: cameraModel, gravity: gravity, layoutHints: hints);
  if (fromFile != null) {
    if (serial != null) {
      // Kept for the files of the camera, and of its model, without one; the viewer does not wait for the write
      unawaited(store.remember(serial, fromFile));
    }
    return (calibration: fromFile, readFailed: false);
  }

  final downBody = downBodyFromAccelerometer(trailer?.meanAccelerometer ?? accelerometer);
  // The camera's own calibration first; another camera of the same model is still closer than the nominal values
  final cached =
      (serial == null ? null : await store.forSerial(serial, downBody: downBody)) ??
      (cameraModel == null ? null : await store.forModel(cameraModel, downBody: downBody));
  if (cached != null) {
    return (calibration: cached.copyWith(gravity: gravity, layoutHints: hints), readFailed: readFailed);
  }
  final square = frameSquare != null && frameSquare > 0 ? frameSquare : _nominalSquare;
  return (
    calibration: nominalX3(
      square,
    ).copyWith(downBody: downBody, serial: serial, cameraModel: cameraModel, gravity: gravity, layoutHints: hints),
    readFailed: readFailed,
  );
}

/// What [trailer] says of the layout of a video: its lens order, its files or tracks, the recording it belongs to and
/// the window of the sensor its frames show; null without a trailer
Insta360LayoutHints? insta360LayoutHintsOf(Insta360Trailer? trailer) {
  if (trailer == null) {
    return null;
  }
  final crop = trailer.crop;
  final hasWindow = crop != null && crop.sourceWidth > 0 && crop.sourceHeight > 0 && crop.width > 0 && crop.height > 0;
  return Insta360LayoutHints(
    fileLayout: trailer.fileLayout,
    trackOrder: trailer.trackOrder,
    streamLayout: trailer.streamLayout,
    imageCategory: trailer.imageCategory,
    groupIdentity: trailer.groupIdentity,
    videoWindow: hasWindow
        ? (
            areaWidth: crop.sourceWidth,
            areaHeight: crop.sourceHeight,
            width: crop.width,
            height: crop.height,
            offsetX: crop.offsetX,
            offsetY: crop.offsetY,
          )
        : null,
  );
}

// [value] trimmed, null when it is empty
String? _named(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// The translated name of where a calibration came from, for the label of the panorama viewer
String dualFisheyeSourceLabel(Translations t, DualFisheyeSource source) => switch (source) {
  DualFisheyeSource.file => t.raw_360_calibration_file,
  DualFisheyeSource.cachedSerial => t.raw_360_calibration_cached,
  DualFisheyeSource.nominal => t.raw_360_calibration_nominal,
};

/// Opens the file at [url] for range reads through [client], with [headers]: its last [tailLength] bytes are read at
/// once with a suffix range, whose answer tells the size of the file, and kept for the reads that fall in them (the
/// trailer of an Insta360 file ends there).
///
/// A server that ignores ranges answers with the whole file, 20 MB and more for a raw photo: only its first
/// [headLength] bytes are taken then, the transfer stops there, and they are kept for the reads that fall in them (the
/// EXIF of a photo, with its gravity and its camera model). The size stays unknown, so that the trailer at the end is
/// not looked for. Null when the server answers with an error.
Future<({int? size, ByteRangeReader read})?> openHttpRangeFile(
  http.Client client,
  Uri url, {
  Map<String, String> headers = const {},
  int tailLength = 64 * 1024,
  int headLength = insta360PhotoHeadLength,
}) async {
  final request = http.Request('GET', url)
    ..headers.addAll(headers)
    ..headers['range'] = 'bytes=-$tailLength';
  final response = await client.send(request);
  final ranged = httpRangeReader(client, url, headers: headers);
  if (response.statusCode == 200) {
    final head = await _firstBytes(response.stream, headLength);
    _log.info('No range read of $url: its first ${head.length} bytes only');
    return (size: null, read: _keptBytesReader(head, 0, ranged));
  }
  final contentRange = response.headers['content-range'];
  final match = contentRange == null ? null : RegExp(r'bytes\s+(\d+)-(\d+)/(\d+)').firstMatch(contentRange);
  if (response.statusCode != 206 || match == null) {
    // Leaving the stream cancels the transfer
    await response.stream.listen(null).cancel();
    _log.info('No range read of $url: HTTP ${response.statusCode}');
    return null;
  }
  final start = int.parse(match.group(1)!);
  final size = int.parse(match.group(3)!);
  final tail = await response.stream.toBytes();
  return (size: size, read: _keptBytesReader(tail, start, ranged));
}

/// The first [length] bytes of [stream], fewer when it ends before; leaving it once they arrived cancels the rest of
/// the transfer
Future<Uint8List> _firstBytes(Stream<List<int>> stream, int length) async {
  final builder = BytesBuilder(copy: false);
  await for (final bytes in stream) {
    builder.add(bytes);
    if (builder.length >= length) {
      break;
    }
  }
  final bytes = builder.takeBytes();
  return bytes.length > length ? Uint8List.sublistView(bytes, 0, length) : bytes;
}

/// Reads the bytes of the file at [start] out of [kept] when they are all in it, else with [read]
ByteRangeReader _keptBytesReader(Uint8List kept, int start, ByteRangeReader read) => (offset, length) async {
  final local = offset - start;
  if (local >= 0 && local + length <= kept.length) {
    return Uint8List.sublistView(kept, local, local + length);
  }
  return read(offset, length);
};

/// Finds the calibration of raw dual fisheye files (see [resolveDualFisheyeCalibration], and [readDjiOsvCalibration]
/// for a DJI video) and keeps it in memory, per file, as long as the app runs. A read that fails or takes longer than
/// [timeout] gives the fallbacks, and is tried again next time.
class DualFisheyeCalibrationService implements RawVideoCalibrations {
  DualFisheyeCalibrationService({
    required this.store,
    required this._storage,
    required this._client,
    required this._serverEndpoint,
    required this._headers,
    this.timeout = const Duration(seconds: 10),
    this.maxEntries = 100,
  });

  /// Where the calibrations read are kept by camera
  final DualFisheyeCalibrationStore store;

  final StorageRepository _storage;
  final http.Client Function() _client;
  final String? Function() _serverEndpoint;
  final Map<String, String> Function() _headers;

  /// Longest wait for the reads of a file
  final Duration timeout;

  /// Past this many files, the calibrations found first are forgotten
  final int maxEntries;

  final _results = <String, DualFisheyeCalibration>{};
  final _pending = <String, Future<DualFisheyeCalibration>>{};

  /// The calibration of [asset], a raw dual fisheye photo or video: read from [localFile] when given, else from the
  /// copy on the device when there is one, else from the original on the server
  Future<DualFisheyeCalibration> forAsset(BaseAsset asset, {File? localFile}) => _remembered(
    rawAssetKey(asset),
    () => openAsset(asset, localFile: localFile),
    isPhoto: !asset.isVideo,
    frameSquare: asset.height,
  );

  /// The calibration of [input], an Insta360 video (see [RawVideoResolver]): read from the file it opens, cached under
  /// its key; [frameSquare] is the height of its frames when known
  @override
  Future<DualFisheyeCalibration> forInput(RawVideoInput input, {int? frameSquare}) =>
      _remembered(input.key, input.open, isPhoto: false, frameSquare: frameSquare);

  /// The calibration of [input], a DJI .osv video: from its camd box (see [readDjiOsvCalibration]), else the nominal
  /// values of the Osmo 360. Kept in memory under its key, unless the read failed: the next opening tries again.
  @override
  Future<DualFisheyeCalibration> forDji(RawVideoInput input) async {
    final key = 'dji:${input.key}';
    final known = _results[key];
    if (known != null) {
      return known;
    }
    final pending = _pending[key] ??= _resolveDji(key, input);
    try {
      return await pending;
    } finally {
      unawaited(_pending.remove(key));
    }
  }

  Future<DualFisheyeCalibration> _resolveDji(String key, RawVideoInput input) async {
    DjiOsvCalibration? read;
    var readFailed = false;
    try {
      read = await _readDji(input).timeout(timeout);
    } catch (error) {
      _log.info('Could not read the calibration of $key: $error');
      readFailed = true;
    }
    final calibration = read?.calibration ?? nominalOsmo360();
    _log.fine(
      '$key: ${calibration.source.name} calibration of ${read?.model ?? 'an Osmo 360'}'
      '${read == null ? '' : ', serial ${read.serial}, firmware ${read.firmware}'}',
    );
    if (!readFailed) {
      _keep(key, calibration);
    }
    return calibration;
  }

  Future<DjiOsvCalibration?> _readDji(RawVideoInput input) async {
    final file = await input.open();
    if (file == null) {
      throw StateError('no file to read');
    }
    try {
      return await readDjiOsvCalibration(file.read);
    } finally {
      await file.close();
    }
  }

  /// The calibration of the file named by [key] (unique to it and to its version: a path with its size and date),
  /// [fileSize] bytes that [read] reads; [frameSquare] is the height of its frames when known
  Future<DualFisheyeCalibration> forReader(
    String key, {
    required ByteRangeReader? read,
    required int? fileSize,
    required bool isPhoto,
    int? frameSquare,
  }) => _remembered(
    key,
    () async => read == null || fileSize == null ? null : (size: fileSize, read: read, close: () async {}),
    isPhoto: isPhoto,
    frameSquare: frameSquare,
  );

  Future<DualFisheyeCalibration> _remembered(
    String key,
    Future<RawFileReader?> Function() open, {
    required bool isPhoto,
    int? frameSquare,
  }) async {
    final known = _results[key];
    if (known != null) {
      return known;
    }
    final pending = _pending[key] ??= _resolve(key, open, isPhoto: isPhoto, frameSquare: frameSquare);
    try {
      return await pending;
    } finally {
      unawaited(_pending.remove(key));
    }
  }

  Future<DualFisheyeCalibration> _resolve(
    String key,
    Future<RawFileReader?> Function() open, {
    required bool isPhoto,
    int? frameSquare,
  }) async {
    ResolvedDualFisheyeCalibration resolved;
    try {
      resolved = await _read(open, isPhoto: isPhoto, frameSquare: frameSquare).timeout(timeout);
    } catch (error) {
      _log.info('Could not read the calibration of $key: $error');
      resolved = await resolveDualFisheyeCalibration(
        read: null,
        fileSize: null,
        isPhoto: isPhoto,
        store: store,
        frameSquare: frameSquare,
      );
      resolved = (calibration: resolved.calibration, readFailed: true);
    }
    final calibration = resolved.calibration;
    _log.fine('$key: ${calibration.source.name} calibration of ${calibration.cameraModel ?? 'an unknown camera'}');
    if (!resolved.readFailed) {
      _keep(key, calibration);
    }
    return calibration;
  }

  void _keep(String key, DualFisheyeCalibration calibration) {
    _results
      ..remove(key)
      ..[key] = calibration;
    while (_results.length > maxEntries) {
      _results.remove(_results.keys.first);
    }
  }

  Future<ResolvedDualFisheyeCalibration> _read(
    Future<RawFileReader?> Function() open, {
    required bool isPhoto,
    int? frameSquare,
  }) async {
    final file = await open();
    try {
      return await resolveDualFisheyeCalibration(
        read: file?.read,
        fileSize: file?.size,
        isPhoto: isPhoto,
        store: store,
        frameSquare: frameSquare,
      );
    } finally {
      await file?.close();
    }
  }

  /// Range reads of the file of [asset]: [localFile] when given, else the copy on the device when it can be read, else
  /// the original on the server; null when neither can
  Future<RawFileReader?> openAsset(BaseAsset asset, {File? localFile}) async {
    var file = localFile;
    final localId = asset.localId;
    if (file == null && localId != null) {
      try {
        file = await _storage.getFileForAsset(localId);
      } catch (error) {
        _log.fine('Copy on the device of ${asset.name} not found: $error');
      }
    }
    if (file != null) {
      try {
        final handle = await file.open();
        return (
          size: await handle.length(),
          read: (int offset, int length) async {
            await handle.setPosition(offset);
            return handle.read(length);
          },
          close: handle.close,
        );
      } catch (error) {
        _log.fine('Copy on the device of ${asset.name} unreadable, reading the server copy: $error');
      }
    }

    final remoteId = asset.remoteId;
    final endpoint = _serverEndpoint();
    if (remoteId == null || endpoint == null) {
      return null;
    }
    final opened = await openHttpRangeFile(
      _client(),
      Uri.parse('$endpoint/assets/$remoteId/original'),
      headers: _headers(),
    );
    return opened == null ? null : (size: opened.size, read: opened.read, close: () async {});
  }
}

/// The calibrations of the cameras seen, in the support directory of the app
final dualFisheyeCalibrationStoreProvider = Provider<DualFisheyeCalibrationStore>(
  (_) => DualFisheyeCalibrationStore.appSupport(),
);

/// The calibrations of raw dual fisheye files. Its results last as long as the app.
final dualFisheyeCalibrationServiceProvider = Provider<DualFisheyeCalibrationService>(
  (ref) => DualFisheyeCalibrationService(
    store: ref.watch(dualFisheyeCalibrationStoreProvider),
    storage: ref.watch(storageRepositoryProvider),
    // The app's shared client, with its native SSL setup; read at each file, as it changes when the network settings do
    client: () => NetworkRepository.client,
    serverEndpoint: () => Store.tryGet(StoreKey.serverEndpoint),
    headers: ApiService.getRequestHeaders,
  ),
);

/// The key of the calibration of [asset]: its key among the spatial layouts and its update time tell it from any other
/// file and version
String rawAssetKey(BaseAsset asset) => 'asset:${spatialLayoutKey(asset)}:${asset.updatedAt.millisecondsSinceEpoch}';

/// The calibration of [asset], a raw dual fisheye photo or video (see [DualFisheyeCalibrationService.forAsset])
final dualFisheyeCalibrationProvider = FutureProvider.autoDispose.family<DualFisheyeCalibration, BaseAsset>(
  (ref, asset) => ref.watch(dualFisheyeCalibrationServiceProvider).forAsset(asset),
);
