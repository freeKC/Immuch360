// "Play on..." from the phone with both ends in process: the real RemotePlaybackController and PlayLinkClient of the
// phone, the real PlayLinkServer and ScreenPlayerSession of the screen on the loopback, and a fake player behind them.
// The loopback stands for the screen's LAN address (192.168.1.20): the client refuses anything but a private IPv4.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/infrastructure/network/play_on_screen/play_link_client.dart';
import 'package:immich_mobile/infrastructure/network/play_on_screen/play_link_server.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';

const _screenId = '0123456789abcdef';
const _phoneId = 'fedcba9876543210';
const _machine = 'abcdef0123456789abcdef0123456789abcdef01';
const _token = 'PLEX-TOKEN-OF-THE-PHONE';

/// The player of the screen: what the commands did, and a state the test moves
class _FakeActions implements ScreenPlayerActions {
  final _states = StreamController<ScreenPlayState>.broadcast();
  ScreenPlayState _state = const ScreenPlayState();

  /// What a play ends in: null opens the film, a reason fails it
  ScreenPlayReason? playReason;
  PlayItem? played;
  final seeks = <int>[];
  final tracks = <(PlayTrackKind, String?)>[];
  var stops = 0;

  bool acceptHandover = true;

  /// The question of a handover waits for its cancel
  bool waitForCancel = false;
  String? check;
  bool cancelled = false;
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
    final reason = playReason;
    set(
      ScreenPlayState(
        seq: _state.seq + 1,
        phase: reason == null ? ScreenPlayPhase.opening : ScreenPlayPhase.failed,
        server: item.server,
        item: item.item,
        title: item.title,
        from: from.name,
        positionMs: item.offsetMs,
        reason: reason,
      ),
    );
  }

  @override
  Future<void> pause() async => set(_state.next(phase: ScreenPlayPhase.paused));

  @override
  Future<void> resume() async => set(_state.next(phase: ScreenPlayPhase.playing));

  @override
  Future<void> seek(int positionMs) async {
    seeks.add(positionMs);
    set(_state.next(positionMs: positionMs));
  }

  @override
  Future<void> track(PlayTrackKind kind, String? id) async => tracks.add((kind, id));

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
  }) async {
    this.check = check;
    if (waitForCancel) {
      await cancel;
      cancelled = true;
      return false;
    }
    return acceptHandover;
  }

  @override
  Future<HandoverResult> addServer(HandedPlexServer server, String token) async {
    added.add((server, token));
    return HandoverResult.added;
  }
}

LinkedPeer _peer(String id, {String name = 'Peer'}) => LinkedPeer(
  id: id,
  name: name,
  key: Uint8List.fromList(List.filled(playLinkKeyBytes, 7)),
  linkedAt: DateTime.utc(2026, 11, 10),
);

const _request = PlayOnRequest(
  sourceId: 'source-1',
  server: _machine,
  serverName: 'Home Plex',
  ratingKey: '77',
  title: 'Title 77',
  offsetMs: 5000,
  audio: PlayTrackChoice(language: 'fr'),
  subtitle: PlayTrackChoice(off: true),
  path: '/.item/77/Title 77.mkv',
);

final _source = NetworkSource(
  id: 'source-1',
  type: NetworkSourceType.plex,
  name: 'Home Plex',
  host: '192.168.1.30',
  rootPath: '/Movies',
  useTls: true,
  discoveryId: _machine.toUpperCase(),
  plex: const PlexServerInfo(hash: '0123456789abcdef0123456789abcdef'),
);

