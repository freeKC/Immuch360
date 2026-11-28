// Copy in the viewers of a computer: a right click on the photo or the video shown opens Copy (the file, and the
// picture of a photo, on the clipboard of the system: clipboard_copy.dart) and Copy name; Control C (Command C on
// macOS) copies too while the viewer is shown (copy_targets.dart). A phone, a tablet, a TV and the remote control layout
// of a computer keep their viewers as they are.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/clipboard/clipboard_copy.dart';
import 'package:immich_mobile/desktop/clipboard/copy_targets.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_ui/immich_ui.dart';

/// [child], the item of a viewer, with Copy and Copy name on a computer; [child] itself elsewhere, and where the
/// viewer does not [offer] them (the viewer of the trash, as its grid). [copy] copies the item shown now, [name] gives
/// its file name (null while there is none).
Widget withDesktopViewerCopy({
  Key? key,
  required Future<void> Function(BuildContext context) copy,
  required String? Function() name,
  required Widget child,
  bool offer = true,
}) => CurrentPlatform.isDesktop && offer ? DesktopViewerCopy(key: key, copy: copy, name: name, child: child) : child;

class DesktopViewerCopy extends ConsumerStatefulWidget {
  const DesktopViewerCopy({super.key, required this.copy, required this.name, required this.child});

  final Future<void> Function(BuildContext context) copy;
  final String? Function() name;
  final Widget child;

  @override
  ConsumerState<DesktopViewerCopy> createState() => _DesktopViewerCopyState();
}

class _DesktopViewerCopyState extends ConsumerState<DesktopViewerCopy> implements DesktopCopyTarget {
  ModalRoute<Object?>? _route;

  @override
  void initState() {
    super.initState();
    DesktopCopyTargets.register(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    DesktopCopyTargets.unregister(this);
    super.dispose();
  }

  bool get _enabled => !ref.read(tvModeProvider);

  @override
  bool get isFront => mounted && _enabled && (_route?.isCurrent ?? true) && widget.name() != null;

  @override
  Future<void> copy() async {
    if (mounted && widget.name() != null) {
      await widget.copy(context);
    }
  }

  Future<void> _openMenu(Offset position) async {
    final name = widget.name();
    if (name == null || !_enabled) {
      return;
    }
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) {
      return;
    }
    final t = context.t;
    PopupMenuItem<VoidCallback> entry(Key key, IconData icon, String label, VoidCallback action) => PopupMenuItem(
      key: key,
      value: action,
      child: Row(
        children: [
          Icon(icon, size: ImmichIconSize.sm),
          const SizedBox(width: ImmichSpacing.md),
          Text(label),
        ],
      ),
    );
    final picked = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(Rect.fromPoints(position, position), Offset.zero & overlay.size),
      items: [
        entry(const Key('desktop_viewer_copy'), Icons.content_copy_rounded, t.desktop_copy, () => unawaited(copy())),
        entry(
          const Key('desktop_viewer_copy_name'),
          Icons.text_fields_rounded,
          t.desktop_copy_name,
          () => unawaited(copyNameToClipboard(ref, name)),
        ),
      ],
    );
    if (mounted) {
      picked?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(tvModeProvider)) {
      return widget.child;
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: (details) => unawaited(_openMenu(details.globalPosition)),
      child: widget.child,
    );
  }
}
