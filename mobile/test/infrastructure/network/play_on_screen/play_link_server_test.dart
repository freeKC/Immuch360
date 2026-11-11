import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/infrastructure/network/play_on_screen/play_link_client.dart';
import 'package:immich_mobile/infrastructure/network/play_on_screen/play_link_server.dart';
import 'package:logging/logging.dart';

const _screenId = '0123456789abcdef';
const _phoneId = 'fedcba9876543210';

class _FakeActions implements ScreenPlayerActions {
  final _states = StreamController<ScreenPlayState>.broadcast();
  ScreenPlayState _state = const ScreenPlayState();
  PlayItem? played;
  bool acceptHandover = true;
  String? check;
  final added = <(HandedPlexServer, String)>[];

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
    set(_state.next(phase: ScreenPlayPhase.opening, server: item.server, item: item.item, from: from.name));
  }

  @override
  Future<void> pause() async => set(_state.next(phase: ScreenPlayPhase.paused));

  @override
  Future<void> resume() async => set(_state.next(phase: ScreenPlayPhase.playing));

  @override
  Future<void> seek(int positionMs) async => set(_state.next(positionMs: positionMs));

  @override
  Future<void> track(PlayTrackKind kind, String? id) async {}

  @override
  Future<void> stop() async => set(_state.next(phase: ScreenPlayPhase.idle));

  @override
  Future<bool> askHandover({
    required LinkedPeer from,
    required String server,
    required String check,
    required Future<void> cancel,
  }) async {
    this.check = check;
    return acceptHandover;
  }

  @override
  Future<HandoverResult> addServer(HandedPlexServer server, String token) async {
    added.add((server, token));
    return HandoverResult.added;
  }
}

LinkedPeer _peer(String id, {int keyByte = 7, String name = 'Peer'}) => LinkedPeer(
  id: id,
  name: name,
  key: Uint8List.fromList(List.filled(playLinkKeyBytes, keyByte)),
  linkedAt: DateTime.utc(2026, 11, 10),
);

class _Answer {
  _Answer(this.status, this.body);
  final int status;
  final Uint8List body;
  Map<String, Object?> get json => jsonDecode(utf8.decode(body)) as Map<String, Object?>;
}

