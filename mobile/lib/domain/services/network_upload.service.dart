// Sends photos and videos of a network share to the Immich server, one file at a time, read in sequence from the
// share and streamed to the server without a copy on the device. The files sent are recorded (see UploadRecordStore):
// one sent before, unchanged since and whose asset the server still has is not sent again.
//
// Two steps for the files of drones (see NetworkUploadOptions): a sphere without GPano tags may go with an XMP sidecar
// that tells the server it is 360° (see gpanoSidecarXmp), and a video with an .SRT of the same name beside it gets the
// place of its flight data once the server has read it, when it found none in the video (see VideoLocationService).
// The files the server refuses (see NetworkEntry.isRefusedByServer) are skipped with their reason.

import 'dart:async';

import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/dji_srt.dart';
import 'package:immich_mobile/domain/services/gpano_sidecar.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/domain/services/video_location.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:logging/logging.dart';

final _log = Logger('NetworkUploadService');

/// What became of a file of an upload from a share
enum NetworkUploadOutcome {
  /// The server made a new asset of it
  sent,

  /// The server already had it, or it was sent before and did not change since
  duplicate,

  failed,

  /// The server does not accept files of its kind (see NetworkEntry.isRefusedByServer): not sent
  refused,
}

/// What an upload from a share does beyond sending the files
class NetworkUploadOptions {
  const NetworkUploadOptions({this.tagSpheres = false, this.placeVideos = true});

  /// Send the spheres without GPano tags (the spheres of DJI drones) with an XMP sidecar that makes the server show
  /// them as 360°, see gpanoSidecarXmp. The photo itself is sent unchanged.
  final bool tagSpheres;

  /// Give the videos with an .SRT beside them the place of their flight data, see VideoLocationService
  final bool placeVideos;
}

/// What an upload from a share did, file by file
class NetworkUploadSummary {
  const NetworkUploadSummary({
    this.sent = 0,
    this.duplicates = 0,
    this.failed = 0,
    this.cancelled = false,
    this.lastError,
    this.refused = const [],
    this.spheresTagged = 0,
    this.spheresAlreadyThere = 0,
    this.placed = 0,
    this.placesPending = 0,
  });

  final int sent;
  final int duplicates;
  final int failed;

  /// The names of the files the server does not accept, not sent
  final List<String> refused;

  /// The spheres sent with their 360° tags (see NetworkUploadOptions.tagSpheres)
  final int spheresTagged;

  /// The spheres the server had already: their tags went with them and were dropped with the copy, so the server
  /// shows them flat still
  final int spheresAlreadyThere;

  /// The videos placed on the map from their flight data
  final int placed;

  /// The videos whose place waits for the server to read them (see VideoLocationService.retryPending)
  final int placesPending;

  /// The user stopped it before every file was sent
  final bool cancelled;

  /// What the server or the share said about the last file that failed
  final String? lastError;
}

/// Follows an upload from a share: [onProgress] gets the part of a file sent (0 to 1), [onFinished] what became of it.
/// Files are given by [networkUploadId].
class NetworkUploadListener {
  const NetworkUploadListener({this.onProgress, this.onFinished});

  final void Function(String id, double progress)? onProgress;
  final void Function(String id, NetworkUploadOutcome outcome)? onFinished;
}

/// Whether the server still has the asset [remoteId], out of its trash; throws when it cannot tell
typedef RemoteAssetCheck = Future<bool> Function(String remoteId);

/// What the file of a photo of [fileSystem] declares (see NetworkMediaService.detect), null when it cannot tell
typedef NetworkMediaInfoReader = Future<NetworkMediaInfo?> Function(NetworkFileSystem fileSystem, NetworkEntry entry);

/// Gives the uploaded video [remoteId] the place [latitude], [longitude] unless it has one (see
/// VideoLocationService.place)
typedef VideoPlacer = Future<VideoPlaceOutcome> Function(String remoteId, double latitude, double longitude);

class NetworkUploadService {
  NetworkUploadService(this._uploads, this._records, this._isOnServer, {this._mediaInfo, this._placeVideo});

  final ForegroundUploadService _uploads;
  final UploadRecordStore _records;
  final RemoteAssetCheck _isOnServer;
  final NetworkMediaInfoReader? _mediaInfo;
  final VideoPlacer? _placeVideo;

