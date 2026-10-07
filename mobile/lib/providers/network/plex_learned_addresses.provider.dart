// What each Plex server said about its address outside home at the last connection at home (see
// StoreKey.plexLearnedAddresses). Kept apart from the sources: writing it into a source would close the connection
// open at home for nothing (see NetworkConnections), and it changes on its own when the public address does.

import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';

/// The address outside home a Plex server told
class PlexLearnedAddress {
  const PlexLearnedAddress({required this.host, required this.port, this.mapping, required this.at});

  /// A public IPv4 address
  final String host;
  final int port;

  /// What the server said of its port mapping ("mapped", "unknown"...), null when it said nothing
  final String? mapping;

  /// When the server said it
  final DateTime at;

  Map<String, Object?> toJson() => {
    'host': host,
    'port': port,
    if (mapping != null) 'mapping': mapping,
    'at': at.toUtc().toIso8601String(),
  };

  /// Null when [json] misses the host, a valid port or the date
  static PlexLearnedAddress? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final host = json['host'];
    final port = json['port'];
    final mapping = json['mapping'];
    final at = json['at'] is String ? DateTime.tryParse(json['at'] as String) : null;
    if (host is! String || host.isEmpty || port is! int || port < 1 || port > 65535 || at == null) {
      return null;
    }
    return PlexLearnedAddress(
      host: host,
      port: port,
      mapping: mapping is String && mapping.isNotEmpty ? mapping : null,
      at: at,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlexLearnedAddress &&
      other.host == host &&
      other.port == port &&
      other.mapping == mapping &&
      other.at.isAtSameMomentAs(at);

  @override
  int get hashCode => Object.hash(host, port, mapping, at.microsecondsSinceEpoch);
}

/// The learned addresses by source id, in the Store
class PlexLearnedAddressStore {
  const PlexLearnedAddressStore(this._store);

  final StoreService _store;

  /// The address the server of [sourceId] told last, null when none
  PlexLearnedAddress? read(String sourceId) => PlexLearnedAddress.fromJson(_all()[sourceId]);

  Future<void> write(String sourceId, PlexLearnedAddress address) async {
    final all = _all()..[sourceId] = address.toJson();
    await _store.put(StoreKey.plexLearnedAddresses, jsonEncode(all));
  }

  /// Forgets what the server of [sourceId] told, when its source is removed
  Future<void> remove(String sourceId) async {
    final all = _all();
    if (all.remove(sourceId) == null) {
      return;
    }
    if (all.isEmpty) {
      await _store.delete(StoreKey.plexLearnedAddresses);
    } else {
      await _store.put(StoreKey.plexLearnedAddresses, jsonEncode(all));
    }
  }

  Map<String, Object?> _all() {
    final stored = _store.tryGet(StoreKey.plexLearnedAddresses);
    if (stored == null || stored.isEmpty) {
      return {};
    }
    try {
      final decoded = jsonDecode(stored);
      return decoded is Map ? {for (final entry in decoded.entries) '${entry.key}': entry.value} : {};
    } on FormatException {
      return {};
    }
  }
}

final plexLearnedAddressStoreProvider = Provider<PlexLearnedAddressStore>(
  (ref) => PlexLearnedAddressStore(ref.watch(storeServiceProvider)),
);
