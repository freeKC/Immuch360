// "Play on…" of what only the phone has (release 53), both ends in process: the real RemotePlaybackController,
// PhoneRelayController, PlayLinkClient and relay of the phone; the real PlayLinkServer and ScreenPlayerSession of the
// screen on the loopback, whose fake player reads the item through the real RelayFileSystem. The loopback stands for
// the screen's LAN address (192.168.1.20) and for the phone's on the same network.
//
// What is checked: the screen reads the item from the phone it talks to only, under the MAC of the session, and the
// message names no host; another client, or the screen without the MAC, gets 404; the lease and the foreground service
// end with Stop, the end of the item, a lost screen, the next item, the notification's Stop, and a screen that does not
// take it.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/infrastructure/network/cast/cast_relay.dart';
import 'package:immich_mobile/infrastructure/network/play_on_screen/play_link_client.dart';
import 'package:immich_mobile/infrastructure/network/play_on_screen/play_link_server.dart';
import 'package:immich_mobile/infrastructure/network/play_on_screen/relay_file_system.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_relay.provider.dart';

const _screenId = '0123456789abcdef';
const _phoneId = 'fedcba9876543210';

/// The player of the screen: reads a relayed item as the app's RelayFileSystem does, and keeps it to read again
class _ReadingActions implements ScreenPlayerActions {
  final _states = StreamController<ScreenPlayState>.broadcast();
  ScreenPlayState _state = const ScreenPlayState();
  PlayItem? played;
  Uint8List? read;
  RelayFileSystem? fileSystem;
  Object? readError;
  var stops = 0;

  /// The reason the screen gives instead of reading, when set
  ScreenPlayReason? refuse;

  void set(ScreenPlayState state) {
    _state = state;
    _states.add(state);
  }

  @override
  ScreenPlayState get state => _state;

  @override
  Stream<ScreenPlayState> get states => _states.stream;

  @override
  Future<void> play(PlayItem item, LinkedPeer from) async {
    played = item;
    var reason = refuse;
    final target = item.target;
    if (reason == null && target is RelayPlayTarget) {
      try {
        final opened = fileSystem = await RelayFileSystem.open(target, name: from.name);
        final entry = await opened.stat(opened.path);
        read = await opened.readRange(opened.path, 0, entry.size!);
      } catch (error) {
        readError = error;
        reason = ScreenPlayReason.relayFailed;
      }
    }
    set(
      ScreenPlayState(
        seq: _state.seq + 1,
        phase: reason == null ? ScreenPlayPhase.playing : ScreenPlayPhase.failed,
        server: item.server,
        itemKey: item.item,
        media: item.media,
        from: from.name,
        fromId: from.id,
        reason: reason,
      ),
    );
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> seek(int positionMs) async {}

  @override
  Future<void> track(PlayTrackKind kind, String? id) async {}

  @override
  Future<void> stop() async {
    stops++;
    set(_state.next(phase: ScreenPlayPhase.idle));
  }

  @override
  Future<bool> askHandover({
    required LinkedPeer from,
    required String server,
    required String check,
    required Future<void> cancel,
    String? signInAs,
  }) async => false;

  @override
  Future<HandoverResult> addServer(HandedPlexServer server, String token) async => HandoverResult.failed;

  @override
  Future<bool> canBeSignedIn() async => false;

  @override
  Future<HandoverResult> signIn(LinkedPeer from, Map<String, Object?> payload) async => HandoverResult.failed;
}

/// The foreground service of Android, as the relay starts and stops it
class _KeepAlive implements PlayRelayKeepAlive {
  final starts = <String>[];
  var stopsCount = 0;
  final _stopRequests = StreamController<void>.broadcast();

  bool get running => starts.length > stopsCount;

  void pressStop() => _stopRequests.add(null);

  @override
  Future<void> start({
    required String title,
    required String text,
    required String stopLabel,
    required String channel,
  }) async => starts.add(title);

  @override
  Future<void> stop() async => stopsCount++;

