// Open connections to the network shares, one per source, opened on first use and kept for the life of the app.
// Each open share is registered on the local media bridge so the players can stream its files.

import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/network/smb_file_system.dart';
import 'package:immich_mobile/infrastructure/network/upnp/dlna_file_system.dart';
import 'package:immich_mobile/infrastructure/network/webdav_file_system.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_file_system.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('NetworkConnections');

/// How to open a share of each type. A provider so tests can replace the real clients.
final networkFileSystemOpenersProvider = Provider<Map<NetworkSourceType, NetworkFileSystemOpener>>((ref) {
  return const {
    NetworkSourceType.smb: SmbFileSystem.open,
    NetworkSourceType.webdav: WebDavFileSystem.open,
    NetworkSourceType.dlna: DlnaFileSystem.open,
    NetworkSourceType.plex: PlexFileSystem.open,
    NetworkSourceType.tapo: TapoFileSystem.open,
  };
});

class NetworkConnections {
  NetworkConnections(this._ref, this._bridge);

  final Ref _ref;
  final MediaBridge _bridge;

  final Map<String, NetworkFileSystem> _open = {};
  final Map<String, Future<NetworkFileSystem>> _opening = {};

  /// Bumped when a connection is closed, so that an opening that ends after it is dropped
  final Map<String, int> _generations = {};
  bool _disposed = false;

  /// The open connection of the source with [sourceId], null when it is not open (yet)
  NetworkFileSystem? opened(String sourceId) => _open[sourceId];

  /// The connection of the source with [sourceId], opened and registered on the media bridge on first use.
  /// Throws a [NetworkFileSystemException] when the source is unknown or the share cannot be reached.
  Future<NetworkFileSystem> fileSystem(String sourceId) {
    final open = _open[sourceId];
    if (open != null) {
      return Future.value(open);
    }
    final pending = _opening[sourceId];
    if (pending != null) {
      return pending;
    }

    final opening = _connect(sourceId);
    _opening[sourceId] = opening;
    unawaited(_forgetWhenDone(sourceId, opening));
    return opening;
  }

  Future<void> _forgetWhenDone(String sourceId, Future<NetworkFileSystem> opening) async {
    try {
      await opening;
    } catch (_) {
      // The callers get the error; the next call tries again
    } finally {
      if (identical(_opening[sourceId], opening)) {
        _opening.remove(sourceId)?.ignore();
      }
    }
  }

  /// The media bridge URL of a file of a share, for the image widgets and the players
  Future<Uri> mediaUrl(String sourceId, String path) async {
    await fileSystem(sourceId);
    return _bridge.urlFor(sourceId, path);
  }

  /// Opens [source] with [password] apart from the kept connections, lists its start folder and closes it again.
  /// Returns the number of entries found there; throws when the share cannot be reached or read.
  Future<int> testConnection(NetworkSource source, String? password) async {
    final fileSystem = await _opener(source.type)(source, password == null || password.isEmpty ? null : password);
    try {
      final entries = await fileSystem.list(source.rootPath.isEmpty ? '/' : source.rootPath);
      return entries.length;
    } finally {
      await _closeQuietly(fileSystem);
    }
  }

  /// Closes the connection of the source with [sourceId] and takes it off the media bridge; the next use opens it
  /// again
  Future<void> close(String sourceId) async {
    _generations[sourceId] = (_generations[sourceId] ?? 0) + 1;
    // A connection still opening is dropped when it ends (see _connect); its callers get an error
    _opening.remove(sourceId)?.ignore();
    final fileSystem = _open.remove(sourceId);
    if (fileSystem == null) {
      return;
    }
    _unregister(sourceId);
    await _closeQuietly(fileSystem);
  }

  Future<void> closeAll() async {
    final ids = {..._open.keys, ..._opening.keys};
    await Future.wait(ids.map(close));
  }

  void _dispose() {
    _disposed = true;
    unawaited(closeAll());
  }

  /// Closes the connections of the sources that were removed or changed (new address, new credentials: an update
  /// always stores a new source object, see [NetworkSourcesNotifier.update])
  void _onSourcesChanged(List<NetworkSource> previous, List<NetworkSource> next) {
    final nextById = {for (final source in next) source.id: source};
    for (final source in previous) {
      if (!identical(nextById[source.id], source)) {
        unawaited(close(source.id));
      }
    }
  }

  NetworkFileSystemOpener _opener(NetworkSourceType type) {
    final opener = _ref.read(networkFileSystemOpenersProvider)[type];
    if (opener == null) {
      throw NetworkFileSystemException('No client for ${type.name} shares');
    }
    return opener;
  }

  Future<NetworkFileSystem> _connect(String sourceId) async {
    final generation = _generations[sourceId] ?? 0;
    bool isCurrent() => !_disposed && (_generations[sourceId] ?? 0) == generation;

    final sources = _ref.read(networkSourcesProvider.notifier);
    final source = sources.byId(sourceId);
    if (source == null) {
      throw NetworkFileSystemException('Unknown share $sourceId', isNotFound: true);
    }
    final open = _opener(source.type);
    final password = await sources.readPassword(sourceId);
    final fileSystem = await open(source, password);

    try {
      if (isCurrent()) {
        await _bridge.start();
      }
    } catch (_) {
      await _closeQuietly(fileSystem);
      rethrow;
    }

    if (!isCurrent()) {
      // Closed or changed while connecting: this connection is not wanted anymore
      await _closeQuietly(fileSystem);
      throw NetworkFileSystemException('The connection to ${source.name} was closed');
    }

    _bridge.register(fileSystem);
    _open[sourceId] = fileSystem;
    return fileSystem;
  }

  void _unregister(String sourceId) {
    try {
      _bridge.unregister(sourceId);
    } catch (error, stackTrace) {
      _log.warning('Could not take a share off the media bridge', error, stackTrace);
    }
  }

  Future<void> _closeQuietly(NetworkFileSystem fileSystem) async {
    try {
      await fileSystem.close();
    } catch (error, stackTrace) {
      _log.warning('Could not close the connection to ${fileSystem.source.name}', error, stackTrace);
    }
  }
}

/// The open connections to the network shares (see [NetworkConnections])
final networkConnectionsProvider = Provider<NetworkConnections>((ref) {
  final connections = NetworkConnections(ref, ref.watch(mediaBridgeProvider));
  ref.listen<List<NetworkSource>>(
    networkSourcesProvider,
    (previous, next) => connections._onSourcesChanged(previous ?? const [], next),
  );
  ref.onDispose(connections._dispose);
  return connections;
});
