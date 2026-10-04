// Sends photos and videos of a network share to the Immich server, one file at a time, read in sequence from the
// share and streamed to the server without a copy on the device. The files sent are recorded (see UploadRecordStore):
// one sent before, unchanged since and whose asset the server still has is not sent again.

import 'dart:async';

import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
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
}

/// What an upload from a share did, file by file
class NetworkUploadSummary {
  const NetworkUploadSummary({
    this.sent = 0,
    this.duplicates = 0,
    this.failed = 0,
    this.cancelled = false,
    this.lastError,
  });

  final int sent;
  final int duplicates;
  final int failed;

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

class NetworkUploadService {
  NetworkUploadService(this._uploads, this._records, this._isOnServer);

  final ForegroundUploadService _uploads;
  final UploadRecordStore _records;
  final RemoteAssetCheck _isOnServer;

  /// Sends [entries], files of [fileSystem], to the server, in their order, until [cancelToken] completes. The files
  /// recorded as sent and unchanged since, whose asset the server confirms it still has, are not read at all, and count
  /// as duplicates.
  Future<NetworkUploadSummary> upload(
    NetworkFileSystem fileSystem,
    List<NetworkEntry> entries, {
    required Completer<void> cancelToken,
    NetworkUploadListener listener = const NetworkUploadListener(),
  }) async {
    var sent = 0;
    var duplicates = 0;
    var failed = 0;
    String? lastError;

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
      if (await _isStillSent(entry)) {
        duplicates++;
        listener.onFinished?.call(id, NetworkUploadOutcome.duplicate);
        continue;
      }
      items.add(NetworkUploadItem(fileSystem: fileSystem, entry: entry));
    }

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
    );
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