void main() {
  late _FakeActions actions;
  late ScreenPlayerSession session;
  late PlayLinkServer server;
  late int port;
  late List<LogRecord> logs;
  late StreamSubscription<LogRecord> logListener;

  // The loopback stands for the screen's LAN address: the client refuses anything but a private IPv4
  PlayLinkClient client({String phoneId = _phoneId}) => PlayLinkClient(
    phoneId: phoneId,
    connectTimeout: const Duration(seconds: 2),
    answerTimeout: const Duration(seconds: 3),
    random: Random(4),
    addressOf: (host, port) => Uri(scheme: 'http', host: host == '192.168.1.20' ? '127.0.0.1' : host, port: port),
  );

  /// The screen as the phone keeps it: its id and the link key
  final screen = _peer(_screenId, name: 'Living room TV');

  setUp(() async {
    actions = _FakeActions();
    session = ScreenPlayerSession(
      screenId: _screenId,
      phones: () => [_peer(_phoneId, name: 'Galaxy S24+')],
      actions: actions,
      random: Random(5),
    );
    server = PlayLinkServer(session: session, preferredPort: 0, requestTimeout: const Duration(seconds: 1));
    port = await server.start();
    logs = [];
    Logger.root.level = Level.ALL;
    logListener = Logger.root.onRecord.listen(logs.add);
  });

  tearDown(() async {
    await logListener.cancel();
    await server.stop();
    session.close();
  });

  Future<_Answer> send(
    String method,
    String path, {
    Object? json,
    List<int>? raw,
    ContentType? type,
    String? host,
  }) async {
    final http = HttpClient();
    try {
      final request = await http.open(method, '127.0.0.1', port, path);
      if (host != null) {
        request.headers.host = host;
      }
      final bytes = raw ?? (json == null ? null : utf8.encode(jsonEncode(json)));
      if (bytes != null) {
        request.headers.contentType = type ?? ContentType.json;
        request.add(bytes);
      }
      final response = await request.close();
      final body = await response.fold<BytesBuilder>(BytesBuilder(), (builder, chunk) => builder..add(chunk));
      return _Answer(response.statusCode, body.takeBytes());
    } finally {
      http.close(force: true);
    }
  }

  test('a linked phone connects, plays and follows the state through the long poll', () async {
    final connection = await client().connect(host: '192.168.1.20', port: port, screen: screen);
    expect(connection.address, '127.0.0.1:$port');
    final played = await connection.command({
      'type': 'play',
      ...const PlayItem(server: 'abcdef0123456789', item: '4242', title: 'A film', offsetMs: 5000).toJson(),
    });
    expect(played.status, 'ok');
    expect(played.state.phase, ScreenPlayPhase.opening);
    expect(played.state.from, 'Galaxy S24+');
    expect(actions.played!.item, '4242');

    final pending = connection.status(after: played.state.seq, wait: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    actions.set(actions.state.next(phase: ScreenPlayPhase.playing, positionMs: 6000, durationMs: 7200000));
    final state = await pending;
    expect(state.seq, played.state.seq + 1);
    expect(state.phase, ScreenPlayPhase.playing);
    expect(state.positionMs, 6000);

    final paused = await connection.command({'type': 'pause'});
    expect(paused.state.phase, ScreenPlayPhase.paused);
    await connection.close();
    expect(session.sessionCount, 0);
    // Nothing of the film in the logs
    expect(logs.map((record) => record.message).join('\n'), isNot(contains('A film')));
  });

  test('a phone with another key, or a screen of another id, gets notLinked', () async {
    await expectLater(
      client().connect(host: '192.168.1.20', port: port, screen: _peer(_screenId, keyByte: 8)),
      throwsA(isA<PlayLinkException>().having((e) => e.failure, 'failure', PlayLinkFailure.notLinked)),
    );
    await expectLater(
      client(phoneId: 'aaaaaaaaaaaaaaaa').connect(host: '192.168.1.20', port: port, screen: screen),
      throwsA(isA<PlayLinkException>().having((e) => e.failure, 'failure', PlayLinkFailure.notLinked)),
    );
    // Another screen answers at the address the phone knew: nothing of the link goes to it
    await expectLater(
      client().connect(host: '192.168.1.20', port: port, screen: _peer('1111111122222222')),
      throwsA(isA<PlayLinkException>().having((e) => e.failure, 'failure', PlayLinkFailure.notLinked)),
    );
    expect(session.sessionCount, 0);
  });

  test('only a private IPv4 address is reached, and a screen that does not answer is unreachable', () async {
    await expectLater(
      client().connect(host: '8.8.8.8', port: port, screen: screen),
      throwsA(isA<PlayLinkException>().having((e) => e.failure, 'failure', PlayLinkFailure.invalid)),
    );
    await server.stop();
    await expectLater(
      client().connect(host: '192.168.1.20', port: port, screen: screen),
      throwsA(isA<PlayLinkException>().having((e) => e.failure, 'failure', PlayLinkFailure.unreachable)),
    );
  });

  test('a session the screen forgot is opened again once', () async {
    final connection = await client().connect(host: '192.168.1.20', port: port, screen: screen);
    session.close();
    expect(session.sessionCount, 0);
    final answer = await connection.command({'type': 'pause'});
    expect(answer.status, 'ok');
    expect(session.sessionCount, 1);
  });

  test('the handover goes end to end, with the same check number on both sides', () async {
    final connection = await client().connect(host: '192.168.1.20', port: port, screen: screen);
    final handover = await PhoneHandover.start(connection, serverName: 'Plex at home', random: Random(12));
    expect(handover.check, actions.check);
    const plex = HandedPlexServer(
      name: 'Plex at home',
      machineIdentifier: 'abcdef0123456789',
      hash: '0123456789abcdef0123456789abcdef',
      host: '192.168.1.30',
    );
    expect(await handover.send(plex, 'plex-token-1234'), HandoverResult.added);
    expect(actions.added.single.$2, 'plex-token-1234');
    expect(actions.added.single.$1.host, '192.168.1.30');
    expect(logs.map((record) => record.message).join('\n'), isNot(contains('plex-token-1234')));

    actions.acceptHandover = false;
    final declined = await PhoneHandover.start(connection, serverName: 'Plex at home', random: Random(13));
    expect(await declined.send(plex, 'plex-token-5678'), HandoverResult.declined);
    expect(actions.added, hasLength(1));
  });

  test('a Host that is no IPv4 literal is refused', () async {
    final answer = await send('GET', '/v1/hello', host: 'evil.example');
    expect(answer.status, HttpStatus.forbidden);
    expect(answer.body, isEmpty);
    expect((await send('GET', '/v1/hello')).status, HttpStatus.ok);
  });

  test('a client outside the local network is refused', () async {
    await server.stop();
    server = PlayLinkServer(session: session, preferredPort: 0, isAllowedClient: (_) => false);
    port = await server.start();
    expect((await send('GET', '/v1/hello')).status, HttpStatus.forbidden);
  });

  test('only JSON posts are read, of 16 KiB at most, and unknown routes are 404', () async {
    final text = await send('POST', '/v1/open', raw: utf8.encode('{"v":1}'), type: ContentType.text);
    expect(text.status, HttpStatus.unsupportedMediaType);
    final large = await send('POST', '/v1/cmd', raw: List.filled(PlayLinkServer.maxBody + 1, 0x20));
    expect(large.status, HttpStatus.requestEntityTooLarge);
    final invalid = await send('POST', '/v1/cmd', json: {'v': 2});
    expect(invalid.status, HttpStatus.badRequest);
    expect((await send('GET', '/v1/open')).status, HttpStatus.methodNotAllowed);
    expect((await send('POST', '/v1/hello', json: {'v': 1})).status, HttpStatus.methodNotAllowed);
    expect((await send('GET', '/p/info')).status, HttpStatus.notFound);
  });

  test('a session that does not exist is 410, which does not count as a failure', () async {
    for (var i = 0; i < PlayLinkServer.maxFailures + 2; i++) {
      final gone = await send('POST', '/v1/cmd', json: {'v': 1, 's': 'AAAAAAAAAAA', 'k': 1, 'c': 'AAAA'});
      expect(gone.status, HttpStatus.gone);
    }
    expect((await send('GET', '/v1/hello')).status, HttpStatus.ok);
  });

  test('ten failures a minute block the address', () async {
    for (var i = 0; i < PlayLinkServer.maxFailures; i++) {
      final nonce = (await send('GET', '/v1/hello')).json['n'];
      final refused = await send(
        'POST',
        '/v1/open',
        json: {'v': 1, 'phone': _phoneId, 'ns': nonce, 'np': 'AAAAAAAAAAAAAAAAAAAAAA', 'proof': 'AAAA'},
      );
      expect(refused.status, HttpStatus.forbidden);
    }
    final blocked = await send('GET', '/v1/hello');
    expect(blocked.status, HttpStatus.tooManyRequests);
    await expectLater(
      client().connect(host: '192.168.1.20', port: port, screen: screen),
      throwsA(isA<PlayLinkException>().having((e) => e.failure, 'failure', PlayLinkFailure.invalid)),
    );
  });
}
