// The players of Immuch360 Desktop, kept and reused across pages (design 2.2) rather than one made and disposed per
// page, for three reasons:
// - each libmpv instance holds a decoder, a demuxer cache of up to 256 MiB and, for a player on screen, a texture:
//   the pool bounds them (the viewer's page, a second page only while both play, one frame grabber), so that an 8K
//   video does not leave a decoder and a few hundred megabytes behind each page swiped on a 16 GB computer
//   (plan 2.7);
// - making a player costs a libmpv start and a texture: a page swiped to takes the idle one;
// - media_kit #1449: each Player.dispose() on Windows took one COM reference off the window's thread, and drag and
//   drop died after four. The vendored media_kit gives it back (packages/media_kit/IMMUCH360-NOTE.md); the pool
//   also disposes rarely, only beyond its idle limit.
//
// A page holds a lease. It gets a player when it first needs one (a load, a play), not when it is built: the viewer
// builds the pages around the one on screen. A player that does not play (the page swiped away, which the viewer only
// pauses, or a video paused or ended) is taken from its lease before an idle one is used or a new one made: it would
// keep its decoder (for 8K HEVC, hundreds of megabytes of frame surfaces, in the shared memory of an integrated GPU)
// and keep filling its cache for a page that may not come back, where plan 2.7 allows one decoder beyond the viewer,
// the frame grabber's. When every player of a kind plays, the one of the lease used longest ago is taken. Either way
// that lease is suspended (its owner is told first, to note where the video was) and gets a player again, at that
// position, the next time its owner needs one.
//
// What a lease's owner does on its player (an open, a stop) goes through [PlayerLease.guard], and the pool waits for
// it before it stops the player or gives it to another lease: an open that ended after the stop would leave a file
// held by a parked player, or start the previous page's video in the next page's player.
//
// Before a job of the AI features on the graphics card (a 360° panorama), the pool lets go of every player that does
// not play (PlayerPool.releaseForGraphicsJob, issue #13): the budget the driver gives the job counts the decoders and
// textures of the app as used.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:logging/logging.dart';

final _log = Logger('PlayerPool');

typedef PlayerFactory = Future<PlaybackEngine> Function(PlayerKind kind);

class PlayerPool {
  PlayerPool({required this._create, Map<PlayerKind, int>? maxPlayers, this.maxIdle = 1})
    : maxPlayers = {...defaultMaxPlayers, ...?maxPlayers};

  /// The players at once per kind: the page on screen and one more that plays too (a page opened over a video that
  /// plays on), and one frame grabber. A player that does not play is taken before a second one is made. Two live
  /// views (two camera pages open, one over the other); a camera serves two viewers at most, the Tapo app included,
  /// so a page never holds more than one stream of the same camera.
  static const defaultMaxPlayers = {PlayerKind.playback: 2, PlayerKind.thumbnail: 1, PlayerKind.live: 2};

  final PlayerFactory _create;
  final Map<PlayerKind, int> maxPlayers;

  /// Stopped players kept per kind for the next page; one more is disposed
  final int maxIdle;

  final _idle = <PlayerKind, List<PlaybackEngine>>{};
  final _leases = <PlayerLease>[];

  /// Players being made, per kind, so that two pages asking at once do not pass the limit
  final _creating = <PlayerKind, int>{};

  /// Players a turn of the pool holds on their way out of a lease or out of the idle list (a hand over, a release, a
  /// replacement after a lost picture), until they land in a lease, in the idle list or in their dispose: a close
  /// takes them as well (see [close]), and the turn then leaves them alone (see [_land])
  final _inTransit = <PlaybackEngine>{};

  /// The disposes under way, so that a close bounds them as well and a player is disposed once
  final _disposing = <PlaybackEngine, Future<void>>{};

  /// One change of the pool at a time: a hand over awaits the suspended owner and the player
  Future<void> _turn = Future.value();
  int _clock = 0;
  bool _disposed = false;

  /// Players made and disposed since the pool exists, for the tests and the soak of the harness
  int created = 0;
  int disposed = 0;

  /// A lease for a page that shows (or grabs from) videos; it takes no player yet
  PlayerLease lease(PlayerKind kind, {required String label, Future<void> Function()? onSuspend}) {
    final lease = PlayerLease._(this, kind, label, onSuspend);
    _leases.add(lease);
    return lease;
  }

  /// Players of [kind] held by leases
  int activeCount(PlayerKind kind) => _leases.where((lease) => lease.kind == kind && lease._engine != null).length;

