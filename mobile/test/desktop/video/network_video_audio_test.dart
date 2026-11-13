// The notice of the network video page when libmpv plays another audio track than the film's default one, or none
// (release 47, the desktop Plex validation of 13 November 2026: La Bataille de Gaulle played silent on its TrueHD
// track, with no word). The computers' libmpv decodes TrueHD since the 20261113-2 releases: the tests give the player
// the missing codecs of the Quest's libmpv, the one that still lacks TrueHD.

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
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
import 'fake_playback_engine.dart';

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
  final missing = MediaKitVideoPlayerController.missingAudioCodecs;

  // The app's resolver of a video on a computer reads the Store of the app
  setUpAll(() async {
    final appDb = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(appDb), listenUpdates: false);
  });

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [_source]));
    share = MemoryShare(
      _source,
      files: {
        '/film.mkv': mp4File(mp4Moov([mp4VideoTrack(const [])])),
      },
    );
    calls = [];
    // A libmpv without TrueHD (the Quest's)
    MediaKitVideoPlayerController.missingAudioCodecs = const {'truehd', 'mlp'};
    MediaKitVideoPlayerController.preferredAudioLanguage = null;
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
    desktopPlayerPool = null;
    desktopVideoAvailable = false;
    MediaKitVideoPlayerController.missingAudioCodecs = missing;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      null,
    );
    await store.dispose();
    await db.close();
  });

  /// The page of a film on a computer, with libmpv as its player, and the player
  Future<FakePlaybackEngine> pumpFilm(WidgetTester tester) async {
    // A computer, its players those of the test
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final players = FakePlayers(onCreate: (engine) => engine.autoLoad = const Duration(minutes: 90));
    desktopPlayerPool = players.pool;
    desktopVideoAvailable = true;
    await pumpNetworkRouter(
      tester,
      home: NetworkVideoPage(sourceId: _source.id, path: '/film.mkv'),
      settle: false,
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        overrideConnections((ref) => FakeConnections(ref, share)),
        appConfigProvider.overrideWithValue(const AppConfig()),
        isHorizonOsProvider.overrideWith((ref) async => false),
        panorama360VideoSupportedProvider.overrideWithValue(false),
        networkMediaServiceProvider.overrideWith((ref) => _NoDetection()),
        videoPlayerProvider('network:nas:/film.mkv').overrideWith((ref) => _RecordingPlayer(calls)),
      ],
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    for (var i = 0; i < 20 && players.made.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return players.made.single;
  }

  testWidgets('a TrueHD track gives its place to AC3, and the page says so', (tester) async {
    final engine = await pumpFilm(tester);
    engine.audioTrack.value = '1';
    engine.audioTracks.value = const [
      DesktopAudioTrack(id: '1', title: 'French TrueHD 7.1', language: 'fre', channels: 8, codec: 'truehd'),
      DesktopAudioTrack(id: '2', title: 'French AC3 5.1', language: 'fre', channels: 6, codec: 'ac3'),
    ];
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(engine.calls, contains('audio 2'));
    expect(find.byKey(const Key('film_audio_switched')), findsOneWidget);
    expect(find.textContaining('Audio: French AC3 5.1'), findsOneWidget);
    expect(find.textContaining('(TrueHD is not playable on this device)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a film with TrueHD only: the page says it has no sound this device can play', (tester) async {
    final engine = await pumpFilm(tester);
    engine.audioTrack.value = '1';
    engine.audioTracks.value = const [
      DesktopAudioTrack(id: '1', language: 'fre', channels: 8, codec: 'truehd', isDefault: true),
    ];
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('film_audio_none')), findsOneWidget);
    expect(find.text('This film has no sound this device can play'), findsOneWidget);
    expect(find.text('Let the server convert it'), findsNothing, reason: 'no conversion on the computers');
    await tester.pump(const Duration(seconds: 10));
    debugDefaultTargetPlatformOverride = null;
  });
}
