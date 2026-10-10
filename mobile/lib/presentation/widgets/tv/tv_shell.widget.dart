import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';

/// The remote control layout (Android TV, or the setting turned on), around the whole app in the builder of
/// MaterialApp, under the theme and above the navigator:
/// - Flutter's own TV mode (NavigationMode.directional: disabled controls stay focusable, a slider leaves up and down
///   to the focus);
/// - overscan margins of 5% (48 x 27 dp), as the TV guidelines ask: TVs may cut the edges of the picture, and app
///   bars, rails, dialogs and the overlays of the viewers read MediaQuery.padding, while full screen media still fill
///   the screen;
/// - channel up and down scroll a page, and up and down leave a text field (a single line field keeps them for its
///   caret otherwise, and the focus would be stuck in it);
/// - the arrows move the focus out of a group of radio buttons too, and OK picks a choice (see
///   [radioArrowMovesFocus]);
/// - the focus highlight of Material widgets shown at all times, under the one ring of [TvFocusRing].
///
/// Off ([enabled] false), it hands everything down as it is. It stays in the tree when the setting changes so that the
/// widgets above the navigator keep their shape: the router would otherwise replay its current address as a new deep
/// link, which pushed the splash screen and started the session again on top of the open page.
class TvShell extends StatefulWidget {
  const TvShell({super.key, this.enabled = true, required this.child});

  /// Whether the remote control layout is on
  final bool enabled;

  final Widget child;

  /// The overscan margins of the TV guidelines, 5% of a 960 x 540 dp screen
  static const overscan = EdgeInsets.symmetric(horizontal: 48, vertical: 27);

  static final shortcuts = <ShortcutActivator, Intent>{
    const SingleActivator(LogicalKeyboardKey.channelUp): const ScrollIntent(
      direction: AxisDirection.up,
      type: ScrollIncrementType.page,
    ),
    const SingleActivator(LogicalKeyboardKey.channelDown): const ScrollIntent(
      direction: AxisDirection.down,
      type: ScrollIncrementType.page,
    ),
    const SingleActivator(LogicalKeyboardKey.arrowUp): const DirectionalFocusIntent(
      TraversalDirection.up,
      ignoreTextFields: false,
    ),
    const SingleActivator(LogicalKeyboardKey.arrowDown): const DirectionalFocusIntent(
      TraversalDirection.down,
      ignoreTextFields: false,
    ),
  };

  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> {
  /// The highlight strategy of the app before the remote control layout, given back when it is turned off
  FocusHighlightStrategy? _previousStrategy;

  /// Whether the highlight strategy and the radio key handler of the layout are in place
  var _on = false;

  @override
  void initState() {
    super.initState();
    _apply();
  }

  @override
  void didUpdateWidget(TvShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled) {
      // After the frame: the widgets that follow the highlight mode rebuild then, not in the middle of this build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _apply();
        }
      });
    }
  }

  @override
  void dispose() {
    if (_on) {
      _turnOff();
    }
    super.dispose();
  }

  void _apply() {
    if (widget.enabled && !_on) {
      // Material widgets draw their focus overlay only after a key was pressed, by default: on a TV the focus is the
      // only cursor, from the first frame on
      _previousStrategy = FocusManager.instance.highlightStrategy;
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      FocusManager.instance.addEarlyKeyEventHandler(radioArrowMovesFocus);
      _on = true;
    } else if (!widget.enabled && _on) {
      _turnOff();
    }
  }

  void _turnOff() {
    FocusManager.instance.removeEarlyKeyEventHandler(radioArrowMovesFocus);
    FocusManager.instance.highlightStrategy = _previousStrategy ?? FocusHighlightStrategy.automatic;
    _on = false;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final enabled = widget.enabled;
    // The same widgets on and off, see [TvShell]
    return MediaQuery(
      data: enabled
          ? media.copyWith(
              navigationMode: NavigationMode.directional,
              padding: _atLeast(media.padding, TvShell.overscan),
              viewPadding: _atLeast(media.viewPadding, TvShell.overscan),
            )
          : media,
      child: Shortcuts(
        debugLabel: 'TV remote',
        shortcuts: enabled ? TvShell.shortcuts : const <ShortcutActivator, Intent>{},
        child: TvFocusRing(enabled: enabled, child: widget.child),
      ),
    );
  }
}

EdgeInsets _atLeast(EdgeInsets insets, EdgeInsets minimum) => EdgeInsets.fromLTRB(
  max(insets.left, minimum.left),
  max(insets.top, minimum.top),
  max(insets.right, minimum.right),
  max(insets.bottom, minimum.bottom),
);

final _arrowDirections = {
  LogicalKeyboardKey.arrowUp: TraversalDirection.up,
  LogicalKeyboardKey.arrowDown: TraversalDirection.down,
  LogicalKeyboardKey.arrowLeft: TraversalDirection.left,
  LogicalKeyboardKey.arrowRight: TraversalDirection.right,
};

/// How far above the focused node a radio button may be: the focus node of a RadioListTile sits about fifteen widgets
/// under it
const _radioSearchDepth = 40;

/// An arrow pressed on a radio button moves the focus, as on any other control of a TV page. Flutter's RadioGroup
/// takes the arrows to move the choice instead (the keyboard convention of the web): with a remote, whose only way down
/// is an arrow, the focus never left the group, each press changed the choice on the way, and a choice that opens
/// another page (Plex in the share form) or changes the layout (the remote control layout setting) acted at once. OK
/// still picks the choice that has the focus. Called before the focus tree sees the key, since the group's own
/// shortcuts sit under the TV shell.
///
/// The move goes through the traversal policy around the group, the one the controls next to it use: the group's own
/// policy keeps a history of its moves that the moves of the other controls do not update, and Up from the field
/// under the group then Up again would bounce back to the field.
@visibleForTesting
KeyEventResult radioArrowMovesFocus(KeyEvent event) {
  final direction = _arrowDirections[event.logicalKey];
  final node = FocusManager.instance.primaryFocus;
  final context = node?.context;
  if (direction == null || node == null || context == null || event is KeyUpEvent) {
    return KeyEventResult.ignored;
  }
  final group = _radioGroupOf(context);
  if (group == null) {
    return KeyEventResult.ignored;
  }
  (FocusTraversalGroup.maybeOf(group) ?? ReadingOrderTraversalPolicy()).inDirection(node, direction);
  // Handled even at the edge of the page: the group would move the choice otherwise
  return KeyEventResult.handled;
}

/// The RadioGroup around [context] when it is the focus of a radio button of that group, else null
BuildContext? _radioGroupOf(BuildContext context) {
  var radio = false;
  BuildContext? group;
  var depth = 0;
  context.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is RadioGroup) {
      group = radio ? element : null;
      return false;
    }
    radio = radio || widget is RadioListTile || widget is Radio || widget is RawRadio;
    depth++;
    // Past the depth without a radio button: some other control, which the group leaves alone anyway
    return radio || depth < _radioSearchDepth;
  });
  return group;
}
