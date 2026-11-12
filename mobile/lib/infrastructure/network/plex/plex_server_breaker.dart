// The health of each Plex server as this app sees it: a breaker shared by every request to one server (its films
// list, film page, pictures, tracks, downloads and the media bridge's reads all go through PlexFileSystem).
//
// On 11 November 2026 a test server dropped its listener after an evening of playback: the app sent 94 requests in
// 76 s, up to 14 at once, every one refused, each tile's picture and each page asking again on its own. The breaker
// stops that: after [PlexServerBreaker.threshold] network failures in a row (refused, reset, no answer in time) it
// opens, and the calls fail at once without touching the network, but for one probe at a time, let through after a
// wait that doubles from [PlexServerBreaker.firstProbeDelay] up to [PlexServerBreaker.maxProbeDelay]. While open, a
// timer lets that probe through by itself ([PlexServerBreaker.onProbe], the connection asks /identity), so that the
// pages showing "The Plex server stopped answering" come back alone once the server answers again; it stops after
// [PlexServerBreaker.probeFor] without a request, so a phone left on the error page does not ask all night. A Retry
// of the user lets one probe through at once ([PlexServerBreaker.probeNow]).
//
// The breaker also remembers whether the server answered in this run of the app ([PlexServerBreaker.everReached]):
// a failure then is a server that stopped, never a reason to tell the user to set up remote access.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

final _log = Logger('PlexServerBreaker');

/// Where a breaker stands
enum PlexBreakerState {
  /// Requests go to the server
  closed,

  /// The server stopped answering: requests fail at once, but one probe at a time
  open,
}

/// The breaker of one server, see the top of this file. Not thread safe beyond the Dart event loop, which is all the
/// app needs.
class PlexServerBreaker extends ChangeNotifier {
  PlexServerBreaker({
    this.threshold = defaultThreshold,
    this.firstProbeDelay = defaultFirstProbeDelay,
    this.maxProbeDelay = defaultMaxProbeDelay,
    this.probeFor = defaultProbeFor,
    DateTime Function()? clock,
  }) : assert(threshold > 0),
       _clock = clock ?? DateTime.now;

  /// Network failures in a row that open the breaker
  final int threshold;

  /// The wait before the first probe once open; it doubles after each failed probe
  final Duration firstProbeDelay;

  /// The longest wait between two probes
  final Duration maxProbeDelay;

  /// How long the breaker keeps probing by itself after the last request it refused or let through
  final Duration probeFor;

  static const defaultThreshold = 3;
  static const defaultFirstProbeDelay = Duration(seconds: 2);
  static const defaultMaxProbeDelay = Duration(seconds: 30);
  static const defaultProbeFor = Duration(minutes: 10);

  final DateTime Function() _clock;

  PlexBreakerState _state = PlexBreakerState.closed;
  int _failures = 0;
  Duration _delay = Duration.zero;
  DateTime? _nextProbe;
  bool _probing = false;
  DateTime? _lastSuccess;
  DateTime _lastDemand = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _timer;
  bool _disposed = false;

  /// What the last failure of the network was told as, kept by the connection for the calls refused before the server
  /// ever answered
  Object? lastFailure;

  /// What the timer of an open breaker runs to let a probe through by itself: a light request of the connection
  /// (/identity) that goes through [admit] like any other. Null when no connection is open.
  Future<void> Function()? onProbe;

  PlexBreakerState get state => _state;
  bool get isOpen => _state == PlexBreakerState.open;

  /// Network failures in a row so far
  int get failures => _failures;

  /// Whether the server answered once in this run of the app
  bool get everReached => _lastSuccess != null;

  /// When the server last answered, null when never in this run
  DateTime? get lastSuccess => _lastSuccess;

  /// The wait before the next probe of an open breaker, zero when one may go now; zero when closed
  Duration get retryIn {
    final next = _nextProbe;
    if (!isOpen || next == null) {
      return Duration.zero;
    }
    final left = next.difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }

  /// A permit for a request to the server now, null when it must not go. Closed: always. Open: once the probe wait is
  /// over and no other probe is under way, and that request is then the probe; every other call is refused, and must
  /// not touch the network. A request let through ends with [answered], [failed] or [released] of its permit.
  PlexBreakerPermit? admit() {
    _lastDemand = _clock();
    if (!isOpen) {
      return const PlexBreakerPermit._(false);
    }
    if (_probing) {
      return null;
    }
    final next = _nextProbe;
    if (next != null && _clock().isBefore(next)) {
      return null;
    }
    _probing = true;
    return const PlexBreakerPermit._(true);
  }