  /// Sends [entries], files of [fileSystem], to the server, in their order, until [cancelToken] completes. The files
  /// recorded as sent and unchanged since, whose asset the server confirms it still has, are not read at all, and count
  /// as duplicates. The files the server refuses are not sent. [options] tells what else goes with the files.
  Future<NetworkUploadSummary> upload(
    NetworkFileSystem fileSystem,
    List<NetworkEntry> entries, {
    required Completer<void> cancelToken,
    NetworkUploadListener listener = const NetworkUploadListener(),
    NetworkUploadOptions options = const NetworkUploadOptions(),
  }) async {
    var sent = 0;
    var duplicates = 0;
    var failed = 0;
    String? lastError;
    final refused = <String>[];
    var spheresTagged = 0;
    var spheresAlreadyThere = 0;
    var placed = 0;
    var placesPending = 0;
    // The flight data of the videos by their id, and the folders listed to find it
    final fixes = <String, DjiSrtFix>{};
    final folders = <String, Future<List<NetworkEntry>?>>{};

    final byId = <String, NetworkEntry>{};
    final items = <NetworkUploadItem>[];
    for (final entry in entries) {
      // The server is asked about each file recorded: a cancel meanwhile is not kept waiting for all of them
      if (cancelToken.isCompleted) {
        break;
      }
      final id = networkUploadId(entry);
      if (entry.isDirectory || byId.containsKey(id)) {
        continue;
      }
      byId[id] = entry;
      if (entry.isRefusedByServer) {
        refused.add(entry.name);
        listener.onFinished?.call(id, NetworkUploadOutcome.refused);
        continue;
      }
      if (await _isStillSent(entry)) {
        duplicates++;
        listener.onFinished?.call(id, NetworkUploadOutcome.duplicate);
        continue;
      }
      final sidecarXmp = options.tagSpheres && entry.isImage ? await _sphereSidecar(fileSystem, entry) : null;
      if (options.placeVideos && entry.isVideo && _placeVideo != null) {
        final fix = await _flightFix(fileSystem, entry, folders);
        if (fix != null) {
          fixes[id] = fix;
        }
      }
      items.add(NetworkUploadItem(fileSystem: fileSystem, entry: entry, sidecarXmp: sidecarXmp));
    }
    final withSidecar = {
      for (final item in items)
        if (item.sidecarXmp != null) item.id,
    };

    // The files as they were on their share right before they were sent: what the server got, and what the record keeps
    final sending = <String, NetworkEntry>{};
    final pending = <Future<void>>[];
    await _uploads.uploadNetworkFiles(
      items,
      cancelToken: cancelToken,
      callbacks: SourceUploadCallbacks(
        onSending: (id, entry) => sending[id] = entry,
        onProgress: (id, bytes, total) => listener.onProgress?.call(id, total > 0 ? bytes / total : 0),
        onSuccess: (id, remoteId, {required isDuplicate}) {
          if (isDuplicate) {
            duplicates++;
          } else {
            sent++;
          }
          if (withSidecar.contains(id)) {
            // A duplicate is not uploaded again: the server drops the sidecar with the copy
            if (isDuplicate) {
              spheresAlreadyThere++;
            } else {
              spheresTagged++;
            }
          }
          final fix = fixes[id];
          final placeVideo = _placeVideo;
          if (fix != null && placeVideo != null) {
            // In the background, while the next files go: the server reads each video in a job of its own
            pending.add(
              placeVideo(remoteId, fix.latitude, fix.longitude).then(
                (outcome) {
                  if (outcome == VideoPlaceOutcome.placed) {
                    placed++;
                  } else if (outcome == VideoPlaceOutcome.pending) {
                    placesPending++;
                  }
                },
                onError: (Object error, StackTrace stackTrace) =>
                    _log.warning('Could not place ${byId[id]?.name} from its flight data', error, stackTrace),
              ),
            );
          }
          final entry = sending[id] ?? byId[id];
          if (entry != null) {
            // Recorded before the listener hears of it, so that the badge of the file is there when it looks
            pending.add(
              _record(entry, remoteId).whenComplete(() {
                listener.onFinished?.call(id, isDuplicate ? NetworkUploadOutcome.duplicate : NetworkUploadOutcome.sent);
              }),
            );
          }
        },
        onError: (id, errorMessage) {
          failed++;
          lastError = errorMessage;
          listener.onFinished?.call(id, NetworkUploadOutcome.failed);
        },
      ),
    );
    await Future.wait(pending);

    return NetworkUploadSummary(
      sent: sent,
      duplicates: duplicates,
      failed: failed,
      cancelled: cancelToken.isCompleted,
      lastError: lastError,
      refused: refused,
      spheresTagged: spheresTagged,
      spheresAlreadyThere: spheresAlreadyThere,
      placed: placed,
      placesPending: placesPending,
    );
  }

