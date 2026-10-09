// The pool of the desktop players (plan 2.5): players reused rather than made per page, bounded per kind, the one of
// the lease used longest ago handed over with its owner told first, disposed only beyond the idle limit.

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
    await recent.acquire();
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
