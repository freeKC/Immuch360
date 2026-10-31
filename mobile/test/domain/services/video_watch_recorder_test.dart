import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/models/watch_progress.dart';
import 'package:immich_mobile/domain/services/video_watch_recorder.dart';
import 'package:immich_mobile/infrastructure/repositories/watch_progress.repository.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';
import 'package:native_video_player/native_video_player.dart';

import '../../fixtures/watch_progress.fake.dart';

/// The rows given, kept in memory
class _Rows implements WatchProgressRepository {
  _Rows(this.rows);

  final List<WatchProgress> rows;

  @override
  Future<List<WatchProgress>> load({int maxRows = watchProgressMaxRows}) async => rows;

  @override
  Future<void> upsert(WatchProgress row) async {}

  @override
  Future<void> delete(String key) async {}

  @override
  Future<void> close() async {}
}

/// The rows of a database slow to open (a cold start on a TV): they come when the test says
class _LateRows implements WatchProgressRepository {
  _LateRows(this.rows);

  final List<WatchProgress> rows;
  final _opened = Completer<void>();
  final written = <WatchProgress>[];

  void open() => _opened.complete();

  @override
  Future<List<WatchProgress>> load({int maxRows = watchProgressMaxRows}) async {
    await _opened.future;
    return rows;
  }

  @override
  Future<void> upsert(WatchProgress row) async => written.add(row);

  @override
  Future<void> delete(String key) async {}

  @override
  Future<void> close() async {}
}

/// The player of a page as the recorder hears it: the test tells its state, and it records what it was asked
class _Player extends VideoPlayerNotifier {
  final startsAt = <Duration>[];
  final seeks = <Duration>[];
  final loops = <bool>[];
  bool suspended = false;

  void emit({Duration? position, Duration? duration, VideoPlaybackStatus? status}) {
    state = state.copyWith(
      position: position ?? state.position,
      duration: duration ?? state.duration,
      status: status ?? state.status,
    );
  }

  @override
  bool get isSuspendedForExternalPlayer => suspended;

  @override
  bool seekWhenReady(Duration position) {
    startsAt.add(position);
    return true;
  }

  @override
  void seekTo(Duration position) => seeks.add(position);

  @override
  Future<void> setLoop(bool loop) async => loops.add(loop);
}

