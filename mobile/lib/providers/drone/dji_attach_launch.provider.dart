// The plug of a DJI remote that brought the app forward through its attach entry, after the pilot said yes to "Open
// this screen when the remote is plugged in" (p2/design-ux-phone-2026-10-24.md, 8.4). The live screen opens once the
// app is past its start (the splash, a sign in), and not a second time when it is already in the stack. Android's own
// question and the USB permission that comes with its answer are the native side's; nothing here reaches the remote.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_tile.widget.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:logging/logging.dart';

final _log = Logger('DjiAttachLaunch');

class DjiAttachLaunch {
  DjiAttachLaunch(this._ref);

  final Ref _ref;

  /// A plug brought the app forward and the live screen is not open yet
  bool _pending = false;

  /// The router listened to while the app is still on its start
  StackRouter? _waiting;

  /// The app came to the front, at its start or on a resume: a plug that brought it opens the live screen
  Future<void> check() async {
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

  void _open() {
    if (!_pending) {
      return;
    }
    final router = _ref.read(appRouterProvider);
    if (!router.isRouteActive(TabShellRoute.name)) {
      // Still on the splash or a sign in: the router says when the app is in
      if (_waiting == null) {
        _waiting = router;
        router.addListener(_open);
      }
      return;
    }
    _pending = false;
    _waiting?.removeListener(_open);
    _waiting = null;
    if (router.isRouteActive(DjiLiveRoute.name)) {
      return;
    }
    unawaited(router.push(const DjiLiveRoute()));
  }
}

final djiAttachLaunchProvider = Provider<DjiAttachLaunch>((ref) => DjiAttachLaunch(ref));
