// Reads what a 360° video declares about itself (see probeSphericalMetadata): from the copy on the device when there
// is one, else from the original on the server, with a few HTTP range requests rather than the whole file.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/spatial_media.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:logging/logging.dart';

final _log = Logger('SphericalProbe');

/// Reads [url] with HTTP range requests through [client], with [headers] on top of the range. A server that ignores
/// the range is read from the start only, and the transfer stops once the bytes asked for arrived, or as soon as
/// [cancelled] says so (a probe past its time: its reads no longer take the link from the player).
///
/// The transfer is stopped by an abort of its request: the client of Android (package:ok_http) goes on reading a body
/// whose stream nobody listens to any more until its end (the 3.6 MB index of a two hour film, read for 40 s beside
/// the player over 1.5 Mbit/s after the probe had given up, 31 October 2026). Never before the answer came: that
/// client then completes its response twice, from a thread of OkHttp, and the app crashes.
ByteRangeReader httpRangeReader(
  http.Client client,
  Uri url, {
  Map<String, String> headers = const {},
  bool Function()? cancelled,
}) => (offset, length) async {
  if (cancelled?.call() ?? false) {
    throw http.ClientException('Cancelled', url);
  }
  final abort = Completer<void>();
  var answered = false;
  void stop() {
    if (answered && !abort.isCompleted) {
      abort.complete();
    }
  }

  // A read that waits for its next bytes hears of a cancel from here
  final watch = cancelled == null
      ? null
      : Timer.periodic(const Duration(milliseconds: 250), (_) {
          if (cancelled()) {
            stop();
          }
        });
  try {
    final request = http.AbortableRequest('GET', url, abortTrigger: abort.future)
      ..headers.addAll(headers)
      ..headers['range'] = 'bytes=$offset-${offset + length - 1}';
    final response = await client.send(request);
    answered = true;
    if (cancelled?.call() ?? false) {
      throw http.ClientException('Cancelled', url);
    }
    final status = response.statusCode;
    // Past the end of the file
    if (status == 416) {
      return Uint8List(0);
    }
    if (status != 206 && !(status == 200 && offset == 0)) {
      throw http.ClientException('HTTP $status for the bytes $offset to ${offset + length - 1}', url);
    }
    final builder = BytesBuilder(copy: false);
    await for (final bytes in response.stream) {
      builder.add(bytes);
      if (builder.length >= length) {
        break;
      }
      if (cancelled?.call() ?? false) {
        throw http.ClientException('Cancelled', url);
      }
    }
    final bytes = builder.takeBytes();
    return bytes.length > length ? Uint8List.sublistView(bytes, 0, length) : bytes;
  } on http.RequestAbortedException {
    throw http.ClientException('Cancelled', url);
  } finally {
    watch?.cancel();
    // Whatever is left of the body, a server that ignored the range or a probe that gave up, is not read
    stop();
  }
};

/// [read], with the first [headLength] bytes of the file read once and every read within them served from there: a
/// server that ignores the range still gives the head of its file, where the transcoded stream of Immich keeps its moov
/// box (faststart), however long the video. A read past the head goes to [read].
ByteRangeReader headPrefetchReader(ByteRangeReader read, {int headLength = 1 << 20}) {
  Future<Uint8List>? head;
  return (offset, length) async {
    if (offset + length > headLength) {
      return read(offset, length);
    }
    final bytes = await (head ??= read(0, headLength));
    if (offset >= bytes.length) {
      return Uint8List(0);
    }
    return Uint8List.sublistView(bytes, offset, math.min(offset + length, bytes.length));
  };
}

/// Probes a file on the device, see [probeSphericalMetadata]
Future<SphericalProbe> probeSphericalFile(File file) async {
  final handle = await file.open();
  try {
    return await probeSphericalMetadata((offset, length) async {
      await handle.setPosition(offset);
      return handle.read(length);
    });
  } finally {
    await handle.close();
  }
}

