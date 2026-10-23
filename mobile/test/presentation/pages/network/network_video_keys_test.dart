// The video page of a share with a remote control. On a TV left and right go to the previous or next file of the
// folder whatever the video does (they seek in a file opened on its own), OK shows the controls with play and pause
// focused, Down from there the time bar, where left and right seek (faster while held), any key brings back the app
// bar and the controls, which hide 5 s after the last key while the video plays, and Back hides them before it
// leaves, while the Back button of the app bar leaves at once. Elsewhere OK pauses and plays, left and right seek by
// 10 s while it plays and go to the previous or next file while it is paused. The media keys work from anywhere on
// the page. A video that cannot be had shows Retry, which Down and OK reach. A phone keeps Back as before, and its
// bars hide 5 s after they show while the video plays too.

import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/pages/network/network_video.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_video_controls.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:native_video_player/native_video_player.dart';

import '../../../domain/services/spherical_probe_fixtures.dart';
import 'network_viewer_fakes.dart';

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

/// A player with nothing native behind it, that records what the page asks and follows it
class _FakePlayer extends VideoPlayerNotifier {
  _FakePlayer(this.calls, VideoPlayerState initial) {
    state = initial;
  }

  final List<String> calls;

  // Nothing native loads it: the status stays the one of the test, never "buffering" a second later
  @override
  Future<void> load(VideoSource source) async {}

  @override
  Future<void> setLoop(bool loop) async => _loops.add(loop);

  @override
  Future<void> play() async {
    calls.add('play');
    state = state.copyWith(status: VideoPlaybackStatus.playing);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    state = state.copyWith(status: VideoPlaybackStatus.paused);
  }

  @override
  Future<void> restart() async {
    calls.add('restart');
    state = state.copyWith(position: Duration.zero, status: VideoPlaybackStatus.playing);
  }

  @override
  void seekTo(Duration position) {
    calls.add('seek ${position.inSeconds}');
    state = state.copyWith(position: position);
  }
}

/// What the page asked of the player's loop
final _loops = <bool>[];

const _source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'Home NAS', host: 'nas', share: 'media');

