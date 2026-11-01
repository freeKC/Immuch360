// The close of the window (close_sequence.dart, FreeKC's report of 1 November 2026: the window froze at a close): the
// app ends its own work first, one step after the other, each bounded, so that a player, a media bridge or a database
// that does not answer never holds the close, which then lasts the sum of the bounds at most. What was never made is
// not made for a close, the connections to the shares are left to the end of the process, and the logs go last.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/desktop/window/close_sequence.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/models/watch_progress.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/video_watch_recorder.dart';
import 'package:immich_mobile/infrastructure/repositories/watch_progress.repository.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';

import '../video/fake_playback_engine.dart';

/// A media bridge whose stop never ends
class _HangingBridge implements MediaBridge {
  _HangingBridge([this.order]);

  final List<String>? order;
  bool stopAsked = false;

  @override
  Future<void> start() async {}

  @override
  void register(NetworkFileSystem fileSystem) {}

  @override
  void unregister(String sourceId) {}

  @override
  Uri urlFor(String sourceId, String path) => Uri.parse('http://127.0.0.1:1/$sourceId$path');

  @override
  void registerGenerated(String id, GeneratedMedia media) {}

  @override
  void unregisterGenerated(String id) {}

  @override
  Future<void> stop() {
    stopAsked = true;
    order?.add('bridge');
    return Completer<void>().future;
  }
}

/// The connections to the shares, whose close never ends (an SMB server that stopped answering)
class _HangingConnections extends NetworkConnections {
  _HangingConnections(super.ref, super.bridge, [this.order]);

  final List<String>? order;
  bool closeAsked = false;

  @override
  Future<void> closeAll() {
    closeAsked = true;
    order?.add('shares');
    return Completer<void>().future;
  }
}

/// The database of the watch progress, whose writes never end (a disk that does not answer)
class _StuckWrites implements WatchProgressRepository {
  final asked = <WatchProgress>[];

  @override
  Future<List<WatchProgress>> load({int maxRows = watchProgressMaxRows}) async => const [];

  @override
  Future<void> upsert(WatchProgress row) {
    asked.add(row);
    return Completer<void>().future;
  }

  @override
  Future<void> delete(String key) async {}

  @override
  Future<void> close() async {}
}

/// The player of a page as the recorder hears it
class _Player extends VideoPlayerNotifier {
  void emit({Duration? position, Duration? duration, VideoPlaybackStatus? status}) {
    state = state.copyWith(
      position: position ?? state.position,
      duration: duration ?? state.duration,
      status: status ?? state.status,
    );
  }

  @override
  bool seekWhenReady(Duration position) => true;
}