  /// Stopped players of [kind] waiting for a lease
  int idleCount(PlayerKind kind) => _idle[kind]?.length ?? 0;

  /// The window closes: every player is disposed at once, each given [timeout], without waiting for the turn of the
  /// pool (a hand over may wait for a player being made, which libmpv held for 71 s on 1 November 2026): those of the
  /// leases, the idle ones, those a turn holds on their way and those a turn is disposing. A player that has not ended
  /// by then is told to stop calling Dart ([PlaybackEngine.silence]) and left to the end of the process. The leases
  /// get no player any more; one made after this is disposed at once.
  Future<void> close({required Duration timeout}) {
    _disposed = true;
    final engines = {
      for (final lease in _leases) ?lease._engine,
      for (final idle in _idle.values) ...idle,
      ..._inTransit,
      ..._disposing.keys,
    };
    for (final lease in _leases) {
      lease._engine = null;
    }
    _idle.clear();
    _inTransit.clear();
    return Future.wait([for (final engine in engines) _disposeWithin(engine, timeout)]);
  }

  Future<void> _disposeWithin(PlaybackEngine engine, Duration timeout) => _disposeEngine(engine).timeout(
    timeout,
    onTimeout: () {
      _log.warning('A ${engine.kind.name} player did not end within ${timeout.inMilliseconds} ms: left as it is');
      try {
        engine.silence();
      } catch (error, stackTrace) {
        _log.warning('Could not silence a player', error, stackTrace);
      }
    },
  );

  /// Lets go of the players that do not play before a job of the AI features on the graphics card (issue #13: an 8K
  /// decoder holds about 1.3 GB of the card): the idle players of every kind, and the players of the leases of pages and
  /// live views that do not play, suspended as for a hand over (their owner told first, after what it started on its
  /// player; each gets a player again, at the same position, the next time it needs one). The player that plays on
  /// screen stays, and so does the frame grabber at work: its grab ends within seconds and its player then waits idle.
  /// Gives the number of players disposed, once their disposes ended.
  Future<int> releaseForGraphicsJob() => _serial(() async {
    if (_disposed) {
      return 0;
    }
    final engines = [for (final idle in _idle.values) ...idle];
    _idle.clear();
    _inTransit.addAll(engines);
    for (final lease in [..._leases]) {
      final engine = lease._engine;
      if (engine == null || lease.kind == PlayerKind.thumbnail || engine.playing.value) {
        continue;
      }
      _log.fine('${lease.label} lets go of its player for a job on the graphics card');
      lease._engine = null;
      lease._suspended = true;
      _inTransit.add(engine);
      engines.add(engine);
      await lease._settled();
      try {
        await lease._onSuspend?.call();
      } catch (error, stackTrace) {
        _log.warning('${lease.label} could not note where its video was', error, stackTrace);
      }
    }
    var released = 0;
    for (final engine in engines) {
      // Not disposed here once a close took it: the close disposes it
      if (_land(engine)) {
        await _disposeEngine(engine);
        released++;
      }
    }
    return released;
  });

  /// Disposes every player; the leases get none any more
  Future<void> dispose() => _serial(() async {
    _disposed = true;
    final engines = [for (final lease in _leases) ?lease._engine, for (final idle in _idle.values) ...idle];
    for (final lease in _leases) {
      lease._engine = null;
    }
    _idle.clear();
    for (final engine in engines) {
      await _disposeEngine(engine);
    }
  });

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _turn.then((_) => action());
    _turn = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<PlaybackEngine> _acquire(PlayerLease lease, PlaybackEngine? sparing) => _serial(() async {
    if (_disposed || lease._closed) {
      throw StateError('The player pool or the lease is closed');
    }
    final held = lease._engine;
    if (held != null) {
      return held;
    }
    // Cleared here, in the turn: a lease that a later turn suspends again stays suspended
    PlaybackEngine give(PlaybackEngine engine, {bool taken = false}) {
      // A player taken from another lease, which a close took on its way and disposes
      if (taken && !_land(engine)) {
        throw StateError('The player pool closed meanwhile');
      }
      // The pool closed while the player was made (see [close])
      if (_disposed) {
        unawaited(_disposeEngine(engine));
        throw StateError('The player pool closed meanwhile');
      }
      lease._suspended = false;
      return lease._engine = engine;
    }

    final kind = lease.kind;
    // A page's player that does not play goes first (see the top of this file); the frame grabber has one player.
    // The player [sparing] names is never taken: the one the second player of a pair plays with.
    bool spared(PlaybackEngine engine) => identical(engine, sparing);
    final resting = kind == PlayerKind.playback
        ? _leastRecentlyUsed(lease, (engine) => !spared(engine) && !engine.playing.value)
        : null;
    if (resting != null) {
      return give(await _takeFrom(resting, lease), taken: true);
    }
    final idle = _idle[kind];
    while (idle != null && idle.isNotEmpty) {
      final engine = idle.removeLast();
      if (!engine.textureLost.value) {
        return give(engine);
      }
      // Its graphics device was lost while it waited here: it would show nothing in the next page
      await _disposeEngine(engine);
    }
    final limit = maxPlayers[kind] ?? 1;
    if (activeCount(kind) + (_creating[kind] ?? 0) < limit) {
      _creating[kind] = (_creating[kind] ?? 0) + 1;
      try {
        final engine = await _create(kind);
        created++;
        if (lease._closed) {
          _park(engine);
          throw StateError('The lease closed while its player was made');
        }
        return give(engine);
      } finally {
        _creating[kind] = _creating[kind]! - 1;
      }
    }
    // Every player is taken: the one of the lease used longest ago changes hands
    final victim = _leastRecentlyUsed(lease, (engine) => !spared(engine));
    if (victim == null) {
      throw StateError('No ${kind.name} player is free');
    }
    return give(await _takeFrom(victim, lease), taken: true);
  });