/// Runs the probe of 360° videos (see [probeSphericalMetadata]) and keeps its results in memory, per asset.
///
/// A probe that fails gives null, and is tried again next time. One that takes longer than [timeout] gives null and
/// stops its reads there (on 31 October 2026 a probe past its 5 s went on reading the 3.6 MB index of a film for 39 s,
/// beside the player); it is not tried again for [retryAfterTimeout]: the link is slow, and every page of that video
/// would read the index again.
class SphericalProbeService {
  SphericalProbeService({
    required this._storage,
    required this._client,
    required this._serverEndpoint,
    required this._headers,
    this.timeout = const Duration(seconds: 5),
    this.maxEntries = 200,
    this.retryAfterTimeout = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// How long a probe that timed out is not tried again, see the class
  final Duration retryAfterTimeout;
  final DateTime Function() _clock;

  // When the probe of each asset key last timed out
  final _timedOut = <String, DateTime>{};

  final StorageRepository _storage;
  final http.Client Function() _client;
  final String? Function() _serverEndpoint;
  final Map<String, String> Function() _headers;

  /// Longest wait for a probe
  final Duration timeout;

  /// Past this many assets, the results probed first are forgotten
  final int maxEntries;

  // Results per asset key (see spatialLayoutKey), the latest last, and the probes under way
  final _results = <String, SphericalProbe>{};
  final _pending = <String, Future<SphericalProbe?>>{};

  /// What an earlier probe of [asset] found, without reading anything; null when it was not probed or forgotten. For
  /// the lists that guess from what is at hand, the 360° page for one, where a read per video would take too long.
  SphericalProbe? cached(BaseAsset asset) => _results[spatialLayoutKey(asset)];

  /// What the file of [asset], a video, declares; null for a photo, and when the probe fails or times out.
  ///
  /// Reads [localFile] when given, else the copy on the device when there is one, else the original on the server.
  Future<SphericalProbe?> probe(BaseAsset asset, {File? localFile}) async {
    if (!asset.isVideo) {
      return null;
    }
    final key = spatialLayoutKey(asset);
    final known = _results[key];
    if (known != null) {
      return known;
    }
    final timedOut = _timedOut[key];
    if (timedOut != null && _clock().difference(timedOut) < retryAfterTimeout) {
      return null;
    }
    final pending = _pending[key] ??= _probeWithin(asset, localFile, key);
    try {
      final result = await pending;
      if (result != null) {
        _results
          ..remove(key)
          ..[key] = result;
        while (_results.length > maxEntries) {
          _results.remove(_results.keys.first);
        }
      }
      return result;
    } finally {
      unawaited(_pending.remove(key));
    }
  }

  /// What the server's transcoded stream of the video [videoId] declares (its codec and frame size, which the server's
  /// transcoding settings decide: H.264 at the original 5760 x 2880 for one), read from the head of the stream (see
  /// [headPrefetchReader]); null without a server, and when the probe fails or times out. Kept per video, apart from
  /// the probes of the assets.
  Future<SphericalProbe?> probeTranscoded(String videoId) async {
    final key = 'playback:$videoId';
    final known = _results[key];
    if (known != null) {
      return known;
    }
    final endpoint = _serverEndpoint();
    if (endpoint == null) {
      return null;
    }
    final pending = _pending[key] ??= () async {
      var cancelled = false;
      try {
        final url = Uri.parse('$endpoint/assets/$videoId/video/playback');
        final probe = await probeSphericalMetadata(
          headPrefetchReader(httpRangeReader(_client(), url, headers: _headers(), cancelled: () => cancelled)),
        ).timeout(timeout);
        _log.fine('Transcoded stream of $videoId: $probe');
        return probe;
      } catch (error) {
        _log.info('Could not read the transcoded stream of $videoId: $error');
        return null;
      } finally {
        cancelled = true;
      }
    }();
    try {
      final result = await pending;
      if (result != null) {
        _results[key] = result;
        while (_results.length > maxEntries) {
          _results.remove(_results.keys.first);
        }
      }
      return result;
    } finally {
      unawaited(_pending.remove(key));
    }
  }

  Future<SphericalProbe?> _probeWithin(BaseAsset asset, File? localFile, String key) async {
    var cancelled = false;
    try {
      final probe = await _probe(asset, localFile, () => cancelled).timeout(timeout);
      _log.fine('${asset.name}: $probe');
      return probe;
    } on TimeoutException {
      _timedOut[key] = _clock();
      _log.info(
        'The spherical metadata of ${asset.name} took longer than ${timeout.inSeconds} s: not read again for now',
      );
      return null;
    } catch (error) {
      _log.info('Could not read the spherical metadata of ${asset.name}: $error');
      return null;
    } finally {
      // Its reads stop where they are
      cancelled = true;
    }
  }

  Future<SphericalProbe?> _probe(BaseAsset asset, File? localFile, bool Function() cancelled) async {
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
        return await probeSphericalFile(file);
      } catch (error) {
        _log.fine('Copy on the device of ${asset.name} unreadable, reading the server copy: $error');
      }
    }

    final remoteId = asset.remoteId;
    final endpoint = _serverEndpoint();
    if (remoteId == null || endpoint == null) {
      return null;
    }
    final url = Uri.parse('$endpoint/assets/$remoteId/original');
    return probeSphericalMetadata(httpRangeReader(_client(), url, headers: _headers(), cancelled: cancelled));
  }
}

/// The probe of 360° videos. Its results last as long as the app.
final sphericalProbeServiceProvider = Provider<SphericalProbeService>(
  (ref) => SphericalProbeService(
    storage: ref.watch(storageRepositoryProvider),
    // The app's shared client, with its native SSL setup and the authentication of the server; read at each probe,
    // as it changes when the network settings do
    client: () => NetworkRepository.client,
    serverEndpoint: () => Store.tryGet(StoreKey.serverEndpoint),
    headers: ApiService.getRequestHeaders,
  ),
);
