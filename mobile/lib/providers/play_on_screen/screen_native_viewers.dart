// The app's own viewers that run outside the window of the app's pages, for "Play from a phone" on a big screen
// (release 53): the 360° player of Android TV (an activity of its own) and of the computers (a route over the
// window), and the immersive viewer of the Meta Quest (an activity of its own).
//
// While one of them is in front, the window of the app is stopped: the receiver keeps listening then
// (ScreenPlayerController), so that the phone keeps the screen. A phone's next item, or its Stop, closes the viewer
// first, as its close button or Back would: the page under it is the one the play replaces or closes.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/spherical_player_route.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:logging/logging.dart';

final _log = Logger('ScreenPlayer');

/// See the top of this file; a fake in the tests
abstract interface class ScreenNativeViewers {
  /// Whether one of the app's 360° or immersive viewers is open, as the sessions that opened it know
  bool get open;

  /// Closes it, as its close button does; nothing when none is open. Never throws.
  Future<void> close();
}

class AppScreenNativeViewers implements ScreenNativeViewers {
  AppScreenNativeViewers(this._ref);

  final Ref _ref;

  static const _channel = MethodChannel('app.immuch360/native_viewers');

  @override
  bool get open {
    try {
      return _ref.read(sphericalVideoSessionProvider).isOpen ||
          (CurrentPlatform.isAndroid && _ref.read(immersiveSessionProvider).isOpen);
    } catch (error) {
      _log.fine('Play from a phone: the 360° viewers did not say whether one is open (${error.runtimeType})');
      return false;
    }
  }

  @override
  Future<void> close() async {
    if (!open) {
      return;
    }
    try {
      if (CurrentPlatform.isDesktop) {
        // The 360° player of the computers is a route over the pages: only it goes
        _ref
            .read(appRouterProvider)
            .navigatorKey
            .currentState
            ?.popUntil((route) => route.settings.name != DesktopSphericalPlayerPage.routeName);
        return;
      }
      if (CurrentPlatform.isAndroid) {
        await _channel.invokeMethod<bool>('closeAll');
      }
    } catch (error) {
      _log.info('Play from a phone: the 360° viewer did not close (${error.runtimeType})');
    }
  }
}

final screenNativeViewersProvider = Provider<ScreenNativeViewers>(AppScreenNativeViewers.new);

/// The asset a phone's play asked the screen's asset viewer to open in its 360° view (ScreenPlaySphereOpener), as the
/// 360° button would: null once it opened, or for none
final screenPlaySphereRequestProvider = StateProvider<String?>((_) => null);