  /// The GPano sidecar of [entry] when it is a sphere without GPano tags whose frame size its EXIF gives (see
  /// NetworkMediaInfo.isUntaggedSphere), null otherwise and when it cannot be read
  Future<String?> _sphereSidecar(NetworkFileSystem fileSystem, NetworkEntry entry) async {
    final mediaInfo = _mediaInfo;
    if (mediaInfo == null) {
      return null;
    }
    try {
      final info = await mediaInfo(fileSystem, entry);
      final width = info?.frameWidth;
      final height = info?.frameHeight;
      if (info == null || !info.isUntaggedSphere || width == null || height == null) {
        return null;
      }
      return gpanoSidecarXmp(width: width, height: height);
    } catch (error, stackTrace) {
      _log.warning('Could not tell whether ${entry.name} is a sphere', error, stackTrace);
      return null;
    }
  }

  /// The first fix of the .SRT beside the video [entry] (same name, case aside, see djiSrtNameFor), null when there
  /// is none or it holds no position. Each folder is listed once per upload ([folders]).
  Future<DjiSrtFix?> _flightFix(
    NetworkFileSystem fileSystem,
    NetworkEntry entry,
    Map<String, Future<List<NetworkEntry>?>> folders,
  ) async {
    final slash = entry.path.lastIndexOf('/');
    final folder = slash <= 0 ? '/' : entry.path.substring(0, slash);
    try {
      final listing = await (folders[folder] ??= fileSystem
          .list(folder)
          .then<List<NetworkEntry>?>(
            (entries) => entries,
            onError: (Object error) {
              _log.info('Could not list $folder for the flight data of its videos: $error');
              return null;
            },
          ));
      if (listing == null) {
        return null;
      }
      final srtName = djiSrtNameFor(entry.name, listing.where((file) => !file.isDirectory).map((file) => file.name));
      if (srtName == null) {
        return null;
      }
      final srt = listing.firstWhere((file) => !file.isDirectory && file.name == srtName);
      final size = srt.size ?? (await fileSystem.stat(srt.path)).size;
      if (size == null || size <= 0) {
        return null;
      }
      final fix = await readDjiSrtFix((offset, length) => fileSystem.readRange(srt.path, offset, length), size);
      if (fix == null) {
        _log.info('${srt.name} holds no position');
      }
      return fix;
    } catch (error, stackTrace) {
      _log.warning('Could not read the flight data of ${entry.name}', error, stackTrace);
      return null;
    }
  }

  /// Whether [entry] was sent before, did not change since, and its asset is still on the server out of the trash. A
  /// record of an asset the server does not have anymore is forgotten; one it cannot tell about is kept. Either way the
  /// file is sent again, and the server answers "duplicate" if it has it after all.
  Future<bool> _isStillSent(NetworkEntry entry) async {
    final record = await _records.find(entry);
    if (record == null) {
      return false;
    }
    try {
      if (await _isOnServer(record.remoteId)) {
        return true;
      }
      await _records.remove(entry);
    } catch (error, stackTrace) {
      _log.warning('Could not ask the server about ${record.remoteId}, sent from ${entry.path}', error, stackTrace);
    }
    return false;
  }

  Future<void> _record(NetworkEntry entry, String remoteId) async {
    try {
      await _records.add(entry, remoteId);
    } catch (error, stackTrace) {
      _log.warning('Could not record that ${entry.path} was sent', error, stackTrace);
    }
  }
}
