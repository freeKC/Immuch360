// Selecting several photos and videos with the keyboard and the mouse on a computer, as every desktop app does:
// Control click (Command click on macOS) adds one or takes it out, Shift click adds a range, a right click opens the
// actions of the whole selection, Control A selects the whole grid and Escape clears it (those two through
// DesktopShell). The rules live here once; each grid hands over its own selection through a DesktopSelectable: the
// timeline (timeline_selection.dart, over multiSelectProvider) and the folder of a share (network_selection.dart, over
// networkSelectionProvider). There is no third selection state: those two are only called.
//
// A plain click stays what it was: it opens the item when nothing is selected, and adds it or takes it out while
// something is. Touch, the TV and the remote control layout are unchanged; a long press, a drag and the circle of a
// header still select as before.

import 'dart:async';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_ui/immich_ui.dart';

/// What a click on an item of a grid does on a computer
enum DesktopClick {
  /// A plain click while nothing is selected: the page opens the item, as before
  open,

  /// Adds the item to the selection, or takes it out
  toggle,

  /// Adds the items from the last one clicked (the anchor) to this one
  range,

  /// Opens the actions of the selection: a right click, or Control click on macOS
  menu,
}

/// Whether the key that adds to a selection is held: Command on macOS, Control on Windows and Linux
bool desktopAddKeyPressed() {
  final keyboard = HardwareKeyboard.instance;
  return CurrentPlatform.isMacOS ? keyboard.isMetaPressed : keyboard.isControlPressed;
}

/// The name of the key that adds to a selection, for the hint: ⌘ on macOS, Ctrl elsewhere
String desktopAddKeyName() => CurrentPlatform.isMacOS ? '⌘' : 'Ctrl';

/// What a click does with the keys held now: Shift (with Control or Command too) adds a range, Control (Command on
/// macOS) adds or takes out, Control on macOS opens the menu as a right click would. A plain click opens the item, or
/// adds or takes it out while [selecting]. A [secondary] click always opens the menu.
DesktopClick desktopClickOf({required bool selecting, bool secondary = false}) {
  if (secondary) {
    return DesktopClick.menu;
  }
  final keyboard = HardwareKeyboard.instance;
  if (keyboard.isShiftPressed) {
    return DesktopClick.range;
  }
  if (desktopAddKeyPressed()) {
    return DesktopClick.toggle;
  }
  if (CurrentPlatform.isMacOS && keyboard.isControlPressed) {
    return DesktopClick.menu;
  }
  return selecting ? DesktopClick.toggle : DesktopClick.open;
}

/// The selection of a grid, as the rules of this file see it: the items in the order of the grid, by their index
abstract interface class DesktopSelectable<T> {
  /// How many items are selected
  int get count;

  /// Whether a plain click adds or takes out rather than opening
  bool get selecting;

  /// Whether Escape has something to clear: an item selected, or a share folder still picking
  bool get hasSelection;

  bool isSelected(T item);

  /// The items from [from] to [to] of the grid, both included, [from] not after [to]
  Future<List<T>> range(int from, int to);

  /// Adds [items] to the selection, never takes one out; those that cannot be selected are left out
  void addAll(List<T> items);

  /// Adds [item], or takes it out when it was selected
  void toggle(T item);

  /// Selects the whole grid; twice in a row, everything stays selected
  Future<void> selectAll();

  /// Selects nothing
  void clear();
}

/// The anchor of a grid's selection (the item of the last click that added or took out one), and what a click does
/// with it
class DesktopSelectionController<T> {
  DesktopSelectionController(this.selectable);

  DesktopSelectable<T> selectable;

  ({int index, T item})? _anchor;

  /// Where the next Shift click starts its range; none once the selection is empty
  ({int index, T item})? get anchor => selectable.count == 0 ? null : _anchor;

  /// Applies [click] on [item] at [index]: [DesktopClick.open] and [DesktopClick.menu] are left to the caller
  Future<void> click(DesktopClick click, int index, T item) async {
    switch (click) {
      case DesktopClick.open:
      case DesktopClick.menu:
        return;
      case DesktopClick.toggle:
        selectable.toggle(item);
        _anchor = (index: index, item: item);
      case DesktopClick.range:
        final from = anchor;
        if (from == null) {
          // Nothing to start from: the item alone, which becomes the anchor
          selectable.addAll([item]);
          _anchor = (index: index, item: item);
          return;
        }
        selectable.addAll(await selectable.range(math.min(from.index, index), math.max(from.index, index)));
    }
  }