/// Waits until [condition] holds, a few seconds at most
Future<void> _until(bool Function() condition, {Duration within = const Duration(seconds: 8)}) async {
  final deadline = DateTime.now().add(within);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Not reached within $within');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late _FakeActions actions;
  late ScreenPlayerSession session;
  late PlayLinkServer server;
  late ProviderContainer container;
  late PlayScreenAddress address;
  final screen = _peer(_screenId, name: 'Living room TV');

  setUp(() async {
    actions = _FakeActions();
    session = ScreenPlayerSession(
      screenId: _screenId,
      phones: () => [_peer(_phoneId, name: 'Galaxy S24+')],
      actions: actions,
      random: Random(5),
    );
    server = PlayLinkServer(session: session, preferredPort: 0, requestTimeout: const Duration(seconds: 2));
    address = (host: '192.168.1.20', port: await server.start());
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
            readToken: (sourceId) async => sourceId == 'source-1' ? _token : null,
            learnedPublic: (_) => (host: 'plex.example.org', port: 32443),
          ),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await server.stop();
    session.close();
  });

  RemotePlaybackController controller() => container.read(remotePlaybackProvider.notifier);
  RemotePlayback? playback() => container.read(remotePlaybackProvider);

  test('a play names the film, never a token, and the controller follows the screen by long poll', () async {
    expect(await controller().play(screen, address, _request), PlayOnOutcome.playing);
    expect(actions.played?.server, _machine);
    expect(actions.played?.item, '77');
    expect(actions.played?.offsetMs, 5000);
    expect(actions.played?.audio?.language, 'fr');
    expect(actions.played?.subtitle?.off, isTrue);
    expect(actions.played?.toJson().toString(), isNot(contains(_token)));
    expect(playback()?.screen.id, _screenId);
    expect(playback()?.state.phase, ScreenPlayPhase.opening);

    actions.set(actions.state.next(phase: ScreenPlayPhase.playing, positionMs: 12000, durationMs: 60000));
    await _until(() => playback()?.state.phase == ScreenPlayPhase.playing);
    expect(playback()?.state.positionMs, 12000);
    expect(playback()?.state.durationMs, 60000);
    // The remote of the screen paused it: the phone sees it at the next state
    actions.set(actions.state.next(phase: ScreenPlayPhase.paused));
    await _until(() => playback()?.state.phase == ScreenPlayPhase.paused);
    expect(playback()?.ended, isFalse);
  });

  test('a screen without the server: its row offers the handover, until a play works there', () async {
    actions.playReason = ScreenPlayReason.noSuchServer;
    expect(await controller().play(screen, address, _request), PlayOnOutcome.noSuchServer);
    expect(container.read(screensWithoutServerProvider), {
      _screenId: {_machine},
    });
    expect(playback(), isNull);

    actions.playReason = null;
    expect(await controller().play(screen, address, _request), PlayOnOutcome.playing);
    expect(container.read(screensWithoutServerProvider)[_screenId], isEmpty);
  });

  for (final (reason, outcome) in [
    (ScreenPlayReason.declined, PlayOnOutcome.declined),
    (ScreenPlayReason.tokenRefused, PlayOnOutcome.screenCannotOpen),
    (ScreenPlayReason.unreachable, PlayOnOutcome.screenCannotOpen),
    (ScreenPlayReason.notFound, PlayOnOutcome.notFound),
    (ScreenPlayReason.failed, PlayOnOutcome.failed),
  ]) {
    test('a play the screen answers ${reason.wire} is ${outcome.name}, and no controller shows', () async {
      actions.playReason = reason;
      expect(await controller().play(screen, address, _request), outcome);
      expect(playback(), isNull);
    });
  }

  test('a screen that does not know this phone, or that is not there', () async {
    final stranger = LinkedPeer(
      id: _screenId,
      name: 'Living room TV',
      key: Uint8List.fromList(List.filled(playLinkKeyBytes, 8)),
      linkedAt: DateTime.utc(2026, 11, 10),
    );
    expect(await controller().play(stranger, address, _request), PlayOnOutcome.notLinked);
    final port = address.port;
    await server.stop();
    expect(await controller().play(screen, (host: '192.168.1.20', port: port), _request), PlayOnOutcome.unreachable);
  });

  test('pause, resume, seek clamped to the film, tracks, stop at the position the screen told', () async {
    await controller().play(screen, address, _request);
    actions.set(actions.state.next(phase: ScreenPlayPhase.playing, positionMs: 5000, durationMs: 60000));
    await _until(() => playback()?.state.phase == ScreenPlayPhase.playing);

    await controller().pause();
    expect(playback()?.state.phase, ScreenPlayPhase.paused, reason: 'the answer carries the state at once');
    await controller().resume();
    expect(playback()?.state.phase, ScreenPlayPhase.playing);

    await controller().seekBy(const Duration(seconds: -10));
    expect(actions.seeks.last, 0);
    actions.set(actions.state.next(positionMs: 50000));
    await _until(() => playback()?.state.positionMs == 50000);
    await controller().seekBy(const Duration(seconds: 30));
    expect(actions.seeks.last, 60000);
    await controller().seekBy(const Duration(seconds: -10));
    expect(actions.seeks.last, 50000);

    await controller().track(PlayTrackKind.audio, '1.0');
    await controller().track(PlayTrackKind.subtitle, null);
    expect(actions.tracks, [(PlayTrackKind.audio, '1.0'), (PlayTrackKind.subtitle, null)]);

    expect(await controller().stop(), const Duration(milliseconds: 50000));
    expect(actions.stops, 1);
    expect(playback(), isNull);
  });

  test('another phone playing something else there ends this controller', () async {
    await controller().play(screen, address, _request);
    actions.set(
      ScreenPlayState(seq: actions.state.seq + 1, phase: ScreenPlayPhase.playing, server: _machine, item: '78'),
    );
    await _until(() => playback() == null);
  });

  test('a command to a screen that went says it no longer answers, and the bar may close', () async {
    await controller().play(screen, address, _request);
    await server.stop();
    await controller().pause();
    expect(playback()?.lost, isTrue);
    controller().dismiss();
    expect(playback(), isNull);
  });

  test('the long poll of a screen that went says so after a few tries', () async {
    await controller().play(screen, address, _request);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await server.stop();
    await _until(() => playback()?.lost ?? false, within: const Duration(seconds: 15));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('the request of a film: its Plex server by machine identifier, never for another kind of share', () {
    final film = PlayOnRequest.ofItem(source: _source, ratingKey: '77', title: 'Title 77', offsetMs: 4200, path: '/a');
    expect(film?.sourceId, 'source-1');
    expect(film?.server, _machine, reason: 'the machine identifier in lower case, as the screen matches it');
    expect(film?.serverName, 'Home Plex');
    expect(film?.item.toJson(), {
      'kind': 'plex',
      'server': _machine,
      'item': '77',
      'serverName': 'Home Plex',
      'title': 'Title 77',
      'offsetMs': 4200,
    });
    expect(film?.path, '/a');
    expect(PlayOnRequest.ofItem(source: _source, ratingKey: '77', offsetMs: -5)?.offsetMs, 0);
    expect(PlayOnRequest.ofItem(source: _source, ratingKey: ''), isNull);
    expect(PlayOnRequest.ofItem(source: null, ratingKey: '77'), isNull);
    const share = NetworkSource(
      id: 'source-2',
      type: NetworkSourceType.smb,
      name: 'NAS',
      host: '192.168.1.31',
      discoveryId: _machine,
    );
    expect(PlayOnRequest.ofItem(source: share, ratingKey: '77'), isNull);
    const unknown = NetworkSource(id: 'source-3', type: NetworkSourceType.plex, name: 'Plex', host: '192.168.1.32');
    expect(PlayOnRequest.ofItem(source: unknown, ratingKey: '77'), isNull);
  });

  group('Add (server) to (screen)', () {
    test('both users accept: the server and the phone token reach the screen, the same check on both', () async {
      container.read(screensWithoutServerProvider.notifier).state = {
        _screenId: {_machine},
      };
      String? shown;
      var sent = false;
      final result = await controller().addServer(
        screen,
        address,
        _source,
        confirm: (check) async {
          shown = check;
          return true;
        },
        onSent: () => sent = true,
      );
      expect(result, HandoverResult.added);
      expect(sent, isTrue);
      expect(shown, matches(RegExp(r'^[0-9]{6}$')));
      expect(actions.check, shown, reason: 'the screen shows the number the phone shows');
      final (handed, token) = actions.added.single;
      expect(token, _token);
      expect(handed.name, 'Home Plex');
      expect(handed.machineIdentifier, _machine);
      expect(handed.hash, '0123456789abcdef0123456789abcdef');
      expect(handed.host, '192.168.1.30');
      expect(handed.port, isNull);
      expect(handed.publicHost, 'plex.example.org');
      expect(handed.publicPort, 32443);
      expect(handed.rootPath, '/Movies');
      expect(container.read(screensWithoutServerProvider)[_screenId], isEmpty);
    });

    test('the user of the screen says Not now: declined, nothing added', () async {
      actions.acceptHandover = false;
      final result = await controller().addServer(screen, address, _source, confirm: (_) async => true);
      expect(result, HandoverResult.declined);
      expect(actions.added, isEmpty);
    });

    test('cancelled on the phone: no token leaves it, and the question goes from the screen', () async {
      actions.waitForCancel = true;
      final result = await controller().addServer(screen, address, _source, confirm: (_) async => false);
      expect(result, isNull);
      await _until(() => actions.cancelled);
      expect(actions.added, isEmpty);
    });

    test('a source without its token or its certificate moves nothing', () async {
      const noToken = NetworkSource(
        id: 'source-2',
        type: NetworkSourceType.plex,
        name: 'Other',
        host: '192.168.1.31',
        useTls: true,
        discoveryId: _machine,
        plex: PlexServerInfo(hash: '0123456789abcdef0123456789abcdef'),
      );
      var asked = false;
      expect(
        await controller().addServer(
          screen,
          address,
          noToken,
          confirm: (_) async {
            asked = true;
            return true;
          },
        ),
        HandoverResult.failed,
      );
      expect(asked, isFalse);
      expect(actions.check, isNull, reason: 'no hello went to the screen');
    });

    test('a screen that is not there', () async {
      final port = address.port;
      await server.stop();
      expect(
        await controller().addServer(screen, (host: '192.168.1.20', port: port), _source, confirm: (_) async => true),
        HandoverResult.unreachable,
      );
    });
  });
}
