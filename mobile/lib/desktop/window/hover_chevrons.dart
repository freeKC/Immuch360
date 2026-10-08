// Previous and next chevrons at the edges of a flat photo on a computer (design 4.3). A finger turns the pages of the
// viewers, a mouse cannot: Flutter lets only touch like devices drag a PageView (ScrollBehavior.dragDevices), and
// letting the mouse drag would fight with the pan of a zoomed photo. So the chevrons show while the mouse moves over
// the viewer and hide a few seconds after it stops, as the controls of a video player do. The keyboard has the arrows,
// so the chevrons take no focus; their tooltips name them for screen readers.

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// The chevrons, as a layer to put above the pages in a Stack. [canNavigate] is asked each time they show, since the
/// viewers do not rebuild on every page change; [onNavigate] gets -1 for the previous page, 1 for the next.
class DesktopPageChevrons extends StatefulWidget {
  const DesktopPageChevrons({super.key, required this.canNavigate, required this.onNavigate});

  final bool Function(int direction) canNavigate;
  final void Function(int direction) onNavigate;

  /// How long the chevrons stay once the mouse stops
  static const hideAfter = Duration(seconds: 3);

  /// The width of the band along each edge that holds a chevron
  static const edgeWidth = 96.0;

  @override
  State<DesktopPageChevrons> createState() => _DesktopPageChevronsState();
}

class _DesktopPageChevronsState extends State<DesktopPageChevrons> {
  bool _visible = false;

  /// The mouse is on a chevron: it stays
  bool _onChevron = false;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _show() {
    _hide?.cancel();
    if (!_onChevron) {
      _hide = Timer(DesktopPageChevrons.hideAfter, () => _setVisible(false));
    }
    _setVisible(true);
  }

  void _setVisible(bool visible) {
    if (mounted && visible != _visible) {
      setState(() => _visible = visible);
    }
  }

  void _onChevronHover(bool inside) {
    _onChevron = inside;
    _show();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      // Translucent: the photo under it keeps its taps, drags and zoom
      child: MouseRegion(
        hitTestBehavior: HitTestBehavior.translucent,
        onHover: (event) {
          if (event.kind == PointerDeviceKind.mouse) {
            _show();
          }
        },
        onExit: (_) {
          _hide?.cancel();
          _setVisible(false);
        },
        child: Stack(
          children: [
            Align(alignment: Alignment.centerLeft, child: _chevron(context, -1)),
            Align(alignment: Alignment.centerRight, child: _chevron(context, 1)),
          ],
        ),
      ),
    );
  }

  Widget _chevron(BuildContext context, int direction) {
    final shown = _visible && widget.canNavigate(direction);
    final highContrast = MediaQuery.highContrastOf(context);
    final button = IconButton(
      key: Key(direction < 0 ? 'desktop_chevron_previous' : 'desktop_chevron_next'),
      tooltip: direction < 0 ? context.t.previous : context.t.next,
      iconSize: 32,
      color: Colors.white,
      style: IconButton.styleFrom(
        backgroundColor: highContrast ? Colors.black : Colors.black54,
        side: highContrast ? const BorderSide(color: Colors.white, width: 2) : null,
        padding: const EdgeInsets.all(12),
      ),
      icon: Icon(direction < 0 ? Icons.chevron_left_rounded : Icons.chevron_right_rounded),
      onPressed: () {
        widget.onNavigate(direction);
        // The next page may have no neighbour on that side
        if (mounted) {
          setState(() {});
        }
      },
    );
    return SizedBox(
      width: DesktopPageChevrons.edgeWidth,
      child: Center(
        // Not reachable with Tab: the arrows do the same from the keyboard
        child: ExcludeFocus(
          child: IgnorePointer(
            ignoring: !shown,
            child: ExcludeSemantics(
              excluding: !shown,
              child: MouseRegion(
                onEnter: (_) => _onChevronHover(true),
                onExit: (_) => _onChevronHover(false),
                child: AnimatedOpacity(
                  opacity: shown ? 1 : 0,
                  duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : Durations.short4,
                  child: button,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [child] with the chevrons above it, for a viewer that has no Stack of its own
Widget withDesktopPageChevrons(
  Widget child, {
  required bool Function(int direction) canNavigate,
  required void Function(int direction) onNavigate,
}) => Stack(
  fit: StackFit.expand,
  children: [
    child,
    DesktopPageChevrons(canNavigate: canNavigate, onNavigate: onNavigate),
  ],
);