  /// Before the menu of a right click on [item]: an item outside the selection becomes the selection, as in a file
  /// manager, or joins it when [add] (Control or Command held); an item already selected leaves it as it is
  void prepareMenu(int index, T item, {required bool add}) {
    if (selectable.isSelected(item)) {
      return;
    }
    if (!add) {
      selectable.clear();
    }
    selectable.addAll([item]);
    _anchor = (index: index, item: item);
  }

  /// [item] was selected another way (a long press): the next Shift click starts from it
  void anchorAt(int index, T item) => _anchor = (index: index, item: item);

  void forget() => _anchor = null;
}

/// A grid that Control A and Escape reach through DesktopShell
abstract interface class DesktopSelectionTarget {
  /// Whether the grid is the one shown: its route on top, its tab the active one
  bool get isFront;

  bool get hasSelection;

  bool get isMenuOpen;

  Future<void> selectAll();

  void clear();

  void closeMenu();
}

/// The grids that can be selected in now; the one in front gets the keys of the window
abstract final class DesktopSelectionTargets {
  static final List<DesktopSelectionTarget> _targets = [];

  static void register(DesktopSelectionTarget target) {
    _targets
      ..remove(target)
      ..add(target);
  }

  static void unregister(DesktopSelectionTarget target) => _targets.remove(target);

  /// The grid shown, the last one registered when two are
  static DesktopSelectionTarget? get active => _targets.reversed.firstWhereOrNull((target) => target.isFront);

  @visibleForTesting
  static int get length => _targets.length;
}

/// The grid [child] on a computer, selected in by [selectable]: what the tiles call on a click (see [maybeOf]), the
/// target of Control A and Escape while it is shown, and the menu of a right click, with the entries of [menu] (built
/// while the menu shows, with this scope's context, which lives as long as the grid) then Select all and Deselect all.
/// Nothing of this while not [enabled] (the read only mode, the remote control layout).
class DesktopSelectionScope<T> extends ConsumerStatefulWidget {
  const DesktopSelectionScope({
    super.key,
    required this.selectable,
    required this.empty,
    required this.menu,
    this.enabled = true,
    required this.child,
  });

  final DesktopSelectable<T> selectable;

  /// Whether the selection is empty: the anchor goes with it, however it was cleared (the close button, Back)
  final ProviderListenable<bool> empty;

  final List<Widget> Function(BuildContext context, WidgetRef ref) menu;
  final bool enabled;
  final Widget child;

  /// The scope of the grid around [context], when it selects
  static DesktopSelectionScopeState<T>? maybeOf<T>(BuildContext context) {
    final scope = context.findAncestorStateOfType<DesktopSelectionScopeState<T>>();
    return scope != null && scope.widget.enabled ? scope : null;
  }

  @override
  ConsumerState<DesktopSelectionScope<T>> createState() => DesktopSelectionScopeState<T>();
}

class DesktopSelectionScopeState<T> extends ConsumerState<DesktopSelectionScope<T>> implements DesktopSelectionTarget {
  late final DesktopSelectionController<T> controller = DesktopSelectionController(widget.selectable);

  MenuController? _menu;
  ModalRoute<Object?>? _route;

  /// Where the last button went down over the grid, for a menu opened by a click that carries no position
  Offset? _lastPointerDown;

  DesktopSelectable<T> get selectable => widget.selectable;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      DesktopSelectionTargets.register(this);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(DesktopSelectionScope<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    controller.selectable = widget.selectable;
    if (widget.enabled == oldWidget.enabled) {
      return;
    }
    if (widget.enabled) {
      DesktopSelectionTargets.register(this);
    } else {
      DesktopSelectionTargets.unregister(this);
      closeMenu();
    }
  }

  @override
  void dispose() {
    DesktopSelectionTargets.unregister(this);
    super.dispose();
  }

  @override
  bool get isFront {
    if (!mounted || !widget.enabled || !(_route?.isCurrent ?? true)) {
      return false;
    }
    // The tabs of the tab shell stay built side by side: the active one only (as handleStatusBarTap of the timeline)
    final routeData = context.findAncestorWidgetOfExactType<RouteDataScope>()?.routeData;
    return routeData?.isActive ?? true;
  }

