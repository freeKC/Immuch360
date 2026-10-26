// The keys of a remote pressed while a page or a dialog opens, in the remote control layout. Until the first frame of
// the new route gave it the focus, the focus is still on the page under it: OK on a tile then Down at once moved the
// focus on the page left behind, and a second OK opened another page there, under the new one (the Drone tile of the
// Library on the emulator, 26 October). So the keys that move or press are dropped from the moment a route is asked
// for until its first frame: Back goes through, and so do the media and volume keys.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';

/// The keys held while a route opens: the arrows, OK, the channel keys and Menu (Info too, which opens Options as Menu
/// does on the watch page of the drone)
final _heldKeys = {
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  ...remoteOkKeys,
  LogicalKeyboardKey.channelUp,
  LogicalKeyboardKey.channelDown,
  LogicalKeyboardKey.contextMenu,
  LogicalKeyboardKey.info,
};

/// Drops the keys of [_heldKeys] while a route opens. A route holds them from its push ([AppNavigationObserver]) until
/// the microtask after its first frame, where the observer gives a focus to a page that took none; a page added to the
/// router's stack holds them from that moment, since the router shows it only at the next frame
/// ([holdKeysOnNewPages]). Never longer than [cap] after the last hold, should a frame never come.
///
/// A press dropped is dropped whole: its repeats and its release too, whenever they come. The release of a key
/// pressed before goes through, so that a page that saw it go down (OK held) also sees it go up.
class RouteOpeningKeyGate {
  RouteOpeningKeyGate._();

  static final instance = RouteOpeningKeyGate._();

  /// The longest the keys are held after a route was asked for
  static const cap = Duration(milliseconds: 500);

  /// What holds the keys: the routes that open, and the next frame
  final _holds = <Object>{};
  final _sinceLastHold = Stopwatch();

  /// The presses dropped whose release has not come yet
  final _dropped = <PhysicalKeyboardKey>{};

  /// The focus manager the handler was added to, while there is something to hold or a release to drop
  FocusManager? _manager;

  /// The next frame holds the keys, once for any number of new pages before it
  final _nextFrame = Object();

  /// Whether the keys are held now
  bool get holds => _holds.isNotEmpty && _sinceLastHold.elapsed < cap;

  /// [route] was pushed: the keys wait until [opened]
  void opening(Route<Object?> route) => _hold(route);

  /// [route] showed its first frame and has the focus: the keys go to it
  void opened(Route<Object?> route) {
    _holds.remove(route);
    _stopIfIdle();
  }

  /// A page was asked for and shows at the next frame: the keys wait until the microtask after it
  void holdUntilNextFrame() {
    if (_holds.contains(_nextFrame)) {
      _sinceLastHold
        ..reset()
        ..start();
      return;
    }
    _hold(_nextFrame);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      scheduleMicrotask(() {
        _holds.remove(_nextFrame);
        _stopIfIdle();
      });
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _hold(Object reason) {
    _holds.add(reason);
    _sinceLastHold
      ..reset()
      ..start();
    final manager = FocusManager.instance;
    if (!identical(_manager, manager)) {
      _manager?.removeEarlyKeyEventHandler(_onKey);
      _manager = manager;
      manager.addEarlyKeyEventHandler(_onKey);
    }
  }

  /// Nothing held and no release to drop: the handler goes until the next route
  void _stopIfIdle() {
    if (_holds.isNotEmpty || _dropped.isNotEmpty) {
      return;
    }
    _manager?.removeEarlyKeyEventHandler(_onKey);
    _manager = null;
    _sinceLastHold
      ..stop()
      ..reset();
  }

  KeyEventResult _onKey(KeyEvent event) {
    final key = event.physicalKey;
    if (event is KeyUpEvent) {
      if (_dropped.remove(key)) {
        _stopIfIdle();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent && _dropped.contains(key)) {
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent) {
      // A new press: the release of the last one never came
      _dropped.remove(key);
    }
    if (_holds.isNotEmpty && _sinceLastHold.elapsed >= cap) {
      // No frame came in time: the keys go through again
      _holds.clear();
    }
    if (_holds.isEmpty || !_heldKeys.contains(event.logicalKey)) {
      _stopIfIdle();
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      _dropped.add(key);
    }
    return KeyEventResult.handled;
  }

  /// Forgets everything held and dropped, for the tests
  @visibleForTesting
  void reset() {
    _holds.clear();
    _dropped.clear();
    _stopIfIdle();
  }
}

/// In the remote control layout ([remoteLayout]), holds the keys from the moment a page is added to [router]'s stack:
/// auto_route adds it at once and shows it at the next frame only, where [AppNavigationObserver] sees its push. A page
/// that comes back on top (a pop) holds nothing. Returns the function that stops listening.
VoidCallback holdKeysOnNewPages(RoutingController router, bool Function() remoteLayout) {
  var shown = router.stack.toSet();
  void onChange() {
    final now = router.stack.toSet();
    if (remoteLayout() && now.difference(shown).isNotEmpty) {
      RouteOpeningKeyGate.instance.holdUntilNextFrame();
    }
    shown = now;
  }

  router.addListener(onChange);
  return () => router.removeListener(onChange);
}
