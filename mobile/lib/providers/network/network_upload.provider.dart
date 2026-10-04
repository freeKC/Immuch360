// The uploads of photos and videos of the network shares to the Immich server: the one under way with the progress of
// its files, and the record of the files sent before.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_upload.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The record of the files of the shares sent to the server by the user signed in, one file per server and user in
/// the support folder of the app (not the cache, which the system may empty); none without a user. Made again when
/// another user signs in, so that a logout has nothing to clear. Tests replace it.
final uploadRecordStoreProvider = Provider<UploadRecordStore>((ref) {
  final userId = ref.watch(currentUserProvider.select((user) => user?.id));
  // The address entered at login: the endpoint itself changes with the automatic switch between the local and the
  // external address of the same server
  final server = Store.tryGet(StoreKey.serverUrl) ?? Store.tryGet(StoreKey.serverEndpoint);
  if (userId == null || server == null) {
    return UploadRecordStore(() async => null);
  }
  return UploadRecordStore(
    () async =>
        File(p.join((await getApplicationSupportDirectory()).path, UploadRecordStore.fileNameFor(server, userId))),
  );
});

final networkUploadServiceProvider = Provider<NetworkUploadService>(
  (ref) => NetworkUploadService(
    ref.watch(foregroundUploadServiceProvider),
    ref.watch(uploadRecordStoreProvider),
    // Read once a file recorded before is selected again: the api is not needed before
    (remoteId) => ref.read(assetApiRepositoryProvider).isInLibrary(remoteId),
  ),
);

/// The files of the shares sent to the server, by [UploadRecordStore.keyOf]: empty until the record is read
class NetworkUploadRecordsNotifier extends Notifier<Map<String, UploadRecord>> {
  @override
  Map<String, UploadRecord> build() {
    final store = ref.watch(uploadRecordStoreProvider);
    var isCurrent = true;
    ref.onDispose(() => isCurrent = false);
    unawaited(
      store.load().then((records) {
        if (isCurrent) {
          state = Map.unmodifiable(records);
        }
      }),
    );
    return const {};
  }

  /// Takes the records again from the store, once a file was recorded
  Future<void> refresh() async {
    final records = await ref.read(uploadRecordStoreProvider).load();
    state = Map.unmodifiable(records);
  }
}

final networkUploadRecordsProvider = NotifierProvider<NetworkUploadRecordsNotifier, Map<String, UploadRecord>>(
  NetworkUploadRecordsNotifier.new,
);

/// The upload from a share under way, if any, and its files
class NetworkUploadState {
  const NetworkUploadState({this.isRunning = false, this.total = 0, this.finished = 0, this.progress = const {}});

  final bool isRunning;

  /// The files of the upload
  final int total;

  /// The files done with, sent or not
  final int finished;

  /// The files still to send, and those that failed, by [networkUploadId]: the part of the file sent, from 0 to 1, or
  /// [failed] for a file that could not be sent. Kept for the failures once the upload ends, until the next one.
  final Map<String, double> progress;

  /// The progress of a file that could not be sent
  static const failed = -1.0;

  /// The position of the file being sent among [total], from 1
  int get current => min(finished + 1, total);

  /// The part of the whole upload done, from 0 to 1
  double get fraction {
    if (total == 0) {
      return 0;
    }
    final sending = progress.values.where((value) => value > 0 && value < 1).fold(0.0, (sum, value) => sum + value);
    return min(1.0, (finished + sending) / total);
  }
}

/// Sends files of a share to the server, one upload at a time (see [NetworkUploadService]); the browser and the
/// viewers show its progress
class NetworkUploadNotifier extends Notifier<NetworkUploadState> {
  Completer<void>? _cancelToken;

  @override
  NetworkUploadState build() {
    // A session without a server has nowhere to send the files anymore
    ref.listen<bool>(hasServerProvider, (_, hasServer) {
      if (!hasServer) {
        cancel();
      }
    });
    return const NetworkUploadState();
  }

  /// Sends the files among [entries] of the share [sourceId]; null when an upload is already under way. Throws when
  /// the share cannot be reached. Once [stop] was called, the upload it stopped no longer changes the state.
  Future<NetworkUploadSummary?> upload(String sourceId, List<NetworkEntry> entries) async {
    if (state.isRunning) {
      return null;
    }
    final files = entries.where((entry) => !entry.isDirectory).toList();
    if (files.isEmpty) {
      return const NetworkUploadSummary();
    }

    // Read before the first await
    final connections = ref.read(networkConnectionsProvider);
    final service = ref.read(networkUploadServiceProvider);
    final records = ref.read(networkUploadRecordsProvider.notifier);

    final cancelToken = Completer<void>();
    _cancelToken = cancelToken;
    bool isCurrent() => identical(_cancelToken, cancelToken);
    state = NetworkUploadState(
      isRunning: true,
      total: files.length,
      progress: {for (final file in files) networkUploadId(file): 0.0},
    );
    try {
      final fileSystem = await connections.fileSystem(sourceId);
      return await service.upload(
        fileSystem,
        files,
        cancelToken: cancelToken,
        listener: NetworkUploadListener(
          onProgress: (id, progress) {
            if (isCurrent() && state.progress.containsKey(id)) {
              state = _with(progress: {...state.progress, id: progress});
            }
          },
          onFinished: (id, outcome) {
            if (!isCurrent()) {
              return;
            }
            final progress = {...state.progress};
            if (outcome == NetworkUploadOutcome.failed) {
              progress[id] = NetworkUploadState.failed;
            } else {
              progress.remove(id);
              unawaited(records.refresh());
            }
            state = _with(finished: state.finished + 1, progress: progress);
          },
        ),
      );
    } finally {
      // A record the server did not confirm may have been forgotten, whatever became of its file
      unawaited(records.refresh());
      if (isCurrent()) {
        _cancelToken = null;
        // The files not sent because of a cancel go back to normal; the failures stay marked
        state = NetworkUploadState(
          progress: {
            for (final MapEntry(:key, :value) in state.progress.entries)
              if (value == NetworkUploadState.failed) key: value,
          },
        );
      }
    }
  }

  /// Stops the upload under way: the file being sent is abandoned, the next ones are not sent
  void cancel() {
    final cancelToken = _cancelToken;
    if (cancelToken != null && !cancelToken.isCompleted) {
      cancelToken.complete();
    }
  }

  /// Stops the upload under way and forgets it at once, its failures with it: called on logout, when the request in
  /// flight must not go on streaming and nothing of the upload concerns the next user. The upload stopped ends on its
  /// own, without changing the state anymore.
  void stop() {
    cancel();
    _cancelToken = null;
    state = const NetworkUploadState();
  }

  NetworkUploadState _with({int? finished, required Map<String, double> progress}) => NetworkUploadState(
    isRunning: state.isRunning,
    total: state.total,
    finished: finished ?? state.finished,
    progress: progress,
  );
}

final networkUploadProvider = NotifierProvider<NetworkUploadNotifier, NetworkUploadState>(NetworkUploadNotifier.new);
