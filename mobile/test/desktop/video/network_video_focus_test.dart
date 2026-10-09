// The video page of a share on a computer, which reports "resumed" each time its window gets the focus back (another
// window, a file dialog, the window minimised and restored) and never "paused" before it: the video the user paused,
// never started or saw to its end stays so. A phone, which goes through "paused", still plays on when it comes back.

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_video.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';

import '../../domain/services/spherical_probe_fixtures.dart';
import '../../presentation/pages/network/network_viewer_fakes.dart';

/// Reads nothing from the file: the page plays it as a flat video
class _NoDetection extends NetworkMediaService {
  @override
  Future<NetworkMediaInfo?> detect(
    NetworkEntry entry,
    ByteRangeReader read, {
    bool thorough = false,
    bool Function()? isWanted,
  }) async => null;
}

/// Records what the page asks of its player, paused at 30 s
class _RecordingPlayer extends VideoPlayerNotifier {
  _RecordingPlayer(this.calls) {
    state = state.copyWith(
      position: const Duration(seconds: 30),
      duration: const Duration(minutes: 2),
      status: VideoPlaybackStatus.paused,
    );
  }

  final List<String> calls;

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');
}

const _source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'Home NAS', host: 'nas', share: 'media');

void main() {
  late Drift db;
  late StoreService store;
  late MemoryShare share;
  late List<String> calls;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [_source]));
    share = MemoryShare(
      _source,
      files: {
        '/clip.mp4': mp4File(mp4Moov([mp4VideoTrack(const [])])),
      },
    );
    calls = [];
    // The native view of the phones: created, with nothing behind it
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async => switch (call.method) {
        'create' => 0,
        'resize' => {'width': (call.arguments as Map)['width'], 'height': (call.arguments as Map)['height']},
        _ => null,
      },
    );
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      null,
    );
    await store.dispose();
    await db.close();
  });

  Future<void> pumpVideo(WidgetTester tester) async {
    await pumpNetworkRouter(
      tester,
      home: NetworkVideoPage(sourceId: _source.id, path: '/clip.mp4'),
      settle: false,
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        overrideConnections((ref) => FakeConnections(ref, share)),
        appConfigProvider.overrideWithValue(const AppConfig()),
        isHorizonOsProvider.overrideWith((ref) async => false),
        panorama360VideoSupportedProvider.overrideWithValue(false),
        networkMediaServiceProvider.overrideWith((ref) => _NoDetection()),
        videoPlayerProvider('network:nas:/clip.mp4').overrideWith((ref) => _RecordingPlayer(calls)),
      ],
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> lifecycle(WidgetTester tester, List<AppLifecycleState> states) async {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
  }

  for (final platform in const [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) {
    testWidgets('${platform.name}: the focus coming back to the window plays nothing', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      await pumpVideo(tester);

      await lifecycle(tester, const [AppLifecycleState.inactive, AppLifecycleState.resumed]);
      await lifecycle(tester, const [AppLifecycleState.inactive, AppLifecycleState.hidden]);
      await lifecycle(tester, const [AppLifecycleState.inactive, AppLifecycleState.resumed]);

      expect(calls, isNot(contains('play')), reason: 'the paused video stays paused');
      await tester.pump(const Duration(seconds: 2));
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('a phone plays on when it comes back to the foreground', (tester) async {
    await pumpVideo(tester);

    await lifecycle(tester, const [AppLifecycleState.inactive, AppLifecycleState.resumed]);

    expect(calls, contains('play'));
    await tester.pump(const Duration(seconds: 2));
  });
}
