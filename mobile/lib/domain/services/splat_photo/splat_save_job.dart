// Saving a splat scene to Immich as a splat photo (plan of 3 November 2026, section 6.3): the job behind "Save to
// Immich" of the splat viewer's page, of the Quest's splat page and of "Upload to Immich" of the shares and folders.
//
// 1. The SPZ: a local SPZ is used where it is; a PLY is converted to SPZ version 2 with the maker's splat_cloud.dart
//    and spz_v2_writer.dart, in an isolate, behind a memory gate ("This PLY is too large to convert on this device").
// 2. Its head and SHA-256 (and the PLY's SHA-256, SplatSourceSha256).
// 3. Already there? The device's record (splat_saves.json: SplatSha256 to the server, the asset id, the carrier's SHA-1
//    and the date) checked with the asset itself; then the splat photos of the server by name (originalFileName
//    "_splat"), the 128 KiB head of at most 10 of them compared on SplatSha256 and SplatSourceSha256. "Save another
//    copy" skips both.
// 4. The poster: the page's capture, or drawn (splat_poster_draw.dart), or the card; then the carrier written next to
//    the cache (.part, renamed at the end), which gives its length and SHA-1.
// 5. bulk-upload-check with the SHA-1: a duplicate stops here.
// 6. The upload, with the x-immich-checksum header (a duplicate answers before the body is read) and, on servers 2.5.0
//    and later, the immuch360 metadata item; a 400 is tried once more without it.
// 7. The album "Splat scenes" when asked: created at the first save that asks for it, its id kept per server.
// 8. The record written, the carrier deleted.
//
// The server is reached through [SplatSaveServer], so that the tests give a fake one and count what it was asked.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/splat/splat_cloud.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/models/splat/spz_v2_writer.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_exif.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_writer.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:logging/logging.dart';

final _log = Logger('SplatSaveJob');

/// The key of the metadata item of a splat photo, on servers 2.5.0 and later
const splatSaveMetadataKey = 'immuch360';

/// The first server version that takes the metadata field of an upload
const splatSaveMetadataSince = (2, 5, 0);

/// The splat photos of the server whose head is read, at most, when looking for one of the same scene
const splatSaveHeadReads = 10;

/// What a job is doing, or how it ended
enum SplatSaveState {
  idle,
  converting,
  checking,
  drawing,
  writing,
  uploading,
  done,
  duplicate,
  alreadyThere,
  inTrash,
  failed,
  cancelled;

  bool get isFinal => index >= done.index;
}

/// Why a job failed
enum SplatSaveProblem {
  /// The PLY is larger than this device converts
  plyTooLarge,

  /// The scene is not a splat this reads, or is cut
  unreadable,

  /// Above 1 GiB, the writer's limit
  tooLarge,

  /// A 413, or the connection closed while the file was sent: a proxy in front of the server limits uploads
  refusedSize,

  /// The user's quota on the server is full
  quota,

  /// The server could not be reached
  unreachable,

  /// The server said no ([SplatSaveStatus.detail] holds its message)
  server,

  /// Anything else ([SplatSaveStatus.detail])
  other,
}

/// Where a job stands: its [state], the [share] done of that step, the asset on the server once known
final class SplatSaveStatus {
  const SplatSaveStatus(
    this.state, {
    this.share = 0,
    this.assetId,
    this.savedAt,
    this.problem,
    this.detail,
    this.carrierBytes,
    this.sceneBytes,
  });

  final SplatSaveState state;

  /// The size of the SPZ saved: that of the PLY converted, for "Saved as SPZ: {size} instead of {plySize}"
  final int? sceneBytes;
  final double share;
  final String? assetId;

  /// When the scene was saved before ([SplatSaveState.alreadyThere]), or the date it shows at in the timeline
  final DateTime? savedAt;
  final SplatSaveProblem? problem;
  final String? detail;

  /// The size of the splat photo sent
  final int? carrierBytes;

  @override
  String toString() =>
      'SplatSaveStatus(${state.name}${assetId == null ? '' : ', $assetId'}${problem == null ? '' : ', ${problem!.name}'}'
      '${detail == null ? '' : ', $detail'})';
}

/// What a save is asked to do
final class SplatSaveRequest {
  const SplatSaveRequest({
    required this.scene,
    required this.sceneName,
    required this.sceneDate,
    required this.caption,
    required this.cardLine,
    this.poster,
    this.posterKind = SplatPosterKind.view,
    this.up,
    this.album = true,
    this.albumName = 'Splat scenes',
    this.mark = true,
    this.force = false,
    this.software = 'Immuch360',
    this.creatorTool = 'Immuch360',
  });

