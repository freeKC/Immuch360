// Play from a phone on a big screen: when the receiver listens and announces itself, and what a play does before
// any player opens (a screen without the server, the Quest's question answered Not now), both ends in process.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/network/play_on_screen/play_link_client.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/screen_player_prompts.dart';
import 'package:immich_mobile/providers/play_on_screen/play_links.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/screen_item_openers.dart';
import 'package:immich_mobile/providers/play_on_screen/screen_player.provider.dart';

import '../../test_utils.dart';

class _Secrets implements PlayLinkSecrets {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _Prompts implements ScreenPlayerPrompts {
  bool answer = true;
  final asked = <String>[];
  final toasts = <String>[];

  final askedPhoto = <bool>[];

  @override
  Future<bool> askPlay({required String phone, String? title, bool photo = false}) async {
    asked.add(phone);
    askedPhoto.add(photo);
    return answer;
  }

  @override
  Future<bool> askHandover({
    required String phone,
    required String server,
    required String check,
    required Future<void> cancel,
  }) async => false;

  @override
  void toast({required String from}) => toasts.add(from);
}

const _asset = '3f2504e0-4f89-11d3-9a0c-0305e82c3301';
const _phoneUser = 'a1b2c3d4-0000-4000-8000-00000000abcd';

/// The screen's own Immich server and asset viewer
class _Immich implements ScreenImmichAccess {
  ScreenImmichResolution answer = (asset: null, reason: ScreenPlayReason.notSignedIn);
  final resolved = <ImmichPlayTarget>[];
  final opened = <String>[];
  bool shown = true;

  @override
  Future<ScreenImmichResolution> resolve(ImmichPlayTarget target) async {
    resolved.add(target);
    return answer;
  }

  @override
  PageRouteInfo routeOf(RemoteAsset asset) {
    opened.add(asset.id);
    return const PageRouteInfo('AssetViewerRoute');
  }

