import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';

const _screenId = '0123456789abcdef';
const _phoneId = 'fedcba9876543210';
const _otherPhoneId = '1111111122222222';

const _server = HandedPlexServer(
  name: 'Plex at home',
  machineIdentifier: 'abcdef0123456789',
  hash: '0123456789abcdef0123456789abcdef',
  host: '192.168.1.20',
  port: 32400,
);

class _FakeActions implements ScreenPlayerActions {
  final _states = StreamController<ScreenPlayState>.broadcast();
  ScreenPlayState _state = const ScreenPlayState();
  final calls = <String>[];
  PlayItem? played;
  LinkedPeer? playedFrom;

  /// Answered by the test; null answers at once with [acceptHandover]
  Completer<bool>? handoverAnswer;
  bool acceptHandover = true;
  ({LinkedPeer from, String server, String check})? asked;
  Future<void>? handoverCancel;
  final added = <(HandedPlexServer, String)>[];
  HandoverResult addResult = HandoverResult.added;

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
    calls.add('play');
    played = item;
    playedFrom = from;
    set(_state.next(phase: ScreenPlayPhase.opening, server: item.server, item: item.item, from: from.name));
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    set(_state.next(phase: ScreenPlayPhase.paused));
  }

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> seek(int positionMs) async => calls.add('seek $positionMs');

  @override
  Future<void> track(PlayTrackKind kind, String? id) async => calls.add('track ${kind.wire} $id');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<bool> askHandover({
    required LinkedPeer from,
    required String server,
    required String check,
    required Future<void> cancel,
  }) {
    asked = (from: from, server: server, check: check);
    handoverCancel = cancel;
    return handoverAnswer?.future ?? Future.value(acceptHandover);
  }

  @override
  Future<HandoverResult> addServer(HandedPlexServer server, String token) async {
    added.add((server, token));
    return addResult;
  }
}

LinkedPeer _peer(String id, {int keyByte = 7, String name = 'Galaxy S24+'}) => LinkedPeer(
  id: id,
  name: name,
  key: Uint8List.fromList(List.filled(playLinkKeyBytes, keyByte)),
  linkedAt: DateTime.utc(2026, 11, 10),
);

