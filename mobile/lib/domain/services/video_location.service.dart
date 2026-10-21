// Places a video on the map of the Immich server from the flight data of its drone (see dji_srt.dart), once it is
// uploaded: the server reads the place of a video from its own metadata first, and for a DJI Neo 2 finds none
// (ExifTool does not decode its timed metadata). So the app waits until the server has read the metadata of the new
// asset, and only when it found no place there, sets the one of the .SRT through the API (PUT /assets with a latitude
// and a longitude, which the server then keeps against later reads of the file). A video with a place of its own is
// never touched.
//
// The server reads the metadata of an upload in a job of its own, usually within seconds. When it has not done so
// after [VideoLocationService.timeout], the place waits in a small list of the app (per server and user) and is set the
// next time the list is gone through (see [VideoLocationService.retryPending]).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';

final _log = Logger('VideoLocationService');

/// What the server tells of the metadata of an asset: whether it read them already ([extracted]), and whether they
/// hold a place ([hasLocation])
typedef AssetPlaceState = ({bool extracted, bool hasLocation});

/// The calls of the server the place step needs, see [VideoLocationService]
abstract interface class VideoLocationApi {
  /// What the server knows of the metadata of [assetId]; null when it has no such asset anymore. Throws when it cannot
  /// tell (no network).
  Future<AssetPlaceState?> placeState(String assetId);

  /// Sets the place of [assetId]
  Future<void> setLocation(String assetId, double latitude, double longitude);
}

/// What became of the place of a video
enum VideoPlaceOutcome {
  /// The place of the flight data is set
  placed,

  /// The server found a place in the video itself: nothing changed
  hadOwn,

  /// The server did not read the metadata in time: the place waits in the pending list
  pending,

  /// The asset is gone, or the place could not be set
  failed,
}

/// A place to set once the server has read the metadata of [assetId]
class PendingVideoPlace {
  const PendingVideoPlace({
    required this.assetId,
    required this.latitude,
    required this.longitude,
    required this.since,
  });

  final String assetId;
  final double latitude;
  final double longitude;

  /// When it was put in the list: a place still waiting after [VideoLocationService.pendingLifetime] is dropped
  final DateTime since;

  Map<String, Object> toJson() => {
    'id': assetId,
    'lat': latitude,
    'lon': longitude,
    'since': since.toUtc().toIso8601String(),
  };

  static PendingVideoPlace? fromJson(Object? json) {
    if (json case {
      'id': final String id,
      'lat': final num latitude,
      'lon': final num longitude,
      'since': final String since,
    }) {
      final date = DateTime.tryParse(since);
      if (id.isEmpty || date == null) {
        return null;
      }
      return PendingVideoPlace(
        assetId: id,
        latitude: latitude.toDouble(),
        longitude: longitude.toDouble(),
        since: date,
      );
    }
    return null;
  }
}

/// Sets the place of uploaded videos from their flight data, see [place]
class VideoLocationService {
  VideoLocationService(
    this._api,
    this._pendingFile, {
    this.interval = const Duration(seconds: 3),
    this.timeout = const Duration(seconds: 90),
    this.pendingLifetime = const Duration(days: 30),
    DateTime Function()? now,
    Future<void> Function(Duration duration)? delay,
  }) : _now = now ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed;

  final VideoLocationApi _api;

  /// The JSON file of the pending list; null without a user signed in, when nothing is kept
  final Future<File?> Function() _pendingFile;

  /// Time between two looks at an asset whose metadata the server has not read yet
  final Duration interval;

  /// Longest wait for the server to read the metadata of an upload, after which the place goes to the pending list
  final Duration timeout;

  /// A pending place older than this is dropped: its asset was deleted meanwhile, or the server never read it
  final Duration pendingLifetime;

  final DateTime Function() _now;
  final Future<void> Function(Duration duration) _delay;

  // The changes of the pending list, one after the other
  Future<void> _queue = Future.value();

  /// The file name of the pending list of the user [userId] of the server [server]
  static String fileNameFor(String server, String userId) =>
      'video_places_${sha1.convert(utf8.encode(jsonEncode([server, userId])))}.json';