  @override
  bool showing(String assetId) => shown && opened.contains(assetId);
}

RemoteAsset _remote({AssetType type = AssetType.image, AssetVisibility visibility = AssetVisibility.timeline}) =>
    RemoteAsset(
      id: _asset,
      name: 'IMG_0001.jpg',
      ownerId: _phoneUser,
      checksum: 'c',
      type: type,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      visibility: visibility,
      isEdited: false,
    );

final _phone = LinkedPeer(
  id: 'aabbccdd00112233',
  name: "Fred's Pixel",
  key: Uint8List.fromList(List.generate(32, (i) => i)),
  linkedAt: DateTime.utc(2026, 11, 10),
);

final _screen = LinkedPeer(
  id: '00112233aabbccdd',
  name: 'Living room TV',
  key: _phone.key,
  linkedAt: DateTime.utc(2026, 11, 10),
);

void main() {
  late Drift db;
  late StreamController<AppLifecycleState> lifecycle;
  late List<(String, int, Map<String, String>)> announced;
  late int stopped;
  late bool bigScreen;
  late PairingScreenKind kind;
  late _Secrets secrets;
  late _Prompts prompts;
  late _Immich immich;
  late List<(String, bool)> routes;
  late int closed;
  late ProviderContainer container;

  setUpAll(() async {
    TestUtils.init();
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db));
  });

  tearDownAll(() => db.close());

  setUp(() async {
    await Store.delete(StoreKey.playFromPhoneOff);
    await Store.delete(StoreKey.playFromPhoneAsk);
    lifecycle = StreamController<AppLifecycleState>.broadcast();
    announced = [];
    stopped = 0;
    bigScreen = true;
    kind = PairingScreenKind.tv;
    secrets = _Secrets();
    prompts = _Prompts();
    immich = _Immich();
    routes = [];
    closed = 0;
    container = ProviderContainer(
      overrides: [
        screenImmichAccessProvider.overrideWithValue(immich),
        screenPlayerOpenProvider.overrideWithValue(
          (route, {required replace}) async => routes.add((route.routeName, replace)),
        ),
        screenPlayerShowsProvider.overrideWithValue((name) => false),
        screenPlayerCloseProvider.overrideWithValue(() async => closed++),
        playLinkSecretsProvider.overrideWithValue(secrets),
        screenPlayerPromptsProvider.overrideWithValue(prompts),
        screenPlayerEnvironmentProvider.overrideWith(
          (ref) => ScreenPlayerEnvironment(
            localAddresses: () async => ['127.0.0.1'],
            publicNetworkOnly: () async => false,
            advertise: (name, port, attributes) async {
              announced.add((name, port, attributes));
              return () async => stopped++;
            },
            networkChanges: () => const Stream.empty(),
            lifecycle: () => lifecycle.stream,
            kind: () async => kind,
            isBigScreen: () async => bigScreen,
            installId: () async => _screen.id,
            deviceName: () async => 'Living room TV',
            preferredPort: 0,
          ),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await lifecycle.close();
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 80));

  Future<ScreenPlayerView> start({bool linked = true}) async {
    if (linked) {
      await container.read(linkedPhonesProvider.notifier).add(_phone);
    }
    container.read(screenPlayerProvider);
    await settle();
    return container.read(screenPlayerProvider);
  }

  Future<PlayLinkConnection> connect(int port) => PlayLinkClient(
    phoneId: _phone.id,
    addressOf: (_, _) => Uri(scheme: 'http', host: '127.0.0.1', port: port),
  ).connect(host: '192.168.1.20', port: port, screen: _screen);

  test('no phone linked: nothing listens nor is announced', () async {
    final view = await start(linked: false);
    expect(view.listening, isFalse);
    expect(announced, isEmpty);
  });

  test('a phone linked on a big screen: it listens and announces kind=player with its id', () async {
    final view = await start();
    expect(view.listening, isTrue);
    expect(announced.single.$3, {'v': '1', 'kind': 'player', 'sk': 'tv', 'id': _screen.id, 'pv': '1'});
    expect(announced.single.$2, view.port);
  });

  test('a phone or a tablet never listens', () async {
    bigScreen = false;
    final view = await start();
    expect(view.listening, isFalse);
  });

  test('the setting off, or the app in the background, stops it; back in front it listens again', () async {
    await start();
    lifecycle.add(AppLifecycleState.paused);
    await settle();
    expect(container.read(screenPlayerProvider).listening, isFalse);
    expect(stopped, 1);
    lifecycle.add(AppLifecycleState.resumed);
    await settle();
    expect(container.read(screenPlayerProvider).listening, isTrue);
    container.read(playFromPhoneEnabledProvider.notifier).state = false;
    await settle();
    expect(container.read(screenPlayerProvider).listening, isFalse);
  });

  test('removing the phone ends its session at once', () async {
    final view = await start();
    final connection = await connect(view.port!);
    expect((await connection.status()).phase, ScreenPlayPhase.idle);
    await container.read(linkedPhonesProvider.notifier).remove(_phone.id);
    await settle();
    // No phone left: the listener stops too
    expect(container.read(screenPlayerProvider).listening, isFalse);
    await expectLater(connection.status(), throwsA(isA<PlayLinkException>()));
  });

  test('a play of a server this screen does not have answers noSuchServer, and opens nothing', () async {
    final view = await start();
    final connection = await connect(view.port!);
    final answer = await connection.command({
      'type': 'play',
      ...const PlayItem(server: '0123456789abcdef0123', item: '42', title: 'A film').toJson(),
    });
    expect(answer.status, 'ok');
    expect(answer.state.phase, ScreenPlayPhase.failed);
    expect(answer.state.reason, ScreenPlayReason.noSuchServer);
    expect(answer.state.from, "Fred's Pixel");
    expect(prompts.asked, isEmpty);
    expect(prompts.toasts, isEmpty);
  });

  test('the Quest asks first: Not now answers declined', () async {
    kind = PairingScreenKind.headset;
    prompts.answer = false;
    final view = await start();
    final connection = await connect(view.port!);
    final answer = await connection.command({
      'type': 'play',
      ...const PlayItem(server: '0123456789abcdef0123', item: '42').toJson(),
    });
    expect(prompts.asked, ["Fred's Pixel"]);
    expect(answer.state.reason, ScreenPlayReason.declined);
  });

  test('a TV asks only with Ask before a phone plays', () async {
    container.read(playFromPhoneAskProvider.notifier).state = true;
    prompts.answer = false;
    final view = await start();
    final connection = await connect(view.port!);
    final answer = await connection.command({
      'type': 'play',
      ...const PlayItem(server: '0123456789abcdef0123', item: '42').toJson(),
    });
    expect(prompts.asked, hasLength(1));
    expect(answer.state.reason, ScreenPlayReason.declined);
  });

  group('Immich', () {
    Map<String, Object?> play({PlayMedia media = PlayMedia.photo, List<String> endpoints = const []}) => {
      'type': 'play',
      ...PlayItem.of(
        ImmichPlayTarget(asset: _asset, user: _phoneUser, endpoints: endpoints, media: media),
        title: 'IMG_0001.jpg',
      ).toJson(),
    };

    test('a photo the screen\'s account sees opens in the asset viewer, and the state says showing', () async {
      immich.answer = (asset: _remote(), reason: null);
      final view = await start();
      final connection = await connect(view.port!);
      final answer = await connection.command(play());
      expect(answer.state.reason, isNull);
      expect(answer.state.itemKey, _asset);
      expect(answer.state.server, 'immich');
      expect(answer.state.item, isNull, reason: 'the 16 characters of build 51 are for Plex rating keys');
      expect(answer.state.media, PlayMedia.photo);
      expect(immich.resolved.single.user, _phoneUser);
      expect(routes.single.$1, 'AssetViewerRoute');
      expect(prompts.toasts, ["Fred's Pixel"]);
      final next = await connection.status(after: answer.state.seq, wait: const Duration(seconds: 2));
      expect(next.phase, ScreenPlayPhase.showing);
    });

    test('Stop closes the viewer the phone opened; Back on the remote ends it too', () async {
      immich.answer = (asset: _remote(), reason: null);
      final view = await start();
      final connection = await connect(view.port!);
      final answer = await connection.command(play());
      final showing = await connection.status(after: answer.state.seq, wait: const Duration(seconds: 2));
      expect(showing.phase, ScreenPlayPhase.showing);
      immich.shown = false;
      final gone = await connection.status(after: showing.seq, wait: const Duration(seconds: 2));
      expect(gone.phase, ScreenPlayPhase.idle);
      expect(closed, 0);

      immich.shown = true;
      await connection.command(play());
      final stopped = await connection.command({'type': 'stop'});
      expect(stopped.state.phase, ScreenPlayPhase.idle);
      expect(closed, 1);
    });

    test('a video: the server\'s word wins over the phone\'s, and the TV prompt says play', () async {
      container.read(playFromPhoneAskProvider.notifier).state = true;
      immich.answer = (asset: _remote(type: AssetType.video), reason: null);
      final view = await start();
      final connection = await connect(view.port!);
      final answer = await connection.command(play(media: PlayMedia.video));
      expect(prompts.askedPhoto, [false]);
      expect(answer.state.media, PlayMedia.video);
      expect(answer.state.phase, ScreenPlayPhase.opening);
    });

    test('each refusal goes back as its reason, and nothing opens', () async {
      final view = await start();
      final connection = await connect(view.port!);
      for (final reason in [
        ScreenPlayReason.notSignedIn,
        ScreenPlayReason.otherAccount,
        ScreenPlayReason.otherServer,
        ScreenPlayReason.notVisible,
        ScreenPlayReason.locked,
        ScreenPlayReason.notFound,
        ScreenPlayReason.unreachable,
      ]) {
        immich.answer = (asset: null, reason: reason);
        final answer = await connection.command(play());
        expect(answer.state.phase, ScreenPlayPhase.failed, reason: reason.wire);
        expect(answer.state.reason, reason);
      }
      expect(routes, isEmpty);
      expect(prompts.toasts, isEmpty);
    });

    test('the refusal sentence: same user, another account at the same address, another server', () {
      const target = ImmichPlayTarget(
        asset: _asset,
        user: _phoneUser,
        endpoints: ['https://photos.example.org', 'http://192.168.1.10:2283'],
      );
      expect(
        immichRefusalReason(screenUser: _phoneUser.toUpperCase(), screenEndpoints: const [], target: target),
        ScreenPlayReason.notFound,
      );
      expect(
        immichRefusalReason(
          screenUser: 'other',
          screenEndpoints: const ['http://192.168.1.10:2283/api'],
          target: target,
        ),
        ScreenPlayReason.otherAccount,
      );
      expect(
        immichRefusalReason(screenUser: 'other', screenEndpoints: const ['https://else.example/api'], target: target),
        ScreenPlayReason.otherServer,
      );
    });

    test('a locked asset never opens on a screen, a hidden one neither; archived ones do', () {
      expect(immichScreenRefusal(_remote(visibility: AssetVisibility.locked)), ScreenPlayReason.locked);
      expect(immichScreenRefusal(_remote(visibility: AssetVisibility.hidden)), ScreenPlayReason.notVisible);
      expect(immichScreenRefusal(_remote(visibility: AssetVisibility.archive)), isNull);
      expect(immichScreenRefusal(_remote()), isNull);
    });
  });

  group('shares and media servers', () {
    test('a share this screen does not have answers noSuchSource', () async {
      final view = await start();
      final connection = await connect(view.port!);
      final answer = await connection.command({
        'type': 'play',
        ...const PlayItem.of(
          SharePlayTarget(type: PlayShareType.smb, source: 'nas.local/videos', path: '/a.mp4'),
        ).toJson(),
      });
      expect(answer.state.reason, ScreenPlayReason.noSuchSource, reason: '${answer.status} ${answer.state.toJson()}');
      final jellyfin = await connection.command({
        'type': 'play',
        ...const PlayItem.of(
          MediaServerPlayTarget(type: PlayMediaServerType.jellyfin, server: 'f00d', item: 'abc'),
        ).toJson(),
      });
      expect(jellyfin.state.reason, ScreenPlayReason.noSuchSource);
      expect(routes, isEmpty);
    });

    test('the identity of a share: the UDN of a DLNA server, else host, port and share', () {
      NetworkSource source(
        NetworkSourceType type, {
        String host = 'NAS.local',
        int? port,
        String share = 'Videos',
        String? id,
      }) => NetworkSource(id: 's', type: type, name: 'n', host: host, port: port, share: share, discoveryId: id);
      expect(playShareSourceKey(source(NetworkSourceType.smb)), 'nas.local/Videos');
      expect(playShareSourceKey(source(NetworkSourceType.webdav, port: 8443, share: '/dav')), 'nas.local:8443/dav');
      expect(playShareSourceKey(source(NetworkSourceType.dlna, id: 'uuid:1234')), 'uuid:1234');
      expect(playShareSourceKey(source(NetworkSourceType.plex)), isNull);
      final sources = [source(NetworkSourceType.smb), source(NetworkSourceType.webdav, share: 'Videos')];
      expect(
        findPlayShareSource(
          sources,
          const SharePlayTarget(type: PlayShareType.webdav, source: 'nas.local/Videos', path: '/a.mp4'),
        )?.type,
        NetworkSourceType.webdav,
      );
    });
  });
}
