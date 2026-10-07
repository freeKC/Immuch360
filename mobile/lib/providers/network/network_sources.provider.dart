// The network shares and cameras the user added. The list lives in the Store without any password, in two keys: the
// types builds 19 and older know under StoreKey.networkSources, the later ones under StoreKey.networkSourcesExtra,
// which those builds never load (they would drop the sources of a type they do not know when they write their list
// back). Each secret lives in the secure storage under the secretKey (and for a camera the cameraSecretKey) of its
// source.

import 'dart:math';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/plex_learned_addresses.provider.dart';
import 'package:immich_mobile/providers/tapo/tapo_infrastructure.provider.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:logging/logging.dart';

final _log = Logger('NetworkSources');

class NetworkSourcesNotifier extends Notifier<List<NetworkSource>> {
  /// The entries of a type this build does not know, kept in their key and written back with it
  List<Map<String, Object?>> _legacyUnknown = const [];
  List<Map<String, Object?>> _extraUnknown = const [];

  @override
  List<NetworkSource> build() {
    _legacyUnknown = const [];
    _extraUnknown = const [];
    try {
      final store = ref.watch(storeServiceProvider);
      void dropped(Object? entry) => _log.warning('A stored network source could not be read and is left out');
      final legacy = NetworkSource.decodeStored(store.tryGet(StoreKey.networkSources), onDropped: dropped);
      final extra = NetworkSource.decodeStored(store.tryGet(StoreKey.networkSourcesExtra), onDropped: dropped);
      _legacyUnknown = legacy.unknown;
      _extraUnknown = extra.unknown;
      final sources = <NetworkSource>[];
      final ids = <String>{};
      for (final source in [...legacy.sources, ...extra.sources]) {
        if (ids.add(source.id)) {
          sources.add(source);
        } else {
          _log.fine('A network source is stored twice; the first one is kept');
        }
      }
      // A source stored in the other key than its type's moves to its own at the next save
      return List.unmodifiable(_ordered(sources));
    } on UnsupportedError catch (error) {
      // The store is not initialised: no share was added
      _log.fine('No store for the network shares: $error');
      return const [];
    }
  }

