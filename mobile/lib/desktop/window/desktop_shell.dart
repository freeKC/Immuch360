// What concerns the whole window of Immuch360 Desktop, wrapped around the navigator inside MaterialApp (main.dart, through
// desktopAppShell): the keys that work on every page (Control A for the selection of the grid shown,
// lib/desktop/selection, Control C for the copy of the viewer or of the selection shown, lib/desktop/clipboard, and
// Escape, the one step back: see _onEscape), the back button of the mouse, Alt Left and
// Command [, full screen and the close guard, then the close itself (close_sequence.dart), and the offer to resume the
// 3D videos a quit stopped, once the main page of the library shows
// (never over the splash page, whose replacement would close it, nor over the welcome or the login pages). The viewers
// read their own keys first (remote_keys.dart): what reaches the shell is what no page handled.

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/ui/ai_updates.dart';
import 'package:immich_mobile/desktop/ai/ui/video_resume_offer.dart';
import 'package:immich_mobile/desktop/clipboard/copy_targets.dart';
import 'package:immich_mobile/desktop/selection/desktop_selection.dart';
import 'package:immich_mobile/desktop/video/av2_badge.dart';
import 'package:immich_mobile/desktop/video/desktop_video_view.dart';
import 'package:immich_mobile/desktop/video/video_frame_timings.dart';
import 'package:immich_mobile/desktop/video/xr/headset_view_service.dart';
import 'package:immich_mobile/desktop/window/close_guard.dart';
import 'package:immich_mobile/desktop/window/close_sequence.dart';
import 'package:immich_mobile/desktop/window/desktop_shortcuts.dart';
import 'package:immich_mobile/desktop/window/full_screen.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:logging/logging.dart';
import 'package:window_manager/window_manager.dart';

final _log = Logger('DesktopShell');

/// What the back button of the mouse does when the window is not full screen: what Back does on a phone, through the
/// router (the top route of the top router, a dialog first)
final desktopBackProvider = Provider<Future<bool> Function()>((ref) => ref.watch(appRouterProvider).maybePopTop);

/// Whether the root router showing the routes named [stack] (bottom first) shows the main page of the library on top:
/// the tabs, nothing pushed over them (the splash, the welcome and the login pages are never it)
bool desktopMainPageShown(List<String> stack) => stack.isNotEmpty && stack.last == TabShellRoute.name;

/// Whether the main page of the library shows now, told again at each change of the root router; the tests give
/// theirs
final desktopMainPageShownProvider = Provider<ValueListenable<bool>>((ref) {
  final router = ref.watch(appRouterProvider);
  final shown = ValueNotifier(false);
  void read() => shown.value = desktopMainPageShown([for (final page in router.stack) page.routeData.name]);
  router.addListener(read);
  read();
  ref.onDispose(() {
    router.removeListener(read);
    shown.dispose();
  });
  return shown;
});

/// Whether Flutter's own Escape (DismissIntent, which the app maps to Escape) does something for the widget that has
/// the focus at [context]: a dialog, a sheet or a menu that a click outside closes, a menu anchored on a page, the
/// suggestions of a field. As Shortcuts does, the nearest action decides.
bool answersDismiss(BuildContext context) {
  // Typed as Intent: the app's own DismissIntent is a DoNothingAction, an Action<Intent>
  const intent = DismissIntent();
  final action = Actions.maybeFind<Intent>(context, intent: intent);
  return action != null && action.isEnabled(intent);
}

/// Closes a menu anchored on a page (MenuAnchor, a sort or a ⋮ menu) that is open under [navigator], if any. Flutter
/// gives such a menu its Escape only once the arrows went into it, not when a click opened it; one walk of the tree,
/// at an Escape only.
bool closeAnchoredMenu(BuildContext navigator) {
  MenuController? open;
  void visit(Element element) {
    final widget = element.widget;
    if (widget is RawMenuAnchor && widget.controller.isOpen) {
      open = widget.controller;
      return;
    }
    if (open == null) {
      element.visitChildElements(visit);
    }
  }

  navigator.visitChildElements(visit);
  open?.close();
  return open != null;
}

