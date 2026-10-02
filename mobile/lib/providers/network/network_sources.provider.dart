// The network shares the user added (see StoreKey.networkSources). The list lives in the Store without any password;
// each password lives in the secure storage under the secretKey of its source.

import 'dart:math';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:logging/logging.dart';

final _log = Logger('NetworkSources');

class NetworkSourcesNotifier extends Notifier<List<NetworkSource>> {
  @override
  List<NetworkSource> build() {
    try {
      return NetworkSource.decodeList(ref.watch(storeServiceProvider).tryGet(StoreKey.networkSources));
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

  /// Adds [source] at the end of the list, with its [password] when there is one
  Future<void> add(NetworkSource source, {String? password}) async {
    if (byId(source.id) != null) {
      throw ArgumentError.value(source.id, 'source.id', 'A share with this id already exists');
    }
    await _writePassword(source, password);
    await _save([...state, source]);
  }

  /// Replaces the source with the id of [source], keeping its place in the list. A null [password] keeps the stored
  /// one, an empty one forgets it.
  Future<void> update(NetworkSource source, {String? password}) async {
    final index = state.indexWhere((s) => s.id == source.id);
    if (index < 0) {
      throw ArgumentError.value(source.id, 'source.id', 'No share with this id');
    }
    if (password != null) {
      await _writePassword(source, password);
    }
    // Always a new object, even for a new password only: the open connection of the share is closed when its source
    // object changes (see NetworkConnections), and opened again with the new settings on its next use
    await _save([...state]..[index] = source.copyWith());
  }

  /// Removes the source with [id] and forgets its password; nothing happens on the server
  Future<void> remove(String id) async {
    final source = byId(id);
    if (source == null) {
      return;
    }
    await _save(state.where((s) => s.id != id).toList());
    try {
      await ref.read(secureStorageServiceProvider).delete(source.secretKey);
    } catch (error, stackTrace) {
      _log.warning('Could not forget the password of a removed share', error, stackTrace);
    }
  }

  /// The stored password of the source with [id], null when it has none or is unknown
  Future<String?> readPassword(String id) async {
    final source = byId(id);
    if (source == null) {
      return null;
    }
    final password = await ref.read(secureStorageServiceProvider).read(source.secretKey);
    return password == null || password.isEmpty ? null : password;
  }

  Future<void> _writePassword(NetworkSource source, String? password) async {
    final storage = ref.read(secureStorageServiceProvider);
    if (password == null || password.isEmpty) {
      await storage.delete(source.secretKey);
    } else {
      await storage.write(source.secretKey, password);
    }
  }

  Future<void> _save(List<NetworkSource> sources) async {
    final store = ref.read(storeServiceProvider);
    if (sources.isEmpty) {
      await store.delete(StoreKey.networkSources);
    } else {
      await store.put(StoreKey.networkSources, NetworkSource.encodeList(sources));
    }
    state = List.unmodifiable(sources);
  }
}

final networkSourcesProvider = NotifierProvider<NetworkSourcesNotifier, List<NetworkSource>>(
  NetworkSourcesNotifier.new,
);

/// The source with this id, null once it is removed
final networkSourceProvider = Provider.family<NetworkSource?, String>((ref, id) {
  return ref.watch(networkSourcesProvider).where((source) => source.id == id).firstOrNull;
});