  @override
  Stream<void> get stopRequests => _stopRequests.stream;

  @override
  bool get needsAppOpen => false;
}

LinkedPeer _peer(String id, {String name = 'Peer'}) => LinkedPeer(
  id: id,
  name: name,
  key: Uint8List.fromList(List.filled(playLinkKeyBytes, 7)),
  linkedAt: DateTime.utc(2026, 11, 10),
);

Future<void> _until(bool Function() condition, {Duration within = const Duration(seconds: 12)}) async {
  final deadline = DateTime.now().add(within);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Not reached within $within');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

final _video = Uint8List.fromList(List<int>.generate(50000, (index) => (index * 7) % 256));

PlayOnRequest _local(String id, {Uint8List? bytes, bool readable = true}) => PlayOnRequest.relayed(
  sourceId: playOnLocalSource,
  serverName: '',
  title: 'VID_$id.mp4',
  localAssetId: id,
  relay: PlayOnRelayItem(
    key: 'local:$id',
    name: 'VID_$id.mp4',
    media: PlayMedia.video,
    content: () async => readable
        ? PlayOnRelayContent(
            content: CastRelayContent.local(bytes: bytes ?? _video, contentType: 'video/mp4'),
            mime: 'video/mp4',
            size: (bytes ?? _video).length,
          )
        : null,
  ),
);

void main() {
  late _ReadingActions actions;
  late ScreenPlayerSession session;
  late PlayLinkServer server;
  late ProviderContainer container;
  late PlayScreenAddress address;
  late _KeepAlive keepAlive;
  late Set<PlayKind> screenKinds;
  String? phoneAddress;
  final screen = _peer(_screenId, name: 'Living room TV');

  Future<void> startScreen() async {
    session = ScreenPlayerSession(
      screenId: _screenId,
      phones: () => [_peer(_phoneId, name: 'Galaxy S24+')],
      actions: actions,
      kinds: screenKinds,
      random: Random(5),
      // The loopback stands for the phone's address on the home network
      relayHostOf: (client) => client == '127.0.0.1' ? '127.0.0.1' : null,
    );
    server = PlayLinkServer(session: session, preferredPort: 0, requestTimeout: const Duration(seconds: 2));
    address = (host: '192.168.1.20', port: await server.start());
  }

  setUp(() async {
    actions = _ReadingActions();
    keepAlive = _KeepAlive();
    screenKinds = const {PlayKind.plex, PlayKind.immich, PlayKind.share, PlayKind.mediaServer, PlayKind.relay};
    phoneAddress = '127.0.0.1';
    await startScreen();
    container = ProviderContainer(
      overrides: [
        phonePlayEnvironmentProvider.overrideWithValue(
          PhonePlayEnvironment(
            client: () async => PlayLinkClient(
              phoneId: _phoneId,
              connectTimeout: const Duration(seconds: 2),
              answerTimeout: const Duration(seconds: 3),
              random: Random(4),
              addressOf: (host, port) =>
                  Uri(scheme: 'http', host: host == '192.168.1.20' ? '127.0.0.1' : host, port: port),
            ),
            readToken: (_) async => null,
            learnedPublic: (_) => null,
          ),
        ),
        phoneRelayEnvironmentProvider.overrideWithValue(
          PhoneRelayEnvironment(
            addressFor: (screenHost) async => screenHost == '192.168.1.20' ? phoneAddress : null,
            bind: (address) => CastRelayServer.bind(address, port: 0),
            keepAlive: keepAlive,
            texts: () => (title: (s) => 'Sending to $s', text: 'text', stopLabel: 'Stop', channel: 'channel'),
            clientOf: (host) => host == '192.168.1.20' ? '127.0.0.1' : host,
          ),
        ),
      ],
    );
    // The relay follows the playback from the start, as the app's dock makes it
    container.read(phoneRelayProvider);
  });

  tearDown(() async {
    container.dispose();
    await server.stop();
    session.close();
  });

  RemotePlaybackController controller() => container.read(remotePlaybackProvider.notifier);
  PhoneRelayController relay() => container.read(phoneRelayProvider.notifier);
  List<CastRelayLease> leases() => relay().leases.toList();

  Future<({int status, int length})> rawGet(CastRelayLease lease, {String? mac}) async {
    final client = HttpClient();
    try {
      final request = await client.get('127.0.0.1', lease.port, lease.path);
      if (mac != null) {
        request.headers.set(playRelayHeader, mac);
      }
      final response = await request.close();
      final body = await response.fold<int>(0, (length, chunk) => length + chunk.length);
      return (status: response.statusCode, length: body);
    } finally {
      client.close(force: true);
    }
  }

  test('a video on this phone only: the screen reads it from the phone it talks to, under the MAC of the session; '
      'the play names no host', () async {
    expect(await controller().play(screen, address, _local('1')), PlayOnOutcome.playing);
    expect(actions.read, _video, reason: '${actions.readError}');
    final target = actions.played!.target as RelayPlayTarget;
    expect(target.origin!.host, '127.0.0.1', reason: 'the address of the session, never one of the message');
    final json = actions.played!.toJson();
    expect(json.keys, isNot(contains('host')));
    expect(json['kind'], 'relay');
    expect(json['size'], _video.length);
    final lease = leases().single;
    expect(target.lease, lease.id);
    expect(lease.client, '127.0.0.1');
    expect(container.read(remotePlaybackProvider)?.request.ratingKey, lease.id);
    expect(container.read(phoneRelayProvider)?.screen, 'Living room TV');
    expect(keepAlive.starts, ['Sending to Living room TV']);
    expect(keepAlive.running, isTrue);

    // Without the MAC, or with the MAC under another key: the 404 of an unknown path
    expect((await rawGet(lease)).status, HttpStatus.notFound);
    expect((await rawGet(lease, mac: playRelayMac(List.filled(32, 1), lease.path))).status, HttpStatus.notFound);
    // The MAC under the session's K_relay: served
    final mac = playRelayMac(target.origin!.relayKey, lease.path);
    expect((await rawGet(lease, mac: mac)).length, _video.length);
  });

  test('another device of the network never gets it: the lease is the screen\'s address', () async {
    expect(await controller().play(screen, address, _local('1')), PlayOnOutcome.playing);
    final lease = leases().single;
    final target = actions.played!.target as RelayPlayTarget;
    // A lease of the same content for another device: what a client at another address sees of this one
    final relayServer = await CastRelayServer.bind('127.0.0.1', port: 0);
    addTearDown(relayServer.close);
    final foreign = relayServer.lease(
      CastRelayContent.local(bytes: _video, contentType: 'video/mp4'),
      client: '192.168.1.99',
      macKeys: () => [target.origin!.relayKey],
    );
    expect((await rawGet(foreign, mac: playRelayMac(target.origin!.relayKey, foreign.path))).status, 404);
    expect(lease.isRevoked, isFalse);
  });

  test('Stop ends the lease and the service: the screen reads nothing more', () async {
    await controller().play(screen, address, _local('1'));
    final opened = actions.fileSystem!;
    await controller().stop();
    expect(actions.stops, 1);
    await _until(() => leases().isEmpty);
    expect(keepAlive.running, isFalse);
    expect(container.read(phoneRelayProvider), isNull);
    await expectLater(
      opened.readRange(opened.path, 0, 10),
      throwsA(isA<NetworkFileSystemException>().having((error) => error.isNotFound, 'isNotFound', isTrue)),
    );
  });

  test('the end of the video on the screen ends the lease; the service stays for the next item of the slideshow '
      'until the dock goes', () async {
    await controller().play(screen, address, _local('1'));
    expect(leases(), hasLength(1));
    actions.set(actions.state.next(phase: ScreenPlayPhase.ended));
    await _until(() => leases().isEmpty);
    expect(keepAlive.running, isTrue, reason: 'Android refuses a start from the background for the next item');
    // The next item of the phone's slideshow goes with the service already up
    expect(await controller().showNext(_local('2')), PlayOnOutcome.playing);
    expect(keepAlive.starts, hasLength(1));
    expect(leases(), hasLength(1));
    controller().dismiss();
    await _until(() => !keepAlive.running);
    expect(leases(), isEmpty);
  });

  test('an Immich item of the same slideshow keeps the service, and needs no lease', () async {
    await controller().play(screen, address, _local('1'));
    final immich = PlayOnRequest.forTarget(
      sourceId: playOnImmichSource,
      target: const ImmichPlayTarget(
        asset: '3f2504e0-4f89-11d3-9a0c-0305e82c3301',
        user: 'a1b2c3d4-0000-4000-8000-00000000abcd',
        media: PlayMedia.photo,
      ),
      serverName: 'photos.example.org',
    );
    expect(await controller().showNext(immich), PlayOnOutcome.playing);
    expect(leases(), isEmpty);
    expect(keepAlive.running, isTrue);
    await controller().stop();
    await _until(() => !keepAlive.running);
  });

  test('Back on the remote of the screen (idle) ends the lease', () async {
    await controller().play(screen, address, _local('1'));
    actions.set(actions.state.next(phase: ScreenPlayPhase.idle));
    await _until(() => leases().isEmpty);
  });

  test('a lost screen ends the lease', () async {
    await controller().play(screen, address, _local('1'));
    await server.stop();
    session.close();
    await _until(() => container.read(remotePlaybackProvider)?.lost ?? false);
    expect(leases(), isEmpty);
    expect(keepAlive.running, isFalse);
  });

  test('the next item revokes the lease of the one before, and the service keeps running', () async {
    await controller().play(screen, address, _local('1'));
    final first = leases().single;
    final second = Uint8List.fromList(List<int>.filled(1000, 9));
    expect(await controller().showNext(_local('2', bytes: second)), PlayOnOutcome.playing);
    expect(actions.read, second);
    expect(first.isRevoked, isTrue);
    expect(leases().single.id, (actions.played!.target as RelayPlayTarget).lease);
    expect(keepAlive.running, isTrue);
    expect(keepAlive.starts, hasLength(1));
  });

  test('Stop in the notification stops the item on the screen and ends the leases', () async {
    await controller().play(screen, address, _local('1'));
    keepAlive.pressStop();
    await _until(() => actions.stops == 1 && leases().isEmpty);
    expect(keepAlive.running, isFalse);
    expect(container.read(remotePlaybackProvider), isNull);
  });

  test('a screen of release 52 does not take it: Update, and no lease stays', () async {
    await server.stop();
    session.close();
    screenKinds = const {PlayKind.plex, PlayKind.immich, PlayKind.share, PlayKind.mediaServer};
    await startScreen();
    expect(await controller().play(screen, address, _local('1')), PlayOnOutcome.needsUpdate);
    expect(leases(), isEmpty);
    expect(keepAlive.running, isFalse);
  });

  test('an item the phone cannot read any more: nothing goes to the screen', () async {
    expect(await controller().play(screen, address, _local('1', readable: false)), PlayOnOutcome.relayFailed);
    expect(actions.played, isNull);
    expect(leases(), isEmpty);
    expect(keepAlive.starts, isEmpty);
  });

  test('the screen could not read it: relayFailed, and the lease goes', () async {
    actions.refuse = ScreenPlayReason.relayFailed;
    expect(await controller().play(screen, address, _local('1')), PlayOnOutcome.relayFailed);
    expect(leases(), isEmpty);
    expect(keepAlive.running, isFalse);
  });

  test('a phone without an address on the screen\'s network sends nothing', () async {
    phoneAddress = null;
    expect(await controller().play(screen, address, _local('1')), PlayOnOutcome.relayFailed);
    expect(actions.played, isNull);
    expect(leases(), isEmpty);
  });
}