/// Whether Escape may take [route] back a step: a page over another, never the main page of the library nor the first
/// page of the window (Escape never quits nor signs out)
bool canEscapePage(ModalRoute<Object?>? route) =>
    route is PageRoute && !route.isFirst && route.settings.name != TabShellRoute.name;

class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> with WindowListener {
  late final _window = ref.read(desktopWindowProvider);
  late final _fullScreen = ref.read(desktopFullScreenProvider.notifier);
  bool _closing = false;

  /// Whether the main page shows, for the offer to resume the 3D videos; null when the router is not there (a test)
  ValueListenable<bool>? _mainPage;
  var _offered = false;

  /// Stops the frame times of a playing video in the log (video_frame_timings.dart)
  late final void Function() _stopFrameTimings;

  @override
  void initState() {
    super.initState();
    // The AV2 videos of the library and of the shares get their thumbnails through it before any video opens
    ref.read(av2PlaybacksProvider);
    // Every view of an AV2 video asks its thumbnail again once the AV2 decoder is installed, not its tiles alone
    ref.read(av2ThumbnailVariantsProvider);
    _stopFrameTimings = watchVideoFrameTimings();
    // The headset view's crash guard reads its marker at the start (Windows only)
    unawaited(ref.read(headsetViewServiceProvider).startUp());
    _window.addListener(this);
    FocusManager.instance.addEarlyKeyEventHandler(_onEarlyKeyResult);
    // The 3D videos a quit or a crash stopped are offered to resume once the main page shows (video_resume_offer.dart)
    try {
      final mainPage = ref.read(desktopMainPageShownProvider)..addListener(_onMainPage);
      _mainPage = mainPage;
      _onMainPage();
    } catch (error) {
      _log.info('No router to wait for the main page: the 3D videos stopped are not offered: $error');
    }
    unawaited(
      _window.setPreventClose(true).catchError((Object error, StackTrace stack) {
        // The window then closes without asking, as any window does
        _log.warning('The close guard could not be set', error, stack);
      }),
    );
  }

