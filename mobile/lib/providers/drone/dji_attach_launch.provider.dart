// The plug of a DJI remote that brought the app forward through its attach entry, with "Open this screen when the
// remote is plugged in" on (p2/design-ux-phone-2026-10-24.md, 8.4; on by default since FreeKC's rule of 25 October).
// The live screen opens once the app is past its start (the splash, a sign in), and not a second time when it is
// already in the stack. Android's own question and the USB permission that comes with its answer are the native
// side's; nothing here reaches the remote.
//
// The decision reads the whole stack of the root router, not the visible route: with the live screen on top, the tab
// shell under it is not "active" for the router, and a plug answered while the screen was open must not push a second
// live screen once the pilot leaves the first (review of 24 October 2026, finding 1).

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_tile.widget.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:logging/logging.dart';

final _log = Logger('DjiAttachLaunch');

/// What a plug that brought the app forward does, from the names of the routes in the root router's stack
enum DjiAttachLaunchStep {
  /// The live screen is in the stack already, visible or under Diagnostics: the plug is done with
  done,

  /// The app is still on its splash or a sign in: wait for the router to reach the tabs
  wait,

  /// The app is past its start and no live screen is open: open one
  open,
}

/// The step for a root stack holding the routes named [stack], bottom first. Pure, so that it is tested with a fake
/// stack.
DjiAttachLaunchStep djiAttachLaunchStep(Iterable<String> stack) {
  if (stack.contains(DjiLiveRoute.name)) {
    return DjiAttachLaunchStep.done;
  }
  if (!stack.contains(TabShellRoute.name)) {
    return DjiAttachLaunchStep.wait;
  }
  return DjiAttachLaunchStep.open;
}

class DjiAttachLaunch {
  DjiAttachLaunch(this._ref);

  final Ref _ref;

  /// A plug brought the app forward and the live screen is not open yet
  bool _pending = false;

  /// The router listened to while the app is still on its start
  StackRouter? _waiting;

  /// The app came to the front, at its start or on a resume: the entry follows the settings, and a plug that brought
  /// it opens the live screen
  Future<void> check() async {
    await applyEntry();
    if (!_ref.read(djiLinkEnabledProvider)) {
      return;
    }
    bool launched;
    try {
      launched = await _ref.read(djiLinkApiProvider).takeAttachLaunch();
    } catch (error) {
      _log.fine('No answer about the attach entry: $error');
      return;
    }
    if (!launched) {
      return;
    }
    _log.info('A DJI remote was plugged in: the live screen opens');
    _pending = true;
    _open();
  }

  /// Tells the native side whether the entry may be offered for the cable: with the DJI live video on, on a phone or a
  /// tablet. "Open this screen when the remote is plugged in" is on by default there, so a fresh install opens the live
  /// screen at the first plug once it ran once; a TV and the Quest only watch a phone's relay and never offer it. Off
  /// Android there is no DJI link and nothing to tell: no call at each start and resume on iOS or a computer.
  Future<void> applyEntry() async {
    if (!_ref.read(djiLinkSupportedProvider)) {
      return;
    }
    try {
      await _ref.read(isHorizonOsProvider.future);
    } catch (_) {
      // Not known: the Quest is told again at the next resume
    }
    final offered = _ref.read(djiLinkEnabledProvider) && !_ref.read(djiReceiverOnlyProvider);
    await _ref.read(djiLiveSettingSyncProvider)(offered);
  }

  void _open() {
    if (!_pending) {
      return;
    }
    final router = _ref.read(appRouterProvider);
    final step = djiAttachLaunchStep(router.stackData.map((route) => route.name));
    if (step == DjiAttachLaunchStep.wait) {
      // Still on the splash or a sign in: the router says when the app is in
      if (_waiting == null) {
        _waiting = router;
        router.addListener(_open);
      }
      return;
    }
    // Opened here or by any other way meanwhile: the plug is answered either way
    _pending = false;
    _waiting?.removeListener(_open);
    _waiting = null;
    if (step == DjiAttachLaunchStep.open) {
      unawaited(router.push(const DjiLiveRoute()));
    }
  }
}

final djiAttachLaunchProvider = Provider<DjiAttachLaunch>((ref) => DjiAttachLaunch(ref));
