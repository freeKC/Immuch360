// Full screen on a computer (design 4.4): F11 anywhere, F and the full screen button in the viewers, Escape and the
// back button of the mouse to leave (DesktopShell). The window itself goes full screen through window_manager; no full
// screen route of a player is used, so the viewers keep their own controls.
//
// Leaving the viewer that went full screen leaves full screen too, so that the grid never stays full screen by
// surprise. A viewer that gives way to another one (the next photo of a network folder replaces its page, the 360°
// view of a share photo closes onto it) keeps it: the viewers that show a full screen button tell this file where they
// are, and full screen follows the one on top.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:logging/logging.dart';
import 'package:window_manager/window_manager.dart';

final _log = Logger('DesktopFullScreen');

/// The window of the app, behind a class of its own so that the tests replace window_manager, which needs the runner
class DesktopWindow {
  const DesktopWindow();

  Future<void> setFullScreen(bool fullScreen) => windowManager.setFullScreen(fullScreen);

  /// While true, the close button of the window only tells the listeners (onWindowClose), see close_guard.dart
  Future<void> setPreventClose(bool preventClose) => windowManager.setPreventClose(preventClose);

  /// Closes the window and ends the app, once the close guard let it go
  Future<void> destroy() => windowManager.destroy();

  void addListener(WindowListener listener) => windowManager.addListener(listener);

  void removeListener(WindowListener listener) => windowManager.removeListener(listener);
}

final desktopWindowProvider = Provider<DesktopWindow>((ref) => const DesktopWindow());

/// The routes of the viewers, by name: the photo and video viewers of the timeline, the 360° photo view, the memories
/// and the slideshow, the photos and videos of the network shares. A viewer opened without a name (the 360° view of a
/// share photo) is known by its full screen button. Panorama360Route and VideoRoute are not here: despite their names
/// they are grids (the 360° list of the Library, the Videos of Search), where F and Escape do nothing.
const desktopViewerRouteNames = {
  AssetViewerRoute.name,
  PanoramaViewerRoute.name,
  MemoryRoute.name,
  SlideshowRoute.name,
  NetworkPhotoRoute.name,
  NetworkVideoRoute.name,
};

/// Whether full screen is on. Changed through [toggle], [enter] and [leave]; also follows the window when the system
/// takes it out of full screen (the green button of macOS).
class DesktopFullScreen extends Notifier<bool> {
  /// The routes of the viewers that show a full screen button now
  final _viewers = <ModalRoute<Object?>>{};

  /// The viewer that went full screen: leaving it leaves full screen
  ModalRoute<Object?>? _viewer;

  @override
  bool build() => false;

  /// Whether [route] is the route of a viewer
  bool isViewer(ModalRoute<Object?>? route) =>
      route != null && (_viewers.contains(route) || desktopViewerRouteNames.contains(route.settings.name));

  /// Called by [DesktopFullScreenButton]: [route] is a viewer as long as the button is there
  void attachViewer(ModalRoute<Object?> route) => _viewers.add(route);

  void detachViewer(ModalRoute<Object?> route) => _viewers.remove(route);

  /// Full screen on or off; [from] is the route of the page that asked, for the rule at the top of this file
  Future<void> toggle({ModalRoute<Object?>? from}) => state ? leave() : enter(from: from);

  Future<void> enter({ModalRoute<Object?>? from}) async {
    _follow(isViewer(from) ? from : null);
    if (state) {
      return;
    }
    state = true;
    await _apply(true);
  }

  Future<void> leave() async {
    _viewer = null;
    if (!state) {
      return;
    }
    state = false;
    await _apply(false);
  }

  /// The window entered or left full screen by itself
  void windowChanged({required bool fullScreen}) {
    if (!fullScreen) {
      _viewer = null;
    }
    state = fullScreen;
  }

  Future<void> _apply(bool fullScreen) async {
    final window = ref.read(desktopWindowProvider);
    try {
      await window.setFullScreen(fullScreen);
    } catch (error, stack) {
      // The state stays as asked, so that the button and the keys offer the way back, which the window then takes
      _log.warning('The window could not ${fullScreen ? 'enter' : 'leave'} full screen', error, stack);
    }
  }

  void _follow(ModalRoute<Object?>? viewer) {
    _viewer = viewer;
    if (viewer == null) {
      return;
    }
    unawaited(
      viewer.popped.then((_) {
        if (_viewer == viewer) {
          // Once the page under it, or the one that replaced it, is built
          SchedulerBinding.instance.addPostFrameCallback((_) => _afterViewerGone(viewer));
          SchedulerBinding.instance.scheduleFrame();
        }
      }),
    );
  }

  void _afterViewerGone(ModalRoute<Object?> gone) {
    if (_viewer != gone) {
      return;
    }
    final next = _viewers.where((route) => route != gone && route.isCurrent).firstOrNull;
    if (next != null) {
      _follow(next);
      return;
    }
    unawaited(leave());
  }
}

final desktopFullScreenProvider = NotifierProvider<DesktopFullScreen, bool>(DesktopFullScreen.new);

/// The full screen button of a viewer's app bar on a computer. Labelled for screen readers by its tooltip.
class DesktopFullScreenButton extends ConsumerStatefulWidget {
  const DesktopFullScreenButton({super.key});

  @override
  ConsumerState<DesktopFullScreenButton> createState() => _DesktopFullScreenButtonState();
}

class _DesktopFullScreenButtonState extends ConsumerState<DesktopFullScreenButton> {
  late final _fullScreen = ref.read(desktopFullScreenProvider.notifier);
  ModalRoute<Object?>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      final previous = _route;
      if (previous != null) {
        _fullScreen.detachViewer(previous);
      }
      _route = route;
      if (route != null) {
        _fullScreen.attachViewer(route);
      }
    }
  }

  @override
  void dispose() {
    final route = _route;
    if (route != null) {
      _fullScreen.detachViewer(route);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fullScreen = ref.watch(desktopFullScreenProvider);
    return IconButton(
      key: const Key('desktop_full_screen'),
      icon: Icon(fullScreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded),
      tooltip: fullScreen ? context.t.desktop_exit_full_screen : context.t.desktop_full_screen,
      onPressed: () => unawaited(_fullScreen.toggle(from: _route)),
    );
  }
}

/// Whether [context] is inside a viewer (see [desktopViewerRouteNames]); the 360° view of a share photo has no route
/// name of its own
bool isInViewer(BuildContext context, DesktopFullScreen fullScreen) =>
    fullScreen.isViewer(ModalRoute.of(context)) || context.findAncestorWidgetOfExactType<PanoramaViewerPage>() != null;
