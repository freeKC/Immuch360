import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:immich_mobile/providers/asset_viewer/spatial_video.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';

/// Records how the session gives the viewer's player its video back
class _RecordingVideoPlayer extends VideoPlayerNotifier {
  final calls = <String>[];

  /// Stands for a disposed player, whose dispose would reach the wakelock plugin
  bool gone = false;

  @override
  bool get mounted => !gone && super.mounted;

  @override
  Future<void> resumeAfterExternalPlayerAt(Duration position, {required bool play}) async =>
      calls.add('resume at ${position.inMilliseconds} ${play ? 'playing' : 'paused'}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Drift db;
  late StoreService store;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  group('SpatialLayoutOverrides', () {
    test('has no layout for an asset the user never changed', () {
      expect(SpatialLayoutOverrides(store).get('asset-1'), isNull);
    });

    test('remembers a layout per asset, in the store', () async {
      final overrides = SpatialLayoutOverrides(store);

      await overrides.set('asset-1', SpatialStereoLayout.topBottom);
      await overrides.set('asset-2', SpatialStereoLayout.sideBySideSwapped);
      await overrides.set('asset-1', SpatialStereoLayout.none);

      expect(overrides.get('asset-1'), SpatialStereoLayout.none);
      expect(overrides.get('asset-2'), SpatialStereoLayout.sideBySideSwapped);
      expect(
        store.tryGet(StoreKey.spatialLayoutOverrides),
        '{"asset-2":"sideBySideSwapped","asset-1":"none"}',
        reason: 'the latest choice goes last',
      );

      // Read back from the database, as after a restart
      final restarted = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
      expect(SpatialLayoutOverrides(restarted).get('asset-1'), SpatialStereoLayout.none);
      await restarted.dispose();
    });

    test('forgets a layout', () async {
      final overrides = SpatialLayoutOverrides(store);
      await overrides.set('asset-1', SpatialStereoLayout.topBottom);
      await overrides.set('asset-2', SpatialStereoLayout.sideBySide);

      await overrides.remove('asset-1');
      await overrides.remove('asset-3');

      expect(overrides.get('asset-1'), isNull);
      expect(overrides.get('asset-2'), SpatialStereoLayout.sideBySide);
    });

    test('forgets the oldest choices past its limit', () async {
      final overrides = SpatialLayoutOverrides(store, maxEntries: 2);

      await overrides.set('asset-1', SpatialStereoLayout.topBottom);
      await overrides.set('asset-2', SpatialStereoLayout.sideBySide);
      await overrides.set('asset-1', SpatialStereoLayout.sideBySide);
      await overrides.set('asset-3', SpatialStereoLayout.topBottom);

      expect(overrides.get('asset-2'), isNull);
      expect(overrides.get('asset-1'), SpatialStereoLayout.sideBySide);
      expect(overrides.get('asset-3'), SpatialStereoLayout.topBottom);
    });

    test('ignores a damaged stored value', () async {
      await store.put(StoreKey.spatialLayoutOverrides, 'not json');
      final overrides = SpatialLayoutOverrides(store);

      expect(overrides.get('asset-1'), isNull);
      await overrides.set('asset-1', SpatialStereoLayout.topBottom);
      expect(overrides.get('asset-1'), SpatialStereoLayout.topBottom);
    });
  });

  group('SpatialVideoSession', () {
    late SpatialLayoutOverrides overrides;
    late SpatialVideoSession session;
    late _RecordingVideoPlayer player;

    setUp(() {
      overrides = SpatialLayoutOverrides(store);
      session = SpatialVideoSession(overrides);
      player = _RecordingVideoPlayer();
    });

    test('gives the viewer its video back where the player left it, playing or not', () async {
      for (final wasPlaying in [true, false]) {
        player.calls.clear();
        session.start(
          layoutKey: 'asset-1',
          layout: SpatialStereoLayout.sideBySide,
          guess: SpatialStereoLayout.sideBySide,
          player: player,
        );
        expect(session.isOpen, isTrue);

        session.closed(83500, wasPlaying, SpatialStereoLayout.sideBySide);
        await pumpEventQueue();

        expect(player.calls, ['resume at 83500 ${wasPlaying ? 'playing' : 'paused'}']);
        expect(session.isOpen, isFalse);
      }
    });

    test('remembers the layout the user picked in the player', () async {
      session.start(
        layoutKey: 'asset-1',
        layout: SpatialStereoLayout.auto,
        guess: SpatialStereoLayout.auto,
        player: player,
      );

      session.closed(0, false, SpatialStereoLayout.topBottomSwapped);
      await pumpEventQueue();

      expect(overrides.get('asset-1'), SpatialStereoLayout.topBottomSwapped);
    });

    test('remembers nothing when the layout did not change', () async {
      session.start(
        layoutKey: 'asset-1',
        layout: SpatialStereoLayout.sideBySide,
        guess: SpatialStereoLayout.sideBySide,
        player: player,
      );

      session.closed(0, false, SpatialStereoLayout.sideBySide);
      await pumpEventQueue();

      expect(overrides.get('asset-1'), isNull);
      expect(store.tryGet(StoreKey.spatialLayoutOverrides), isNull);
    });

    test('forgets the layout picked before when the user goes back to Auto, the guess', () async {
      await overrides.set('asset-1', SpatialStereoLayout.sideBySide);
      session.start(
        layoutKey: 'asset-1',
        layout: SpatialStereoLayout.sideBySide,
        guess: SpatialStereoLayout.auto,
        player: player,
      );

      session.closed(0, false, SpatialStereoLayout.auto);
      await pumpEventQueue();

      expect(overrides.get('asset-1'), isNull);
    });

    test('remembers Auto picked over a wrong guess, so that the guess does not come back', () async {
      session.start(
        layoutKey: 'asset-1',
        layout: SpatialStereoLayout.sideBySide,
        guess: SpatialStereoLayout.sideBySide,
        player: player,
      );

      session.closed(0, false, SpatialStereoLayout.auto);
      await pumpEventQueue();

      expect(overrides.get('asset-1'), SpatialStereoLayout.auto);
    });

    test('forgets Auto picked before when the user goes back to the guess', () async {
      await overrides.set('asset-1', SpatialStereoLayout.auto);
      session.start(
        layoutKey: 'asset-1',
        layout: SpatialStereoLayout.auto,
        guess: SpatialStereoLayout.sideBySide,
        player: player,
      );

      session.closed(0, false, SpatialStereoLayout.sideBySide);
      await pumpEventQueue();

      expect(overrides.get('asset-1'), isNull);
    });

    test('ignores a close it did not see open, and a second close', () async {
      session.closed(1000, true, SpatialStereoLayout.topBottom);
      session.start(
        layoutKey: 'asset-1',
        layout: SpatialStereoLayout.auto,
        guess: SpatialStereoLayout.auto,
        player: player,
      );
      session.closed(2000, true, SpatialStereoLayout.auto);
      session.closed(3000, true, SpatialStereoLayout.topBottom);
      await pumpEventQueue();

      expect(player.calls, ['resume at 2000 playing']);
      expect(overrides.get('asset-1'), isNull);
    });

    test('leaves the viewer alone once its player is gone', () async {
      session.start(
        layoutKey: 'asset-1',
        layout: SpatialStereoLayout.auto,
        guess: SpatialStereoLayout.auto,
        player: player,
      );
      player.gone = true;

      session.closed(1000, true, SpatialStereoLayout.sideBySide);
      await pumpEventQueue();

      expect(player.calls, isEmpty);
      expect(overrides.get('asset-1'), SpatialStereoLayout.sideBySide, reason: 'the choice is still remembered');
    });

    test('a cancelled session ignores a late close', () async {
      session.start(
        layoutKey: 'asset-1',
        layout: SpatialStereoLayout.auto,
        guess: SpatialStereoLayout.auto,
        player: player,
      );
      session.cancel();

      session.closed(1000, true, SpatialStereoLayout.sideBySide);
      await pumpEventQueue();

      expect(player.calls, isEmpty);
      expect(overrides.get('asset-1'), isNull);
    });

    test('clamps a negative position to the start', () async {
      session.start(
        layoutKey: 'asset-1',
        layout: SpatialStereoLayout.auto,
        guess: SpatialStereoLayout.auto,
        player: player,
      );

      session.closed(-40, false, SpatialStereoLayout.auto);
      await pumpEventQueue();

      expect(player.calls, ['resume at 0 paused']);
    });
  });

  test('the session provider receives the closed event of the native player', () async {
    final container = ProviderContainer(overrides: [storeServiceProvider.overrideWithValue(store)]);
    final player = _RecordingVideoPlayer();
    container
        .read(spatialVideoSessionProvider)
        .start(layoutKey: 'asset-1', layout: SpatialStereoLayout.auto, guess: SpatialStereoLayout.auto, player: player);

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'dev.flutter.pigeon.immich_mobile.SpatialVideoEvents.closed',
      SpatialVideoEvents.pigeonChannelCodec.encodeMessage(<Object?>[42000, true, SpatialStereoLayout.topBottom]),
      (_) {},
    );
    await pumpEventQueue();

    expect(player.calls, ['resume at 42000 playing']);
    expect(container.read(spatialLayoutOverridesProvider).get('asset-1'), SpatialStereoLayout.topBottom);

    // Disposing the provider unregisters it
    container.dispose();
    ByteData? reply;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'dev.flutter.pigeon.immich_mobile.SpatialVideoEvents.closed',
      SpatialVideoEvents.pigeonChannelCodec.encodeMessage(<Object?>[1000, false, SpatialStereoLayout.auto]),
      (data) => reply = data,
    );
    expect(reply, isNull);
    expect(player.calls, hasLength(1));
  });
}
