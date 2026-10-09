// The pool of the desktop players (plan 2.5): players reused rather than made per page, bounded per kind, a player that
// does not play taken first, else the one of the lease used longest ago, handed over with its owner told first and
// after what the owner started on it, disposed only beyond the idle limit or when its picture is lost.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';

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
}
