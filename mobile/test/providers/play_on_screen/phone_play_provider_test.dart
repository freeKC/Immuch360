// "Play on..." from the phone with both ends in process: the real RemotePlaybackController and PlayLinkClient of the
// phone, the real PlayLinkServer and ScreenPlayerSession of the screen on the loopback, and a fake player behind them.
// The loopback stands for the screen's LAN address (192.168.1.20): the client refuses anything but a private IPv4.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/jellyfin_server_info.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/services/pairing/phone_pairing.service.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/infrastructure/network/play_on_screen/play_link_client.dart';
import 'package:immich_mobile/infrastructure/network/play_on_screen/play_link_server.dart';
import 'package:immich_mobile/providers/pairing/phone_pairing.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/screen_item_openers.dart';

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
        item: item.kind == PlayKind.plex ? item.item : null,
        itemKey: item.item,
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

  /// "Sign (screen) in": whether this screen is signed out, what its sign in ends in, the sessions it got
  bool signedOut = true;
  HandoverResult signInResult = HandoverResult.added;
  final signedInWith = <Map<String, Object?>>[];

  @override
  Future<bool> canBeSignedIn() async => signedOut;

  @override
  Future<HandoverResult> signIn(LinkedPeer from, Map<String, Object?> payload) async {
    signedInWith.add(payload);
    return signInResult;
  }

  @override
  Future<bool> askHandover({
    required LinkedPeer from,
    required String server,
    required String check,
    required Future<void> cancel,
    String? signInAs,
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

/// The sessions of the phone's account on its server
class _Sessions implements PairingSessions {
  final created = <String>[];
  final deleted = <String>[];
  PairingSessionsFailure? failure;

  @override
  Future<({String id, String token})> create({required String deviceType, required String deviceOS}) async {
    if (failure case final failure?) {
      throw PairingSessionsException(failure);
    }
    created.add(deviceType);
    return (id: 'session-${created.length}', token: 'screen-token-${created.length}');
  }

  @override
  Future<void> delete(String id) async => deleted.add(id);

  @override
  Future<List<({String id, DateTime? updatedAt})>> list() async => const [];
}

/// The screens this phone signed in, without the store
class _PairedScreens extends PairedScreensNotifier {
  @override
  List<PairedScreen> build() => const [];

  @override
  Future<void> add(PairedScreen screen) async => state = [screen, ...state];

  @override
  Future<void> remove(String sessionId) async =>
      state = state.where((screen) => screen.sessionId != sessionId).toList();
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
  late _Sessions sessions;
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
    sessions = _Sessions();
    container = ProviderContainer(
      overrides: [
        pairingSessionsProvider.overrideWithValue(sessions),
        playHostResolverProvider.overrideWithValue((host) async => host == 'nas.local' ? '192.168.1.10' : null),
        pairedScreensProvider.overrideWith(_PairedScreens.new),
        phonePairingAccountProvider.overrideWithValue(
          () async => const PhonePairingAccount(
            server: 'https://photos.example.org',
            endpoints: ['http://192.168.1.10:2283', 'https://photos.example.org'],
            headers: {'X-Proxy-Secret': 'never-sent'},
            userName: 'Fred',
            userEmail: 'fred@example.org',
            phoneName: 'Galaxy S24+',
          ),
        ),
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

  group('Sign (screen) in', () {
    test(
      'both users accept: a new session of the account goes to the screen, listed among the screens signed in',
      () async {
        container.read(screensSignedOutProvider.notifier).state = {_screenId};
        String? shown;
        PhonePairingAccount? account;
        final result = await controller().signInScreen(
          screen,
          address,
          confirm: (check, of) async {
            shown = check;
            account = of;
            return true;
          },
        );
        expect(result, ScreenSignInOutcome.signedIn);
        expect(actions.check, shown, reason: 'the screen shows the number the phone shows');
        expect(account?.userName, 'Fred');
        expect(sessions.created, ['Immuch360 on Living room TV']);
        expect(sessions.deleted, isEmpty);
        final payload = actions.signedInWith.single;
        expect(payload['token'], 'screen-token-1');
        expect(payload['sessionId'], 'session-1');
        expect(payload['endpoints'], ['http://192.168.1.10:2283', 'https://photos.example.org']);
        expect(payload.containsKey('headers'), isFalse, reason: 'the custom headers of the phone never go this way');
        expect(container.read(pairedScreensProvider).single.sessionId, 'session-1');
        expect(container.read(screensSignedOutProvider), isEmpty);
      },
    );

    test('the screen says Not now, or cannot reach the server: its session is deleted at once', () async {
      actions.acceptHandover = false;
      expect(
        await controller().signInScreen(screen, address, confirm: (_, _) async => true),
        ScreenSignInOutcome.declined,
      );
      expect(sessions.deleted, ['session-1']);
      expect(actions.signedInWith, isEmpty);
      actions.acceptHandover = true;
      actions.signInResult = HandoverResult.unreachable;
      expect(
        await controller().signInScreen(screen, address, confirm: (_, _) async => true),
        ScreenSignInOutcome.serverUnreachable,
      );
      expect(sessions.deleted, ['session-1', 'session-2']);
      expect(container.read(pairedScreensProvider), isEmpty);
    });

    test('cancelled on the phone: no session is made', () async {
      actions.waitForCancel = true;
      expect(await controller().signInScreen(screen, address, confirm: (_, _) async => false), isNull);
      await _until(() => actions.cancelled);
      expect(sessions.created, isEmpty);
    });

    test('a screen signed in already: nothing asked, no session made', () async {
      actions.signedOut = false;
      var asked = false;
      expect(
        await controller().signInScreen(
          screen,
          address,
          confirm: (_, _) async {
            asked = true;
            return true;
          },
        ),
        ScreenSignInOutcome.alreadySignedIn,
      );
      expect(asked, isFalse);
      expect(sessions.created, isEmpty);
    });

    test('a server too old to make a session for another device', () async {
      sessions.failure = PairingSessionsFailure.serverTooOld;
      expect(
        await controller().signInScreen(screen, address, confirm: (_, _) async => true),
        ScreenSignInOutcome.serverTooOld,
      );
      expect(actions.signedInWith, isEmpty);
    });
  });

  group('Immich', () {
    const asset = '3F2504E0-4F89-11D3-9A0C-0305E82C3301';
    const user = 'a1b2c3d4-0000-4000-8000-00000000abcd';

    RemoteAsset remote({AssetType type = AssetType.image, AssetVisibility visibility = AssetVisibility.timeline}) =>
        RemoteAsset(
          id: asset,
          name: 'IMG_0001.HEIC',
          ownerId: user,
          checksum: 'c',
          type: type,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          visibility: visibility,
          isEdited: false,
          width: 4032,
          height: 3024,
        );

    PlayOnRequest request(BaseAsset of) => PlayOnRequest.ofAsset(
      of,
      userId: user,
      endpoints: const [
        'https://Photos.example.org/api',
        'https://photos.example.org:443/api/',
        'http://192.168.1.10:2283/api',
        'http://10.0.0.2:2283/api',
        'http://10.0.0.3:2283/api',
        'http://10.0.0.4:2283/api',
      ],
      serverName: 'photos.example.org',
    )!;

    test('the request names the asset, the account and four addresses at most, the same address once', () {
      final photo = request(remote());
      final target = photo.target as ImmichPlayTarget;
      expect(photo.kind, PlayKind.immich);
      expect(photo.isPhoto, isTrue);
      expect(target.asset, asset.toLowerCase());
      expect(target.user, user);
      expect(target.endpointHashes, [
        immichEndpointHash('https://photos.example.org'),
        immichEndpointHash('http://192.168.1.10:2283'),
        immichEndpointHash('http://10.0.0.2:2283'),
        immichEndpointHash('http://10.0.0.3:2283'),
      ]);
      expect(jsonEncode(photo.item.toJson()), isNot(contains('photos.example.org')));
      expect(jsonEncode(photo.item.toJson()), isNot(contains('192.168.1.10')));
      expect(photo.immich?.locked, isFalse);
      expect(request(remote(visibility: AssetVisibility.locked)).immich?.locked, isTrue);
      expect(request(remote(type: AssetType.video)).isPhoto, isFalse);
      // A photo on this phone only: nothing a screen could ask its server for
      final local = LocalAsset(
        id: 'local-1',
        name: 'a.jpg',
        type: AssetType.image,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        playbackStyle: AssetPlaybackStyle.image,
        isEdited: false,
      );
      expect(PlayOnRequest.ofAsset(local, userId: user, endpoints: const [], serverName: 'x'), isNull);
    });

    test('a play names the asset, never a token, and the controller follows the photo on the screen', () async {
      final photo = request(remote());
      expect(await controller().play(screen, address, photo), PlayOnOutcome.playing);
      final played = actions.played!;
      expect(played.kind, PlayKind.immich);
      expect((played.target as ImmichPlayTarget).asset, asset.toLowerCase());
      expect(played.toJson().keys.toSet(), {'kind', 'asset', 'user', 'endpointHashes', 'media', 'title', 'offsetMs'});
      expect(playback()?.isOfAsset(asset), isTrue);
      actions.set(actions.state.next(phase: ScreenPlayPhase.showing));
      await _until(() => playback()?.state.phase == ScreenPlayPhase.showing);
      expect(playback()?.ended, isFalse);
    });

    test('a 360° photo carries its projection to the screen, for the screen\'s 360° viewer', () async {
      final pano = PlayOnRequest.ofAsset(
        remote(),
        userId: user,
        endpoints: const [],
        serverName: 'x',
        projection: PlayProjection.equirect,
      )!;
      expect(await controller().play(screen, address, pano), PlayOnOutcome.playing);
      expect(actions.played!.target.projection, PlayProjection.equirect);
      expect(pano.immich!.projection, PlayProjection.equirect);
    });

    test('the next photo sent while the screen shows one takes its place, the controller stays', () async {
      expect(await controller().play(screen, address, request(remote())), PlayOnOutcome.playing);
      final next = PlayOnRequest.ofAsset(
        RemoteAsset(
          id: '00000000-0000-4000-8000-000000000002',
          name: 'b.jpg',
          ownerId: user,
          checksum: 'd',
          type: AssetType.image,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          isEdited: false,
        ),
        userId: user,
        endpoints: const [],
        serverName: 'x',
      )!;
      expect(await controller().play(screen, address, next), PlayOnOutcome.playing);
      actions.set(actions.state.next(phase: ScreenPlayPhase.showing));
      await _until(() => playback()?.state.phase == ScreenPlayPhase.showing);
      expect(playback()?.isOfAsset('00000000-0000-4000-8000-000000000002'), isTrue);
    });

    test('a build 51 screen, which plays Plex films only, asks for an update', () async {
      await server.stop();
      session.close();
      session = ScreenPlayerSession(
        screenId: _screenId,
        phones: () => [_peer(_phoneId, name: 'Galaxy S24+')],
        actions: actions,
        kinds: const {PlayKind.plex},
        random: Random(6),
      );
      server = PlayLinkServer(session: session, preferredPort: 0, requestTimeout: const Duration(seconds: 2));
      final old = (host: '192.168.1.20', port: await server.start());
      expect(await controller().play(screen, old, request(remote())), PlayOnOutcome.needsUpdate);
      expect(actions.played, isNull);
      // A film still plays there
      expect(await controller().play(screen, old, _request), PlayOnOutcome.playing);
    });

    for (final (reason, outcome) in [
      (ScreenPlayReason.notSignedIn, PlayOnOutcome.notSignedIn),
      (ScreenPlayReason.otherAccount, PlayOnOutcome.otherAccount),
      (ScreenPlayReason.otherServer, PlayOnOutcome.otherServer),
      (ScreenPlayReason.notVisible, PlayOnOutcome.notVisible),
      (ScreenPlayReason.locked, PlayOnOutcome.locked),
      (ScreenPlayReason.noSuchSource, PlayOnOutcome.noSuchSource),
    ]) {
      test('a screen that answers ${reason.wire} is ${outcome.name}, and no controller shows', () async {
        actions.playReason = reason;
        expect(await controller().play(screen, address, request(remote())), outcome);
        expect(playback(), isNull);
      });
    }
  });

  group('shares and media servers', () {
    NetworkSource source(
      NetworkSourceType type, {
      String host = 'NAS.local',
      String share = 'Videos',
      String? discoveryId,
      JellyfinServerInfo? jellyfin,
    }) => NetworkSource(
      id: 'share-1',
      type: type,
      name: 'NAS',
      host: host,
      share: share,
      discoveryId: discoveryId,
      jellyfin: jellyfin,
    );

    test('a share known by a host name goes with the address this phone finds for it', () async {
      final byName = PlayOnRequest.ofShareFile(source: source(NetworkSourceType.smb), path: '/a.mp4', photo: false)!;
      expect(await controller().play(screen, address, byName), PlayOnOutcome.playing);
      expect((actions.played!.target as SharePlayTarget).hostAddresses, ['192.168.1.10']);
      final byAddress = PlayOnRequest.ofShareFile(
        source: source(NetworkSourceType.smb, host: '192.168.1.11'),
        path: '/a.mp4',
        photo: false,
      )!;
      expect(await controller().play(screen, address, byAddress), PlayOnOutcome.playing);
      expect((actions.played!.target as SharePlayTarget).hostAddresses, isEmpty, reason: 'the address is the host');
      final unknown = PlayOnRequest.ofShareFile(
        source: source(NetworkSourceType.webdav, host: 'nowhere.local'),
        path: '/a.mp4',
        photo: false,
      )!;
      expect(await controller().play(screen, address, unknown), PlayOnOutcome.playing);
      expect((actions.played!.target as SharePlayTarget).hostAddresses, isEmpty);
    });

    test('a file of a share names the share and the path, never its user or password', () {
      final request = PlayOnRequest.ofShareFile(
        source: source(NetworkSourceType.smb),
        path: '/Holidays/beach.mp4',
        photo: false,
        offsetMs: 4000,
      )!;
      final target = request.target as SharePlayTarget;
      expect(target.type, PlayShareType.smb);
      expect(target.source, 'nas.local/Videos');
      expect(target.path, '/Holidays/beach.mp4');
      expect(request.offsetMs, 4000);
      expect(request.item.toJson().keys, isNot(contains('password')));

      final dlna = PlayOnRequest.ofShareFile(
        source: source(NetworkSourceType.dlna, discoveryId: 'uuid:4d696e69'),
        path: '/0/1/a.jpg',
        photo: true,
        offsetMs: 4000,
      )!;
      expect((dlna.target as SharePlayTarget).source, 'uuid:4d696e69');
      expect(dlna.isPhoto, isTrue);
      expect(dlna.offsetMs, 0);
    });

    test('a Jellyfin or Emby item names the server id and the item id of its path', () {
      final jellyfin = PlayOnRequest.ofShareFile(
        source: source(
          NetworkSourceType.jellyfin,
          discoveryId: 'F00DCAFE',
          jellyfin: const JellyfinServerInfo(serverId: 'f00dcafe', userId: 'u', product: 'emby'),
        ),
        path: '/.items/1234/-/Film.mkv',
        photo: false,
      )!;
      final target = jellyfin.target as MediaServerPlayTarget;
      expect(target.type, PlayMediaServerType.emby);
      expect(target.server, 'f00dcafe');
      expect(target.item, '1234');
      expect(playMediaServerItemOfPath('/Films/Film.mkv'), isNull);
    });

    test('nothing for a folder of this device, or a path that climbs out', () {
      expect(
        PlayOnRequest.ofShareFile(source: source(NetworkSourceType.documentTree), path: '/a.jpg', photo: true),
        isNull,
      );
      expect(
        PlayOnRequest.ofShareFile(source: source(NetworkSourceType.webdav), path: '/../a.jpg', photo: true),
        isNull,
      );
    });

    test('a play of a share file reaches the screen whole', () async {
      final request = PlayOnRequest.ofShareFile(
        source: source(NetworkSourceType.webdav, share: '/dav'),
        path: '/Photos/a.jpg',
        photo: true,
      )!;
      expect(await controller().play(screen, address, request), PlayOnOutcome.playing);
      final played = actions.played!.target as SharePlayTarget;
      expect(played.type, PlayShareType.webdav);
      expect(played.source, 'nas.local/dav');
      expect(played.path, '/Photos/a.jpg');
      expect(played.media, PlayMedia.photo);
    });
  });
}
