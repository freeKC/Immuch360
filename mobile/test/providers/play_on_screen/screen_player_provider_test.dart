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
import 'package:immich_mobile/providers/play_on_screen/screen_native_viewers.dart';
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

  /// What the Quest's user answers to a 360° item
  ScreenSphereChoice? sphereAnswer = ScreenSphereChoice.window;
  final askedSphere = <String>[];

  @override
  Future<ScreenSphereChoice?> askPlaySphere({required String phone, String? title, bool photo = false}) async {
    askedSphere.add(phone);
    return sphereAnswer;
  }

  @override
  Future<bool> askHandover({
    required String phone,
    required String server,
    required String check,
    required Future<void> cancel,
    String? signInAs,
  }) async => false;

  @override
  void toast({required String from}) => toasts.add(from);
}

/// The app's 360° player and immersive viewer, as the sessions that open them know them
class _Native implements ScreenNativeViewers {
  @override
  bool open = false;

  /// On screen, rather than open in the background after Home or the Meta button
  bool inFront = true;
  int closes = 0;

  @override
  Future<NativeViewerPlace> place() async => !open
      ? NativeViewerPlace.none
      : inFront
      ? NativeViewerPlace.front
      : NativeViewerPlace.behind;

  @override
  Future<void> close() async {
    closes++;
    open = false;
  }
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
    // Arguments of their own, as AssetViewerRoute has: the router keeps that very object for the page
    return PageRouteInfo('AssetViewerRoute', args: [asset.id]);
  }

  @override
  bool showing(String assetId) => shown && opened.contains(assetId);

  /// Whether this screen has a 360° view for the asset
  bool sphere = true;
  final sphereOpened = <String>[];

  @override
  PageRouteInfo panoramaRouteOf(RemoteAsset asset) {
    opened.add(asset.id);
    return PageRouteInfo('PanoramaViewerRoute', args: [asset.id, 'panorama']);
  }

  @override
  bool canSphere(RemoteAsset asset) => sphere;

  @override
  void openSphere(RemoteAsset asset) => sphereOpened.add(asset.id);
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
  late _Native native;

  /// The page in front of the router: the last one a play opened, or one the screen's user opened
  late ScreenPlayerFront front;
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
    native = _Native();
    front = (name: 'TabShellRoute', args: null);
    container = ProviderContainer(
      overrides: [
        screenImmichAccessProvider.overrideWithValue(immich),
        screenNativeViewersProvider.overrideWithValue(native),
        // No lookup of the network in the tests
        playHostResolverProvider.overrideWithValue((_) async => null),
        screenPlayerOpenProvider.overrideWithValue((route, {required replace}) async {
          routes.add((route.routeName, replace));
          front = (name: route.routeName, args: route.args);
        }),
        screenPlayerFrontProvider.overrideWithValue(() => front),
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
            nativeViewer: native.place,
            nativeViewerCheck: const Duration(milliseconds: 10),
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

  test(
    'a 360° viewer of the app in front keeps it listening; once it closed without the window back, it stops',
    () async {
      await start();
      native.open = true;
      lifecycle.add(AppLifecycleState.hidden);
      lifecycle.add(AppLifecycleState.paused);
      await settle();
      expect(container.read(screenPlayerProvider).listening, isTrue);
      expect(stopped, 0);
      // Closed, and the window came back: nothing changes
      native.open = false;
      lifecycle.add(AppLifecycleState.resumed);
      await settle();
      expect(container.read(screenPlayerProvider).listening, isTrue);
      // Open again, then closed while the app stays in the background, the window not back
      native.open = true;
      lifecycle.add(AppLifecycleState.paused);
      await settle();
      expect(container.read(screenPlayerProvider).listening, isTrue);
      native.open = false;
      await settle();
      expect(container.read(screenPlayerProvider).listening, isFalse);
      expect(stopped, 1);
      lifecycle.add(AppLifecycleState.resumed);
      await settle();
      expect(container.read(screenPlayerProvider).listening, isTrue);
    },
  );

  test(
    'a 360° viewer sent to the background by Home stays open but stops the listener; back in front, it listens again',
    () async {
      await start();
      native.open = true;
      lifecycle.add(AppLifecycleState.hidden);
      lifecycle.add(AppLifecycleState.paused);
      await settle();
      expect(container.read(screenPlayerProvider).listening, isTrue);
      // Home (Android TV) or the Meta button (Quest) in the viewer: stopped, not destroyed, so still open
      native.inFront = false;
      await settle();
      expect(container.read(screenPlayerProvider).listening, isFalse);
      expect(stopped, 1);
      // Back to the viewer from Recents, the window still stopped under it
      native.inFront = true;
      await settle();
      expect(container.read(screenPlayerProvider).listening, isTrue);
      // The viewer closed and the window came back
      native.open = false;
      lifecycle.add(AppLifecycleState.resumed);
      await settle();
      expect(container.read(screenPlayerProvider).listening, isTrue);
      expect(stopped, 1);
    },
  );

  test('a 360° viewer already in the background when the window stops never keeps the listener up', () async {
    await start();
    native.open = true;
    native.inFront = false;
    lifecycle.add(AppLifecycleState.paused);
    await settle();
    expect(container.read(screenPlayerProvider).listening, isFalse);
    expect(stopped, 1);
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
    Map<String, Object?> play({PlayMedia media = PlayMedia.photo}) => {
      'type': 'play',
      ...PlayItem.of(
        ImmichPlayTarget(asset: _asset, user: _phoneUser, media: media),
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

    test('the next photo of the same phone replaces the one it opened, without asking again nor a new toast', () async {
      kind = PairingScreenKind.headset;
      immich.answer = (asset: _remote(), reason: null);
      final view = await start();
      final connection = await connect(view.port!);
      final first = await connection.command(play());
      await connection.status(after: first.state.seq, wait: const Duration(seconds: 2));
      expect(prompts.asked, hasLength(1));
      expect(prompts.toasts, hasLength(1));

      final second = await connection.command(play());
      expect(second.state.reason, isNull);
      expect(routes.map((route) => route.$2), [false, true], reason: 'the second replaces the page the phone opened');
      expect(prompts.asked, hasLength(1), reason: 'the Quest asked for the first item only');
      expect(prompts.toasts, hasLength(1));

      // Once the screen's user closed it, the next play asks again
      final shown = await connection.status(after: second.state.seq, wait: const Duration(seconds: 2));
      expect(shown.phase, ScreenPlayPhase.showing);
      immich.shown = false;
      final closedByOwner = await connection.status(after: shown.seq, wait: const Duration(seconds: 2));
      expect(closedByOwner.phase, ScreenPlayPhase.idle);
      immich.shown = true;
      front = (name: 'TabShellRoute', args: null);
      await connection.command(play());
      expect(prompts.asked, hasLength(2));
    });

    test('a page the screen\'s user opened stays under a phone\'s play, and Stop does not close it', () async {
      immich.answer = (asset: _remote(), reason: null);
      final view = await start();
      final connection = await connect(view.port!);
      // The TV's owner looks at a photo of their own
      front = (name: 'AssetViewerRoute', args: Object());
      await connection.command(play());
      expect(routes.single, ('AssetViewerRoute', false), reason: 'pushed over the owner\'s photo, not in its place');

      // The phone's page in front: Stop closes it
      await connection.command({'type': 'stop'});
      expect(closed, 1);

      // The owner's page in front again (Back went to it): Stop from the phone leaves it
      await connection.command(play());
      front = (name: 'AssetViewerRoute', args: Object());
      await connection.command({'type': 'stop'});
      expect(closed, 1);
    });

    test('a film\'s player in front is replaced, as build 51 did', () async {
      immich.answer = (asset: _remote(), reason: null);
      final view = await start();
      final connection = await connect(view.port!);
      front = (name: 'NetworkVideoRoute', args: Object());
      await connection.command(play());
      expect(routes.single, ('AssetViewerRoute', true));
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
      final target = ImmichPlayTarget(
        asset: _asset,
        user: _phoneUser,
        endpointHashes: [
          immichEndpointHash('https://photos.example.org')!,
          immichEndpointHash('http://192.168.1.10:2283')!,
        ],
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

  group('360° items', () {
    Map<String, Object?> play({
      PlayMedia media = PlayMedia.photo,
      PlayProjection projection = PlayProjection.equirect,
    }) => {
      'type': 'play',
      ...PlayItem.of(
        ImmichPlayTarget(asset: _asset, user: _phoneUser, media: media, projection: projection),
        title: 'PANO_0001.jpg',
      ).toJson(),
    };

    test('a 360° photo opens in the 360° photo viewer of a TV, which Stop closes', () async {
      immich.answer = (asset: _remote(), reason: null);
      final view = await start();
      final connection = await connect(view.port!);
      final answer = await connection.command(play());
      expect(routes.single.$1, 'PanoramaViewerRoute');
      expect(answer.state.sphere, isTrue);
      final showing = await connection.status(after: answer.state.seq, wait: const Duration(seconds: 2));
      expect(showing.phase, ScreenPlayPhase.showing);
      expect(showing.sphere, isTrue);
      final stopped = await connection.command({'type': 'stop'});
      expect(closed, 1);
      expect(stopped.state.phase, ScreenPlayPhase.idle);
      expect(stopped.state.sphere, isFalse);
    });

    test('the same photo without the hint, or on a screen without a 360° view, opens in the asset viewer', () async {
      immich.answer = (asset: _remote(), reason: null);
      final view = await start();
      final connection = await connect(view.port!);
      final flat = await connection.command(play(projection: PlayProjection.flat));
      expect(routes.last.$1, 'AssetViewerRoute');
      expect(flat.state.sphere, isFalse);
      immich.sphere = false;
      final video = await connection.command(play(media: PlayMedia.video));
      expect(routes.last.$1, 'AssetViewerRoute');
      expect(immich.sphereOpened, isEmpty);
      expect(video.state.sphere, isFalse);
    });

    test('a 360° video on a TV: the asset viewer opens its 360° player; while that plays the phone reads a playing '
        'sphere; the next item closes it first', () async {
      immich.answer = (asset: _remote(type: AssetType.video), reason: null);
      final view = await start();
      final connection = await connect(view.port!);
      final answer = await connection.command(play(media: PlayMedia.video));
      expect(routes.single.$1, 'AssetViewerRoute');
      expect(immich.sphereOpened, [_asset]);
      native.open = true;
      final playing = await connection.status(after: answer.state.seq, wait: const Duration(seconds: 2));
      expect(playing.phase, ScreenPlayPhase.playing);
      expect(playing.sphere, isTrue);
      // The phone's next item: the 360° player goes, the asset viewer the play opened is replaced
      immich.answer = (asset: _remote(), reason: null);
      final next = await connection.command(play(projection: PlayProjection.flat));
      expect(native.closes, 1);
      expect(routes.last, ('AssetViewerRoute', true));
      expect(next.state.sphere, isFalse);
      expect(prompts.toasts, hasLength(1), reason: 'the next item of the same phone shows no new toast');
    });

    test('Stop closes the 360° player first', () async {
      immich.answer = (asset: _remote(type: AssetType.video), reason: null);
      final view = await start();
      final connection = await connect(view.port!);
      await connection.command(play(media: PlayMedia.video));
      native.open = true;
      await connection.command({'type': 'stop'});
      expect(native.closes, 1);
    });

    test('the Quest asks headset or window once for a phone\'s 360° items', () async {
      kind = PairingScreenKind.headset;
      immich.answer = (asset: _remote(), reason: null);
      final view = await start();
      final connection = await connect(view.port!);
      // In the window: the 360° photo viewer of the window
      final answer = await connection.command(play());
      expect(prompts.askedSphere, ["Fred's Pixel"]);
      expect(prompts.asked, isEmpty, reason: 'one question, not two');
      expect(routes.single.$1, 'PanoramaViewerRoute');
      expect(immich.sphereOpened, isEmpty);
      await connection.status(after: answer.state.seq, wait: const Duration(seconds: 2));
      // Its next 360° item: no question again
      await connection.command(play());
      expect(prompts.askedSphere, hasLength(1));
      expect(routes.last, ('PanoramaViewerRoute', true));
    });

    test('In the headset: the asset viewer opens the immersive viewer, for a photo as for a video', () async {
      kind = PairingScreenKind.headset;
      prompts.sphereAnswer = ScreenSphereChoice.headset;
      immich.answer = (asset: _remote(), reason: null);
      final view = await start();
      final connection = await connect(view.port!);
      final answer = await connection.command(play());
      expect(routes.single.$1, 'AssetViewerRoute');
      expect(immich.sphereOpened, [_asset]);
      expect(answer.state.sphere, isTrue);
      prompts.sphereAnswer = null;
      // Not now on a new phone's first item ends it there
      await connection.command({'type': 'stop'});
      final declined = await connection.command(play(media: PlayMedia.video));
      expect(declined.state.reason, ScreenPlayReason.declined);
    });

    test('a flat item of a phone on the Quest asks the usual question, then its first 360° item asks where', () async {
      kind = PairingScreenKind.headset;
      immich.answer = (asset: _remote(), reason: null);
      final view = await start();
      final connection = await connect(view.port!);
      final answer = await connection.command(play(projection: PlayProjection.flat));
      expect(prompts.asked, hasLength(1));
      await connection.status(after: answer.state.seq, wait: const Duration(seconds: 2));
      await connection.command(play());
      expect(prompts.asked, hasLength(1));
      expect(prompts.askedSphere, hasLength(1));
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

    test('a share known by its address on one device and by its name on the other is the same share', () async {
      NetworkSource share(
        String host, {
        String shareName = 'Videos',
        int? port,
        NetworkSourceType type = NetworkSourceType.smb,
      }) => NetworkSource(id: host, type: type, name: 'NAS', host: host, port: port, share: shareName);
      Future<String?> resolve(String host) async => switch (host) {
        'nas.local' => '192.168.1.10',
        'other.local' => '192.168.1.99',
        'outside.example.org' => '203.0.113.5',
        _ => null,
      };
      const byName = SharePlayTarget(type: PlayShareType.smb, source: 'nas.local/Videos', path: '/a.mp4');
      // The screen knows it by its address: the address the phone found, or the one the screen finds for the name
      for (final target in [
        byName.withHostAddresses(['192.168.1.10']),
        byName,
      ]) {
        expect((await matchPlayShareSource([share('192.168.1.10')], target, resolve: resolve))?.id, '192.168.1.10');
      }
      // The phone knows it by its address, the screen by its name
      const byAddress = SharePlayTarget(type: PlayShareType.smb, source: '192.168.1.10/Videos', path: '/a.mp4');
      expect((await matchPlayShareSource([share('NAS.local')], byAddress, resolve: resolve))?.id, 'NAS.local');
      // Another machine, another share, another port, another protocol, an address outside home: none
      expect(await matchPlayShareSource([share('other.local')], byAddress, resolve: resolve), isNull);
      expect(
        await matchPlayShareSource([share('192.168.1.10', shareName: 'Photos')], byName, resolve: resolve),
        isNull,
      );
      expect(await matchPlayShareSource([share('192.168.1.10', port: 4450)], byName, resolve: resolve), isNull);
      expect(
        await matchPlayShareSource([share('192.168.1.10', type: NetworkSourceType.webdav)], byName, resolve: resolve),
        isNull,
      );
      const outside = SharePlayTarget(type: PlayShareType.smb, source: 'outside.example.org/Videos', path: '/a.mp4');
      expect(await matchPlayShareSource([share('203.0.113.5')], outside, resolve: resolve), isNull);
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