void main() {
  const minute = Duration(minutes: 1);
  const film = Duration(minutes: 100);
  const key = WatchKey('asset:a');
  final now = DateTime.utc(2026, 10, 31, 9);

  late ProviderContainer container;
  late WatchProgressStore store;
  late _Player player;

  WatchProgress row({int minutes = 42, bool watched = false, Duration duration = film}) =>
      WatchProgress(key: key.key, position: minute * minutes, duration: duration, watched: watched, updatedAt: now);

  /// The store with [rows], loaded, and a fresh player
  void setUpWith(FakeAsync async, List<WatchProgress> rows) {
    container = ProviderContainer(
      overrides: [
        watchProgressRepositoryProvider.overrideWithValue(_Rows(rows)),
        watchProgressClockProvider.overrideWithValue(() => now),
      ],
    );
    store = container.read(watchProgressProvider.notifier);
    async.flushMicrotasks();
    player = _Player();
  }

  VideoWatchRecorder recorderFor({
    WatchRule rule = const WatchRule(),
    Duration? duration = film,
    void Function(Duration position)? onResumed,
  }) =>
      VideoWatchRecorder(store: store, player: player, key: key, rule: rule, duration: duration, onResumed: onResumed)
        ..start();

  Duration? saved() => store.find(key)?.position;

  tearDown(() => container.dispose());

  test('a film resumes where it was left, once the player is ready', () {
    fakeAsync((async) {
      setUpWith(async, [row()]);

      recorderFor();

      expect(player.startsAt, [minute * 42]);
    });
  });

  test('a shorter video, a watched film and an unknown one start from the beginning', () {
    fakeAsync((async) {
      setUpWith(async, [row(minutes: 3, duration: const Duration(minutes: 8))]);
      recorderFor(duration: const Duration(minutes: 8));
      expect(player.startsAt, isEmpty);

      setUpWith(async, [row(minutes: 0, watched: true)]);
      recorderFor();
      expect(player.startsAt, isEmpty);

      setUpWith(async, []);
      recorderFor();
      expect(player.startsAt, isEmpty);
    });
  });

  test('says where it resumed once the film plays from there, once', () {
    fakeAsync((async) {
      setUpWith(async, [row()]);
      final notices = <Duration>[];
      recorderFor(onResumed: notices.add);

      player.emit(position: Duration.zero, duration: film, status: VideoPlaybackStatus.paused);
      player.emit(position: minute * 42);
      expect(notices, isEmpty, reason: 'not before it plays');

      player.emit(status: VideoPlaybackStatus.playing);
      player.emit(position: minute * 42 + const Duration(seconds: 1));
      player.emit(status: VideoPlaybackStatus.paused);
      player.emit(status: VideoPlaybackStatus.playing);

      expect(notices, [minute * 42]);
    });
  });

  test('nothing is saved before the video played in this page', () {
    fakeAsync((async) {
      setUpWith(async, [row()]);
      final recorder = recorderFor();

      // Reported ended at its start as it loads, then paused, then the page goes
      player.emit(position: Duration.zero, duration: film, status: VideoPlaybackStatus.completed);
      player.emit(status: VideoPlaybackStatus.paused);
      async.elapse(const Duration(seconds: 30));
      recorder.dispose();

      expect(saved(), minute * 42);
    });
  });

  test('saves every 5 s while it plays, and stops once paused', () {
    fakeAsync((async) {
      setUpWith(async, []);
      recorderFor();

      player.emit(position: minute * 10, duration: film, status: VideoPlaybackStatus.playing);
      async.elapse(const Duration(seconds: 4));
      expect(saved(), isNull);

      player.emit(position: minute * 11);
      async.elapse(const Duration(seconds: 1));
      expect(saved(), minute * 11);

      player.emit(position: minute * 12);
      async.elapse(const Duration(seconds: 5));
      expect(saved(), minute * 12);

      player.emit(position: minute * 13, status: VideoPlaybackStatus.paused);
      expect(saved(), minute * 13, reason: 'the pause saves');
      player.emit(position: minute * 14);
      async.elapse(const Duration(seconds: 20));
      expect(saved(), minute * 13, reason: 'nothing more while paused');
    });
  });

  test('a swipe pauses the page, and the pause saves', () {
    fakeAsync((async) {
      setUpWith(async, []);
      recorderFor();

      player.emit(position: minute * 20, duration: film, status: VideoPlaybackStatus.playing);
      player.emit(position: minute * 20 + const Duration(seconds: 2), status: VideoPlaybackStatus.paused);

      expect(saved(), minute * 20 + const Duration(seconds: 2));
    });
  });

  test('a failure after it played saves too', () {
    fakeAsync((async) {
      setUpWith(async, []);
      recorderFor();

      player.emit(position: minute * 20, duration: film, status: VideoPlaybackStatus.playing);
      player.emit(status: VideoPlaybackStatus.failed);

      expect(saved(), minute * 20);
    });
  });

  test('played to its end, the film is watched and starts from 0 next time', () {
    fakeAsync((async) {
      setUpWith(async, [row()]);
      recorderFor();

      player.emit(position: film - const Duration(seconds: 1), duration: film, status: VideoPlaybackStatus.playing);
      // A player that reports its end at 0
      player.emit(position: Duration.zero, status: VideoPlaybackStatus.completed);

      expect(store.find(key)?.watched, isTrue);
      expect(saved(), Duration.zero);
    });
  });

  test('the page going saves where it is', () {
    fakeAsync((async) {
      setUpWith(async, []);
      final recorder = recorderFor();

      player.emit(position: minute * 30, duration: film, status: VideoPlaybackStatus.playing);
      async.elapse(const Duration(seconds: 2));
      player.emit(position: minute * 31);
      recorder.dispose();
      expect(saved(), isNull, reason: 'right after the frame the page goes in, not during it');
      async.flushMicrotasks();

      expect(saved(), minute * 31);
      async.elapse(const Duration(seconds: 10));
      player.emit(position: minute * 35);
      expect(saved(), minute * 31, reason: 'nothing once it is gone');
    });
  });

  test('an external player taking the video saves where it was, not the stop that follows', () {
    fakeAsync((async) {
      setUpWith(async, []);
      final recorder = recorderFor();
      player.emit(position: minute * 30, duration: film, status: VideoPlaybackStatus.playing);

      recorder.onSuspend(minute * 30);
      player.suspended = true;
      player.emit(position: Duration.zero, status: VideoPlaybackStatus.completed);

      expect(saved(), minute * 30);
    });
  });

  test('the position an external player hands back is saved, and is where the video loads again', () {
    fakeAsync((async) {
      setUpWith(async, []);
      final recorder = recorderFor();
      player.emit(duration: film);

      recorder.onHandBack(minute * 55);

      expect(saved(), minute * 55);
      expect(recorder.resumePositionAfterExternalPlayer(), minute * 55);
    });
  });

  test('a player that tells no position loads again where the film was saved', () {
    fakeAsync((async) {
      setUpWith(async, [row()]);
      final recorder = recorderFor();

      expect(recorder.resumePositionAfterExternalPlayer(), minute * 42);
    });
  });

  test('nothing is saved for a video that is no film', () {
    fakeAsync((async) {
      setUpWith(async, []);
      final recorder = recorderFor(duration: const Duration(minutes: 8));

      player.emit(position: const Duration(minutes: 4), duration: const Duration(minutes: 8));
      player.emit(status: VideoPlaybackStatus.playing);
      async.elapse(const Duration(seconds: 10));
      player.emit(status: VideoPlaybackStatus.paused);
      recorder.dispose();

      expect(store.find(key), isNull);
    });
  });

  test('nothing at all with the setting off', () {
    fakeAsync((async) {
      setUpWith(async, [row()]);
      final recorder = recorderFor(rule: const WatchRule(enabled: false));

      player.emit(position: minute * 50, duration: film, status: VideoPlaybackStatus.playing);
      player.emit(status: VideoPlaybackStatus.paused);
      recorder.dispose();

      expect(player.startsAt, isEmpty);
      expect(saved(), minute * 42);
    });
  });

  group('the loop', () {
    test('a film plays once whatever Looping says, a shorter video loops as set', () {
      fakeAsync((async) {
        setUpWith(async, []);

        expect(recorderFor().loopsWith(true), isFalse);
        expect(recorderFor(duration: const Duration(minutes: 3)).loopsWith(true), isTrue);
        expect(recorderFor(duration: const Duration(minutes: 3)).loopsWith(false), isFalse);
      });
    });

    test('a film whose duration the player tells only once ready stops looping then', () {
      fakeAsync((async) {
        setUpWith(async, []);
        final recorder = recorderFor(duration: null);
        expect(recorder.loopsWith(true), isTrue, reason: 'not known to be a film yet');

        player.emit(duration: film);
        player.emit(position: const Duration(seconds: 1));

        expect(player.loops, [false]);
      });
    });

    test('a short video keeps its loop', () {
      fakeAsync((async) {
        setUpWith(async, []);
        recorderFor(duration: null).loopsWith(true);

        player.emit(duration: const Duration(minutes: 2));

        expect(player.loops, isEmpty);
      });
    });
  });

  test('a file whose duration differs from the one kept goes back to its start once the resume went', () {
    fakeAsync((async) {
      setUpWith(async, [row()]);
      final notices = <Duration>[];
      recorderFor(duration: null, onResumed: notices.add);
      expect(player.startsAt, [minute * 42]);

      // A player that tells the duration only after the seek to where the film was left
      player.emit(position: minute * 42, duration: film + minute * 5, status: VideoPlaybackStatus.playing);

      expect(player.seeks, [Duration.zero]);
      expect(notices, isEmpty);
    });
  });

  group('with the player of the app, whose native player loads a video again at 0 (Media3)', () {
    const ms = 60000;
    final source = VideoSource(path: 'https://server/assets/a/video/playback', type: .network, headers: const {});
    final wakelock = VideoPlayerNotifier.toggleWakelock;
    late VideoPlayerNotifier inApp;
    late FakeNativePlayer native;

    setUp(() => VideoPlayerNotifier.toggleWakelock = (_) async {});
    tearDown(() => VideoPlayerNotifier.toggleWakelock = wakelock);

    /// The player of a page and its native player of [duration], told of each other as the viewer does
    void attach({Duration duration = film}) {
      native = FakeNativePlayer(durationMs: duration.inMilliseconds);
      inApp = VideoPlayerNotifier()..attachController(native);
      native.onPlaybackReady.addListener(inApp.onNativePlaybackReady);
      native.onPlaybackPositionChanged.addListener(inApp.onNativePositionChanged);
      native.onPlaybackStatusChanged.addListener(inApp.onNativeStatusChanged);
    }

    VideoWatchRecorder recorderOn({Duration? duration = film, void Function(Duration position)? onResumed}) =>
        VideoWatchRecorder(
          store: store,
          player: inApp,
          key: key,
          rule: const WatchRule(),
          duration: duration,
          onResumed: onResumed,
        )..start();

    List<String> seeks() => native.calls.where((call) => call.startsWith('seek')).toList();

    /// The film loads, resumes at 42:00, plays to 45:00, goes to an external player and comes back at 50:00: loaded
    /// again, at 0 until the player is ready
    VideoWatchRecorder handedBack(FakeAsync async) {
      setUpWith(async, [row()]);
      attach();
      final recorder = recorderOn();
      unawaited(inApp.load(source));
      async.flushMicrotasks();
      native.ready();
      async.flushMicrotasks();
      unawaited(inApp.play());
      async.flushMicrotasks();
      native.moveTo(45 * ms);
      async.flushMicrotasks();

      unawaited(inApp.suspendForExternalPlayer());
      async.flushMicrotasks();
      expect(saved(), minute * 45);
      unawaited(inApp.resumeAfterExternalPlayerAt(minute * 50, play: false));
      async.flushMicrotasks();
      expect(native.calls.where((call) => call == 'load'), hasLength(2));
      expect(inApp.state.position, Duration.zero, reason: 'at its start until it is ready again');
      expect(saved(), minute * 50);
      return recorder;
    }

    test('the page going before the player is ready again keeps where the external player left the film', () {
      fakeAsync((async) {
        final recorder = handedBack(async);
        async.elapse(const Duration(seconds: 10));

        recorder.dispose();
        async.flushMicrotasks();

        expect(saved(), minute * 50);
      });
    });

    test('a new load of the page in between (the original downloaded again) keeps it too, and resumes there', () {
      fakeAsync((async) {
        final first = handedBack(async);

        // What _startRecorder does: the recorder of the load before goes, then the one of the new load starts
        first.dispose();
        async.flushMicrotasks();
        expect(saved(), minute * 50);
        final notices = <Duration>[];
        final second = recorderOn(onResumed: notices.add);
        expect(second.startAt, isNull, reason: 'the position handed back wins, with no notice');

        native.ready();
        async.flushMicrotasks();
        expect(seeks().last, 'seek ${50 * ms}');
        unawaited(inApp.play());
        async.flushMicrotasks();
        native.moveTo(50 * ms + 500);
        async.flushMicrotasks();
        expect(notices, isEmpty);

        second.dispose();
        async.flushMicrotasks();
        expect(saved(), minute * 50 + const Duration(milliseconds: 500));
      });
    });

    test('taken again by an external player before it is ready, the film goes there where it was handed back', () {
      fakeAsync((async) {
        handedBack(async);

        unawaited(inApp.suspendForExternalPlayer());
        async.flushMicrotasks();

        expect(saved(), minute * 50);
      });
    });

    test('a file whose duration differs from the one kept starts from the beginning, and says nothing', () {
      fakeAsync((async) {
        setUpWith(async, [row()]);
        // Another file at the same place of a share, which tells no duration: 5 minutes longer
        attach(duration: film + minute * 5);
        final notices = <Duration>[];
        recorderOn(duration: null, onResumed: notices.add);
        unawaited(inApp.load(source));
        async.flushMicrotasks();

        native.ready();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));

        expect(seeks(), isEmpty);
        expect(inApp.state.position, Duration.zero);
        unawaited(inApp.play());
        async.flushMicrotasks();
        native.moveTo(1000);
        async.flushMicrotasks();
        expect(notices, isEmpty);
      });
    });

    test("a duration of the page a few seconds off the player's still resumes", () {
      fakeAsync((async) {
        setUpWith(async, [row()]);
        attach();
        // The server's probe of the original, 5 s longer than the stream the player plays
        recorderOn(duration: film + const Duration(seconds: 5));
        unawaited(inApp.load(source));
        async.flushMicrotasks();

        native.ready();
        async.flushMicrotasks();

        expect(seeks(), ['seek ${42 * ms}']);
      });
    });

    test('at the threshold, the duration of the player decides, the one the row was saved with', () {
      fakeAsync((async) {
        const player = Duration(minutes: 10, milliseconds: 100);
        setUpWith(async, [row(minutes: 5, duration: player)]);
        attach(duration: player);
        // 9:59.8 for the server, no film by it: loops as set until the player says otherwise
        final recorder = recorderOn(duration: const Duration(minutes: 9, seconds: 59, milliseconds: 800));
        expect(recorder.loopsWith(true), isTrue);
        unawaited(inApp.load(source));
        async.flushMicrotasks();

        native.ready();
        async.flushMicrotasks();

        expect(native.calls, contains('loop false'));
        expect(seeks(), ['seek ${5 * ms}']);
      });
    });

    test('"Play from the start" before the film played: no notice when it passes where it was left', () {
      fakeAsync((async) {
        setUpWith(async, [row(minutes: 1)]);
        attach();
        final notices = <Duration>[];
        recorderOn(onResumed: notices.add);
        unawaited(inApp.load(source));
        async.flushMicrotasks();
        native.ready();
        async.flushMicrotasks();

        unawaited(inApp.restart());
        async.elapse(const Duration(milliseconds: 200));
        native.moveTo(1000);
        async.flushMicrotasks();
        native.moveTo(60 * 1000 + 500);
        async.flushMicrotasks();

        expect(notices, isEmpty);
      });
    });

    group('a database slower to open than the page waits (storeWait)', () {
      late _LateRows rows;

      void setUpLate(FakeAsync async) {
        rows = _LateRows([row()]);
        container = ProviderContainer(
          overrides: [
            watchProgressRepositoryProvider.overrideWithValue(rows),
            watchProgressClockProvider.overrideWithValue(() => now),
          ],
        );
        store = container.read(watchProgressProvider.notifier);
        async.flushMicrotasks();
        attach();
      }

      test('saves nothing before its rows come, then takes a film that barely started where it was left', () {
        fakeAsync((async) {
          setUpLate(async);
          final notices = <Duration>[];
          final recorder = recorderOn(onResumed: notices.add);
          unawaited(inApp.load(source));
          async.flushMicrotasks();
          native.ready();
          async.flushMicrotasks();
          unawaited(inApp.play());
          async.flushMicrotasks();
          native.moveTo(3000);
          async.elapse(const Duration(seconds: 6));
          native.moveTo(9000);
          async.flushMicrotasks();
          expect(rows.written, isEmpty, reason: 'nothing over the row the database holds');

          rows.open();
          async.flushMicrotasks();
          expect(saved(), minute * 42);
          async.elapse(const Duration(milliseconds: 200));
          expect(seeks(), ['seek ${42 * ms}']);
          native.moveTo(42 * ms + 500);
          async.flushMicrotasks();
          expect(notices, [minute * 42]);

          native.moveTo(43 * ms);
          recorder.dispose();
          async.flushMicrotasks();
          expect(saved(), minute * 43);
        });
      });

      test('rows that come before the player is ready resume at the ready', () {
        fakeAsync((async) {
          setUpLate(async);
          recorderOn();
          unawaited(inApp.load(source));
          async.flushMicrotasks();

          rows.open();
          async.flushMicrotasks();
          native.ready();
          async.flushMicrotasks();

          expect(seeks(), ['seek ${42 * ms}']);
        });
      });

      test('a film watched past its start meanwhile stays where it is', () {
        fakeAsync((async) {
          setUpLate(async);
          final recorder = recorderOn();
          unawaited(inApp.load(source));
          async.flushMicrotasks();
          native.ready();
          async.flushMicrotasks();
          unawaited(inApp.play());
          async.flushMicrotasks();
          native.moveTo(40 * 1000);
          async.flushMicrotasks();

          rows.open();
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 200));

          expect(seeks(), isEmpty);
          recorder.dispose();
          async.flushMicrotasks();
          expect(saved(), const Duration(seconds: 40));
        });
      });
    });
  });
}
