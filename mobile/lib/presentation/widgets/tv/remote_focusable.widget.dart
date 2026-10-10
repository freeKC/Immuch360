import 'dart:async';

import 'package:flutter/material.dart';

/// A tap target that the remote control of a TV, a keyboard or a game pad also reaches: it takes the focus with the
/// arrows, and OK (select, enter, space, game button A) taps it. Replaces a bare GestureDetector(onTap:,
/// onLongPress:), which no key reaches. Touch is unchanged: the same GestureDetector, no ripple; the slight scale
/// only shows while the focus highlight does, that is after a key was used.
class RemoteFocusable extends StatefulWidget {
  const RemoteFocusable({
    super.key,
    required this.onTap,
    this.onLongPress,
    this.autofocus = false,
    this.focusNode,
    this.focusScale = 1.04,
    required this.child,
  });

  final VoidCallback onTap;

  /// Touch only: holding OK is no long press in Flutter, and what a long press does on phones (selection) is hidden on
  /// a TV anyway
  final VoidCallback? onLongPress;
  final bool autofocus;
  final FocusNode? focusNode;

  /// The scale of [child] while it shows the focus
  final double focusScale;
  final Widget child;

  @override
  State<RemoteFocusable> createState() => _RemoteFocusableState();
}

class _RemoteFocusableState extends State<RemoteFocusable> {
  bool _highlighted = false;

  late final Map<Type, Action<Intent>> _actions = {
    ActivateIntent: CallbackAction<ActivateIntent>(
      onInvoke: (_) {
        widget.onTap();
        return null;
      },
    ),
  };

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      actions: _actions,
      onShowFocusHighlight: (highlighted) {
        if (highlighted != _highlighted) {
          setState(() => _highlighted = highlighted);
        }
      },
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _highlighted ? widget.focusScale : 1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Gives the focus once to the first item of [child] that takes it, when [enabled]: the first item of a page in the
/// remote control layout, when that item has no autofocus of its own (a button of immich_ui for instance). The first
/// is the top one on screen, the left one of a row: the order of the focus tree puts the buttons inside a list tile
/// before the tile itself. A page that scrolls brings that item into view: a focus given this way does not scroll by
/// itself, unlike a move of the arrows, and the focused item could sit below the screen.
class RemoteInitialFocus extends StatefulWidget {
  const RemoteInitialFocus({super.key, this.enabled = true, required this.child});

  final bool enabled;
  final Widget child;

  @override
  State<RemoteInitialFocus> createState() => _RemoteInitialFocusState();
}

class _RemoteInitialFocusState extends State<RemoteInitialFocus> {
  final _node = FocusNode(debugLabel: 'RemoteInitialFocus', canRequestFocus: false, skipTraversal: true);
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _focusFirstAfterFrame();
  }

  @override
  void didUpdateWidget(RemoteInitialFocus oldWidget) {
    super.didUpdateWidget(oldWidget);
    _focusFirstAfterFrame();
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  void _focusFirstAfterFrame() {
    if (!widget.enabled || _done) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.enabled || _done) {
        return;
      }
      final first = topLeftFocusNode(_node.traversalDescendants);
      if (first != null) {
        _done = true;
        first.requestFocus();
        _bringIntoView(first);
      }
    });
  }

  @override
  Widget build(BuildContext context) => Focus(focusNode: _node, child: widget.child);
}

/// Scrolls the scroll views around [node] the least that shows it whole, as a move of the arrows does
void _bringIntoView(FocusNode node) {
  final context = node.context;
  if (context == null) {
    return;
  }
  // Each one scrolls only when the item is past that edge
  unawaited(Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart));
  unawaited(Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd));
}

/// The node of [nodes] at the top of the screen, the left one of a row: the first item for a remote control. Nodes
/// that are not laid out are left out.
FocusNode? topLeftFocusNode(Iterable<FocusNode> nodes) {
  FocusNode? best;
  Rect? bestRect;
  for (final node in nodes) {
    final object = node.context?.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      continue;
    }
    final rect = node.rect;
    // Within a pixel, the same row
    final better =
        bestRect == null ||
        rect.top < bestRect.top - 1 ||
        ((rect.top - bestRect.top).abs() <= 1 && rect.left < bestRect.left);
    if (better) {
      best = node;
      bestRect = rect;
    }
  }
  return best;
}
