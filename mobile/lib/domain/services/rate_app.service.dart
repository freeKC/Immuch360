// The invitation to rate the app (lib/domain/models/rate_app.dart): counts the opens and the viewings that ended well,
// keeps the crashes and the asks, and at the moment of the rule asks the store of the build. Google Play and the App
// Store get their own prompt with nothing of the app's before it (their rules forbid a question first, a button that
// calls them, or a review prompt of the app's own); the Quest store build gets the app's sentence, with Not now and
// Rate. The moment: a viewing just ended well, then the app shows a browse page with nothing above it for a short
// pause.
//
// The viewers, the players and the health reports tell what happens through RateAppSignals, one line each, so that the
// files of Immich carry no more than that line. Nothing of it leaves the device.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/rate_app.dart';
import 'package:logging/logging.dart';

final _log = Logger('RateApp');

// The viewers that are activities of their own over the app: the app is paused while they show
const _nativeViewings = {
  RateAppViewing.immersive,
  RateAppViewing.sphericalVideo,
  RateAppViewing.spatialVideo,
  RateAppViewing.splat,
};

/// Where the state of the invitation is kept (StoreKey.rateAppState); tests replace it
class RateAppMemory {
  const RateAppMemory({required this.read, required this.write});

  final String? Function() read;
  final Future<void> Function(String text) write;
}

/// The store of the build (StoreReviewApi)
abstract interface class RateAppStoreApi {
  /// The store's review prompt: Play's card, StoreKit's prompt. True when the request went through
  Future<bool> requestReview();

  /// The page of the app on the store of the build, or its address in the browser. True when something opened
  Future<bool> openStorePage();
}

/// What the app shows, and the app's own invitation
abstract interface class RateAppScreen {
  /// Whether the app is in the foreground on a browse page (the tabs of the app) with nothing above it
  bool get browsing;

  /// The kiosk mode of the Quest is on
  bool get kioskActive;

  /// The version warning of the profile menu is present
  bool get versionWarning;

  /// Shows the app's invitation and gives what the user chose (Back or a tap outside is Not now); null when it could
  /// not show
  Future<RateAppAnswer?> showInvite();
}

/// See the top of this file
class RateAppService {
  RateAppService({
    required this.channel,
    required this.build,
    required this.memory,
    required this.store,
    required this.screen,
    DateTime Function()? now,
    this.enabled = kRateAppInvite,
    this.screenshotMode = false,
    this.useForegroundMarker = false,
    this.settle = kRateAppSettle,
  }) : _now = now ?? DateTime.now;

  /// The store of this build
  final RateAppChannel channel;

  /// PackageInfo.buildNumber
  final int build;

  /// [kRateAppInvite]
  final bool enabled;

  /// The store captures (kScreenshotMode): nothing is asked
  final bool screenshotMode;

  /// Whether a crash is told by the marker of the foreground (iOS, and Android before 11), rather than by the exit
  /// reports of AppHealth.kt
  final bool useForegroundMarker;

  /// The pause on a browse page before an ask
  final Duration settle;

  /// Where the state is kept
  final RateAppMemory memory;

  /// The review prompt and the page of the store
  final RateAppStoreApi store;

  /// What the app shows, and its own invitation
  final RateAppScreen screen;

  final DateTime Function() _now;

  RateAppState _state = const RateAppState();
  Future<void> _writes = Future.value();

  // The viewings open, since when, and those during which a video could not play
  final _open = <RateAppViewing, DateTime>{};
  final _spoiled = <RateAppViewing>{};
  DateTime? _lastSuccess;

  // A viewing ended well: the next browse page may ask
  bool _pending = false;
  bool _asking = false;
  Timer? _settleTimer;
  DateTime? _backgroundAt;

  /// The state kept now
  RateAppState get state => _state;

  /// The last decision taken: "due", or why the app did not ask (the lab tests read it)
  String? lastDecision;

  /// Reads the state, tells a run that ended in the foreground (with [useForegroundMarker]), and counts this start
  Future<void> start() async {
    _state = RateAppState.decode(
      memory.read(),
      onError: (error) => _log.warning('The kept state did not read, counting again from now: $error'),
    );
    final lastBuild = _state.build;
    if (useForegroundMarker && _state.foreground && lastBuild != null) {
      _log.info('The last run of build $lastBuild ended in the foreground');
      _state = _state.copyWith(problemBuild: lastBuild, problemAt: _now());
    }
    _opened();
    if (useForegroundMarker) {
      _state = _state.copyWith(foreground: true);
    }
    await _save();
  }

  /// The app came back to the foreground: an open after [kRateAppReopenAfter] away
  void resumed() {
    final away = _backgroundAt;
    _backgroundAt = null;
    if (away != null && _now().difference(away) >= kRateAppReopenAfter) {
      _opened();
      unawaited(_save());
    }
    if (useForegroundMarker && !_state.foreground) {
      _state = _state.copyWith(foreground: true);
      unawaited(_save());
    }
    _schedule();
  }

  /// The app left the foreground. A native viewer open over it (the immersive viewer of the Quest, the players, the
  /// splat viewer) is not time away; the 360° photo viewer of the app is a page of it, and does not count here
  void paused() {
    _settleTimer?.cancel();
    if (!_open.keys.any(_nativeViewings.contains)) {
      _backgroundAt ??= _now();
    }
    if (useForegroundMarker && _state.foreground) {
      _state = _state.copyWith(foreground: false);
      unawaited(_save());
    }
  }

  /// The app shows another page
  void pageShown() => _schedule();

  /// A viewing of [kind] opens
  void viewingOpened(RateAppViewing kind) {
    _open[kind] = _now();
    _spoiled.remove(kind);
  }

