// The selection of a timeline on a computer (the rules are in desktop_selection.dart): Control, Shift and right clicks
// on its tiles, Control A and Escape, written into multiSelectProvider. Each page that scopes timelineServiceProvider
// has a selection of its own, so everything here reads through the WidgetRef of the timeline, never the root
// container. The bottom sheet of the page keeps all of its actions; the menu of a right click offers the main ones for
// the whole selection, "Upload to Immich" first.
//
// Control A loads the assets of the timeline by chunks and changes the selection once, so that thousands of photos
// do not copy the selection thousands of times; in the search results it takes the results loaded so far.

import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/selection/desktop_selection.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/download.action.dart';
import 'package:immich_mobile/presentation/actions/share.action.dart';
import 'package:immich_mobile/presentation/actions/upload.action.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';

/// How many assets Control A and a long Shift click load at a time
const _chunk = 1000;

/// The selection of the timeline that [_ref] reads, see the top of this file. [_mounted] tells whether the timeline is
/// still there after a load.
class TimelineSelectable implements DesktopSelectable<BaseAsset> {
  TimelineSelectable(this._ref, this._mounted);

  final WidgetRef _ref;
  final bool Function() _mounted;

  MultiSelectState get _state => _ref.read(multiSelectProvider);

  MultiSelectNotifier get _notifier => _ref.read(multiSelectProvider.notifier);

  @override
  int get count => _state.selectedAssets.length;

  /// While a selection is made, or on the page that picks the photos of an album: a plain click adds or takes out
  @override
  bool get selecting => _state.isEnabled || _state.forceEnable;

  @override
  bool get hasSelection => _state.isEnabled;

  @override
  bool isSelected(BaseAsset item) => _state.selectedAssets.contains(item);

  @override
  Future<List<BaseAsset>> range(int from, int to) => _load(from, to + 1 - from);

  /// One change of the selection, and none when every asset of [items] is selected already (the notifier would take
  /// them all out); the assets an album already holds (locked) are never taken
  @override
  void addAll(List<BaseAsset> items) {
    final state = _state;
    final rest = _withoutLocked(items, state.lockedSelectionAssets);
    if (rest.isEmpty || rest.every(state.selectedAssets.contains)) {
      return;
    }
    _notifier.toggleBucketSelectionByAssets(rest);
  }

  @override
  void toggle(BaseAsset item) {
    if (_withoutLocked([item], _state.lockedSelectionAssets).isEmpty) {
      return;
    }
    _notifier.toggleAssetSelection(item);
  }

  @override
  Future<void> selectAll() async {
    final assets = await _load(0, _ref.read(timelineServiceProvider).totalAssets);
    if (_mounted()) {
      addAll(assets);
    }
  }

  /// As the close button of the selection does; on the page that picks the photos of an album, the picked ones go and
  /// the page stays a picker
  @override
  void clear() {
    final state = _state;
    if (state.selectedAssets.isEmpty) {
      return;
    }
    if (state.forceEnable) {
      _notifier.toggleBucketSelectionByAssets(state.selectedAssets.toList());
      return;
    }
    _notifier.reset();
  }

  /// [count] assets of the timeline from [start], by chunks: one large load would replace the buffer of the timeline
  /// by the whole timeline
  Future<List<BaseAsset>> _load(int start, int count) async {
    final service = _ref.read(timelineServiceProvider);
    final end = math.min(start + count, service.totalAssets);
    final assets = <BaseAsset>[];
    for (var index = math.max(start, 0); index < end; index += _chunk) {
      assets.addAll(await service.loadAssets(index, math.min(_chunk, end - index)));
      if (!_mounted()) {
        break;
      }
    }
    return assets;
  }
}

