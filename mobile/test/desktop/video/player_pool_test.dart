// The pool of the desktop players (plan 2.5): players reused rather than made per page, bounded per kind, a player that
// does not play taken first, else the one of the lease used longest ago, handed over with its owner told first and
// after what the owner started on it, disposed only beyond the idle limit or when its picture is lost. At the close of
// the window every player is disposed at once, none of them waited for longer than its bound, those on their way
// between two places included. Before a job of the AI features on the graphics card (issue #13), the players that do
// not play are let go, the one that plays, those of a page on screen (the 360° page and its pair) and the frame grabber
// at work kept.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';

import 'fake_playback_engine.dart';

void main() {
  test('a lease takes no player until it asks for one', () async {
    final players = FakePlayers();
    final lease = players.pool.lease(PlayerKind.playback, label: 'viewer');
    expect(lease.engine, isNull);
    expect(players.made, isEmpty);

    final engine = await lease.acquire();
    expect(players.made, [engine]);
    expect(await lease.acquire(), same(engine), reason: 'the same player while the lease holds it');
    expect(players.pool.activeCount(PlayerKind.playback), 1);
  });

  test('a released player is stopped, kept, and reused by the next lease rather than a new one made', () async {
    final players = FakePlayers();
    final first = players.pool.lease(PlayerKind.playback, label: 'viewer');
    final engine = await first.acquire() as FakePlaybackEngine;
    await engine.open('/videos/a.mp4');
    await engine.setRate(2);
    await engine.setLoop(true);

    await first.release();
    expect(engine.calls.last, 'stop');
    expect(engine.rate, 1, reason: 'the next page starts at its own speed');
    expect(engine.loop, isFalse);
    expect(players.pool.idleCount(PlayerKind.playback), 1);
    expect(engine.disposed, isFalse);

    final second = players.pool.lease(PlayerKind.playback, label: 'network video');
    expect(await second.acquire(), same(engine));
    expect(players.pool.created, 1);
  });

  test('beyond the idle limit a released player is disposed', () async {
    final players = FakePlayers();
    final a = players.pool.lease(PlayerKind.playback, label: 'a');
    final b = players.pool.lease(PlayerKind.playback, label: 'b');
    final engineA = await a.acquire() as FakePlaybackEngine;
    // Both play, so that b gets a player of its own
    await engineA.play();
    final engineB = await b.acquire() as FakePlaybackEngine;

    await a.release();
    await b.release();
    await Future<void>.delayed(Duration.zero);
    expect(players.pool.idleCount(PlayerKind.playback), 1);
    expect([engineA.disposed, engineB.disposed], [false, true]);
    expect(players.pool.disposed, 1);
  });

  test('at the limit, the player of the lease used longest ago changes hands, its owner told first', () async {
    final players = FakePlayers(maxPlayers: {PlayerKind.playback: 2});
    final events = <String>[];
    final oldest = players.pool.lease(
      PlayerKind.playback,
      label: 'oldest',
      onSuspend: () async => events.add('oldest suspended'),
    );
    final recent = players.pool.lease(
      PlayerKind.playback,
      label: 'recent',
      onSuspend: () async => events.add('recent suspended'),
    );
    final oldestEngine = await oldest.acquire() as FakePlaybackEngine;
    await oldestEngine.play();
    await (await recent.acquire()).play();
    // Used again later: the oldest by use is now "oldest" only if not touched
    recent.touch();

    final third = players.pool.lease(PlayerKind.playback, label: 'third');
    final engine = await third.acquire();

    expect(engine, same(oldestEngine));
    expect(events, ['oldest suspended']);
    expect(oldest.isSuspended, isTrue);
    expect(oldest.engine, isNull);
    expect(oldestEngine.calls, contains('stop'), reason: 'handed over stopped');
    expect(players.made, hasLength(2), reason: 'no third player');

    // The suspended lease gets a player back when it asks, from the one used longest ago in turn
    await engine.play();
    final back = await oldest.acquire();
    expect(oldest.isSuspended, isFalse);
    expect(back, isNot(same(engine)));
    expect(events, ['oldest suspended', 'recent suspended']);
  });

  test('the kinds have their own limits: the frame grabber never takes a page\'s player', () async {
    final players = FakePlayers();
    final viewer = players.pool.lease(PlayerKind.playback, label: 'viewer');
    final other = players.pool.lease(PlayerKind.playback, label: 'other');
    final viewerEngine = await viewer.acquire();
    await viewerEngine.play();
    await other.acquire();

    final thumbnails = players.pool.lease(PlayerKind.thumbnail, label: 'thumbnails');
    final grabber = await thumbnails.acquire();
    expect(grabber.kind, PlayerKind.thumbnail);
    expect(viewer.engine, same(viewerEngine));
    expect(viewer.isSuspended, isFalse);
    expect(players.pool.activeCount(PlayerKind.thumbnail), 1);
  });

  test('two leases asking at once do not make more players than the limit', () async {
    final players = FakePlayers(maxPlayers: {PlayerKind.playback: 1});
    final a = players.pool.lease(PlayerKind.playback, label: 'a');
    final b = players.pool.lease(PlayerKind.playback, label: 'b');

    final engines = await Future.wait([a.acquire(), b.acquire()]);
    expect(players.made, hasLength(1));
    expect(engines[1], same(engines[0]), reason: 'b took the one player, a was suspended');
    expect(a.isSuspended, isTrue);
  });

  test('a player that does not play (a page swiped away) is taken before a second one is made', () async {
    final players = FakePlayers();
    final events = <String>[];
    final swiped = players.pool.lease(
      PlayerKind.playback,
      label: 'swiped away',
      onSuspend: () async => events.add('swiped away suspended'),
    );
    final engine = await swiped.acquire() as FakePlaybackEngine;
    await engine.open('/videos/8k.mp4');
    await engine.play();
    // The viewer pauses the page it leaves
    await engine.pause();

    final current = players.pool.lease(PlayerKind.playback, label: 'current');
    expect(await current.acquire(), same(engine));
    expect(players.made, hasLength(1), reason: 'no second decoder for a page that does not play');
    expect(events, ['swiped away suspended']);
    expect(engine.calls.last, 'stop', reason: 'its file closed, its cache let go');
    expect(swiped.isSuspended, isTrue);

    // A player that plays keeps it: a second one is made for the next page
    await engine.open('/videos/b.mp4');
    await engine.play();
    final third = players.pool.lease(PlayerKind.playback, label: 'third');
    expect(await third.acquire(), isNot(same(engine)));
    expect(current.engine, same(engine));
    expect(players.made, hasLength(2));
  });

  test('the second player of a pair never takes the player it plays with, even while that one opens', () async {
    final players = FakePlayers();
    final page = players.pool.lease(PlayerKind.playback, label: '360 video');
    final first = await page.acquire() as FakePlaybackEngine;
    await first.open('/videos/osmo.osv');
    // Not playing yet: another lease would take it first
    final pair = players.pool.lease(PlayerKind.playback, label: '360 video, second stream');
    final second = await pair.acquire(sparing: first);
    expect(second, isNot(same(first)));
    expect(page.engine, same(first));
    expect(players.made, hasLength(2));

    // At the limit, both playing: the player that changes hands is never the spared one
    final third = players.pool.lease(PlayerKind.playback, label: 'third');
    await first.play();
    await (second as FakePlaybackEngine).play();
    expect(
      await third.acquire(sparing: first),
      same(second),
      reason: 'the page was used longest ago, but its player is spared',
    );
    expect(page.engine, same(first));
  });

  test('the pool waits for what the owner started on its player before it stops it or hands it over', () async {
    final players = FakePlayers();
    final a = players.pool.lease(PlayerKind.playback, label: 'a');
    final engine = await a.acquire() as FakePlaybackEngine;
    final opening = Completer<void>();
    final opened = a.guard(() async {
      await opening.future;
      await engine.open('/videos/a.mp4');
    });

    // Another page asks while the open runs: the player is taken from a at once, stopped only after the open
    final b = players.pool.lease(PlayerKind.playback, label: 'b');
    final handed = b.acquire();
    await pumpEventQueue();
    expect(a.engine, isNull, reason: 'nothing new starts on it');
    expect(engine.calls, isEmpty, reason: 'not stopped while the open runs');

    opening.complete();
    await opened;
    expect(await handed, same(engine));
    expect(engine.calls, ['open /videos/a.mp4 at 0', 'pause', 'stop'], reason: 'the file a opened is closed first');

    // The same for a release (b plays, so that c gets a player of its own)
    await engine.play();
    final c = players.pool.lease(PlayerKind.playback, label: 'c');
    final other = await c.acquire() as FakePlaybackEngine;
    final closing = Completer<void>();
    final late = c.guard(() async {
      await closing.future;
      await other.open('/videos/c.mp4');
    });
    final released = c.release();
    await pumpEventQueue();
    expect(other.calls, isEmpty);
    closing.complete();
    await late;
    await released;
    expect(other.calls, ['open /videos/c.mp4 at 0', 'pause', 'stop']);
    expect(players.pool.idleCount(PlayerKind.playback), 1);
  });

  test('a player whose picture is lost is disposed with the idle ones; the lease gets a new one', () async {
    final players = FakePlayers();
    final events = <String>[];
    final spare = players.pool.lease(PlayerKind.playback, label: 'spare');
    final spareEngine = await spare.acquire() as FakePlaybackEngine;
    await spareEngine.play();
    final viewer = players.pool.lease(
      PlayerKind.playback,
      label: 'viewer',
      onSuspend: () async => events.add('viewer suspended'),
    );
    final lost = await viewer.acquire() as FakePlaybackEngine;
    await lost.play();
    await spare.release();
    expect(players.pool.idleCount(PlayerKind.playback), 1);

    await viewer.discard();
    expect(events, ['viewer suspended'], reason: 'its owner notes where the video was');
    expect(viewer.isSuspended, isTrue);
    expect(lost.disposed, isTrue);
    expect(spareEngine.disposed, isTrue, reason: 'made on the same lost device');
    expect(players.pool.idleCount(PlayerKind.playback), 0);

    final fresh = await viewer.acquire();
    expect(fresh, isNot(same(lost)));
    expect(players.made, hasLength(3));
    expect(viewer.isSuspended, isFalse);
  });

  test('a player that lost its picture while parked, or before it was parked, is never handed out', () async {
    final players = FakePlayers(maxIdle: 2);
    final first = players.pool.lease(PlayerKind.playback, label: 'first');
    final second = players.pool.lease(PlayerKind.playback, label: 'second');
    final lostWhileParked = await first.acquire() as FakePlaybackEngine;
    await lostWhileParked.play();
    final lostBeforeParked = await second.acquire() as FakePlaybackEngine;
    await lostBeforeParked.play();
    await first.release();
    lostWhileParked.textureLost.value = true;
    lostBeforeParked.textureLost.value = true;
    await second.release();
    expect(lostBeforeParked.disposed, isTrue);
    expect(players.pool.idleCount(PlayerKind.playback), 1);

    final next = players.pool.lease(PlayerKind.playback, label: 'next');
    final engine = await next.acquire();
    expect(lostWhileParked.disposed, isTrue);
    expect(engine, isNot(same(lostWhileParked)));
    expect(players.made, hasLength(3));
  });

  test('a released lease gets no player again, and the pool disposes everything at the end', () async {
    final players = FakePlayers();
    final lease = players.pool.lease(PlayerKind.playback, label: 'viewer');
    final engine = await lease.acquire() as FakePlaybackEngine;
    await lease.release();
    expect(lease.isClosed, isTrue);
    await expectLater(lease.acquire(), throwsStateError);

    await players.pool.dispose();
    expect(engine.disposed, isTrue);
  });

  group('a job of the AI features on the graphics card', () {
    test('the idle players of every kind and those of the paused pages go, their owners told; the playing one and the '
        'grabber at work stay', () async {
      final players = FakePlayers();
      final events = <String>[];
      // A page that plays on screen
      final playing = players.pool.lease(PlayerKind.playback, label: 'viewer');
      final playingEngine = await playing.acquire() as FakePlaybackEngine;
      await playingEngine.play();
      // A page paused over it, as the viewer leaves a page swiped away
      final paused = players.pool.lease(
        PlayerKind.playback,
        label: 'paused',
        onSuspend: () async => events.add('paused suspended'),
      );
      final pausedEngine = await paused.acquire() as FakePlaybackEngine;
      await pausedEngine.open('/videos/8k.mp4');
      await pausedEngine.play();
      await pausedEngine.pause();
      // A live view stopped, then its lease given back: its player waits idle
      final live = players.pool.lease(PlayerKind.live, label: 'camera');
      final liveEngine = await live.acquire() as FakePlaybackEngine;
      await live.release();
      // The frame grabber at work, and an idle one of a grab before
      final grabbing = players.pool.lease(PlayerKind.thumbnail, label: 'thumbnails');
      final grabberEngine = await grabbing.acquire() as FakePlaybackEngine;
      expect(players.pool.idleCount(PlayerKind.live), 1);

      final released = await players.pool.releaseForGraphicsJob();

      expect(released, 2);
      expect(pausedEngine.disposed, isTrue);
      expect(liveEngine.disposed, isTrue);
      expect(playingEngine.disposed, isFalse);
      expect(grabberEngine.disposed, isFalse);
      expect(playing.engine, same(playingEngine));
      expect(grabbing.engine, same(grabberEngine));
      expect(events, ['paused suspended']);
      expect(paused.isSuspended, isTrue);
      expect(paused.engine, isNull);
      expect(players.pool.idleCount(PlayerKind.live), 0);
      expect(players.pool.disposed, 2);

      // The paused page gets a new player when it plays again
      final back = await paused.acquire();
      expect(back, isNot(same(pausedEngine)));
      expect(paused.isSuspended, isFalse);
    });

    test(
      'the players of a page on screen stay, paused or not: the 360° page and the second player of its pair',
      () async {
        final players = FakePlayers(maxPlayers: {PlayerKind.playback: 3});
        final events = <String>[];
        var shown = true;
        // The viewer's page behind the 360° page, not on screen
        final behind = players.pool.lease(
          PlayerKind.playback,
          label: 'viewer',
          onSuspend: () async => events.add('viewer suspended'),
          onScreen: () => false,
        );
        final behindEngine = await behind.acquire() as FakePlaybackEngine;
        await behindEngine.play();
        final page = players.pool.lease(
          PlayerKind.playback,
          label: '360 video',
          onSuspend: () async => events.add('page suspended'),
          onScreen: () => shown,
        );
        final pageEngine = await page.acquire() as FakePlaybackEngine;
        await pageEngine.play();
        final pair = players.pool.lease(
          PlayerKind.playback,
          label: '360 video, second stream',
          onSuspend: () async => events.add('pair suspended'),
          onScreen: () => shown,
        );
        final pairEngine = await pair.acquire(sparing: pageEngine) as FakePlaybackEngine;
        // Each its own player, then all three paused
        expect({behindEngine, pageEngine, pairEngine}, hasLength(3));
        for (final engine in [behindEngine, pageEngine, pairEngine]) {
          await engine.pause();
        }

        expect(await players.pool.releaseForGraphicsJob(), 1);
        expect(events, ['viewer suspended']);
        expect(behindEngine.disposed, isTrue);
        expect(page.engine, same(pageEngine));
        expect(pair.engine, same(pairEngine));
        expect(page.isSuspended || pair.isSuspended, isFalse);
        expect(pageEngine.disposed || pairEngine.disposed, isFalse);

        // Once the page is closed or left, they go as any other
        shown = false;
        expect(await players.pool.releaseForGraphicsJob(), 2);
        expect(events, ['viewer suspended', 'page suspended', 'pair suspended']);
        expect(pageEngine.disposed && pairEngine.disposed, isTrue);
      },
    );

    test('the pool waits for what the owner started on its player before it lets it go', () async {
      final players = FakePlayers();
      final lease = players.pool.lease(PlayerKind.playback, label: 'viewer');
      final engine = await lease.acquire() as FakePlaybackEngine;
      final opening = Completer<void>();
      final opened = lease.guard(() async {
        await opening.future;
        await engine.open('/videos/a.mp4');
      });

      var done = false;
      final release = players.pool.releaseForGraphicsJob().then((count) {
        done = true;
        return count;
      });
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse, reason: 'the open runs first');
      expect(engine.disposed, isFalse);

      opening.complete();
      await opened;
      expect(await release, 1);
      expect(engine.calls.where((call) => call.startsWith('open')), hasLength(1));
      expect(engine.disposed, isTrue);
      expect(lease.isSuspended, isTrue);
    });

    test('nothing to let go, and nothing once the pool is closed', () async {
      final players = FakePlayers();
      expect(await players.pool.releaseForGraphicsJob(), 0);
      final lease = players.pool.lease(PlayerKind.playback, label: 'viewer');
      await lease.acquire();
      await players.pool.close(timeout: const Duration(seconds: 1));
      expect(await players.pool.releaseForGraphicsJob(), 0);
    });
  });

  group('the close of the window', () {
    test('every player is disposed at once; one that does not answer is told to stop calling Dart and left', () async {
      final players = FakePlayers();
      final viewer = players.pool.lease(PlayerKind.playback, label: 'viewer');
      final grabber = players.pool.lease(PlayerKind.thumbnail, label: 'thumbnails');
      final spare = players.pool.lease(PlayerKind.playback, label: 'network video');
      final stuck = await viewer.acquire() as FakePlaybackEngine;
      await stuck.play();
      final grab = await grabber.acquire() as FakePlaybackEngine;
      final idle = await spare.acquire() as FakePlaybackEngine;
      await spare.release();
      expect(players.pool.idleCount(PlayerKind.playback), 1);
      // A libmpv that does not answer (a film of a share that stopped answering, a texture being made)
      stuck.holdDispose = Completer<void>();

      final watch = Stopwatch()..start();
      await players.pool.close(timeout: const Duration(milliseconds: 200));
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect([grab.disposed, idle.disposed], [true, true]);
      expect(stuck.disposed, isFalse);
      expect(stuck.silenced, isTrue);
      expect([grab.silenced, idle.silenced], [false, false], reason: 'a disposed player calls nothing any more');
      expect(viewer.engine, isNull);
      await expectLater(viewer.acquire(), throwsStateError);
    });

    test(
      'a player being handed to another page is disposed with the others, and the hand over gives it to no one',
      () async {
        final players = FakePlayers();
        final a = players.pool.lease(PlayerKind.playback, label: 'a');
        final engine = await a.acquire() as FakePlaybackEngine;
        // a's open still runs: the pool waits for it before it stops the player and gives it to b
        final opening = Completer<void>();
        final opened = a.guard(() => opening.future);
        final b = players.pool.lease(PlayerKind.playback, label: 'b');
        final refused = expectLater(b.acquire(), throwsStateError);
        await pumpEventQueue();
        expect(a.engine, isNull, reason: 'on its way from a to b');
        engine.holdDispose = Completer<void>();

        await players.pool.close(timeout: const Duration(milliseconds: 200)).timeout(const Duration(seconds: 2));
        expect(engine.silenced, isTrue, reason: 'its dispose did not end: libmpv is told to stop calling Dart');

        opening.complete();
        await opened;
        await refused;
        expect(b.engine, isNull);
        expect(engine.calls, ['silence'], reason: 'the hand over leaves alone a player the close took');
        expect(engine.disposeCalls, 1);
      },
    );

    test('a player being released is disposed with the others, and never parked', () async {
      final players = FakePlayers();
      final page = players.pool.lease(PlayerKind.playback, label: 'page');
      final engine = await page.acquire() as FakePlaybackEngine;
      final closing = Completer<void>();
      final closed = page.guard(() => closing.future);
      final released = page.release();
      await pumpEventQueue();

      await players.pool.close(timeout: const Duration(milliseconds: 200)).timeout(const Duration(seconds: 2));
      expect(engine.disposed, isTrue, reason: 'within the bound of the close, not after the page ended its close');

      closing.complete();
      await closed;
      await released;
      expect(engine.calls, isNot(contains('stop')));
      expect(engine.disposeCalls, 1);
      expect(players.pool.idleCount(PlayerKind.playback), 0);
    });

    test('a player being replaced after its picture was lost is disposed with the others while its owner notes where '
        'the video was', () async {
      final players = FakePlayers();
      final noted = Completer<void>();
      final viewer = players.pool.lease(PlayerKind.playback, label: 'viewer', onSuspend: () => noted.future);
      final lost = await viewer.acquire() as FakePlaybackEngine;
      lost.holdDispose = Completer<void>();
      final discarded = viewer.discard();
      await pumpEventQueue();

      await players.pool.close(timeout: const Duration(milliseconds: 200)).timeout(const Duration(seconds: 2));
      expect(lost.silenced, isTrue);

      noted.complete();
      await discarded.timeout(const Duration(seconds: 2));
      expect(lost.disposeCalls, 1, reason: 'the replacement leaves alone a player the close took');
    });

    test('a dispose that a turn of the pool started is bounded and silenced as well, and the idle players it was to '
        'dispose next are disposed at once', () async {
      final players = FakePlayers();
      final spare = players.pool.lease(PlayerKind.playback, label: 'spare');
      final idle = await spare.acquire() as FakePlaybackEngine;
      await idle.play();
      final viewer = players.pool.lease(PlayerKind.playback, label: 'viewer');
      final lost = await viewer.acquire() as FakePlaybackEngine;
      await spare.release();
      expect(players.pool.idleCount(PlayerKind.playback), 1);
      // The player whose picture was lost does not end: the idle one made on the same device waits behind it
      lost.holdDispose = Completer<void>();
      unawaited(viewer.discard());
      await pumpEventQueue();
      expect(lost.disposeCalls, 1);
      expect(idle.disposed, isFalse);

      await players.pool.close(timeout: const Duration(milliseconds: 200)).timeout(const Duration(seconds: 2));
      expect(lost.silenced, isTrue);
      expect(lost.disposeCalls, 1, reason: 'a dispose under way is waited for, not asked again');
      expect(idle.disposed, isTrue);
      expect(idle.silenced, isFalse);
    });

    test('the close does not wait for a player being made, which is disposed once made', () async {
      final made = Completer<PlaybackEngine>();
      final pool = PlayerPool(create: (kind) => made.future);
      final lease = pool.lease(PlayerKind.playback, label: 'viewer');
      final acquiring = lease.acquire();
      final failed = expectLater(acquiring, throwsStateError);
      // libmpv's render context took 71 s to be made on 1 November 2026 (the CUDA start of a laptop's second GPU)
      await Future<void>.delayed(Duration.zero);
      await pool.close(timeout: const Duration(milliseconds: 200)).timeout(const Duration(seconds: 2));

      final madeLate = FakePlaybackEngine(PlayerKind.playback, 1);
      made.complete(madeLate);
      await failed;
      await Future<void>.delayed(Duration.zero);
      expect(madeLate.disposed, isTrue);
      expect(lease.engine, isNull);
    });
  });
}
