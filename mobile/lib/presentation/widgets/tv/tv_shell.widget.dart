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
/// - the focus highlight of Material widgets shown at all times, under the one ring of [TvFocusRing].
class TvShell extends StatefulWidget {
  const TvShell({super.key, required this.child});

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
  late final FocusHighlightStrategy _previousStrategy;

  @override
  void initState() {
    super.initState();
    // Material widgets draw their focus overlay only after a key was pressed, by default: on a TV the focus is the only
    // cursor, from the first frame on
    _previousStrategy = FocusManager.instance.highlightStrategy;
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
  }

  @override
  void dispose() {
    FocusManager.instance.highlightStrategy = _previousStrategy;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        navigationMode: NavigationMode.directional,
        padding: _atLeast(media.padding, TvShell.overscan),
        viewPadding: _atLeast(media.viewPadding, TvShell.overscan),
      ),
      child: Shortcuts(
        debugLabel: 'TV remote',
        shortcuts: TvShell.shortcuts,
        child: TvFocusRing(child: widget.child),
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