  /// Sets the place [latitude], [longitude] on the video [assetId] once the server has read its metadata, unless they
  /// hold a place: looks every [interval] for up to [timeout], then leaves it to the pending list. Once [stop]
  /// completes (the user cancelled the upload), the place goes to the pending list at once.
  Future<VideoPlaceOutcome> place(String assetId, double latitude, double longitude, {Future<void>? stop}) async {
    final deadline = _now().add(timeout);
    var stopped = false;
    unawaited(stop?.then((_) => stopped = true));
    Future<VideoPlaceOutcome> leaveToPending() async {
      await _addPending(PendingVideoPlace(assetId: assetId, latitude: latitude, longitude: longitude, since: _now()));
      return VideoPlaceOutcome.pending;
    }

    while (true) {
      AssetPlaceState? state;
      var known = true;
      try {
        state = await _api.placeState(assetId);
      } catch (error) {
        // No answer now: asked again until the deadline, then kept for later
        _log.info('Could not ask the server about $assetId: $error');
        known = false;
      }
      if (known && state == null) {
        _log.info('$assetId is gone from the server: no place to set');
        return VideoPlaceOutcome.failed;
      }
      if (state != null && state.extracted) {
        return _setUnlessPlaced(assetId, state, latitude, longitude);
      }
      if (stopped || !_now().isBefore(deadline)) {
        return leaveToPending();
      }
      await (stop == null ? _delay(interval) : Future.any([_delay(interval), stop]));
      if (stopped) {
        return leaveToPending();
      }
    }
  }

  /// Goes once through the pending list: sets each place whose asset the server has read meanwhile (unless it found a
  /// place of its own), drops those of assets gone and those older than [pendingLifetime], keeps the others. Gives how
  /// many places were set.
  Future<int> retryPending() => _serial(_retryPending);

  Future<int> _retryPending() async {
    final pending = await _readPending();
    if (pending.isEmpty) {
      return 0;
    }
    var placed = 0;
    final kept = <PendingVideoPlace>[];
    for (final entry in pending) {
      if (_now().difference(entry.since) > pendingLifetime) {
        _log.info('Dropped the place of ${entry.assetId}, waiting since ${entry.since}');
        continue;
      }
      AssetPlaceState? state;
      try {
        state = await _api.placeState(entry.assetId);
      } catch (error) {
        _log.info('Could not ask the server about ${entry.assetId}: $error');
        kept.add(entry);
        continue;
      }
      if (state == null) {
        continue;
      }
      if (!state.extracted) {
        kept.add(entry);
        continue;
      }
      final outcome = await _setUnlessPlaced(entry.assetId, state, entry.latitude, entry.longitude, keep: false);
      if (outcome == VideoPlaceOutcome.placed) {
        placed++;
      } else if (outcome == VideoPlaceOutcome.failed) {
        kept.add(entry);
      }
    }
    await _writePending(kept);
    return placed;
  }

  /// The places waiting for the server, oldest first
  Future<List<PendingVideoPlace>> pending() => _serial(_readPending);

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<VideoPlaceOutcome> _setUnlessPlaced(
    String assetId,
    AssetPlaceState state,
    double latitude,
    double longitude, {
    bool keep = true,
  }) async {
    if (state.hasLocation) {
      _log.fine('$assetId has a place of its own');
      return VideoPlaceOutcome.hadOwn;
    }
    try {
      await _api.setLocation(assetId, latitude, longitude);
      _log.info('Placed $assetId from its flight data');
      return VideoPlaceOutcome.placed;
    } catch (error, stackTrace) {
      _log.warning('Could not set the place of $assetId', error, stackTrace);
      if (keep) {
        await _addPending(PendingVideoPlace(assetId: assetId, latitude: latitude, longitude: longitude, since: _now()));
        return VideoPlaceOutcome.pending;
      }
      return VideoPlaceOutcome.failed;
    }
  }

  Future<void> _addPending(PendingVideoPlace place) => _serial(() async {
    final pending = await _readPending();
    pending
      ..removeWhere((entry) => entry.assetId == place.assetId)
      ..add(place);
    await _writePending(pending);
  });

  Future<List<PendingVideoPlace>> _readPending() async {
    try {
      final file = await _pendingFile();
      // ignore: avoid_slow_async_io
      if (file == null || !await file.exists()) {
        return [];
      }
      final json = jsonDecode(await file.readAsString());
      final list = json is Map ? json['places'] : null;
      if (list is! List) {
        return [];
      }
      return [
        for (final item in list)
          if (PendingVideoPlace.fromJson(item) case final PendingVideoPlace place) place,
      ];
    } catch (error, stackTrace) {
      _log.warning('Could not read the places waiting for the server', error, stackTrace);
      return [];
    }
  }

  Future<void> _writePending(List<PendingVideoPlace> pending) async {
    try {
      final file = await _pendingFile();
      if (file == null) {
        return;
      }
      if (pending.isEmpty) {
        // ignore: avoid_slow_async_io
        if (await file.exists()) {
          await file.delete();
        }
        return;
      }
      await file.parent.create(recursive: true);
      // A temporary file renamed over the list: the app stopped in the middle of a write leaves the previous one
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({'version': 1, 'places': pending.map((entry) => entry.toJson()).toList()}),
        flush: true,
      );
      await temporary.rename(file.path);
    } catch (error, stackTrace) {
      _log.warning('Could not write the places waiting for the server', error, stackTrace);
    }
  }
}