  /// The SPZ or the PLY on this device (a share's file is copied into the cache first)
  final File scene;

  /// Its name: "room.spz", "salon.ply"
  final String sceneName;

  /// The scene's date: the file's modified time, the date it shows at in the timeline
  final DateTime sceneDate;

  /// The page's capture of the view on screen (or the poster a sheet drew), a JPEG of the poster's shape; null to
  /// draw one
  final Uint8List? poster;

  /// What made [poster]: the view on screen, a drawing, the card
  final SplatPosterKind posterKind;

  /// The orientation the user chose for the scene: 'yUp', 'zUp' or 'yDown'
  final String? up;

  /// Add the photo to the album [albumName]
  final bool album;
  final String albumName;

  /// The mark in a drawn poster (the page draws its own)
  final bool mark;

  /// "Save another copy": no look for one already there
  final bool force;

  /// dc:description of the packet for a scene of n gaussians, in the app's language
  final String Function(int gaussians) caption;

  /// The line under the name on a card, for a scene of n gaussians
  final String Function(int gaussians) cardLine;

  final String software;
  final String creatorTool;
}

/// An asset of the server, as the job needs it
final class SplatServerAsset {
  const SplatServerAsset({required this.id, required this.originalFileName, this.isTrashed = false, this.createdAt});

  final String id;
  final String originalFileName;
  final bool isTrashed;

  /// When it reached the server
  final DateTime? createdAt;
}

/// The answer of bulk-upload-check for one file
final class SplatBulkAnswer {
  const SplatBulkAnswer({required this.accept, this.assetId, this.isTrashed = false});

  final bool accept;
  final String? assetId;
  final bool isTrashed;
}

/// The server the job saves to (see the top of this file)
abstract interface class SplatSaveServer {
  /// The server's URL, the key of the records
  String get url;

  /// Its version, (major, minor, patch); null when it cannot be read
  Future<(int, int, int)?> version();

  /// The asset [id]; null when the server has it no more
  Future<SplatServerAsset?> asset(String id);

  /// The assets whose original file name holds [name], the newest first, trashed ones too
  Future<List<SplatServerAsset>> searchByName(String name, {int size = 50});

  /// The first [length] bytes of the original of [assetId]; null when they could not be read in time, or once
  /// [cancelled] says so. Whatever the server sends past them is not read.
  Future<Uint8List?> head(String assetId, int length, {bool Function()? cancelled});

  Future<SplatBulkAnswer> bulkCheck(String id, String sha1);

  Future<UploadResult> upload(UploadSource source, {Completer<void>? cancel, void Function(int, int)? onProgress});

  Future<bool> albumExists(String id);

  /// The id of a new album named [name]
  Future<String> createAlbum(String name);

  Future<void> addToAlbum(String albumId, String assetId);
}

/// One scene saved from this device
final class SplatSaveRecord {
  const SplatSaveRecord({
    required this.server,
    required this.splatSha256,
    required this.assetId,
    required this.carrierSha1,
    required this.savedAt,
  });

  final String server;
  final String splatSha256;
  final String assetId;
  final String carrierSha1;
  final DateTime savedAt;

  Map<String, Object?> toJson() => {
    'server': server,
    'splatSha256': splatSha256,
    'assetId': assetId,
    'carrierSha1': carrierSha1,
    'savedAt': savedAt.toUtc().toIso8601String(),
  };

  static SplatSaveRecord? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final server = json['server'];
    final sum = json['splatSha256'];
    final assetId = json['assetId'];
    final savedAt = DateTime.tryParse('${json['savedAt']}');
    if (server is! String || sum is! String || assetId is! String || savedAt == null) {
      return null;
    }
    return SplatSaveRecord(
      server: server,
      splatSha256: sum,
      assetId: assetId,
      carrierSha1: '${json['carrierSha1'] ?? ''}',
      savedAt: savedAt,
    );
  }
}

/// The scenes saved from this device and the album of each server, in splat_saves.json
class SplatSaveRecords {
  SplatSaveRecords(this._file);

  final Future<File> Function() _file;

  /// The most records kept: the oldest go first
  static const most = 2000;