  /// The viewing of [kind] closed; [normal] false when it ended on an error (the splat renderer gone)
  void viewingClosed(RateAppViewing kind, {bool normal = true}) {
    final since = _open.remove(kind);
    final spoiled = _spoiled.remove(kind);
    if (since == null) {
      return;
    }
    final open = _now().difference(since);
    if (spoiled || !rateAppViewingCounts(open, normal: normal)) {
      _log.fine(
        'A ${kind.name} viewing of ${open.inSeconds} s does not count'
        '${spoiled ? ', a video could not play' : ''}${normal ? '' : ', it ended on an error'}',
      );
      return;
    }
    succeeded(kind);
  }

  /// A viewing of [kind] ended well: a film turned watched, or a viewer that stayed open long enough
  void succeeded(RateAppViewing kind) {
    final now = _now();
    final last = _lastSuccess;
    _lastSuccess = now;
    // The film of the immersive viewer is also recorded as watched as it closes: one viewing
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _state = _state.copyWith(successes: _state.successes + 1);
    unawaited(_save());
    _log.info('A ${kind.name} viewing ended well (${_state.successes})');
    _pending = true;
    _schedule();
  }

  /// A video could not play (AppHealth): the viewings open now do not count
  void videoProblem() => _spoiled.addAll(_open.keys);

  /// An exit report of AppHealth.kt: a crash of a build blocks the asks in that build
  void exitReported(String text) {
    if (!rateAppExitIsCrash(text)) {
      return;
    }
    final crashed = rateAppExitBuild(text) ?? build;
    _log.info('A crash of build $crashed was reported');
    _state = _state.copyWith(problemBuild: crashed, problemAt: _now());
    unawaited(_save());
  }

  /// The What's new notice showed
  void noticeShown() {
    _state = _state.copyWith(noticeAt: _now());
    unawaited(_save());
  }

  /// Stops the pending pause
  void dispose() => _settleTimer?.cancel();

  void _opened() => _state = rateAppOpened(_state, now: _now(), build: build);

  void _schedule() {
    if (!_pending || _asking) {
      return;
    }
    _settleTimer?.cancel();
    _settleTimer = Timer(settle, () => unawaited(_settled()));
  }

  Future<void> _settled() async {
    if (!_pending || _asking || !screen.browsing) {
      return;
    }
    final reason = rateAppBlocker(
      _state,
      RateAppContext(
        channel: channel,
        build: build,
        now: _now(),
        enabled: enabled,
        screenshotMode: screenshotMode,
        kioskActive: screen.kioskActive,
        versionWarning: screen.versionWarning,
      ),
    );
    _pending = false;
    lastDecision = reason ?? 'due';
    if (reason != null) {
      _log.info(reason);
      return;
    }
    _asking = true;
    try {
      await _ask();
    } catch (error, stackTrace) {
      _log.warning('The invitation did not go through', error, stackTrace);
    } finally {
      _asking = false;
    }
  }

  Future<void> _ask() async {
    if (channel == RateAppChannel.horizonStore) {
      _log.info('Due: the invitation of the app shows');
      final answer = await screen.showInvite();
      if (answer == null) {
        _log.info('The invitation could not show');
        return;
      }
      _record(answer);
      await _save();
      _log.info('The invitation was answered: ${answer.name}');
      if (answer == RateAppAnswer.rate && !await store.openStorePage()) {
        _log.warning('The store page did not open');
      }
      return;
    }
    // Play and StoreKit never say whether their prompt showed: the ask counts as made, before the request
    _log.info('Due: the review prompt of ${channel.name} is asked');
    _record(RateAppAnswer.none);
    await _save();
    final went = await store.requestReview();
    _log.info(went ? 'The review prompt was asked' : 'The review prompt could not be asked');
  }

  void _record(RateAppAnswer answer) =>
      _state = rateAppAsked(_state, RateAppAsk(build: build, at: _now(), channel: channel, answer: answer));

  Future<void> _save() {
    final text = _state.encode();
    return _writes = _writes.then((_) => memory.write(text)).catchError((Object error) {
      _log.warning('Could not keep the state of the invitation: $error');
    });
  }
}

/// The one line entry of the viewers, the players and the health reports into the invitation: nothing happens while
/// no service listens (a build that asks nothing, the computers, a background engine). The exit reports and the What's
/// new notice told before the service started are kept for it.
abstract final class RateAppSignals {
  static RateAppService? _service;
  static final _exits = <String>[];
  static bool _notice = false;

  /// The service that listens, null for none
  static RateAppService? get service => _service;

  /// [service] listens from now on (null: none), and gets what was told before it
  static void register(RateAppService? service) {
    _service?.dispose();
    _service = service;
    if (service == null) {
      return;
    }
    for (final text in _exits) {
      service.exitReported(text);
    }
    _exits.clear();
    if (_notice) {
      service.noticeShown();
      _notice = false;
    }
  }

  static void viewingOpened(RateAppViewing kind) => _service?.viewingOpened(kind);

  static void viewingClosed(RateAppViewing kind, {bool normal = true}) => _service?.viewingClosed(kind, normal: normal);

  static void succeeded(RateAppViewing kind) => _service?.succeeded(kind);

  static void videoProblem() => _service?.videoProblem();

  static void pageShown() => _service?.pageShown();

  static void exitReported(String text) {
    final service = _service;
    if (service != null) {
      service.exitReported(text);
    } else if (_exits.length < 16) {
      _exits.add(text);
    }
  }

  static void noticeShown() {
    final service = _service;
    if (service != null) {
      service.noticeShown();
    } else {
      _notice = true;
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _service?.dispose();
    _service = null;
    _exits.clear();
    _notice = false;
  }
}
