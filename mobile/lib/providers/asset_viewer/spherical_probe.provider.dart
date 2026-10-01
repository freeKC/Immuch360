// Reads what a 360° video declares about itself (see probeSphericalMetadata): from the copy on the device when there
// is one, else from the original on the server, with a few HTTP range requests rather than the whole file.

import 'dart:async';
import 'dart:io';
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
/// the range is read from the start only, and the transfer stops once the bytes asked for arrived.
ByteRangeReader httpRangeReader(http.Client client, Uri url, {Map<String, String> headers = const {}}) =>
    (offset, length) async {
      final request = http.Request('GET', url)
        ..headers.addAll(headers)
        ..headers['range'] = 'bytes=$offset-${offset + length - 1}';
      final response = await client.send(request);
      final status = response.statusCode;
      // Past the end of the file
      if (status == 416) {
        await response.stream.listen(null).cancel();
        return Uint8List(0);
      }
      if (status != 206 && !(status == 200 && offset == 0)) {
        await response.stream.listen(null).cancel();
        throw http.ClientException('HTTP $status for the bytes $offset to ${offset + length - 1}', url);
      }
      final builder = BytesBuilder(copy: false);
      // Leaving the loop cancels the transfer
      await for (final bytes in response.stream) {
        builder.add(bytes);
        if (builder.length >= length) {
          break;
        }
      }
      final bytes = builder.takeBytes();
      return bytes.length > length ? Uint8List.sublistView(bytes, 0, length) : bytes;
    };

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
/// A probe that fails or takes longer than [timeout] gives null, and is tried again next time.
class SphericalProbeService {
  SphericalProbeService({
    required this._storage,
    required this._client,
    required this._serverEndpoint,
    required this._headers,
    this.timeout = const Duration(seconds: 5),
    this.maxEntries = 200,
  });

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
    final pending = _pending[key] ??= _probeWithin(asset, localFile);
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

  Future<SphericalProbe?> _probeWithin(BaseAsset asset, File? localFile) async {
    try {
      final probe = await _probe(asset, localFile).timeout(timeout);
      _log.fine('${asset.name}: $probe');
      return probe;
    } catch (error) {
      _log.info('Could not read the spherical metadata of ${asset.name}: $error');
      return null;
    }
  }

  Future<SphericalProbe?> _probe(BaseAsset asset, File? localFile) async {
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
    return probeSphericalMetadata(httpRangeReader(_client(), url, headers: _headers()));
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
