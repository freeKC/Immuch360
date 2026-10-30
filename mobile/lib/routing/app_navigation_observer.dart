import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/routing/route_opening_key_gate.dart';

class AppNavigationObserver extends AutoRouterObserver {
  /// Riverpod Instance
  final WidgetRef ref;

  AppNavigationObserver({required this.ref});

  @override
  void didPush(Route route, Route? previousRoute) {
    ref.invalidate(inLockedViewProvider);
    ref.invalidate(isAssetViewerOpenProvider);
    unawaited(
      Future(() {
        ref.read(currentRouteNameProvider.notifier).state = route.settings.name;
        ref.read(previousRouteNameProvider.notifier).state = previousRoute?.settings.name;
        ref.read(previousRouteDataProvider.notifier).state = previousRoute?.settings;
      }),
    );
    _keepAFocus(route, opening: true);
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    ref.invalidate(inLockedViewProvider);
    ref.invalidate(isAssetViewerOpenProvider);
    _keepAFocus(previousRoute);
  }

  /// In the remote control layout an item always has the focus (the TV guidelines), or the first arrow is lost: a
  /// page that focuses nothing by itself gets its first item, and so does a page that comes back without the item it
  /// had focused. A route [opening] holds the keys that move or press until then (RouteOpeningKeyGate): before its
  /// first frame they would reach the page under it.
  void _keepAFocus(Route? route, {bool opening = false}) {
    if (route is! ModalRoute || !ref.read(tvModeProvider)) {
      return;
    }
    if (opening) {
      RouteOpeningKeyGate.instance.opening(route);
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      // The autofocus of the page applies in a microtask of the frame that built it: after it
      scheduleMicrotask(() {
        try {
          focusFirstItemIfNone(route);
        } finally {
          if (opening) {
            RouteOpeningKeyGate.instance.opened(route);
          }
        }
      });
    });
  }
}

/// Focuses the first item of [route] in reading order, when it is the current route and nothing inside it has the
/// focus. An item of the app bar (its Back button first) only when the page itself shows none yet: a list that comes
/// after loading then takes the focus once it shows (see [_handOverToBody]).
@visibleForTesting
void focusFirstItemIfNone(ModalRoute route) {
  final context = route.subtreeContext;
  if (!route.isActive || !route.isCurrent || context == null || !context.mounted) {
    return;
  }
  // The focus scope of the route, around its page
  final scope = FocusScope.of(context);
  // An item of the route asked for the focus (applied in a microtask), or has it
  if (scope.focusedChild != null) {
    return;
  }
  final focused = FocusManager.instance.primaryFocus;
  if (focused != null && focused != scope && focused.ancestors.contains(scope)) {
    return;
  }
  final policy = FocusTraversalGroup.maybeOf(context) ?? ReadingOrderTraversalPolicy();
  // Flutter gives the scope itself while the page shows no item yet (a grid still loading, under no app bar): the
  // focus stayed on the scope, nothing showed it, and the first Down went to the Back button once the grid came
  final found = policy.findFirstFocus(scope, ignoreCurrentFocus: true);
  final first = found == scope ? null : found;
  if (first != null && !_inAppBar(first)) {
    first.requestFocus();
    return;
  }
  final body = _bodyItem(scope);
  if (body != null) {
    _focusBodyItem(body);
    return;
  }
  first?.requestFocus();
  _handOverToBody(route, first);
}

/// Focuses the item of a page [_bodyItem] found. One on the screen takes the focus where it is: the page keeps its
/// header whole (the name of an album of the server at its bottom). One under the bottom of the screen comes up into
/// view.
void _focusBodyItem(({FocusNode item, bool below}) body) {
  body.item.requestFocus();
  final context = body.item.context;
  if (body.below && context != null && context.mounted) {
    unawaited(Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd));
  }
}

/// Gives the focus to the page of [route] once it shows an item, as long as the focus stays where
/// [focusFirstItemIfNone] put it ([given], an item of the app bar, or nothing): Flutter drops the autofocus of an item
/// built while its page already has a focused item, so the first folder of a share listed after a second would never
/// get it, and OK would press the Back button instead. Checked after each frame (the ones that show the list among
/// them) until then, or until the user moves the focus or the route goes away.
void _handOverToBody(ModalRoute route, FocusNode? given) {
  SchedulerBinding.instance.addPostFrameCallback((_) {
    // After the autofocus of the frame, applied in a microtask
    scheduleMicrotask(() {
      final context = route.subtreeContext;
      if (!route.isActive || context == null || !context.mounted) {
        return;
      }
      final scope = FocusScope.of(context);
      // Under a dialog: the focus comes back to the page when it closes
      final waits = !route.isCurrent;
      final kept = given == null ? scope.focusedChild == null : given.hasPrimaryFocus || waits;
      if (!kept) {
        return;
      }
      final body = waits ? null : _bodyItem(scope);
      if (body == null) {
        _handOverToBody(route, given);
        return;
      }
      _focusBodyItem(body);
    });
  });
}

/// The item of the page in [scope] that asked for the focus, else its first one on screen, else its first one under
/// the bottom of the screen ([below]: the grid of an album of the server, under a header of 400 dp, starts below a TV
/// screen of 540 dp; the page opened with the focus nowhere, OK did nothing and Down went to the Back button); null
/// while the page shows none (only its app bar has items)
({FocusNode item, bool below})? _bodyItem(FocusScopeNode scope) {
  final screen = scope.rect;
  final items = scope.traversalDescendants.where((node) => _laidOut(node) && !_inAppBar(node)).toList();
  final onScreen = items.where((node) => screen.contains(node.rect.center)).toList();
  final shown = onScreen.where(_asksForFocus).firstOrNull ?? topLeftFocusNode(onScreen);
  if (shown != null) {
    return (item: shown, below: false);
  }
  final below = topLeftFocusNode(
    items.where((node) {
      final center = node.rect.center;
      return center.dy >= screen.bottom && center.dx >= screen.left && center.dx <= screen.right;
    }),
  );
  return below == null ? null : (item: below, below: true);
}

/// Whether [node] has a place on screen to compare: its rect needs a laid out box
bool _laidOut(FocusNode node) {
  final object = node.context?.findRenderObject();
  return object is RenderBox && object.attached && object.hasSize;
}

bool _inAppBar(FocusNode node) => node.context?.findAncestorWidgetOfExactType<AppBar>() != null;

/// Whether the item was built with autofocus (a Focus of its own, or the one inside a list tile or a button)
bool _asksForFocus(FocusNode node) {
  final widget = node.context?.widget;
  return widget is Focus && widget.autofocus;
}

/// Tracks routes that are undergoing a pop transition
class TransitioningRouteObserver extends NavigatorObserver {
  int _transitioningRoutes = 0;

  /// Whether a "popping" route is still on screen
  bool get hasTransitioningRoute => _transitioningRoutes > 0;

  @override
  void didPop(Route route, Route? previousRoute) {
    if (route is! TransitionRoute) {
      return;
    }

    _transitioningRoutes += 1;
    // Transition completed and route disposed
    unawaited(route.completed.whenComplete(() => _transitioningRoutes -= 1));
  }
}