  /// The other lease of [lease]'s kind used longest ago whose player passes [test], null when there is none
  PlayerLease? _leastRecentlyUsed(PlayerLease lease, bool Function(PlaybackEngine engine) test) =>
      (_leases.where((other) {
        final engine = other._engine;
        return other.kind == lease.kind && engine != null && !identical(other, lease) && test(engine);
      }).toList()..sort((a, b) => a._lastUsed.compareTo(b._lastUsed))).firstOrNull;

  /// Suspends [victim] and gives its player, stopped, to [lease]; the player is on its way until the caller lands it
  Future<PlaybackEngine> _takeFrom(PlayerLease victim, PlayerLease lease) async {
    final engine = victim._engine!;
    _log.fine('${victim.label} gives its player to ${lease.label}');
    // Taken first, so that the owner starts nothing new on it, then what it started ends before the stop
    victim._engine = null;
    victim._suspended = true;
    _inTransit.add(engine);
    await victim._settled();
    try {
      await victim._onSuspend?.call();
    } catch (error, stackTrace) {
      _log.warning('${victim.label} could not note where its video was', error, stackTrace);
    }
    // Not stopped once a close took it: it is being disposed
    if (_inTransit.contains(engine)) {
      await _stop(engine);
    }
    return engine;
  }

  /// [engine] ends its way: false when a close took it meanwhile and disposes it, which the turn then leaves alone
  bool _land(PlaybackEngine engine) => _inTransit.remove(engine);

  Future<void> _release(PlayerLease lease) => _serial(() async {
    lease._closed = true;
    _leases.remove(lease);
    final engine = lease._engine;
    lease._engine = null;
    if (engine != null) {
      _inTransit.add(engine);
    }
    // An open still running would load its file after the stop, into a parked player that would hold it
    await lease._settled();
    if (engine == null) {
      return;
    }
    // Not stopped nor parked once a close took it: it is being disposed
    if (_inTransit.contains(engine)) {
      await _stop(engine);
    }
    if (_land(engine)) {
      _park(engine);
    }
  });

  /// Disposes the player of [lease], which can no longer show a picture (its graphics device was lost), with the idle
  /// players made on the same device; the lease is suspended, its owner told first, and gets a new player at its next
  /// [PlayerLease.acquire]
  Future<void> _discard(PlayerLease lease) => _serial(() async {
    final engine = lease._engine;
    if (engine == null || lease._closed) {
      return;
    }
    _log.warning('${lease.label} lost the picture of its player: a new player replaces it');
    lease._engine = null;
    lease._suspended = true;
    _inTransit.add(engine);
    await lease._settled();
    try {
      await lease._onSuspend?.call();
    } catch (error, stackTrace) {
      _log.warning('${lease.label} could not note where its video was', error, stackTrace);
    }
    final idle = _idle.remove(engine.kind) ?? const [];
    _inTransit.addAll(idle);
    for (final other in [engine, ...idle]) {
      if (_land(other)) {
        await _disposeEngine(other);
      }
    }
  });

  /// Keeps a stopped [engine] for the next lease, or disposes it beyond [maxIdle] or when it can no longer show a
  /// picture
  void _park(PlaybackEngine engine) {
    final idle = _idle.putIfAbsent(engine.kind, () => []);
    if (!_disposed && idle.length < maxIdle && !engine.textureLost.value) {
      idle.add(engine);
    } else {
      unawaited(_disposeEngine(engine));
    }
  }

