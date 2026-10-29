// The selection of a folder of a share on a computer (the rules are in desktop_selection.dart): Control, Shift and right
// clicks on its photos and videos, Control A and Escape, written into networkSelectionProvider of the folder, in the
// order of the grid. A folder ignores the keys and opens. The menu of a right click sends the selection to the Immich
// server, as the bar at the bottom of the page does.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/selection/desktop_selection.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/network/network_selection.provider.dart';

/// The scope of the photos and videos of a share folder, which its page reaches from a click on a tile
typedef DesktopNetworkSelectionKey = GlobalKey<DesktopSelectionScopeState<NetworkEntry>>;

/// The picked files of [folder], whose photos and videos are [_media] in the order of the grid
class NetworkFolderSelectable implements DesktopSelectable<NetworkEntry> {
  NetworkFolderSelectable(this._ref, this.folder, this._media);

  final WidgetRef _ref;
  final NetworkFolderKey folder;
  final List<NetworkEntry> Function() _media;

  NetworkSelection get _state => _ref.read(networkSelectionProvider(folder));

  NetworkSelectionNotifier get _notifier => _ref.read(networkSelectionProvider(folder).notifier);

  /// Where [entry] is in the grid, -1 when it is not a photo or video of it
  int indexOf(NetworkEntry entry) => _media().indexWhere((media) => media.path == entry.path);

  @override
  int get count => _state.paths.length;

  @override
  bool get selecting => _state.isActive;

  /// Picking, even with nothing picked yet (the Select button): Escape stops it
  @override
  bool get hasSelection => _state.isActive;

  @override
  bool isSelected(NetworkEntry item) => _state.contains(item.path);

  @override
  Future<List<NetworkEntry>> range(int from, int to) async {
    final media = _media();
    final start = math.max(from, 0);
    final end = math.min(to + 1, media.length);
    return start < end ? media.sublist(start, end) : const [];
  }

  @override
  void addAll(List<NetworkEntry> items) {
    final state = _state;
    if (items.isEmpty || (state.isActive && items.every((entry) => state.contains(entry.path)))) {
      return;
    }
    _notifier.replace({...state.paths, for (final entry in items) entry.path});
  }

  @override
  void toggle(NetworkEntry item) {
    if (_state.isActive) {
      _notifier.toggle(item.path);
    } else {
      _notifier.start(item.path);
    }
  }

  @override
  Future<void> selectAll() async => addAll(_media());

  @override
  void clear() => _notifier.end();
}

/// The grid of a share folder, [child], selected in with the keyboard and the mouse on a computer while [enabled] (not
/// in the remote control layout); [child] itself on a phone. [media] gives the photos and videos of the folder in the
/// order of the grid, [onUpload] sends the picked ones.
Widget withDesktopNetworkSelection({
  required DesktopNetworkSelectionKey key,
  required NetworkFolderKey folder,
  required List<NetworkEntry> Function() media,
  required bool enabled,
  required VoidCallback onUpload,
  required Widget child,
}) {
  if (!CurrentPlatform.isDesktop) {
    return child;
  }
  return _NetworkSelection(
    scopeKey: key,
    folder: folder,
    media: media,
    enabled: enabled,
    onUpload: onUpload,
    child: child,
  );
}

/// A click on [entry]: true when the selection took it (Control, Shift, a click while picking), false when the page
/// opens it as before. A folder always opens.
bool desktopNetworkClick(DesktopNetworkSelectionKey key, NetworkEntry entry) {
  final scope = key.currentState;
  final index = scope == null || entry.isDirectory ? -1 : _indexOf(scope, entry);
  return index >= 0 && scope!.widget.enabled && scope.click(index, entry);
}

/// [entry] was picked by a long press: the next Shift click starts from it
void desktopNetworkAnchor(DesktopNetworkSelectionKey key, NetworkEntry entry) {
  final scope = key.currentState;
  final index = scope == null ? -1 : _indexOf(scope, entry);
  if (index >= 0) {
    scope!.controller.anchorAt(index, entry);
  }
}

/// The tile [tile] of [entry], which a right click picks and opens the menu of the selection from; [tile] itself on a
/// phone
Widget withDesktopNetworkTile(BuildContext context, NetworkEntry entry, Widget tile) {
  if (!CurrentPlatform.isDesktop) {
    return tile;
  }
  return GestureDetector(
    onSecondaryTapUp: (details) {
      final scope = DesktopSelectionScope.maybeOf<NetworkEntry>(context);
      final index = scope == null ? -1 : _indexOf(scope, entry);
      if (index >= 0) {
        scope!.openMenu(index, entry, details.globalPosition);
      }
    },
    child: tile,
  );
}

int _indexOf(DesktopSelectionScopeState<NetworkEntry> scope, NetworkEntry entry) {
  final selectable = scope.selectable;
  return selectable is NetworkFolderSelectable ? selectable.indexOf(entry) : -1;
}

class _NetworkSelection extends ConsumerStatefulWidget {
  const _NetworkSelection({
    required this.scopeKey,
    required this.folder,
    required this.media,
    required this.enabled,
    required this.onUpload,
    required this.child,
  });

  final DesktopNetworkSelectionKey scopeKey;
  final NetworkFolderKey folder;
  final List<NetworkEntry> Function() media;
  final bool enabled;
  final VoidCallback onUpload;
  final Widget child;

  @override
  ConsumerState<_NetworkSelection> createState() => _NetworkSelectionState();
}

class _NetworkSelectionState extends ConsumerState<_NetworkSelection> {
  late final _selectable = NetworkFolderSelectable(ref, widget.folder, () => widget.media());

  @override
  Widget build(BuildContext context) {
    return DesktopSelectionScope<NetworkEntry>(
      key: widget.scopeKey,
      selectable: _selectable,
      empty: networkSelectionProvider(widget.folder).select((selection) => selection.paths.isEmpty),
      enabled: widget.enabled,
      menu: _menu,
      child: widget.child,
    );
  }

  /// "Upload to Immich", or why there is none, as the bar at the bottom of the page says
  List<Widget> _menu(BuildContext context, WidgetRef ref) {
    final t = context.t;
    if (!ref.watch(hasServerProvider)) {
      return [
        DesktopSelectionMenuEntry(
          key: const Key('desktop_selection_needs_server'),
          icon: Icons.info_outline_rounded,
          label: t.network_upload_needs_server,
          onPressed: null,
        ),
      ];
    }
    final count = ref.watch(networkSelectionProvider(widget.folder).select((selection) => selection.paths.length));
    return [
      DesktopSelectionMenuEntry(
        key: const Key('desktop_selection_upload'),
        icon: Icons.backup_outlined,
        label: t.network_upload_action,
        onPressed: count > 0 ? widget.onUpload : null,
      ),
    ];
  }
}
