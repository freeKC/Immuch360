// The links of "Play on the TV", kept in the secure storage of each side (never in the Store, never in a backup,
// never logged): on a phone the screens it may play on, on a big screen the phones that may play on it. Each holds
// the other's install id, its name, the 256 bit link key and the date. A phone keeps [maxScreens] screens, a screen
// [maxPhones] phones; the oldest goes when a new one comes. Removing one on either side ends the link: the screen
// refuses the phone's proofs from then on.

import 'dart:async';
import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:logging/logging.dart';

final _log = Logger('PlayLinks');

/// The secure storage keys of the two lists
const playLinkScreensKey = 'play_link_screens';
const playLinkPhonesKey = 'play_link_phones';

/// What the lists are kept in, replaced by a map in the tests
abstract interface class PlayLinkSecrets {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class _SecureSecrets implements PlayLinkSecrets {
  const _SecureSecrets(this._service);
  final SecureStorageService _service;

  @override
  Future<String?> read(String key) => _service.read(key);

  // Kept on this device only: a link key never goes to another device by a backup
  @override
  Future<void> write(String key, String value) => _service.write(key, value, deviceOnly: true);
}

final playLinkSecretsProvider = Provider<PlayLinkSecrets>(
  (ref) => _SecureSecrets(ref.watch(secureStorageServiceProvider)),
);

/// One of the two lists, the latest first
class LinkedPeersNotifier extends AsyncNotifier<List<LinkedPeer>> {
  LinkedPeersNotifier(this._key, this._max);

  final String _key;
  final int _max;

  /// The writes, one after the other
  Future<void> _writes = Future.value();

  @override
  Future<List<LinkedPeer>> build() async {
    final stored = await ref.read(playLinkSecretsProvider).read(_key);
    if (stored == null) {
      return const [];
    }
    try {
      final decoded = jsonDecode(stored);
      return [
        if (decoded is List)
          for (final entry in decoded) ?LinkedPeer.fromJson(entry),
      ];
    } on FormatException {
      _log.warning('The list of linked devices does not read: it starts empty');
      return const [];
    }
  }

  /// The list now, waiting for it to load
  Future<List<LinkedPeer>> current() async => state.valueOrNull ?? await future;

  Future<void> _save(List<LinkedPeer> peers) {
    state = AsyncData(List.unmodifiable(peers));
    final json = jsonEncode([for (final peer in peers) peer.toJson()]);
    return _writes = _writes.then((_) => ref.read(playLinkSecretsProvider).write(_key, json));
  }

  /// Adds [peer], in place of one with the same id
  Future<void> add(LinkedPeer peer) async {
    final peers = await current();
    await _save([peer, ...peers.where((other) => other.id != peer.id)].take(_max).toList());
  }

  Future<void> remove(String id) async {
    final peers = await current();
    await _save(peers.where((peer) => peer.id != id).toList());
  }

  /// The name the other side gave itself at its last connection
  Future<void> rename(String id, String name) async {
    final peers = await current();
    if (peers.every((peer) => peer.id != id || peer.name == name)) {
      return;
    }
    await _save([for (final peer in peers) peer.id == id ? peer.renamed(name) : peer]);
  }
}

/// On a phone: the screens it may play on
const maxLinkedScreens = 16;

/// On a big screen: the phones that may play on it
const maxLinkedPhones = 8;

final linkedScreensProvider = AsyncNotifierProvider<LinkedPeersNotifier, List<LinkedPeer>>(
  () => LinkedPeersNotifier(playLinkScreensKey, maxLinkedScreens),
);

final linkedPhonesProvider = AsyncNotifierProvider<LinkedPeersNotifier, List<LinkedPeer>>(
  () => LinkedPeersNotifier(playLinkPhonesKey, maxLinkedPhones),
);