  @override
  bool get hasSelection => selectable.hasSelection;

  @override
  bool get isMenuOpen => _menu?.isOpen ?? false;

  @override
  Future<void> selectAll() => selectable.selectAll();

  @override
  void clear() {
    selectable.clear();
    controller.forget();
  }

  @override
  void closeMenu() {
    if (isMenuOpen) {
      _menu?.close();
    }
  }

  /// A primary click on [item] at [index]: true when the selection took it, false when the page opens the item as
  /// before
  bool click(int index, T item) {
    final click = desktopClickOf(selecting: selectable.selecting);
    switch (click) {
      case DesktopClick.open:
        return false;
      case DesktopClick.menu:
        // Control click on macOS: the menu where the click was
        openMenu(index, item, _lastPointerDown);
        return true;
      case DesktopClick.toggle:
      case DesktopClick.range:
        unawaited(controller.click(click, index, item));
        return true;
    }
  }

  /// A right click on [item] at [globalPosition]: the item joins the selection as [DesktopSelectionController.prepareMenu]
  /// says, then the menu of the whole selection opens there
  void openMenu(int index, T item, Offset? globalPosition) {
    controller.prepareMenu(index, item, add: desktopAddKeyPressed());
    final box = context.findRenderObject();
    final position = globalPosition != null && box is RenderBox && box.hasSize
        ? box.globalToLocal(globalPosition)
        : null;
    // The entries are built while the menu shows
    setState(() {});
    _menu?.open(position: position);
  }

  List<Widget> _menuEntries(BuildContext context) {
    final t = context.t;
    final entries = widget.menu(context, ref);
    return [
      ...entries,
      if (entries.isNotEmpty) const Divider(height: 1),
      DesktopSelectionMenuEntry(
        key: const Key('desktop_selection_select_all'),
        icon: Icons.select_all_rounded,
        label: t.select_all,
        onPressed: () => unawaited(selectAll()),
      ),
      DesktopSelectionMenuEntry(
        key: const Key('desktop_selection_clear'),
        icon: Icons.deselect_rounded,
        label: t.deselect_all,
        onPressed: clear,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(widget.empty, (_, empty) {
      if (empty) {
        controller.forget();
      }
    });
    // The menu hangs from an empty anchor at the top left corner, opened where the click was: around the whole grid,
    // the anchor would take the clicks on the grid for clicks on the menu, which then would not close
    final grid = Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (widget.enabled)
          Positioned(
            left: 0,
            top: 0,
            child: ImmichMenu(
              consumeOutsideTap: true,
              style: MenuStyle(
                backgroundColor: WidgetStatePropertyAll(context.themeData.scaffoldBackgroundColor),
                surfaceTintColor: const WidgetStatePropertyAll(Colors.grey),
                elevation: const WidgetStatePropertyAll(4),
                shape: const WidgetStatePropertyAll(
                  RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
                ),
                padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
              ),
              children: isMenuOpen ? _menuEntries(context) : const [],
              builder: (context, controller, child) {
                _menu = controller;
                return const SizedBox.shrink();
              },
            ),
          ),
      ],
    );
    return Listener(onPointerDown: (event) => _lastPointerDown = event.position, child: grid);
  }
}

/// An entry of the menu of a right click. The menu closes first, then [onPressed] runs: it must use a context that
/// outlives the menu (the scope's, or the page's).
class DesktopSelectionMenuEntry extends StatelessWidget {
  const DesktopSelectionMenuEntry({super.key, required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;

  /// Null greys the entry
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return MenuItemButton(
      onPressed: onPressed,
      style: MenuItemButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: ImmichSpacing.lg, vertical: ImmichSpacing.md),
      ),
      leadingIcon: Icon(icon, size: ImmichIconSize.sm),
      child: Text(label, style: const TextStyle(fontSize: ImmichTextSize.body)),
    );
  }
}

/// [child] with the hint of the keys and clicks of a selection, on a computer
Widget withDesktopSelectionHint(BuildContext context, Widget child) {
  if (!CurrentPlatform.isDesktop) {
    return child;
  }
  return Tooltip(
    message: context.t.desktop_selection_hint(modifier: desktopAddKeyName()),
    child: child,
  );
}