  /// A new random id for a source, 16 hexadecimal digits
  static String newId() {
    final random = Random.secure();
    return List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  NetworkSource? byId(String id) => state.where((source) => source.id == id).firstOrNull;

  /// Adds [source] after the others of its kind, with its secrets when there are some: [password] is the password
  /// of an SMB or WebDAV share, the token of a Plex server or the password of the TP-Link account of a Tapo camera;
  /// [cameraPassword] the password of the camera account of a Tapo camera, ignored for the other types
  Future<void> add(NetworkSource source, {String? password, String? cameraPassword}) async {
    if (byId(source.id) != null) {
      throw ArgumentError.value(source.id, 'source.id', 'A share with this id already exists');
    }
    await _writeSecret(source, source.secretKey, password);
    if (source.type == NetworkSourceType.tapo) {
      await _writeSecret(source, source.cameraSecretKey, cameraPassword);
    }
    await _save([...state, source]);
  }

  /// Replaces the source with the id of [source], keeping its place in the list. A null secret keeps the stored one,
  /// an empty one forgets it (see [add] for what each secret is).
  Future<void> update(NetworkSource source, {String? password, String? cameraPassword}) async {
    final index = state.indexWhere((s) => s.id == source.id);
    if (index < 0) {
      throw ArgumentError.value(source.id, 'source.id', 'No share with this id');
    }
    if (password != null) {
      await _writeSecret(source, source.secretKey, password);
    }
    if (cameraPassword != null && source.type == NetworkSourceType.tapo) {
      await _writeSecret(source, source.cameraSecretKey, cameraPassword);
    }
    // Always a new object, even for a new password only: the open connection of the share is closed when its source
    // object changes (see NetworkConnections), and opened again with the new settings on its next use
    await _save([...state]..[index] = source.copyWith());
  }

  /// Removes the source with [id] and forgets its secrets, its learned Plex address and what was fetched from a
  /// camera; nothing happens on the server or the camera
  Future<void> remove(String id) async {
    final source = byId(id);
    if (source == null) {
      return;
    }
    await _save(state.where((s) => s.id != id).toList());
    final storage = ref.read(secureStorageServiceProvider);
    final deviceOnly = _isDeviceOnly(source);
    try {
      await storage.delete(source.secretKey, deviceOnly: deviceOnly);
    } catch (error, stackTrace) {
      _log.warning('Could not forget the password of a removed share', error, stackTrace);
    }
    if (source.type == NetworkSourceType.tapo) {
      try {
        await storage.delete(source.cameraSecretKey, deviceOnly: deviceOnly);
      } catch (error, stackTrace) {
        _log.warning('Could not forget the camera account password of a removed camera', error, stackTrace);
      }
      try {
        await ref.read(tapoCameraCacheDeleterProvider)(id);
      } catch (error, stackTrace) {
        _log.warning('Could not delete the videos fetched from a removed camera', error, stackTrace);
      }
    }
    if (source.type == NetworkSourceType.plex) {
      try {
        await ref.read(plexLearnedAddressStoreProvider).remove(id);
      } catch (error, stackTrace) {
        _log.warning('Could not forget the address outside home of a removed Plex server', error, stackTrace);
      }
    }
  }

  /// The stored password (the token of a Plex server, the TP-Link password of a camera) of the source with [id], null
  /// when it has none or is unknown
  Future<String?> readPassword(String id) => _readSecret(id, (source) => source.secretKey);

  /// The stored camera account password of the Tapo camera with [id], null when it has none or is unknown
  Future<String?> readCameraPassword(String id) => _readSecret(id, (source) => source.cameraSecretKey);

  Future<String?> _readSecret(String id, String Function(NetworkSource source) keyOf) async {
    final source = byId(id);
    if (source == null) {
      return null;
    }
    final secret = await ref.read(secureStorageServiceProvider).read(keyOf(source));
    return secret == null || secret.isEmpty ? null : secret;
  }

  /// The secrets of a Plex server (a token with full access to the server) and of a camera (the password of the
  /// TP-Link account) stay on this device: out of the cloud and device to device backups
  static bool _isDeviceOnly(NetworkSource source) =>
      source.type == NetworkSourceType.plex || source.type == NetworkSourceType.tapo;

  Future<void> _writeSecret(NetworkSource source, String key, String? secret) async {
    final storage = ref.read(secureStorageServiceProvider);
    final deviceOnly = _isDeviceOnly(source);
    if (secret == null || secret.isEmpty) {
      await storage.delete(key, deviceOnly: deviceOnly);
    } else {
      await storage.write(key, secret, deviceOnly: deviceOnly);
    }
  }

  /// The shares of the types builds 19 and older know, then the others, each in the order they were added
  static List<NetworkSource> _ordered(List<NetworkSource> sources) => [
    ...sources.where((source) => source.type.inLegacyList),
    ...sources.where((source) => !source.type.inLegacyList),
  ];

  Future<void> _save(List<NetworkSource> sources) async {
    final store = ref.read(storeServiceProvider);
    final ordered = _ordered(sources);
    final legacy = NetworkSource.encodeStored(
      ordered.where((source) => source.type.inLegacyList).toList(),
      _legacyUnknown,
    );
    final extra = NetworkSource.encodeStored(
      ordered.where((source) => !source.type.inLegacyList).toList(),
      _extraUnknown,
    );
    for (final (key, value) in [(StoreKey.networkSources, legacy), (StoreKey.networkSourcesExtra, extra)]) {
      if (value == null) {
        await store.delete(key);
      } else {
        await store.put(key, value);
      }
    }
    state = List.unmodifiable(ordered);
  }
}

final networkSourcesProvider = NotifierProvider<NetworkSourcesNotifier, List<NetworkSource>>(
  NetworkSourcesNotifier.new,
);

/// The source with this id, null once it is removed
final networkSourceProvider = Provider.family<NetworkSource?, String>((ref, id) {
  return ref.watch(networkSourcesProvider).where((source) => source.id == id).firstOrNull;
});