  Future<Map<String, Object?>> _read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return {};
      }
      final json = jsonDecode(await file.readAsString());
      return json is Map<String, Object?> ? json : {};
    } catch (error) {
      _log.fine('splat_saves.json could not be read: $error');
      return {};
    }
  }

  Future<void> _write(Map<String, Object?> json) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final part = File('${file.path}.part');
    await part.writeAsString(jsonEncode(json), flush: true);
    await part.rename(file.path);
  }

  List<SplatSaveRecord> _saves(Map<String, Object?> json) => [
    for (final item in (json['saves'] as List?) ?? const []) ?SplatSaveRecord.fromJson(item),
  ];

  /// The last save of the scene of [splatSha256] to [server]
  Future<SplatSaveRecord?> find(String server, String splatSha256) async =>
      _saves(await _read()).where((r) => r.server == server && r.splatSha256 == splatSha256).lastOrNull;

  Future<void> add(SplatSaveRecord record) async {
    final json = await _read();
    final saves = _saves(json)
      ..removeWhere((r) => r.server == record.server && r.splatSha256 == record.splatSha256)
      ..add(record);
    json['saves'] = [for (final r in saves.skip(math.max(0, saves.length - most))) r.toJson()];
    await _write(json);
  }

  /// The album of the splat scenes on [server]
  Future<String?> album(String server) async {
    final albums = (await _read())['albums'];
    return albums is Map ? albums[server] as String? : null;
  }

  /// The album switch of the save panel and sheet, remembered: on until the user turns it off
  Future<bool> albumOn() async => (await _read())['albumOn'] != false;

  Future<void> setAlbumOn(bool on) async {
    final json = await _read();
    json['albumOn'] = on;
    await _write(json);
  }

  Future<void> setAlbum(String server, String id) async {
    final json = await _read();
    final albums = Map<String, Object?>.from((json['albums'] as Map?) ?? const {});
    albums[server] = id;
    json['albums'] = albums;
    await _write(json);
  }
}

/// The job was cancelled
class SplatSaveCancelled implements Exception {
  const SplatSaveCancelled();
}

/// A failure the job tells as [problem]
class SplatSaveException implements Exception {
  const SplatSaveException(this.problem, [this.detail]);

  final SplatSaveProblem problem;
  final String? detail;

  @override
  String toString() => 'SplatSaveException(${problem.name}${detail == null ? '' : ': $detail'})';
}

/// Draws a poster of the SPZ [spz] (head [head]) turned [up], with the mark when [mark]; a JPEG of the poster's shape
typedef SplatPosterDrawer = Future<Uint8List> Function(File spz, SplatHead head, String? up, bool mark);

/// The card of a scene named [name] with the line [line], with the mark when [mark]
typedef SplatCardDrawer = Future<Uint8List> Function(String name, String line, bool mark);

/// The SHA-256 of [file], read in an isolate
Future<String> splatFileSha256(File file) => Isolate.run(() async {
  final output = _DigestSink();
  final input = sha256.startChunkedConversion(output);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return output.value.toString();
});

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// The PLY [ply] as SPZ version 2 in [out], in an isolate (the maker's reader and writer)
Future<void> convertSplatPlyToSpz(File ply, File out) => Isolate.run(() async {
  final cloud = readSplatPly(await ply.readAsBytes());
  final part = File('${out.path}.part');
  await part.writeAsBytes(writeSpzV2(cloud), flush: true);
  await part.rename(out.path);
});

/// Whether a server of [version] takes the metadata field
bool splatSaveTakesMetadata((int, int, int)? version) {
  if (version == null) {
    return false;
  }
  final (major, minor, patch) = version;
  final (m, n, p) = splatSaveMetadataSince;
  return major != m ? major > m : (minor != n ? minor > n : patch >= p);
}

/// The metadata field of a splat photo of the scene [xmp] tells
String splatSaveMetadataJson(SplatPhotoXmp xmp) => jsonEncode([
  {
    'key': splatSaveMetadataKey,
    'value': {
      'kind': splatPhotoKind,
      'format': xmp.splatFormat ?? splatPhotoFormatSpz,
      'version': xmp.splatVersion,
      'length': xmp.splatLength,
      'sha256': xmp.splatSha256,
      'gaussians': xmp.splatGaussians,
    },
  },
]);

