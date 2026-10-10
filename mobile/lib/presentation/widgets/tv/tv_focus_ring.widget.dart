import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Marks a part of the app where [TvFocusRing] draws no ring around the focused widget: the viewers that show their
/// own state (the key catchers of the 360° views, which cover the screen anyway).
class NoFocusRing extends InheritedWidget {
  const NoFocusRing({super.key, required super.child});

  /// Whether [context] sits under a [NoFocusRing]
  static bool covers(BuildContext context) => context.getElementForInheritedWidgetOfExactType<NoFocusRing>() != null;

  @override
  bool updateShouldNotify(NoFocusRing oldWidget) => false;
}

/// The focus ring of the remote control layout (Android TV): one frame drawn over the whole app around the widget that
/// has the focus, whatever that widget draws itself, so that the focus can be followed from across a room. It moves to
/// the next widget in a short ease and follows the focused widget while it scrolls or moves with a route transition.
///
/// No ring for a focus scope, a widget without a size, a widget that covers nearly the whole screen (the key catchers
/// of the viewers: the ring would only frame the screen) and a widget under [NoFocusRing].
///
/// It never asks for frames of its own except while it moves: the position of the focused widget is read after each
/// frame the app draws anyway.
///
/// Off ([enabled] false), it draws nothing and follows nothing, and keeps the same widgets around [child]: the app
/// keeps its routes when the remote control layout is turned on or off (see TvShell).
class TvFocusRing extends StatefulWidget {
  const TvFocusRing({super.key, this.enabled = true, required this.child});

  /// Whether the ring is drawn
  final bool enabled;

  final Widget child;

  /// Width of the coloured line
  static const strokeWidth = 3.0;

  /// Space between the focused widget and the inner edge of the line
  static const gap = 2.0;

  static const radius = 8.0;

  /// Above this share of the screen, a focused widget gets no ring
  static const maxCoverage = 0.9;

  static const moveDuration = Duration(milliseconds: 120);

  @override
  State<TvFocusRing> createState() => TvFocusRingState();
}

class TvFocusRingState extends State<TvFocusRing> with SingleTickerProviderStateMixin {
  final _paintKey = GlobalKey();
  late final AnimationController _move = AnimationController(vsync: this, duration: TvFocusRing.moveDuration);
  late final Animation<double> _moveCurve = CurvedAnimation(parent: _move, curve: Curves.easeOut);

  FocusNode? _node;
  Rect? _from;
  Rect? _target;
  bool _listening = false;
  bool _frameCallbackPending = false;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      _listen();
    }
  }

  @override
  void didUpdateWidget(TvFocusRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !_listening) {
      _listen();
    } else if (!widget.enabled && _listening) {
      _stopListening();
      _node = null;
      _target = null;
      _from = null;
      _move.stop();
    }
  }

  @override
  void dispose() {
    _stopListening();
    _move.dispose();
    super.dispose();
  }

  void _listen() {
    _listening = true;
    FocusManager.instance.addListener(_onFocusChange);
    _scheduleAfterFrame();
  }

  void _stopListening() {
    _listening = false;
    FocusManager.instance.removeListener(_onFocusChange);
  }

  /// One pending callback at most, even when the ring is turned off and on again within a frame
  void _scheduleAfterFrame() {
    if (_frameCallbackPending) {
      return;
    }
    _frameCallbackPending = true;
    SchedulerBinding.instance.addPostFrameCallback(_afterFrame);
  }

  void _onFocusChange() {
    _update();
    // The focused widget may move in the frame that follows (a list scrolling it into view)
    SchedulerBinding.instance.scheduleFrame();
  }

  void _afterFrame(Duration _) {
    _frameCallbackPending = false;
    if (!_listening) {
      return;
    }
    _update();
    _scheduleAfterFrame();
  }

  /// Reads where the focused widget is now, and moves the ring there: in an ease when the focus went to another
  /// widget, at once when the same widget moved (scrolling, a route transition)
  void _update() {
    if (!mounted) {
      return;
    }
    final node = FocusManager.instance.primaryFocus;
    final target = _ringTarget(node);
    if (target == _target && node == _node) {
      return;
    }
    final shown = _shownRect();
    final moved = node != _node;
    _node = node;
    _target = target;
    if (moved && shown != null && target != null) {
      _from = shown;
      _move.forward(from: 0);
    } else if (!_move.isAnimating) {
      _from = null;
      _move.value = 1;
    }
    _paintKey.currentContext?.findRenderObject()?.markNeedsPaint();
  }

  /// Where the ring is drawn now, in the coordinates of [TvFocusRing]; null when none shows
  @visibleForTesting
  Rect? get ringRect => _shownRect();

  Rect? _shownRect() {
    final target = _target;
    final from = _from;
    if (target == null || from == null || !_move.isAnimating) {
      return target;
    }
    return Rect.lerp(from, target, _moveCurve.value);
  }

  /// The rectangle of [node] in the coordinates of this widget, or null when it gets no ring
  Rect? _ringTarget(FocusNode? node) {
    if (node == null || node is FocusScopeNode) {
      return null;
    }
    final context = node.context;
    if (context == null || !context.mounted || NoFocusRing.covers(context)) {
      return null;
    }
    final object = context.findRenderObject();
    final self = this.context.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize || self is! RenderBox || !self.hasSize) {
      return null;
    }
    final Rect rect;
    try {
      rect = MatrixUtils.transformRect(object.getTransformTo(self), Offset.zero & object.size);
    } catch (_) {
      // Not in the same tree any more (a route being removed): no ring for this frame
      return null;
    }
    // A widget scrolled out of its list, kept for a while but laid out nowhere, has no place on screen
    if (!rect.isFinite || rect.width < 1 || rect.height < 1) {
      return null;
    }
    final screen = Offset.zero & self.size;
    final visible = rect.intersect(screen);
    if (visible.width <= 0 || visible.height <= 0) {
      return null;
    }
    if (visible.width * visible.height >= TvFocusRing.maxCoverage * screen.width * screen.height) {
      return null;
    }
    return rect;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Stack(
      // Above the app's own Directionality
      alignment: Alignment.topLeft,
      fit: StackFit.expand,
      children: [
        widget.child,
        if (widget.enabled)
          IgnorePointer(
            child: CustomPaint(
              key: _paintKey,
              painter: _RingPainter(rect: _shownRect, color: colorScheme.primary, repaint: _move),
            ),
          ),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.rect, required this.color, required Listenable repaint}) : super(repaint: repaint);

  final Rect? Function() rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final focused = rect();
    if (focused == null || !focused.isFinite) {
      return;
    }
    const half = TvFocusRing.strokeWidth / 2;
    final line = RRect.fromRectAndRadius(
      focused.inflate(TvFocusRing.gap + half),
      const Radius.circular(TvFocusRing.radius),
    );
    // A thin dark line around the coloured one, so that the ring reads over a light photo too
    canvas.drawRRect(
      line.inflate(half + 0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black.withAlpha(160),
    );
    canvas.drawRRect(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = TvFocusRing.strokeWidth
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) => oldDelegate.color != color;
}
