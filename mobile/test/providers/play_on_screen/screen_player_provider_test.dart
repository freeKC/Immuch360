// Play from a phone on a big screen: when the receiver listens and announces itself, and what a play does before
// any player opens (a screen without the server, the Quest's question answered Not now), both ends in process.

import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
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

  @override
  Future<bool> askPlay({required String phone, String? title}) async {
    asked.add(phone);
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
    container = ProviderContainer(
      overrides: [
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
}