/// See the top of this file
class SplatSaveJob {
  SplatSaveJob({
    required this.request,
    required this._server,
    required this._records,
    required this._workFolder,
    required this._drawPoster,
    required this._drawCard,
    this.maxPlyBytes,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SplatSaveRequest request;
  final SplatSaveServer _server;
  final SplatSaveRecords _records;
  final Future<Directory> Function() _workFolder;
  final SplatPosterDrawer _drawPoster;
  final SplatCardDrawer _drawCard;
  final DateTime Function() _now;

  /// The largest PLY this device converts; null for no limit
  final int? maxPlyBytes;

  final _cancel = Completer<void>();
  final _status = StreamController<SplatSaveStatus>.broadcast();
  SplatSaveStatus _current = const SplatSaveStatus(SplatSaveState.idle);

  SplatSaveStatus get status => _current;
  Stream<SplatSaveStatus> get changes => _status.stream;
  bool get isCancelled => _cancel.isCompleted;

  void cancel() {
    if (!_cancel.isCompleted) {
      _cancel.complete();
    }
  }

  void _tell(SplatSaveStatus status) {
    _current = status;
    if (!_status.isClosed) {
      _status.add(status);
    }
  }

  void _check() {
    if (isCancelled) {
      throw const SplatSaveCancelled();
    }
  }

  /// Runs the job to its end: the last status, never a throw
  Future<SplatSaveStatus> run() async {
    final made = <File>[];
    try {
      final result = await _run(made);
      _tell(result);
      return result;
    } on SplatSaveCancelled {
      _tell(const SplatSaveStatus(SplatSaveState.cancelled));
      return _current;
    } on SplatSaveException catch (error) {
      _log.warning('${request.sceneName} not saved: $error');
      _tell(SplatSaveStatus(SplatSaveState.failed, problem: error.problem, detail: error.detail));
      return _current;
    } catch (error, stack) {
      _log.warning('${request.sceneName} not saved', error, stack);
      _tell(SplatSaveStatus(SplatSaveState.failed, problem: SplatSaveProblem.other, detail: '$error'));
      return _current;
    } finally {
      for (final file in made) {
        try {
          if (file.existsSync()) {
            file.deleteSync();
          }
        } catch (_) {
          // Kept by another program: the cache's prune takes it later
        }
      }
      await _status.close();
    }
  }

  Future<SplatSaveStatus> _run(List<File> made) async {
    final folder = await _workFolder();
    await folder.create(recursive: true);
    final stamp = _now().microsecondsSinceEpoch;

    // 1. The SPZ
    var spz = request.scene;
    String? sourceSha256;
    var spzName = request.sceneName;
    final isPly = request.sceneName.toLowerCase().endsWith('.ply');
    if (isPly) {
      final plyBytes = await request.scene.length();
      final limit = maxPlyBytes;
      if (limit != null && plyBytes > limit) {
        throw SplatSaveException(SplatSaveProblem.plyTooLarge, '$plyBytes bytes');
      }
      _tell(const SplatSaveStatus(SplatSaveState.converting));
      sourceSha256 = await splatFileSha256(request.scene);
      _check();
      spz = File('${folder.path}/splat-save-$stamp.spz');
      made.add(spz);
      try {
        await convertSplatPlyToSpz(request.scene, spz);
      } on SplatFormatException catch (error) {
        throw SplatSaveException(SplatSaveProblem.unreadable, '$error');
      }
      spzName = '${fileStem(request.sceneName)}$splatPhotoNameSuffix.spz';
      _check();
    }

    // 2. Its head and its sum
    _tell(const SplatSaveStatus(SplatSaveState.checking));
    final length = await spz.length();
    if (length > splatPhotoMaxLength) {
      throw SplatSaveException(SplatSaveProblem.tooLarge, '$length bytes');
    }
    final raf = await spz.open();
    final SplatPhotoScene inspected;
    try {
      inspected = await inspectSplatPhotoScene(
        (offset, count) async {
          await raf.setPosition(offset);
          return raf.read(count);
        },
        length,
        cancelled: () => isCancelled,
      );
    } on SplatPhotoWriteException catch (error) {
      throw SplatSaveException(SplatSaveProblem.unreadable, '$error');
    } finally {
      await raf.close();
    }
    _check();

    // 3. Already there?
    if (!request.force) {
      final found = await _alreadyThere(inspected.sha256, sourceSha256);
      if (found != null) {
        return found;
      }
    }
    _check();

    // 4. The poster, then the splat photo
    _tell(const SplatSaveStatus(SplatSaveState.drawing));
    final head = inspected.head;
    final (poster, posterKind) = await _posterOf(spz, head);
    _check();
    _tell(const SplatSaveStatus(SplatSaveState.writing));
    final carrier = File('${folder.path}/splat-save-$stamp.jpg');
    made.add(carrier);
    final meta = SplatPhotoMeta(
      name: spzName,
      date: SplatPhotoDate.of(request.sceneDate),
      software: request.software,
      creatorTool: request.creatorTool,
      description: request.caption(head.gaussians),
      sourceSha256: sourceSha256,
      up: splatPhotoUps.contains(request.up) ? request.up : null,
      poster: posterKind,
    );
    final SplatPhotoWritten written;
    try {
      written = await writeSplatPhotoFileInIsolate(
        spz: spz,
        posterJpeg: poster,
        meta: meta,
        out: carrier,
        onProgress: (done) => _tell(SplatSaveStatus(SplatSaveState.writing, share: done)),
        cancel: _cancel.future,
      );
    } on SplatPhotoWriteException catch (error) {
      if (isCancelled) {
        throw const SplatSaveCancelled();
      }
      throw SplatSaveException(SplatSaveProblem.unreadable, '$error');
    }
    _check();

    // 5. bulk-upload-check: the server may hold this very file
    final deviceAssetId = 'splat-${written.sha1}';
    _tell(SplatSaveStatus(SplatSaveState.checking, carrierBytes: written.length));
    try {
      final answer = await _server.bulkCheck(deviceAssetId, written.sha1);
      if (!answer.accept && answer.assetId != null) {
        return SplatSaveStatus(
          answer.isTrashed ? SplatSaveState.inTrash : SplatSaveState.duplicate,
          assetId: answer.assetId,
          savedAt: await _savedAtOf(answer.assetId!),
          carrierBytes: written.length,
        );
      }
    } on SocketException catch (error) {
      throw SplatSaveException(SplatSaveProblem.unreachable, '$error');
    } catch (error) {
      // An older server, or a check that failed: the checksum header still stops a duplicate
      _log.fine('bulk-upload-check: $error');
    }
    _check();

    // 6. The upload
    final takesMetadata = splatSaveTakesMetadata(await _server.version());
    UploadSource source({required bool withMetadata}) => UploadSource(
      id: deviceAssetId,
      filename: splatPhotoNameFor(spzName),
      length: written.length,
      openRead: carrier.openRead,
      createdAt: request.sceneDate,
      modifiedAt: request.sceneDate,
      deviceAssetId: deviceAssetId,
      headers: {'x-immich-checksum': written.sha1},
      metadataJson: withMetadata ? splatSaveMetadataJson(written.xmp) : null,
    );
    void progress(int bytes, int total) => _tell(
      SplatSaveStatus(SplatSaveState.uploading, share: total > 0 ? bytes / total : 0, carrierBytes: written.length),
    );
    _tell(SplatSaveStatus(SplatSaveState.uploading, carrierBytes: written.length));
    var result = await _server.upload(
      source(withMetadata: takesMetadata),
      cancel: _cancel,
      onProgress: progress,
    );
    if (!result.isSuccess && !result.isCancelled && takesMetadata && result.statusCode == 400) {
      _log.info('The server refused the metadata of ${carrier.path} (${result.errorMessage}): sent again without it');
      result = await _server.upload(source(withMetadata: false), cancel: _cancel, onProgress: progress);
    }
    if (result.isCancelled || isCancelled) {
      throw const SplatSaveCancelled();
    }
    if (!result.isSuccess || result.remoteAssetId == null) {
      throw _uploadFailure(result, written.length);
    }
    final assetId = result.remoteAssetId!;
    if (result.isDuplicate) {
      return SplatSaveStatus(
        SplatSaveState.duplicate,
        assetId: assetId,
        savedAt: await _savedAtOf(assetId),
        carrierBytes: written.length,
      );
    }

    // 7. The album
    if (request.album) {
      await _addToAlbum(assetId);
    }

    // 8. The record
    try {
      await _records.add(
        SplatSaveRecord(
          server: _server.url,
          splatSha256: inspected.sha256,
          assetId: assetId,
          carrierSha1: written.sha1,
          savedAt: _now(),
        ),
      );
    } catch (error) {
      _log.warning('The save of ${request.sceneName} could not be recorded: $error');
    }
    return SplatSaveStatus(
      SplatSaveState.done,
      share: 1,
      assetId: assetId,
      savedAt: request.sceneDate,
      carrierBytes: written.length,
      sceneBytes: length,
    );
  }

  /// The date of the asset the server already had, for "saved on {date}"; null when it cannot be read
  Future<DateTime?> _savedAtOf(String assetId) async {
    try {
      return (await _server.asset(assetId))?.createdAt;
    } catch (_) {
      return null;
    }
  }

  SplatSaveException _uploadFailure(UploadResult result, int length) {
    final message = result.errorMessage ?? 'HTTP ${result.statusCode}';
    if (result.statusCode == 413 ||
        (result.statusCode == null &&
            RegExp('connection (closed|reset)|broken pipe', caseSensitive: false).hasMatch(message))) {
      return SplatSaveException(SplatSaveProblem.refusedSize, message);
    }
    if (message == 'Quota has been exceeded!') {
      return SplatSaveException(SplatSaveProblem.quota, message);
    }
    if (result.statusCode == null &&
        RegExp('SocketException|Failed host lookup|Connection refused').hasMatch(message)) {
      return SplatSaveException(SplatSaveProblem.unreachable, message);
    }
    return SplatSaveException(SplatSaveProblem.server, message);
  }

  /// The save of the scene already on the server, or null
  Future<SplatSaveStatus?> _alreadyThere(String splatSha256, String? sourceSha256) async {
    // The record of this device, checked against the server
    try {
      final record = await _records.find(_server.url, splatSha256);
      if (record != null) {
        final asset = await _server.asset(record.assetId);
        if (asset != null) {
          return SplatSaveStatus(
            asset.isTrashed ? SplatSaveState.inTrash : SplatSaveState.alreadyThere,
            assetId: asset.id,
            savedAt: record.savedAt,
          );
        }
      }
    } on SocketException catch (error) {
      throw SplatSaveException(SplatSaveProblem.unreachable, '$error');
    } catch (error) {
      _log.fine('The record of the saves: $error');
    }
    _check();
    // The splat photos of the server, the same name first
    final List<SplatServerAsset> hits;
    try {
      hits = await _server.searchByName(splatPhotoNameSuffix);
    } on SocketException catch (error) {
      throw SplatSaveException(SplatSaveProblem.unreachable, '$error');
    } catch (error) {
      _log.fine('The search of the splat photos: $error');
      return null;
    }
    final name = splatPhotoNameFor(request.sceneName).toLowerCase();
    final ordered = [
      ...hits.where((asset) => asset.originalFileName.toLowerCase() == name),
      ...hits.where(
        (asset) => asset.originalFileName.toLowerCase() != name && isSplatPhotoCandidate(asset.originalFileName),
      ),
    ];
    for (final asset in ordered.take(splatSaveHeadReads)) {
      _check();
      final head = await _server.head(asset.id, splatPhotoHeadBytes, cancelled: () => isCancelled);
      final xmp = head == null ? null : SplatPhotoXmp.findIn(head);
      if (xmp == null) {
        continue;
      }
      final same = xmp.splatSha256 == splatSha256 || (sourceSha256 != null && xmp.splatSourceSha256 == sourceSha256);
      if (same) {
        return SplatSaveStatus(
          asset.isTrashed ? SplatSaveState.inTrash : SplatSaveState.alreadyThere,
          assetId: asset.id,
          savedAt: asset.createdAt,
        );
      }
    }
    return null;
  }

  /// The page's capture, or a poster drawn from the scene, or the card
  Future<(Uint8List, SplatPosterKind)> _posterOf(File spz, SplatHead head) async {
    final given = request.poster;
    if (given != null) {
      return (given, request.posterKind);
    }
    try {
      return (await _drawPoster(spz, head, request.up, request.mark), SplatPosterKind.render);
    } catch (error) {
      _log.info('The poster of ${request.sceneName} is the card: $error');
    }
    return (await _drawCard(request.sceneName, request.cardLine(head.gaussians), request.mark), SplatPosterKind.card);
  }

  Future<void> _addToAlbum(String assetId) async {
    try {
      var albumId = await _records.album(_server.url);
      if (albumId == null || !await _server.albumExists(albumId)) {
        albumId = await _server.createAlbum(request.albumName);
        await _records.setAlbum(_server.url, albumId);
      }
      await _server.addToAlbum(albumId, assetId);
    } catch (error) {
      // The photo is saved: the album is a convenience
      _log.warning('The splat photo $assetId could not be added to the album: $error');
    }
  }
}