void main() {
  late Drift db;
  late StoreService store;
  late MemoryShare share;
  late List<String> calls;
  // What the page asks of the player of the next video, /b.mp4
  late List<String> nextCalls;
  late int systemPops;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [_source]));
    final video = mp4File(mp4Moov([mp4VideoTrack(const [])]));
    share = MemoryShare(_source, files: {'/a.jpg': fakePhoto(), '/clip.mp4': video, '/b.mp4': video});
    share.folders['/'] = [share.file('/a.jpg'), share.file('/clip.mp4'), share.file('/b.mp4')];
    calls = [];
    nextCalls = [];
    _loops.clear();
    systemPops = 0;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      return switch (call.method) {
        'create' => 0,
        'resize' => {'width': (call.arguments as Map)['width'], 'height': (call.arguments as Map)['height']},
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') {
        systemPops++;
      }
      return null;
    });
  });

  tearDown(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    await store.dispose();
    await db.close();
  });

  Future<void> pumpVideo(
    WidgetTester tester, {
    required VideoPlaybackStatus status,
    bool tvMode = true,
    bool inFolder = true,
    bool pushed = false,
    bool isTelevision = false,
    bool realNeighbours = false,
  }) async {
    final entries = share.folders['/']!;
    final folder = NetworkFolderMedia(
      entries: entries,
      urls: {for (final entry in entries) entry.path: Uri.parse('http://127.0.0.1:1234/token/nas${entry.path}')},
      index: 1,
    );
    final page = NetworkVideoPage(sourceId: _source.id, path: '/clip.mp4', folder: inFolder ? folder : null);
    final router = await pumpNetworkRouter(
      tester,
      // Opened from a folder, so that its app bar has a Back button
      home: pushed || realNeighbours ? const Scaffold(body: Text('folder')) : page,
      // The remote control layout around the navigator, as in the app
      builder: tvMode ? (context, child) => TvShell(child: child!) : null,
      pages: {
        if (pushed) NetworkVideoRoute.name: (_) => page,
        // The next video in the real page, as the app opens it
        if (realNeighbours)
          NetworkVideoRoute.name: (data) {
            final args = data.argsAs<NetworkVideoRouteArgs>();
            return NetworkVideoPage(key: args.key, sourceId: args.sourceId, path: args.path, folder: args.folder);
          },
      },
      settle: false,
      overrides: [
        tvModeProvider.overrideWithValue(tvMode),
        tvDeviceProvider.overrideWithValue(TvDeviceInfo(isTelevision: isTelevision, isLowRamDevice: false)),
        storeServiceProvider.overrideWithValue(store),
        overrideConnections((ref) => FakeConnections(ref, share)),
        appConfigProvider.overrideWithValue(const AppConfig()),
        isHorizonOsProvider.overrideWith((ref) async => false),
        panorama360VideoSupportedProvider.overrideWithValue(false),
        networkMediaServiceProvider.overrideWith((ref) => _NoDetection()),
        videoPlayerProvider('network:nas:/clip.mp4').overrideWith(
          (ref) => _FakePlayer(
            calls,
            VideoPlayerState(
              position: const Duration(seconds: 30),
              duration: const Duration(minutes: 2),
              status: status,
            ),
          ),
        ),
        videoPlayerProvider('network:nas:/b.mp4').overrideWith(
          (ref) => _FakePlayer(
            nextCalls,
            const VideoPlayerState(
              position: Duration(seconds: 5),
              duration: Duration(minutes: 3),
              status: VideoPlaybackStatus.paused,
            ),
          ),
        ),
      ],
    );
    if (pushed) {
      unawaited(router.push(NetworkVideoRoute(sourceId: _source.id, path: '/clip.mp4')));
    }
    if (realNeighbours) {
      // Opened from the grid of the folder, as in the app: the next file replaces this route
      unawaited(router.push(NetworkVideoRoute(sourceId: _source.id, path: '/clip.mp4', folder: folder)));
      // Past the transition (the page shows a spinner until a native player is ready: no pumpAndSettle)
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  FocusNode playFocus(WidgetTester tester) =>
      tester.widget<IconButton>(find.byKey(const Key('network_video_play_pause'))).focusNode!;

  bool controlsShown() => find.byType(NetworkVideoControls).evaluate().isNotEmpty;

  bool appBarShown(WidgetTester tester) =>
      tester
          .widget<AnimatedOpacity>(find.ancestor(of: find.byType(AppBar), matching: find.byType(AnimatedOpacity)).first)
          .opacity ==
      1;

  testWidgets('on a TV OK shows the controls with play and pause focused, and a second OK pauses', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.playing);

    await press(tester, LogicalKeyboardKey.select);
    expect(calls, isEmpty);
    expect(controlsShown(), isTrue);
    expect(playFocus(tester).hasPrimaryFocus, isTrue);

    await press(tester, LogicalKeyboardKey.select);
    expect(calls, ['pause']);
  });

  testWidgets('on a TV right goes to the next file of the folder while it plays', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.playing);

    await press(tester, LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(find.text('video nas /b.mp4'), findsOneWidget);
    expect(calls, isEmpty);
  });

  testWidgets(
    'on a TV right while it plays opens the next video in a page of its own, whose controls drive its player',
    (tester) async {
      await pumpVideo(tester, status: VideoPlaybackStatus.playing, realNeighbours: true);
      final first = tester.state<NetworkVideoPageState>(find.byType(NetworkVideoPage));

      await press(tester, LogicalKeyboardKey.arrowRight);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final next = tester.state<NetworkVideoPageState>(find.byType(NetworkVideoPage));
      expect(next.widget.path, '/b.mp4');
      expect(identical(next, first), isFalse, reason: 'a new page, not the old one under the new name');
      expect((await next.videoSource)?.path, 'http://127.0.0.1:1234/token/nas/b.mp4', reason: 'it loads the next file');
      expect(find.text('00:05 / 03:00'), findsOneWidget, reason: 'the controls show the player of the next file');

      // OK, then OK on play and pause: the next video plays, the first one is left alone
      await press(tester, LogicalKeyboardKey.select);
      await press(tester, LogicalKeyboardKey.select);
      expect(nextCalls, ['play']);
      expect(calls, isEmpty);
    },
  );

  testWidgets('on a TV left goes to the previous one while it loads', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.buffering);

    await press(tester, LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();

    expect(find.text('photo nas /a.jpg'), findsOneWidget);
  });

  testWidgets('a phone with a keyboard: OK pauses a video that plays, with its controls, and plays it again', (
    tester,
  ) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.playing, tvMode: false);

    await press(tester, LogicalKeyboardKey.select);
    expect(calls, ['pause']);
    expect(find.byType(NetworkVideoControls), findsOneWidget);

    await press(tester, LogicalKeyboardKey.select);
    expect(calls, ['pause', 'play']);
  });

  testWidgets('a phone with a keyboard: left and right seek by 10 s while it plays', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.playing, tvMode: false);

    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowLeft);

    expect(calls, ['seek 40', 'seek 50', 'seek 40']);
    expect(find.text('video nas /clip.mp4'), findsNothing, reason: 'still on the page');
  });

  testWidgets('on a TV the app bar and the controls hide 5 s after the last key while it plays', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.playing);
    expect(controlsShown(), isTrue);
    expect(appBarShown(tester), isTrue);

    await tester.pump(const Duration(seconds: 3));
    await press(tester, LogicalKeyboardKey.mediaFastForward);
    await tester.pump(const Duration(seconds: 4));
    expect(controlsShown(), isTrue, reason: '4 s after the last key');
    await tester.pump(const Duration(seconds: 1));
    expect(controlsShown(), isFalse);
    expect(appBarShown(tester), isFalse);
    expect(find.text('clip.mp4'), findsOneWidget, reason: 'faded out, still in the tree');

    // Any key brings them back, the page keeps the keys
    await press(tester, LogicalKeyboardKey.channelDown);
    expect(controlsShown(), isTrue);
    expect(appBarShown(tester), isTrue);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Network video');
  });

  testWidgets('on a TV the controls hide under play and pause, and the next key is not lost', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.playing);

    await press(tester, LogicalKeyboardKey.select);
    expect(playFocus(tester).hasPrimaryFocus, isTrue);
    await tester.pump(const Duration(seconds: 5));
    expect(controlsShown(), isFalse);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Network video');

    await press(tester, LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('video nas /b.mp4'), findsOneWidget);
  });

  testWidgets('paused, the app bar and the controls stay', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.paused);

    await tester.pump(const Duration(seconds: 10));

    expect(controlsShown(), isTrue);
    expect(appBarShown(tester), isTrue);
  });

  testWidgets('on a phone they hide 5 s after they show while it plays too, and a tap brings them back', (
    tester,
  ) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.playing, tvMode: false);

    await tester.pump(const Duration(seconds: 5));
    expect(controlsShown(), isFalse);
    expect(appBarShown(tester), isFalse);

    await tester.tapAt(tester.getCenter(find.byType(NetworkVideoPage)));
    await tester.pump();
    expect(controlsShown(), isTrue);
    expect(appBarShown(tester), isTrue);
  });

  testWidgets('a TV plays a video once by default, a phone loops it', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.paused, isTelevision: true);
    expect(_loops, [false]);

    await tester.pumpWidget(const SizedBox.shrink());
    _loops.clear();
    await pumpVideo(tester, status: VideoPlaybackStatus.paused, tvMode: false);
    expect(_loops, [true]);
  });

  testWidgets('a phone keeps them while the video loads', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.buffering, tvMode: false);

    await tester.pump(const Duration(seconds: 10));

    expect(controlsShown(), isTrue);
  });

  testWidgets('the media keys: play and pause, fast forward and rewind', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.paused);

    await press(tester, LogicalKeyboardKey.mediaPlayPause);
    await press(tester, LogicalKeyboardKey.mediaFastForward);
    await press(tester, LogicalKeyboardKey.mediaRewind);
    await press(tester, LogicalKeyboardKey.mediaPause);

    expect(calls, ['play', 'seek 40', 'seek 30', 'pause']);
  });

  testWidgets('right goes to the next file of the folder while it is paused', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.paused);

    await press(tester, LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(find.text('video nas /b.mp4'), findsOneWidget);
    expect(calls, isEmpty);
  });

  testWidgets('left goes to the previous one, a photo', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.completed);

    await press(tester, LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();

    expect(find.text('photo nas /a.jpg'), findsOneWidget);
  });

  testWidgets('without a folder (a camera clip) the arrows stay on the page, and seek on a TV', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.paused, inFolder: false);

    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await press(tester, LogicalKeyboardKey.arrowLeft);

    expect(find.byType(NetworkVideoPage), findsOneWidget);
    expect(calls, ['seek 40', 'seek 30', 'seek 20']);
  });

  testWidgets('Down focuses play, the arrows then move between the controls, and the play key still works', (
    tester,
  ) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.playing);

    await press(tester, LogicalKeyboardKey.arrowDown);
    final play = tester.widget<IconButton>(find.byKey(const Key('network_video_play_pause'))).focusNode!;
    expect(play.hasPrimaryFocus, isTrue);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(calls, isEmpty, reason: 'the arrows move between the controls now');

    await press(tester, LogicalKeyboardKey.mediaPlayPause);
    expect(calls, ['pause']);
  });

  testWidgets('on a TV Down from play reaches the time bar, where left and right seek and OK pauses', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.playing);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(playFocus(tester).hasPrimaryFocus, isTrue);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Video time bar');

    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(calls, ['seek 40', 'seek 30', 'seek 20']);
    expect(find.byType(NetworkVideoPage), findsOneWidget);
    expect(
      find.text('video nas /b.mp4'),
      findsNothing,
      reason: 'the arrows seek on the bar, they leave the file no more',
    );

    // Held, the video waits and plays on once the key is released
    calls.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(calls, ['seek 30', 'pause', 'seek 32', 'seek 34', 'play']);

    await press(tester, LogicalKeyboardKey.select);
    expect(calls.last, 'pause');
  });

  testWidgets('on a TV the bars hide 5 s after the last key on the time bar, and right goes to the next file again', (
    tester,
  ) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.playing);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(calls, ['seek 40']);

    await tester.pump(const Duration(seconds: 5));
    expect(controlsShown(), isFalse);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Network video');

    await press(tester, LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('video nas /b.mp4'), findsOneWidget);
  });

  testWidgets('on a TV Back hides the controls first, then leaves', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.paused);
    expect(find.byType(NetworkVideoControls), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(NetworkVideoControls), findsNothing);
    expect(systemPops, 0);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(systemPops, 1);
  });

  testWidgets('on a TV the Back button of the app bar leaves the page', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.paused, pushed: true);

    // A flat video on a TV: the Back button is all the app bar has
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(Focus.of(tester.element(find.byType(BackButtonIcon))).hasPrimaryFocus, isTrue);

    await press(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(NetworkVideoPage), findsNothing);
    expect(find.text('folder'), findsOneWidget);
  });

  testWidgets('a video that cannot be had: Down and OK reach Retry, which tries again', (tester) async {
    share.error = const NetworkFileSystemException('nas does not answer');
    await pumpVideo(tester, status: VideoPlaybackStatus.paused);
    final retry = find.text('Retry');
    expect(retry, findsOneWidget);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(Focus.of(tester.element(retry)).hasPrimaryFocus, isTrue);

    // Up from Retry goes back to the page itself, from where OK goes to Retry too
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Network video');
    await press(tester, LogicalKeyboardKey.select);
    expect(Focus.of(tester.element(retry)).hasPrimaryFocus, isTrue);
    expect(calls, isEmpty, reason: 'nothing to play');

    share.error = null;
    await press(tester, LogicalKeyboardKey.select);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(retry, findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Network video', reason: 'the page takes the keys again');
  });

  testWidgets('a phone leaves at the first Back, controls or not', (tester) async {
    await pumpVideo(tester, status: VideoPlaybackStatus.paused, tvMode: false);
    expect(find.byType(NetworkVideoControls), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(systemPops, 1);
  });
}
