// The players of Immuch360 Desktop, kept and reused across pages (design 2.2) rather than one made and disposed per
// page, for three reasons:
// - each libmpv instance holds a decoder, a demuxer cache of up to 256 MiB and, for a player on screen, a texture:
//   the pool bounds them (the viewer's page and one more player on screen, one frame grabber), so that an 8K video
//   does not leave a few hundred megabytes behind each page swiped on a 16 GB computer (plan 2.7);
// - making a player costs a libmpv start and a texture: a page swiped to takes the idle one;
// - media_kit #1449: each Player.dispose() on Windows took one COM reference off the window's thread, and drag and
//   drop died after four. The vendored media_kit gives it back (packages/media_kit/IMMUCH360-NOTE.md); the pool
//   also disposes rarely, only beyond its idle limit.
//
// A page holds a lease. It gets a player when it first needs one (a load, a play), not when it is built: the viewer
// builds the pages around the one on screen. When every player of a kind is taken, the player of the lease used
// longest ago is taken from it: that lease is suspended (its owner is told first, to note where the video was) and
// gets a player again, at that position, the next time its owner needs one.

import 'dart:async';

import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:logging/logging.dart';

final _log = Logger('PlayerPool');

typedef PlayerFactory = Future<PlaybackEngine> Function(PlayerKind kind);

class PlayerPool {
  PlayerPool({required this._create, Map<PlayerKind, int>? maxPlayers, this.maxIdle = 1})
    : maxPlayers = {...defaultMaxPlayers, ...?maxPlayers};

  /// The players at once per kind: the page on screen and one more (a page opened over it, a page leaving while the
  /// next one loads), and one frame grabber
  static const defaultMaxPlayers = {PlayerKind.playback: 2, PlayerKind.thumbnail: 1};

  final PlayerFactory _create;
  final Map<PlayerKind, int> maxPlayers;

  /// Stopped players kept per kind for the next page; one more is disposed
  final int maxIdle;

  final _idle = <PlayerKind, List<PlaybackEngine>>{};
  final _leases = <PlayerLease>[];

  /// Players being made, per kind, so that two pages asking at once do not pass the limit
  final _creating = <PlayerKind, int>{};

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

  Future<PlaybackEngine> _acquire(PlayerLease lease) => _serial(() async {
    if (_disposed || lease._closed) {
      throw StateError('The player pool or the lease is closed');
    }
    final held = lease._engine;
    if (held != null) {
      return held;
    }
    final kind = lease.kind;
    final idle = _idle[kind];
    if (idle != null && idle.isNotEmpty) {
      return lease._engine = idle.removeLast();
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
        return lease._engine = engine;
      } finally {
        _creating[kind] = _creating[kind]! - 1;
      }
    }
    // Every player is taken: the one of the lease used longest ago changes hands
    final victim =
        (_leases.where((other) => other.kind == kind && other._engine != null && !identical(other, lease)).toList()
              ..sort((a, b) => a._lastUsed.compareTo(b._lastUsed)))
            .firstOrNull;
    if (victim == null) {
      throw StateError('No ${kind.name} player is free');
    }
    final engine = victim._engine!;
    _log.fine('${victim.label} gives its player to ${lease.label}');
    try {
      await victim._onSuspend?.call();
    } catch (error, stackTrace) {
      _log.warning('${victim.label} could not note where its video was', error, stackTrace);
    }
    victim._engine = null;
    victim._suspended = true;
    await _stop(engine);
    return lease._engine = engine;
  });

  Future<void> _release(PlayerLease lease) => _serial(() async {
    lease._closed = true;
    _leases.remove(lease);
    final engine = lease._engine;
    lease._engine = null;
    if (engine == null) {
      return;
    }
    await _stop(engine);
    _park(engine);
  });

  /// Keeps a stopped [engine] for the next lease, or disposes it beyond [maxIdle]
  void _park(PlaybackEngine engine) {
    final idle = _idle.putIfAbsent(engine.kind, () => []);
    if (!_disposed && idle.length < maxIdle) {
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

  Future<void> _disposeEngine(PlaybackEngine engine) async {
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

  /// The player held, null before the first [acquire], while suspended and once released
  PlaybackEngine? get engine => _engine;

  /// Whether the pool took the player away since the last [acquire]
  bool get isSuspended => _suspended;

  bool get isClosed => _closed;

  /// The player of this lease: the one it holds, an idle one, a new one, or the one of the lease used longest ago.
  /// Clears [isSuspended]: the owner reopens its video in it.
  Future<PlaybackEngine> acquire() async {
    touch();
    final engine = await _pool._acquire(this);
    _suspended = false;
    return engine;
  }

  /// Marks the lease as just used (a play, a seek), so that the pool takes another one's player first
  void touch() => _lastUsed = ++_pool._clock;

  /// Gives the player back, stopped; the lease is not used again
  Future<void> release() => _pool._release(this);
}

PlayerPool? _shared;

/// The pool of the app's players, made on first use
PlayerPool get desktopPlayerPool => _shared ??= PlayerPool(create: DesktopPlayer.create);