  /// Once the main page shows, the offer comes after the frame that draws it, once in the life of the window
  void _onMainPage() {
    if (_offered || !mounted || !(_mainPage?.value ?? false)) {
      return;
    }
    _offered = true;
    _mainPage?.removeListener(_onMainPage);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _offerStoppedVideos();
      // The AI components a new version of the app updates, by themselves when the setting and the connection allow
      // it (issue 21, ai_updates.dart)
      if (mounted) {
        unawaited(runAiUpdatesAtStart(ref));
      }
    });
  }

  void _offerStoppedVideos() {
    if (!mounted) {
      return;
    }
    try {
      final navigator = ref.read(desktopNavigatorKeyProvider).currentContext;
      if (navigator == null) {
        _log.warning('No navigator: the 3D videos stopped are not offered');
        return;
      }
      unawaited(
        offerStoppedVideoJobs(navigator, ref).catchError((Object error, StackTrace stack) {
          _log.warning('The offer to resume the 3D videos failed', error, stack);
          return const <VideoResumeAnswer>[];
        }),
      );
    } catch (error, stack) {
      _log.warning('The offer to resume the 3D videos could not start', error, stack);
    }
  }

  @override
  void dispose() {
    _mainPage?.removeListener(_onMainPage);
    _stopFrameTimings();
    _window.removeListener(this);
    FocusManager.instance.removeEarlyKeyEventHandler(_onEarlyKeyResult);
    super.dispose();
  }

  @override
  void onWindowClose() => unawaited(_onClose());

  @override
  void onWindowEnterFullScreen() => _fullScreen.windowChanged(fullScreen: true);

  @override
  void onWindowLeaveFullScreen() => _fullScreen.windowChanged(fullScreen: false);

  Future<void> _onClose() async {
    // A second click on the close button while the dialog shows
    if (_closing) {
      return;
    }
    _closing = true;
    try {
      final reasons = ref.read(desktopCloseReasonsProvider)();
      final navigator = ref.read(desktopNavigatorKeyProvider).currentContext;
      if (reasons.isNotEmpty && navigator != null && !await confirmDesktopClose(navigator, reasons)) {
        return;
      }
      beginDesktopClose(ref.read(desktopCloseLogWritesProvider));
      await _window.prepareClose();
      // Each step bounded: whatever plays, and whatever the share or the server does, the window goes
      await runDesktopClose(ref.read(desktopCloseStepsProvider)());
      await _window.destroy();
    } catch (error, stack) {
      _log.severe('The window could not be closed', error, stack);
    } finally {
      _closing = false;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = desktopWindowKeyOf(event);
    if (key == null) {
      return KeyEventResult.ignored;
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    final route = focused == null ? null : ModalRoute.of(focused);
    switch (key) {
      case DesktopWindowKey.toggleFullScreen:
        unawaited(_fullScreen.toggle(from: route));
        return KeyEventResult.handled;
      case DesktopWindowKey.toggleFullScreenInViewer:
        if (focused == null || !isInViewer(focused, _fullScreen)) {
          return KeyEventResult.ignored;
        }
        unawaited(_fullScreen.toggle(from: route));
        return KeyEventResult.handled;
      case DesktopWindowKey.escape:
        return _onEscape(focused, route);
      case DesktopWindowKey.back:
        // Read before the pages by _onEarlyKey, so that a viewer does not take Alt Left for its left arrow
        return KeyEventResult.ignored;
      case DesktopWindowKey.closeViewer:
        return _closeViewer(focused);
      case DesktopWindowKey.selectAll:
        // Under a dialog or a menu, the grid behind it is not the one shown
        final grid = DesktopSelectionTargets.active;
        if (grid == null || route is PopupRoute) {
          return KeyEventResult.ignored;
        }
        unawaited(grid.selectAll());
        return KeyEventResult.handled;
      case DesktopWindowKey.copy:
        // The viewer or the grid shown, never what lies under a dialog or a menu
        final target = DesktopCopyTargets.active;
        if (target == null || route is PopupRoute) {
          return KeyEventResult.ignored;
        }
        unawaited(target.copy());
        return KeyEventResult.handled;
      case DesktopWindowKey.toggleHeadsetView:
      case DesktopWindowKey.recenterHeadsetView:
        // A player on screen, or a headset view running (xr/headset_view_service.dart); a dialog or a menu keeps H
        if (route is PopupRoute || !ref.exists(headsetViewServiceProvider)) {
          return KeyEventResult.ignored;
        }
        final headset = ref.read(headsetViewServiceProvider);
        if (!headset.handlesKeys) {
          return KeyEventResult.ignored;
        }
        if (key == DesktopWindowKey.recenterHeadsetView) {
          unawaited(headset.recenter());
        } else {
          unawaited(headset.toggle(locale: context.locale));
        }
        return KeyEventResult.handled;
    }
  }

  /// Escape, the one step back of the desktop, in this order:
  /// 1. what answers Flutter's own Escape (DismissIntent) does it: a dialog, a sheet or a menu that a click outside
  ///    closes, a menu anchored on the page, the suggestions of a field; a field with its own Escape (the search of
  ///    the films) took it before the shell;
  /// 2. a dialog that a click outside does not close: one whose Back is its Cancel (a PopScope, as the preparation of
  ///    a splat) gets it, a progress keeps Escape away (Escape never stops what a progress shows);
  /// 3. a menu anchored on the page that a click opened closes (closeAnchoredMenu);
  /// 4. a field typed in lets go of the keyboard, so that the next Escape goes on;
  /// 5. the menu of the grid's selection closes, else its selection clears;
  /// 6. full screen is left;
  /// 7. the viewer closes;
  /// 8. the page shown goes back as its back arrow would (Navigator.maybePop: its PopScope still has a say, the
  ///    discard dialog of an edit for one); never the main page of the library, the first page of the window
  KeyEventResult _onEscape(BuildContext? focused, ModalRoute<Object?>? route) {
    if (focused == null) {
      return KeyEventResult.ignored;
    }
    // A field answers DismissIntent itself (it hides its toolbar, else passes it on): what decides is above it
    final typing = isTypingText();
    final field = typing ? focused.findAncestorStateOfType<EditableTextState>()?.context : null;
    if (answersDismiss(field ?? focused)) {
      return KeyEventResult.ignored;
    }
    if (route is PopupRoute) {
      // A sheet with a Scaffold of its own hides the Escape of its route behind that of its drawer
      if (route.barrierDismissible) {
        unawaited(Navigator.of(focused).maybePop());
        return KeyEventResult.handled;
      }
      return _popGuarded(focused, route) ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (closeAnchoredMenu(Navigator.of(focused).context)) {
      return KeyEventResult.handled;
    }
    if (typing) {
      FocusManager.instance.primaryFocus?.unfocus();
      return KeyEventResult.handled;
    }
    final grid = DesktopSelectionTargets.active;
    if (grid != null && grid.isMenuOpen) {
      grid.closeMenu();
      return KeyEventResult.handled;
    }
    if (grid != null && grid.hasSelection) {
      grid.clear();
      return KeyEventResult.handled;
    }
    if (ref.read(desktopFullScreenProvider)) {
      unawaited(_fullScreen.leave());
      return KeyEventResult.handled;
    }
    if (isInViewer(focused, _fullScreen)) {
      return _closeViewer(focused);
    }
    if (!canEscapePage(route)) {
      return KeyEventResult.ignored;
    }
    unawaited(Navigator.of(focused).maybePop());
    return KeyEventResult.handled;
  }

  /// A dialog that a click outside does not close, whose Back is its Cancel (a PopScope that keeps it): Back is given
  /// to it. A progress without one stays.
  bool _popGuarded(BuildContext focused, PopupRoute<Object?> route) {
    if (route.popDisposition != RoutePopDisposition.doNotPop) {
      return false;
    }
    unawaited(Navigator.of(focused).maybePop());
    return true;
  }

  KeyEventResult _onEarlyKeyResult(KeyEvent event) =>
      _onEarlyKey(event) ? KeyEventResult.handled : KeyEventResult.ignored;

  /// Alt Left, Command [, read before the pages (a viewer would take Alt Left for its left arrow)
  bool _onEarlyKey(KeyEvent event) {
    if (!mounted || desktopWindowKeyOf(event) != DesktopWindowKey.back) {
      return false;
    }
    return _goBack();
  }

  /// The back button of a mouse, Alt Left and Command [: a dialog closes as on Escape (a progress stays), else full
  /// screen is left, else the router goes back as Back does on a phone
  bool _goBack() {
    final focused = FocusManager.instance.primaryFocus?.context;
    final route = focused == null ? null : ModalRoute.of(focused);
    if (focused != null && route is PopupRoute) {
      if (route.barrierDismissible) {
        unawaited(Navigator.of(focused).maybePop());
        return true;
      }
      return _popGuarded(focused, route);
    }
    if (ref.read(desktopFullScreenProvider)) {
      unawaited(_fullScreen.leave());
      return true;
    }
    unawaited(ref.read(desktopBackProvider)());
    return true;
  }

  /// Closes the viewer that has the focus, as its Close button would (its PopScope still has a say)
  KeyEventResult _closeViewer(BuildContext? focused) {
    if (focused == null || !isInViewer(focused, _fullScreen)) {
      return KeyEventResult.ignored;
    }
    unawaited(Navigator.of(focused).maybePop());
    return KeyEventResult.handled;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (isMouseBackButton(event)) {
      _goBack();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      child: Focus(
        debugLabel: 'Desktop window keys',
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: widget.child,
      ),
    );
  }
}