void main() {
  setUp(VideoWatchRecorder.forgetOpen);
  tearDown(() => desktopPlayerPool = null);

  group('runDesktopClose', () {
    test('runs every step in order, each within its bound, whatever the others do', () {
      fakeAsync((async) {
        final ran = <String>[];
        DesktopCloseStep step(String name, int ms, FutureOr<void> Function() run) =>
            DesktopCloseStep(name, Duration(milliseconds: ms), () {
              ran.add(name);
              return run();
            });

        Map<String, DesktopCloseStepEnd>? ends;
        unawaited(
          runDesktopClose([
            step('hangs', 300, () => Completer<void>().future),
            step('fails', 300, () => throw StateError('no')),
            step('slow', 200, () => Future<void>.delayed(const Duration(seconds: 30))),
            step('quick', 100, () async {}),
          ]).then((value) => ends = value),
        );

        async.elapse(const Duration(milliseconds: 499));
        expect(ends, isNull);
        async.elapse(const Duration(milliseconds: 2));
        expect(ran, ['hangs', 'fails', 'slow', 'quick']);
        expect(ends, {
          'hangs': DesktopCloseStepEnd.timedOut,
          'fails': DesktopCloseStepEnd.failed,
          'slow': DesktopCloseStepEnd.timedOut,
          'quick': DesktopCloseStepEnd.done,
        });
        // The slow step's timer still runs: nothing waits for it
        async.elapse(const Duration(seconds: 30));
      });
    });

    test('the steps go in their order, and their bounds add up to the bound of the whole close', () {
      final container = ProviderContainer(
        overrides: [
          mediaBridgeProvider.overrideWithValue(_HangingBridge()),
          networkConnectionsProvider.overrideWith((ref) => _HangingConnections(ref, ref.watch(mediaBridgeProvider))),
        ],
      );
      addTearDown(container.dispose);
      container.read(networkConnectionsProvider);
      final steps = container.read(desktopCloseStepsProvider)();
      expect(steps.map((step) => step.name), ['the watch progress', 'the players', 'the media bridge', 'the logs']);
      expect(steps.fold(Duration.zero, (sum, step) => sum + step.timeout), DesktopCloseBounds.total);
      expect(DesktopCloseBounds.player, lessThan(DesktopCloseBounds.players));
      expect(DesktopCloseBounds.total, lessThanOrEqualTo(const Duration(seconds: 2)));
    });
  });

  group('the steps of the app', () {
    test('nothing that was never made is made for a close', () async {
      var flushed = 0;
      final container = ProviderContainer(
        overrides: [desktopCloseLogsProvider.overrideWithValue(() async => flushed++)],
      );
      addTearDown(container.dispose);

      final steps = container.read(desktopCloseStepsProvider)();
      expect(steps.map((step) => step.name), ['the watch progress', 'the players', 'the logs']);
      final ends = await runDesktopClose(steps);
      expect(ends.values, everyElement(DesktopCloseStepEnd.done));
      expect(flushed, 1);
      expect(container.exists(mediaBridgeProvider), isFalse);
      expect(container.exists(networkConnectionsProvider), isFalse);
    });

    test('a film playing, a player, a bridge and a database that do not answer: the close ends within its bound, the '
        'connections to the shares left as they are, the logs written last', () {
      fakeAsync((async) {
        final order = <String>[];
        final bridge = _HangingBridge(order);
        late _HangingConnections connections;
        final writes = _StuckWrites();
        final container = ProviderContainer(
          overrides: [
            mediaBridgeProvider.overrideWithValue(bridge),
            networkConnectionsProvider.overrideWith(
              (ref) => connections = _HangingConnections(ref, ref.watch(mediaBridgeProvider), order),
            ),
            watchProgressRepositoryProvider.overrideWithValue(writes),
            desktopCloseLogsProvider.overrideWithValue(() {
              order.add('logs');
              return Completer<void>().future;
            }),
          ],
        );
        addTearDown(container.dispose);
        container.read(networkConnectionsProvider);

        // A film that plays in a page
        final store = container.read(watchProgressProvider.notifier);
        async.flushMicrotasks();
        final player = _Player();
        const key = WatchKey('asset:film');
        VideoWatchRecorder(
          store: store,
          player: player,
          key: key,
          rule: const WatchRule(),
          duration: const Duration(minutes: 100),
        ).start();
        player.emit(
          position: const Duration(minutes: 31),
          duration: const Duration(minutes: 100),
          status: VideoPlaybackStatus.playing,
        );

        // Its player, whose libmpv does not answer
        final players = FakePlayers();
        desktopPlayerPool = players.pool;
        final lease = players.pool.lease(PlayerKind.playback, label: 'viewer');
        late FakePlaybackEngine engine;
        unawaited(lease.acquire().then((value) => engine = value as FakePlaybackEngine));
        async.flushMicrotasks();
        engine.holdDispose = Completer<void>();

        Map<String, DesktopCloseStepEnd>? ends;
        unawaited(runDesktopClose(container.read(desktopCloseStepsProvider)()).then((value) => ends = value));
        // Each step has its whole bound, the players their own (all at once): 400 + 400 + 200 + 400 ms
        async.elapse(const Duration(milliseconds: 1399));
        expect(ends, isNull);
        async.elapse(const Duration(milliseconds: 2));

        expect(ends, {
          'the watch progress': DesktopCloseStepEnd.timedOut,
          'the players': DesktopCloseStepEnd.done,
          'the media bridge': DesktopCloseStepEnd.timedOut,
          'the logs': DesktopCloseStepEnd.timedOut,
        });
        expect(store.find(key)?.position, const Duration(minutes: 31), reason: 'saved, its write on its way');
        expect(writes.asked.map((row) => row.position), [const Duration(minutes: 31)]);
        expect(engine.silenced, isTrue);
        expect(engine.disposed, isFalse);
        expect(bridge.stopAsked, isTrue);
        // A polite logoff from a share that stopped answering would wait in libsmb2, which the end of the VM waits for
        expect(connections.closeAsked, isFalse);
        expect(order, ['bridge', 'logs']);
      });
    });
  });
}
