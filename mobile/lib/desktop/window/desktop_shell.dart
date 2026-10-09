// What concerns the whole window of Immuch360 Desktop, wrapped around the navigator inside MaterialApp (main.dart, through
// desktopAppShell): the keys that work on every page, the back button of the mouse, full screen and the close guard.
// The viewers read their own keys first (remote_keys.dart): what reaches the shell is what no page handled.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/window/close_guard.dart';
import 'package:immich_mobile/desktop/window/desktop_shortcuts.dart';
import 'package:immich_mobile/desktop/window/full_screen.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:logging/logging.dart';
import 'package:window_manager/window_manager.dart';

final _log = Logger('DesktopShell');

/// What the back button of the mouse does when the window is not full screen: what Back does on a phone, through the
/// router (the top route of the top router, a dialog first)
final desktopBackProvider = Provider<Future<bool> Function()>((ref) => ref.watch(appRouterProvider).maybePopTop);

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

  @override
  void initState() {
    super.initState();
    _window.addListener(this);
    unawaited(
      _window.setPreventClose(true).catchError((Object error, StackTrace stack) {
        // The window then closes without asking, as any window does
        _log.warning('The close guard could not be set', error, stack);
      }),
    );
  }

  @override
  void dispose() {
    _window.removeListener(this);
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
      case DesktopWindowKey.leaveFullScreenOrViewer:
        // A dialog, a menu or a sheet closes first, through Flutter's own Escape (DismissIntent); a text field keeps
        // its Escape too
        if (route is PopupRoute || (route?.barrierDismissible ?? false) || isTypingText()) {
          return KeyEventResult.ignored;
        }
        if (ref.read(desktopFullScreenProvider)) {
          unawaited(_fullScreen.leave());
          return KeyEventResult.handled;
        }
        return _closeViewer(focused);
      case DesktopWindowKey.closeViewer:
        return _closeViewer(focused);
    }
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
    if (!isMouseBackButton(event)) {
      return;
    }
    if (ref.read(desktopFullScreenProvider)) {
      unawaited(_fullScreen.leave());
      return;
    }
    unawaited(ref.read(desktopBackProvider)());
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