/// [assets] without those of [locked]. Compared with `==`, as the tiles do (the hash of a RemoteAsset holds its
/// localId, which `==` leaves out); by name first, which `==` compares too, so that thousands of assets are not each
/// compared with every locked one.
List<BaseAsset> _withoutLocked(List<BaseAsset> assets, Set<BaseAsset> locked) {
  if (locked.isEmpty) {
    return assets;
  }
  final byName = groupBy(locked, (BaseAsset asset) => asset.name);
  return [
    for (final asset in assets)
      if (!(byName[asset.name]?.any((other) => other == asset) ?? false)) asset,
  ];
}

/// The grid of a timeline, [child], selected in with the keyboard and the mouse on a computer; [child] itself on a
/// phone
Widget withDesktopTimelineSelection(Widget child) =>
    CurrentPlatform.isDesktop ? _TimelineSelection(child: child) : child;

/// A click on the tile of [asset] at [index], from the tile's [context]: true when the selection took it (Control,
/// Shift, a click while selecting), false when the timeline opens the asset as before
bool desktopTimelineClick(BuildContext context, BaseAsset asset, int index) =>
    DesktopSelectionScope.maybeOf<BaseAsset>(context)?.click(index, asset) ?? false;

/// [asset] at [index] was selected by a long press: the next Shift click starts from it
void desktopTimelineAnchor(BuildContext context, BaseAsset asset, int index) =>
    DesktopSelectionScope.maybeOf<BaseAsset>(context)?.controller.anchorAt(index, asset);

/// The tile [tile] of [asset] at [index], which a right click selects and opens the menu of the selection from (not
/// while [locked]); [tile] itself on a phone. The secondary button never competes with the tap, the long press and
/// the drag of the tile, which listen to the primary one.
Widget withDesktopTimelineTile(BuildContext context, BaseAsset asset, int index, Widget tile, {bool locked = false}) {
  if (!CurrentPlatform.isDesktop) {
    return tile;
  }
  return GestureDetector(
    onSecondaryTapUp: locked
        ? null
        : (details) =>
              DesktopSelectionScope.maybeOf<BaseAsset>(context)?.openMenu(index, asset, details.globalPosition),
    child: tile,
  );
}

class _TimelineSelection extends ConsumerStatefulWidget {
  const _TimelineSelection({required this.child});

  final Widget child;

  @override
  ConsumerState<_TimelineSelection> createState() => _TimelineSelectionState();
}

class _TimelineSelectionState extends ConsumerState<_TimelineSelection> {
  late final _selectable = TimelineSelectable(ref, () => mounted);

  @override
  Widget build(BuildContext context) {
    return DesktopSelectionScope<BaseAsset>(
      selectable: _selectable,
      empty: multiSelectProvider.select((state) => state.selectedAssets.isEmpty),
      // The read only mode and the remote control layout select nothing, as the long press there
      enabled: !ref.watch(viewOnlyProvider),
      menu: _menu,
      child: widget.child,
    );
  }

  /// The main actions for the whole selection, each absent when it does not apply (no server, nothing of this computer
  /// to send, the AI features off). Built with the context of the scope, which outlives the menu.
  static List<Widget> _menu(BuildContext context, WidgetRef ref) {
    // The page that picks the photos of an album has its own Done
    if (ref.watch(multiSelectProvider.select((state) => state.forceEnable))) {
      return const [];
    }
    Widget? entry(ActionBuilder action, String key) {
      final item = action.create(context, ref);
      if (item == null) {
        return null;
      }
      return DesktopSelectionMenuEntry(
        key: Key(key),
        icon: item.icon,
        label: item.label,
        onPressed: () => unawaited(Future.sync(item.onAction)),
      );
    }

    return [
      ?entry(const UploadAction(source: ActionSource.timeline), 'desktop_selection_upload'),
      const DesktopMakeImmersiveButton(source: ActionSource.timeline, menuItem: true),
      ?entry(const DownloadAction(source: ActionSource.timeline), 'desktop_selection_download'),
      // "Save to a folder" on Linux, the share sheet of the system elsewhere
      ?entry(const ShareAction(source: ActionSource.timeline), 'desktop_selection_share'),
    ];
  }
}