  /// The server answered, whatever it said (a 404 or a 401 is an answer: the server is there): closes the breaker
  void answered(PlexBreakerPermit permit) {
    _lastSuccess = _clock();
    _failures = 0;
    if (permit.isProbe) {
      _probing = false;
    }
    if (isOpen) {
      _log.info('The Plex server answers again');
      _state = PlexBreakerState.closed;
      _probing = false;
      _delay = Duration.zero;
      _nextProbe = null;
      _timer?.cancel();
      _timer = null;
      _notify();
    }
  }

  /// A request let through failed on the network (refused, reset, no answer in time). Closed, it counts toward
  /// [threshold]. Open, a failed probe pushes the next one further, its wait doubled up to [maxProbeDelay]; the
  /// requests that were under way when the breaker opened change nothing.
  void failed(PlexBreakerPermit permit) {
    if (isOpen) {
      if (!permit.isProbe) {
        return;
      }
      _probing = false;
      _failures++;
      _delay = _delay * 2 > maxProbeDelay ? maxProbeDelay : _delay * 2;
      _nextProbe = _clock().add(_delay);
      _schedule();
      _notify();
      return;
    }
    _failures++;
    if (_failures >= threshold) {
      _log.info('The Plex server stopped answering after $_failures failures: one probe at a time from now on');
      _state = PlexBreakerState.open;
      _probing = false;
      _delay = firstProbeDelay;
      _nextProbe = _clock().add(_delay);
      _schedule();
      _notify();
    }
  }

  /// A request let through ended without telling anything of the server (stopped by its caller)
  void released(PlexBreakerPermit permit) {
    if (permit.isProbe && isOpen) {
      _probing = false;
      _schedule();
    }
  }

  /// The user asked to try again: the next request is the probe, at once
  void probeNow() {
    _lastDemand = _clock();
    if (!isOpen) {
      return;
    }
    _nextProbe = _clock();
    _schedule();
  }

  /// Back to the first state, for the tests and when the source changes
  void reset() {
    _state = PlexBreakerState.closed;
    _failures = 0;
    _delay = Duration.zero;
    _nextProbe = null;
    _probing = false;
    _lastSuccess = null;
    lastFailure = null;
    _timer?.cancel();
    _timer = null;
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (_disposed || onProbe == null) {
      return;
    }
    if (_clock().difference(_lastDemand) > probeFor) {
      _log.fine('Nobody asked for the Plex server for a while: no more probes until the next request');
      return;
    }
    _timer = Timer(retryIn, _probeByItself);
  }

  void _probeByItself() {
    _timer = null;
    final probe = onProbe;
    if (!isOpen || probe == null || _probing || _disposed) {
      return;
    }
    // Due now, whatever the clock says: a timer may fire a hair before the time it was set for
    _nextProbe = _clock();
    // The probe goes through admit like any request; its end is told by the connection
    unawaited(
      probe()
          .catchError((Object _) {
            // Told through failed
          })
          .whenComplete(() {
            // A probe that did not go (its connection closed meanwhile) leaves the next one to the timer
            if (isOpen && !_probing && _timer == null) {
              _nextProbe = _clock().add(_delay);
              _schedule();
            }
          }),
    );
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// What [PlexServerBreaker.admit] gives a request let through
class PlexBreakerPermit {
  const PlexBreakerPermit._(this.isProbe);

  /// Whether the request is the probe of an open breaker
  final bool isProbe;
}

/// The breakers of the Plex servers of this run of the app, by source id: every connection to one server shares one,
/// a connection opened again included
class PlexServerBreakers {
  PlexServerBreakers._();

  static final Map<String, PlexServerBreaker> _breakers = {};

  /// The breaker of the server of [sourceId], made on first use
  static PlexServerBreaker of(String sourceId) => _breakers.putIfAbsent(sourceId, PlexServerBreaker.new);

  /// The breaker of [sourceId] when one was made, null otherwise
  static PlexServerBreaker? existing(String sourceId) => _breakers[sourceId];

  /// The user pressed Retry somewhere: each open breaker lets one probe through at once
  static void probeAllNow() {
    for (final breaker in _breakers.values) {
      breaker.probeNow();
    }
  }

  /// Forgets every breaker, for the tests
  @visibleForTesting
  static void clear() {
    for (final breaker in _breakers.values) {
      breaker.dispose();
    }
    _breakers.clear();
  }
}