  Future<void> _stop(PlaybackEngine engine) async {
    try {
      await engine.pause();
      await engine.stop();
      // The next page starts at its own settings, not at those the last one left
      await engine.setRate(1);
      await engine.setLoop(false);
    } catch (error, stackTrace) {
      _log.warning('Could not stop a player', error, stackTrace);
    }
  }

  /// Disposes [engine] once: a second call while the first runs waits for it (see [close])
  Future<void> _disposeEngine(PlaybackEngine engine) {
    final running = _disposing[engine];
    if (running != null) {
      return running;
    }
    final ending = _endEngine(engine);
    _disposing[engine] = ending;
    unawaited(ending.whenComplete(() => _disposing.remove(engine)));
    return ending;
  }

  Future<void> _endEngine(PlaybackEngine engine) async {
    try {
      await engine.dispose();
      disposed++;
    } catch (error, stackTrace) {
      _log.warning('Could not dispose a player', error, stackTrace);
    }
  }
}

/// The right of a page to a player of the pool, see [PlayerPool.lease]
class PlayerLease {
  PlayerLease._(this._pool, this.kind, this.label, this._onSuspend);

  final PlayerPool _pool;
  final PlayerKind kind;

  /// Who holds it, for the log ("viewer", "network video", "thumbnails"); never a path or a URL
  final String label;
  final Future<void> Function()? _onSuspend;

  PlaybackEngine? _engine;
  int _lastUsed = 0;
  bool _suspended = false;
  bool _closed = false;

  /// The end of the last action started through [guard], null once every one ended
  Future<void>? _tail;

  /// The player held, null before the first [acquire], while suspended and once released
  PlaybackEngine? get engine => _engine;

  /// Whether the pool took the player away since the last [acquire]
  bool get isSuspended => _suspended;

  bool get isClosed => _closed;

  /// The player of this lease: the one it holds, one of a lease that does not play, an idle one, a new one, or the one
  /// of the lease used longest ago, never [sparing] (the player the second player of a pair plays with). Clears
  /// [isSuspended]: the owner reopens its video in it. Another lease may take it before the owner uses it: the owner
  /// checks [engine] first.
  Future<PlaybackEngine> acquire({PlaybackEngine? sparing}) {
    touch();
    return _pool._acquire(this, sparing);
  }

  /// Marks the lease as just used (a play, a seek), so that the pool takes another one's player first
  void touch() => _lastUsed = ++_pool._clock;

  /// Gives the player back, stopped; the lease is not used again
  Future<void> release() => _pool._release(this);

  /// Runs [action], which opens or closes a file on the player of this lease, after the actions guarded before it;
  /// the pool waits for them before it stops the player or gives it to another lease. [action] checks [engine] first:
  /// the player may have been taken meanwhile. It must not ask the pool for a player ([acquire]), which would wait for
  /// the pool while the pool waits for it.
  Future<T> guard<T>(Future<T> Function() action) {
    final previous = _tail;
    final result = previous == null ? Future.sync(action) : previous.then((_) => action());
    late final Future<void> tail;
    void ended() {
      // Nothing is kept once the turn is over, so that a later wait does not hang on an old future
      if (identical(_tail, tail)) {
        _tail = null;
      }
    }

    tail = result.then<void>((_) => ended(), onError: (Object _) => ended());
    _tail = tail;
    return result;
  }

  /// Replaces the player of this lease, which can no longer show a picture (see [PlaybackEngine.textureLost]): it is
  /// disposed, the lease is suspended, its owner told first, and the next [acquire] makes a new one
  Future<void> discard() => _pool._discard(this);

  Future<void> _settled() => _tail ?? Future<void>.value();
}

PlayerPool? _shared;

/// The pool of the app's players, made on first use
PlayerPool get desktopPlayerPool => _shared ??= PlayerPool(create: DesktopPlayer.create);

/// The pool of the app's players when one was made, null before the first video: nothing of it holds the graphics card
PlayerPool? get desktopPlayerPoolIfMade => _shared;

/// Closes the app's pool when it was made (see [PlayerPool.close]): the window closes
Future<void> closeDesktopPlayerPool({required Duration timeout}) => _shared?.close(timeout: timeout) ?? Future.value();

/// Replaces the app's pool (null: made again on first use), for the tests of the pages that build their own view
@visibleForTesting
set desktopPlayerPool(PlayerPool? pool) => _shared = pool;