void main() {
  late DateTime now;
  late _FakeActions actions;
  late List<LinkedPeer> phones;
  late ScreenPlayerSession session;
  var seed = 1;

  setUp(() {
    now = DateTime.utc(2026, 11, 10, 23);
    actions = _FakeActions();
    phones = [_peer(_phoneId), _peer(_otherPhoneId, keyByte: 9, name: 'Pixel')];
    session = ScreenPlayerSession(
      screenId: _screenId,
      phones: () => phones,
      actions: actions,
      clock: () => now,
      random: Random(3),
    );
  });

  /// What the phone posts to /v1/open for [nonce], with [key] (its link key by default)
  Map<String, Object?> openBody(String nonce, {String phoneId = _phoneId, List<int>? key, List<int>? phoneNonce}) {
    final np = phoneNonce ?? pairingRandomBytes(playLinkNonceBytes, Random(seed++));
    final transcript = playLinkTranscript(
      screenId: _screenId,
      phoneId: phoneId,
      screenNonce: pairingDecodeBase64(nonce)!,
      phoneNonce: np,
    );
    return {
      'v': 1,
      'phone': phoneId,
      'ns': nonce,
      'np': pairingBase64(np),
      'proof': pairingBase64(
        playLinkProof(
          key: key ?? phones.firstWhere((peer) => peer.id == phoneId).key,
          role: PlayLinkRole.phone,
          transcript: transcript,
        ),
      ),
    };
  }

  /// A session of [phoneId] opened as the phone opens it, the screen's proof checked
  PlayLinkChannel connect({String phoneId = _phoneId}) {
    final hello = session.hello();
    expect(hello.status, 200);
    expect(hello.body['id'], _screenId);
    final nonce = hello.body['n']! as String;
    final body = openBody(nonce, phoneId: phoneId);
    final opened = session.open(body);
    expect(opened.status, 200);
    final key = phones.firstWhere((peer) => peer.id == phoneId).key;
    final transcript = playLinkTranscript(
      screenId: _screenId,
      phoneId: phoneId,
      screenNonce: pairingDecodeBase64(nonce)!,
      phoneNonce: pairingDecodeBase64(body['np'])!,
    );
    expect(
      pairingSameBytes(
        pairingDecodeBase64(opened.body['proof'])!,
        playLinkProof(key: key, role: PlayLinkRole.screen, transcript: transcript),
      ),
      isTrue,
    );
    final channel = PlayLinkChannel(
      transcript: transcript,
      keys: derivePlayLinkKeys(key: key, transcript: transcript),
      sends: PairingDirection.up,
    );
    expect(opened.body['s'], channel.handle);
    return channel;
  }

  Future<PlayLinkAnswer> raw(PlayLinkChannel channel, Map<String, Object?> message) =>
      session.command(channel.seal(message));

  Future<Map<String, Object?>> send(PlayLinkChannel channel, Map<String, Object?> message) async {
    final answer = await raw(channel, message);
    expect(answer.status, 200, reason: '${answer.body}');
    return channel.open(answer.body)!;
  }

  group('opening a session', () {
    test('a nonce opens one session, once', () {
      final hello = session.hello();
      final nonce = hello.body['n']! as String;
      expect(pairingDecodeBase64(nonce), hasLength(playLinkNonceBytes));
      expect(session.open(openBody(nonce)).status, 200);
      final again = session.open(openBody(nonce));
      expect(again.status, 403);
      expect(again.body['error'], 'nonce');
      expect(session.sessionCount, 1);
    });

    test('a nonce is dead 30 s after it was given', () {
      final nonce = session.hello().body['n']! as String;
      now = now.add(ScreenPlayerSession.nonceLifetime);
      expect(session.open(openBody(nonce)).status, 403);
      final fresh = session.hello().body['n']! as String;
      now = now.add(const Duration(seconds: 29));
      expect(session.open(openBody(fresh)).status, 200);
    });

    test('a phone that is not linked, or a wrong proof, gets 403 and uses the nonce up', () {
      final nonce = session.hello().body['n']! as String;
      final stranger = openBody(nonce, phoneId: 'aaaaaaaaaaaaaaaa', key: List.filled(32, 7));
      final refused = session.open(stranger);
      expect(refused.status, 403);
      expect(refused.body['error'], 'unknown');
      // The nonce went with it
      expect(session.open(openBody(nonce)).status, 403);

      final other = session.hello().body['n']! as String;
      final wrong = session.open(openBody(other, key: List.filled(32, 8)));
      expect(wrong.status, 403);
      expect(wrong.body['error'], 'proof');
      expect(session.open(openBody(other)).status, 403);
      expect(session.sessionCount, 0);
    });

    test('a body that is not an open is 400', () {
      final nonce = session.hello().body['n']! as String;
      expect(session.open({'v': 1, 'phone': 'nope', 'ns': nonce, 'np': 'x', 'proof': 'y'}).status, 400);
      expect(session.open({...openBody(nonce), 'np': pairingBase64(Uint8List(8))}).status, 400);
    });

    test('only the latest nonces are kept', () {
      final first = session.hello().body['n']! as String;
      for (var i = 0; i < ScreenPlayerSession.maxNonces; i++) {
        session.hello();
      }
      expect(session.open(openBody(first)).status, 403);
    });
  });

  group('commands', () {
    test('play opens the item named for the phone, and the answer tells the state', () async {
      final channel = connect();
      final answer = await send(channel, {
        'type': 'play',
        ...const PlayItem(
          server: 'ABCDEF0123456789',
          item: '4242',
          title: 'A film',
          offsetMs: 61000,
          audio: PlayTrackChoice(language: 'fr'),
          subtitle: PlayTrackChoice(off: true),
        ).toJson(),
      });
      expect(answer['status'], 'ok');
      expect(actions.played!.server, 'abcdef0123456789');
      expect(actions.played!.item, '4242');
      expect(actions.played!.offsetMs, 61000);
      expect(actions.played!.audio!.language, 'fr');
      expect(actions.played!.subtitle!.off, isTrue);
      expect(actions.playedFrom!.id, _phoneId);
      final state = ScreenPlayState.fromJson(answer['state']);
      expect(state.phase, ScreenPlayPhase.opening);
      expect(state.from, 'Galaxy S24+');
    });

    test('an item that is no Plex rating key is refused before the player hears of it', () async {
      final channel = connect();
      for (final item in [
        {'type': 'play', 'kind': 'plex', 'server': 'abcdef0123456789', 'item': '../1'},
        {'type': 'play', 'kind': 'plex', 'server': 'a b', 'item': '12'},
        {'type': 'play', 'kind': 'immich', 'server': 'abcdef0123456789', 'item': '12'},
      ]) {
        expect((await send(channel, item))['status'], 'invalid');
      }
      expect(actions.calls, isEmpty);
    });

    test('pause, resume, seek, the tracks and stop go to the player', () async {
      final channel = connect();
      await send(channel, {'type': 'pause'});
      await send(channel, {'type': 'resume'});
      await send(channel, {'type': 'seek', 'positionMs': 90000});
      await send(channel, {'type': 'track', 'kind': 'audio', 'id': '2'});
      await send(channel, {'type': 'track', 'kind': 'subtitle', 'id': null});
      await send(channel, {'type': 'stop'});
      expect(actions.calls, ['pause', 'resume', 'seek 90000', 'track audio 2', 'track subtitle null', 'stop']);
      expect((await send(channel, {'type': 'seek', 'positionMs': -1}))['status'], 'invalid');
      expect((await send(channel, {'type': 'track', 'kind': 'audio', 'id': null}))['status'], 'invalid');
      expect((await send(channel, {'type': 'track', 'kind': 'video', 'id': '1'}))['status'], 'invalid');
      expect((await send(channel, {'type': 'dance'}))['status'], 'unknown');
      expect(actions.calls, hasLength(6));
    });

    test('a replayed or changed command is 400, a session the screen does not know 410', () async {
      final channel = connect();
      final envelope = channel.seal({'type': 'pause'});
      expect((await session.command(envelope)).status, 200);
      expect((await session.command(envelope)).status, 400);
      expect(
        (await session.command({
          ...channel.seal({'type': 'pause'}),
          'c': 'AAAA',
        })).status,
        400,
      );
      expect(
        (await session.command({
          ...channel.seal({'type': 'pause'}),
          's': 'AAAAAAAAAAA',
        })).status,
        410,
      );
      expect(actions.calls, ['pause']);
    });

    test('bye ends the session, with an answer under its keys', () async {
      final channel = connect();
      final answer = await send(channel, {'type': 'bye'});
      expect(answer['status'], 'ok');
      expect(session.sessionCount, 0);
      expect((await raw(channel, {'type': 'pause'})).status, 410);
    });
  });

  group('status', () {
    test('a state past the one the phone has comes at once', () async {
      final channel = connect();
      actions.set(actions.state.next(phase: ScreenPlayPhase.playing, positionMs: 1000));
      final watch = Stopwatch()..start();
      final answer = await send(channel, {'type': 'status', 'after': 0, 'waitMs': 5000});
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      final state = ScreenPlayState.fromJson(answer['state']);
      expect(state.seq, 1);
      expect(state.phase, ScreenPlayPhase.playing);
      expect(state.positionMs, 1000);
    });

    test('the long poll waits for the next state', () async {
      final channel = connect();
      actions.set(actions.state.next(phase: ScreenPlayPhase.playing));
      final pending = send(channel, {'type': 'status', 'after': 1, 'waitMs': 5000});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      actions.set(actions.state.next(phase: ScreenPlayPhase.paused, positionMs: 2000));
      final state = ScreenPlayState.fromJson((await pending)['state']);
      expect(state.seq, 2);
      expect(state.phase, ScreenPlayPhase.paused);
    });

    test('with no change it ends with the state as it is', () async {
      final channel = connect();
      actions.set(actions.state.next(phase: ScreenPlayPhase.playing));
      final watch = Stopwatch()..start();
      final state = ScreenPlayState.fromJson(
        (await send(channel, {'type': 'status', 'after': 1, 'waitMs': 150}))['state'],
      );
      expect(watch.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 140)));
      expect(state.seq, 1);
    });
  });

  group('sessions', () {
    test('a phone removed from the list loses its sessions, the other keeps its own', () async {
      final mine = connect();
      final other = connect(phoneId: _otherPhoneId);
      session.forgetPhone(_phoneId);
      expect((await raw(mine, {'type': 'pause'})).status, 410);
      expect((await raw(other, {'type': 'pause'})).status, 200);
    });

    test('a phone gone from the list meanwhile gets 410 at its next command', () async {
      final channel = connect();
      phones = [phones.last];
      expect((await raw(channel, {'type': 'pause'})).status, 410);
      expect(session.sessionCount, 0);
    });

    test('past the most sessions, the least recently used one ends', () async {
      final channels = <PlayLinkChannel>[];
      for (var i = 0; i < ScreenPlayerSession.maxSessions; i++) {
        channels.add(connect());
        now = now.add(const Duration(seconds: 1));
      }
      // The first one is used again: the second is now the oldest
      await send(channels.first, {'type': 'pause'});
      now = now.add(const Duration(seconds: 1));
      final last = connect();
      expect(session.sessionCount, ScreenPlayerSession.maxSessions);
      expect((await raw(channels[1], {'type': 'pause'})).status, 410);
      expect((await raw(channels.first, {'type': 'pause'})).status, 200);
      expect((await raw(last, {'type': 'pause'})).status, 200);
    });

    test('a session unused for 15 minutes ends', () async {
      final channel = connect();
      now = now.add(ScreenPlayerSession.sessionIdle);
      expect((await raw(channel, {'type': 'pause'})).status, 410);
    });
  });

  group('handover', () {
    /// The phone's side: its hello, and the handover its answer gives
    Future<PlayHandover> start(PlayLinkChannel channel, {int keySeed = 5}) async {
      final own = PairingKeyPair.generate(Random(keySeed));
      final answer = await send(channel, {
        'type': 'handoverHello',
        'pk': pairingBase64(own.publicKey),
        'serverName': 'Plex at home',
      });
      expect(answer['status'], 'ok');
      return PlayHandover.of(own: own, peerKey: pairingDecodeBase64(answer['pk'])!, isPhone: true, session: channel)!;
    }

    Map<String, Object?> serverMessage(PlayHandover handover, {String token = 'plex-token-1234'}) => {
      'type': 'handoverServer',
      'h': handover.channel(isPhone: true).seal({'server': _server.toJson(), 'token': token}),
    };

    test('accepted on the screen, the server and its token are added', () async {
      final channel = connect();
      actions.handoverAnswer = Completer<bool>();
      final handover = await start(channel);
      expect(actions.asked!.check, handover.check);
      expect(actions.asked!.server, 'Plex at home');
      expect(actions.asked!.from.id, _phoneId);
      final pending = send(channel, serverMessage(handover));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Nothing is added before the user of the screen accepts
      expect(actions.added, isEmpty);
      actions.handoverAnswer!.complete(true);
      final answer = await pending;
      expect(answer['status'], 'added');
      final (server, token) = actions.added.single;
      expect(server.machineIdentifier, 'abcdef0123456789');
      expect(server.hash, _server.hash);
      expect(server.host, '192.168.1.20');
      expect(server.port, 32400);
      expect(token, 'plex-token-1234');
    });

    test('the result of the check of the server goes back', () async {
      final channel = connect();
      actions.addResult = HandoverResult.tokenRefused;
      final handover = await start(channel);
      expect((await send(channel, serverMessage(handover)))['status'], 'tokenRefused');
    });

    test('declined, nothing is added and the token is never opened', () async {
      final channel = connect();
      actions.acceptHandover = false;
      final handover = await start(channel);
      // An envelope that cannot open: declined rather than failed shows that the answer of the user came first
      final answer = await send(channel, {
        'type': 'handoverServer',
        'h': {'v': 1, 'h': 'x', 'n': 'AAAA', 'c': 'AAAA'},
      });
      expect(answer['status'], 'declined');
      expect(actions.added, isEmpty);
      // And a proper envelope after that: the handover is used up
      expect((await send(channel, serverMessage(handover)))['status'], 'failed');
      expect(actions.added, isEmpty);
    });

    test('a token sealed for another handover does not open', () async {
      final channel = connect();
      final other = PlayHandover.of(
        own: PairingKeyPair.generate(Random(77)),
        peerKey: PairingKeyPair.generate(Random(78)).publicKey,
        isPhone: true,
        session: channel,
      )!;
      await start(channel);
      expect((await send(channel, serverMessage(other)))['status'], 'failed');
      expect(actions.added, isEmpty);
    });

    test('one handover at a time per session, and none without a hello', () async {
      final channel = connect();
      actions.handoverAnswer = Completer<bool>();
      await start(channel);
      final second = await send(channel, {
        'type': 'handoverHello',
        'pk': pairingBase64(PairingKeyPair.generate(Random(6)).publicKey),
        'serverName': 'Plex at home',
      });
      expect(second['status'], 'busy');

      // Another phone has its own session, and its handover is answered at once
      actions.handoverAnswer = null;
      final fresh = connect(phoneId: _otherPhoneId);
      final handover = await start(fresh, keySeed: 8);
      expect((await send(fresh, serverMessage(handover)))['status'], 'added');
      expect((await send(fresh, serverMessage(handover)))['status'], 'failed');
      final none = connect(phoneId: _otherPhoneId);
      expect((await send(none, serverMessage(handover)))['status'], 'failed');
    });

    test('a hello with a bad key or no server name is invalid', () async {
      final channel = connect();
      expect((await send(channel, {'type': 'handoverHello', 'pk': 'AAAA', 'serverName': 'x'}))['status'], 'invalid');
      expect(
        (await send(channel, {
          'type': 'handoverHello',
          'pk': pairingBase64(PairingKeyPair.generate(Random(6)).publicKey),
        }))['status'],
        'invalid',
      );
      expect(actions.asked, isNull);
    });

    test('the question on the screen is cancelled when the phone is removed', () async {
      final channel = connect();
      actions.handoverAnswer = Completer<bool>();
      await start(channel);
      var cancelled = false;
      unawaited(actions.handoverCancel!.then((_) => cancelled = true));
      session.forgetPhone(_phoneId);
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, isTrue);
    });
  });
}
