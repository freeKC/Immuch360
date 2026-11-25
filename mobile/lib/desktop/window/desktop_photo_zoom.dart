// The zoom and pan of a still picture with a mouse, a trackpad and a keyboard, on a computer (release 53): one shared
// implementation for the viewers of the desktop app that show a flat picture. The asset viewer of the library (an
// opened file included) zooms its PhotoView through [PhotoViewZoomTarget]; the photo page of a share or a folder and
// the comparison of Enhance (AI) draw their picture under a [DesktopZoomView]. The phones, the TV and the Quest keep
// their pinch, their double tap and the remote zoom of release 50: nothing here is built off a computer.
//
// - The wheel zooms around the pointer: the point under the cursor stays under it, about 11 % a notch (the step of
//   the 360° viewer, wheelZoomFactor), between the whole picture ("fit") and [desktopZoomBeyondOneToOne] times its
//   pixels shown one to one, and at least [desktopZoomMinRange] times the fit for a small picture. Out at fit does
//   nothing. A horizontal wheel move, or Shift and the wheel, pans a zoomed picture and is left to the page otherwise.
// - A trackpad pinch zooms around the fingers, two fingers pan a zoomed picture (the PhotoView of the asset viewer
//   reads them itself, as it reads a touch screen); at fit they keep their meaning (the pages turn).
// - A drag with the left button pans a zoomed picture, with a grab cursor, within its edges and without inertia; at
//   fit a drag keeps its meaning.
// - A double click goes from fit to the zoom used last on this picture, else to the pixels one to one (or 2.5 times
//   the fit for a picture smaller than the window), the clicked point staying under the cursor; zoomed, it goes back
//   to fit.
// - The keys, read by each viewer (desktopZoomKeyOf): + and - zoom around the middle, 0 fits, 1 shows the pixels one
//   to one, the arrows pan a zoomed picture, Escape first goes back to fit.
// - The level shows for a moment in the bottom middle, as a percentage of the pixels of the original.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/window/desktop_shortcuts.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';
import 'package:intl/intl.dart';

/// How far past the pixels one to one the zoom goes: 4 times, 400 %
const desktopZoomBeyondOneToOne = 4.0;

/// The zoom of a small picture goes at least this many times its fit
const desktopZoomMinRange = 4.0;

/// A press of + or -
const desktopZoomKeyStep = 1.25;

/// What one press of an arrow pans a zoomed picture by, a share of the window
const desktopZoomPanShare = 0.1;

/// How long the level stays on screen after the last change
const desktopZoomIndicatorFor = Duration(milliseconds: 1200);

/// How long a double click, 0, 1 and the keys take to get to their zoom
const desktopZoomAnimation = Duration(milliseconds: 180);

/// What a viewer shows and how far it may zoom, in the units of its scale
@immutable
class DesktopZoomFrame {
  const DesktopZoomFrame({
    required this.viewport,
    required this.picture,
    required this.fitScale,
    required this.oneToOneScale,
    required this.maxScale,
  });

  /// The frame, its scale and the limits for a picture of [picture] logical pixels at scale 1 in [viewport], shown
  /// whole at [fitScale], whose original has [originalPixels] (turned as shown; null: those of [picture] at
  /// [devicePixelRatio] 1, as PhotoView decodes them), and never past [cap] when the view has a limit of its own
  factory DesktopZoomFrame.of({
    required Size viewport,
    required Size picture,
    required double fitScale,
    required double devicePixelRatio,
    Size? originalPixels,
    double? cap,
  }) {
    final long = picture.longestSide;
    final ratio = devicePixelRatio > 0 ? devicePixelRatio : 1.0;
    final oneToOne = originalPixels != null && originalPixels.longestSide > 0 && long > 0
        ? originalPixels.longestSide / ratio / long
        : 1 / ratio;
    var most = math.max(fitScale * desktopZoomMinRange, oneToOne * desktopZoomBeyondOneToOne);
    if (cap != null && cap.isFinite) {
      most = math.min(most, cap);
    }
    return DesktopZoomFrame(
      viewport: viewport,
      picture: picture,
      fitScale: fitScale,
      oneToOneScale: oneToOne,
      maxScale: math.max(fitScale, most),
    );
  }

  /// The window the picture shows in, logical pixels
  final Size viewport;

  /// The picture at scale 1, logical pixels, turned as shown
  final Size picture;

  /// The scale that shows the whole picture
  final double fitScale;

  /// The scale that shows the pixels of the original one to one on the screen
  final double oneToOneScale;

  /// The largest scale
  final double maxScale;

  @override
  bool operator ==(Object other) =>
      other is DesktopZoomFrame &&
      other.viewport == viewport &&
      other.picture == picture &&
      other.fitScale == fitScale &&
      other.oneToOneScale == oneToOneScale &&
      other.maxScale == maxScale;

  @override
  int get hashCode => Object.hash(viewport, picture, fitScale, oneToOneScale, maxScale);
}

/// A picture the desktop zoom moves. The position is where the middle of the picture is from the middle of the
/// window, logical pixels; a point of the picture at `c` from its middle (at scale 1) shows at `position + scale * c`.
abstract class DesktopZoomTarget implements Listenable {
  /// Null until the picture is laid out
  DesktopZoomFrame? get frame;

  double get scale;

  Offset get position;

  /// Moves the picture at once
  void apply(double scale, Offset position);

  /// Moves the picture in [desktopZoomAnimation], or at once where the system asks for fewer animations
  Future<void> animateTo(double scale, Offset position);
}

/// Whether [target] shows its picture zoomed in, past the fit
bool desktopZoomed(DesktopZoomTarget target) {
  final frame = target.frame;
  return frame != null && target.scale > frame.fitScale * 1.001;
}

/// How much of the original's pixels [target] shows, 1 for one to one; null before its layout
double? desktopZoomLevel(DesktopZoomTarget target) {
  final frame = target.frame;
  return frame == null || frame.oneToOneScale <= 0 ? null : target.scale / frame.oneToOneScale;
}

/// [position] kept within the edges of the picture at [scale]: no empty band past them, the picture in the middle on
/// an axis it does not fill
Offset desktopZoomClamp(DesktopZoomFrame frame, double scale, Offset position) {
  final x = math.max(0.0, (frame.picture.width * scale - frame.viewport.width) / 2);
  final y = math.max(0.0, (frame.picture.height * scale - frame.viewport.height) / 2);
  return Offset(position.dx.clamp(-x, x), position.dy.clamp(-y, y));
}

/// Where a zoom from [scale] at [position] to [next] puts the picture, [focal] (from the middle of the window) staying
/// where it is; at or under the fit, the whole picture in the middle
({double scale, Offset position}) desktopZoomAround(
  DesktopZoomFrame frame,
  double scale,
  Offset position,
  double next,
  Offset focal,
) {
  final clamped = next.clamp(frame.fitScale, frame.maxScale);
  if (clamped <= frame.fitScale * 1.001 || scale <= 0) {
    return (scale: frame.fitScale, position: Offset.zero);
  }
  final moved = focal - (focal - position) * (clamped / scale);
  return (scale: clamped, position: desktopZoomClamp(frame, clamped, moved));
}

/// Zooms [target] by [factor] around [focal], from the middle of the window (the middle itself by default). Whether
/// it changed: not out at fit, nor in at the largest scale.
bool desktopZoomBy(DesktopZoomTarget target, double factor, {Offset focal = Offset.zero, bool animate = false}) {
  final frame = target.frame;
  if (frame == null) {
    return false;
  }
  final scale = target.scale;
  final next = desktopZoomAround(frame, scale, target.position, scale * factor, focal);
  if ((next.scale - scale).abs() < 1e-9 && next.position == target.position) {
    return false;
  }
  animate ? unawaited(target.animateTo(next.scale, next.position)) : target.apply(next.scale, next.position);
  return true;
}

/// The whole picture again, in the middle. Whether it changed.
bool desktopZoomFit(DesktopZoomTarget target, {bool animate = false}) {
  final frame = target.frame;
  if (frame == null || ((target.scale - frame.fitScale).abs() < 1e-9 && target.position == Offset.zero)) {
    return false;
  }
  animate ? unawaited(target.animateTo(frame.fitScale, Offset.zero)) : target.apply(frame.fitScale, Offset.zero);
  return true;
}

/// The pixels of the original one to one, around [focal]. Whether it changed.
bool desktopZoomOneToOne(DesktopZoomTarget target, {Offset focal = Offset.zero, bool animate = false}) {
  final frame = target.frame;
  if (frame == null) {
    return false;
  }
  return desktopZoomBy(target, frame.oneToOneScale / target.scale, focal: focal, animate: animate);
}

/// Pans a zoomed picture by [delta], logical pixels, within its edges. Whether it moved.
bool desktopZoomPan(DesktopZoomTarget target, Offset delta) {
  final frame = target.frame;
  if (frame == null || !desktopZoomed(target)) {
    return false;
  }
  final position = desktopZoomClamp(frame, target.scale, target.position + delta);
  if (position == target.position) {
    return false;
  }
  target.apply(target.scale, position);
  return true;
}

/// What a key does to a still picture on a computer
enum DesktopZoomKey { zoomIn, zoomOut, fit, oneToOne, panLeft, panRight, panUp, panDown, escape }

/// The zoom key [event] stands for, presses and repeats only (a held + keeps zooming): + and - of any layout, 0 and 1
/// of the main row and of the number pad without Control, Alt or Meta, the arrows without any of them and Escape. Never
/// while a text field has the keyboard ([typing], by default [isTypingText]).
DesktopZoomKey? desktopZoomKeyOf(KeyEvent event, {bool? typing}) {
  if (event is KeyUpEvent || (typing ?? isTypingText())) {
    return null;
  }
  final key = event.logicalKey;
  final keyboard = HardwareKeyboard.instance;
  final plain = !keyboard.isControlPressed && !keyboard.isMetaPressed && !keyboard.isAltPressed;
  if (key == LogicalKeyboardKey.escape) {
    return event is KeyDownEvent && plain && !keyboard.isShiftPressed ? DesktopZoomKey.escape : null;
  }
  if (!plain) {
    return null;
  }
  if (isRemoteZoomIn(event)) {
    return DesktopZoomKey.zoomIn;
  }
  if (isRemoteZoomOut(event)) {
    return DesktopZoomKey.zoomOut;
  }
  if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
    return event is KeyDownEvent ? DesktopZoomKey.fit : null;
  }
  if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1) {
    return event is KeyDownEvent ? DesktopZoomKey.oneToOne : null;
  }
  if (keyboard.isShiftPressed) {
    return null;
  }
  return switch (key) {
    LogicalKeyboardKey.arrowLeft => DesktopZoomKey.panLeft,
    LogicalKeyboardKey.arrowRight => DesktopZoomKey.panRight,
    LogicalKeyboardKey.arrowUp => DesktopZoomKey.panUp,
    LogicalKeyboardKey.arrowDown => DesktopZoomKey.panDown,
    _ => null,
  };
}

/// Does what [key] asks of [target]. Whether the key is taken: the zoom keys always (a picture at its limit keeps
/// them), the arrows and Escape only while the picture is zoomed in, so that they keep their meaning otherwise (the
/// next and previous picture, the step back of the window).
bool desktopZoomApplyKey(DesktopZoomTarget target, DesktopZoomKey key, {bool animate = true}) {
  final frame = target.frame;
  if (frame == null) {
    return false;
  }
  final pan = frame.viewport * desktopZoomPanShare;
  switch (key) {
    case DesktopZoomKey.zoomIn:
      desktopZoomBy(target, desktopZoomKeyStep, animate: animate);
      return true;
    case DesktopZoomKey.zoomOut:
      desktopZoomBy(target, 1 / desktopZoomKeyStep, animate: animate);
      return true;
    case DesktopZoomKey.fit:
      desktopZoomFit(target, animate: animate);
      return true;
    case DesktopZoomKey.oneToOne:
      desktopZoomOneToOne(target, animate: animate);
      return true;
    case DesktopZoomKey.escape:
      return desktopZoomed(target) && desktopZoomFit(target, animate: animate);
    case DesktopZoomKey.panLeft:
    case DesktopZoomKey.panRight:
    case DesktopZoomKey.panUp:
    case DesktopZoomKey.panDown:
      if (!desktopZoomed(target)) {
        return false;
      }
      // What comes into view: the arrow to the right shows more of the right side. Taken at an edge too.
      final delta = switch (key) {
        DesktopZoomKey.panLeft => Offset(pan.width, 0),
        DesktopZoomKey.panRight => Offset(-pan.width, 0),
        DesktopZoomKey.panUp => Offset(0, pan.height),
        _ => Offset(0, -pan.height),
      };
      desktopZoomPan(target, delta);
      return true;
  }
}

/// Whether [key] is one of the arrows, which a viewer gives to the zoom only while it has the focus itself (a focused
/// button keeps them to move the focus)
bool isDesktopZoomArrow(DesktopZoomKey key) => switch (key) {
  DesktopZoomKey.panLeft || DesktopZoomKey.panRight || DesktopZoomKey.panUp || DesktopZoomKey.panDown => true,
  _ => false,
};

/// The animation of [DesktopZoomTarget.animateTo], on the ticker of the [DesktopPhotoZoom] that shows the target
/// ([attachTicker]): the scale goes geometrically, so that the zoom looks even, each step through [setTransform] as
/// a move at once would. At once without a ticker. A move at once ([apply]) stops it.
mixin DesktopZoomAnimator on ChangeNotifier implements DesktopZoomTarget {
  AnimationController? _animation;
  ({double scale, Offset position})? _from;
  ({double scale, Offset position})? _to;

  /// Moves the picture, the animation's steps included
  @protected
  void setTransform(double scale, Offset position);

  /// The ticker of the view that shows the target, null once it goes
  void attachTicker(TickerProvider? vsync) {
    _animation?.dispose();
    _animation = vsync == null
        ? null
        : (AnimationController(vsync: vsync, duration: desktopZoomAnimation)..addListener(_onTick));
  }

  void _onTick() {
    final from = _from;
    final to = _to;
    final animation = _animation;
    if (from == null || to == null || animation == null) {
      return;
    }
    final t = Curves.easeOutCubic.transform(animation.value);
    setTransform(
      from.scale * math.pow(to.scale / from.scale, t),
      t >= 1 ? to.position : Offset.lerp(from.position, to.position, t)!,
    );
  }

  @override
  void apply(double scale, Offset position) {
    _animation?.stop();
    setTransform(scale, position);
  }

  @override
  Future<void> animateTo(double scale, Offset position) {
    final animation = _animation;
    if (animation == null || this.scale <= 0 || scale <= 0) {
      apply(scale, position);
      return Future.value();
    }
    _from = (scale: this.scale, position: this.position);
    _to = (scale: scale, position: position);
    return animation.forward(from: 0).orCancel.catchError((_) {});
  }

  @override
  void dispose() {
    _animation?.dispose();
    _animation = null;
    super.dispose();
  }
}

/// The PhotoView of the asset viewer as a [DesktopZoomTarget], through its controller (see [attach]): the picture is
/// the child of its scale boundaries, the fit their initial scale, never past their largest scale
class PhotoViewZoomTarget extends ChangeNotifier with DesktopZoomAnimator {
  PhotoViewZoomTarget({PhotoViewControllerBase? controller, this.originalPixels, this.devicePixelRatio}) {
    attach(controller);
  }

  PhotoViewControllerBase? _controller;
  StreamSubscription<PhotoViewControllerValue>? _changes;
  bool _disposed = false;

  /// The screen's, by default that of the first window
  final double? devicePixelRatio;

  /// The pixel size of the original, turned as shown: the pixels one to one are its own, whatever the decoded picture
  /// (a preview until the original came). Null: the decoded picture is the original.
  Size? originalPixels;

  /// The controller of the PhotoView shown now; its changes are this target's, followed while it has listeners
  void attach(PhotoViewControllerBase? controller) {
    if (identical(controller, _controller)) {
      return;
    }
    _controller = controller;
    _follow();
  }

  void _follow() {
    unawaited(_changes?.cancel());
    _changes = hasListeners && !_disposed
        ? _controller?.outputStateStream.listen((_) {
            if (!_disposed) {
              notifyListeners();
            }
          })
        : null;
  }

  @override
  void addListener(VoidCallback listener) {
    final first = !hasListeners;
    super.addListener(listener);
    if (first) {
      _follow();
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _follow();
    }
  }

  PhotoViewControllerBase? get controller => _controller;

  @override
  DesktopZoomFrame? get frame {
    final bounds = _controller?.scaleBoundaries;
    if (bounds == null || bounds.childSize.isEmpty || bounds.initialScale <= 0) {
      return null;
    }
    return DesktopZoomFrame.of(
      viewport: bounds.outerSize,
      picture: bounds.childSize,
      fitScale: bounds.initialScale,
      devicePixelRatio:
          devicePixelRatio ?? WidgetsBinding.instance.platformDispatcher.views.firstOrNull?.devicePixelRatio ?? 1,
      originalPixels: originalPixels,
      cap: bounds.maxScale,
    );
  }

  @override
  double get scale => _controller?.scale ?? frame?.fitScale ?? 1;

  @override
  Offset get position => _controller?.position ?? Offset.zero;

  /// Through updateMultiple, which tells the scale state too (zoomed in, back to the fit): PhotoView's own animations
  /// do not, and the viewer then turned its pages and hid its bars as if the photo were whole
  @override
  void setTransform(double scale, Offset position) => _controller?.updateMultiple(scale: scale, position: position);

  @override
  void dispose() {
    _disposed = true;
    unawaited(_changes?.cancel());
    _changes = null;
    super.dispose();
  }
}

/// The scale and position of a picture under a [DesktopZoomView], which lays it out ([layout]) and animates it
/// ([attachTicker]); the page that shows the picture holds it, as an InteractiveViewer's TransformationController
class DesktopZoomController extends ChangeNotifier with DesktopZoomAnimator {
  DesktopZoomFrame? _frame;
  double _scale = 1;
  Offset _position = Offset.zero;

  @override
  DesktopZoomFrame? get frame => _frame;

  @override
  double get scale => _scale;

  @override
  Offset get position => _position;

  /// What the picture looks like on screen: its middle at the middle of the window moved by [position], [scale]
  /// times its fitted size (the fit is scale 1 here)
  Matrix4 get matrix {
    final viewport = _frame?.viewport ?? Size.zero;
    final middle = viewport.center(Offset.zero);
    return Matrix4.identity()
      ..translateByDouble(middle.dx + _position.dx, middle.dy + _position.dy, 0, 1)
      ..scaleByDouble(_scale, _scale, 1, 1)
      ..translateByDouble(-middle.dx, -middle.dy, 0, 1);
  }

  /// Called by the view at each layout: a new window or picture keeps the zoom relative to the fit, within the edges
  @visibleForTesting
  void layout(DesktopZoomFrame frame) {
    final previous = _frame;
    if (previous == frame) {
      return;
    }
    _frame = frame;
    if (previous == null || previous.fitScale <= 0) {
      _scale = frame.fitScale;
      _position = Offset.zero;
      return;
    }
    _scale = (_scale / previous.fitScale * frame.fitScale).clamp(frame.fitScale, frame.maxScale);
    _position = desktopZoomClamp(frame, _scale, _position);
  }

  @override
  void setTransform(double scale, Offset position) {
    _scale = scale;
    _position = position;
    notifyListeners();
  }

  /// The whole picture, in the middle, at once: a new photo, a turn
  void reset() {
    final frame = _frame;
    apply(frame?.fitScale ?? 1, Offset.zero);
  }
}

/// A picture that zooms and pans with [DesktopPhotoZoom]: [child] fills the window and holds the picture fitted
/// whole in its middle (BoxFit.contain), [pixelSize] being the picture's pixels turned as shown (its original's when
/// known), null while unknown (the edges are then those of the window)
class DesktopZoomView extends StatefulWidget {
  const DesktopZoomView({
    super.key,
    required this.controller,
    required this.child,
    this.pixelSize,
    this.mouseDrag = true,
  });

  final DesktopZoomController controller;
  final Size? pixelSize;
  final Widget child;

  /// See [DesktopPhotoZoom.mouseDrag]
  final bool mouseDrag;

  @override
  State<DesktopZoomView> createState() => _DesktopZoomViewState();
}

class _DesktopZoomViewState extends State<DesktopZoomView> {
  @override
  Widget build(BuildContext context) {
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        final pixels = widget.pixelSize;
        final picture = pixels == null || pixels.isEmpty
            ? viewport
            : applyBoxFit(BoxFit.contain, pixels, viewport).destination;
        if (viewport.isFinite && !viewport.isEmpty && !picture.isEmpty) {
          widget.controller.layout(
            DesktopZoomFrame.of(
              viewport: viewport,
              picture: picture,
              fitScale: 1,
              devicePixelRatio: ratio,
              // Unknown pixels: one to one is the fit
              originalPixels: pixels ?? Size(picture.width * ratio, picture.height * ratio),
            ),
          );
        }
        return DesktopPhotoZoom(
          target: widget.controller,
          trackpad: true,
          mouseDrag: widget.mouseDrag,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: widget.controller,
              builder: (context, child) => Transform(transform: widget.controller.matrix, child: child),
              child: SizedBox.fromSize(size: viewport, child: widget.child),
            ),
          ),
        );
      },
    );
  }
}

/// The mouse, the wheel and the trackpad of [target] (see the top of this file), around [child], which fills the
/// window of the picture; with the level shown for a moment after each change
class DesktopPhotoZoom extends StatefulWidget {
  const DesktopPhotoZoom({
    super.key,
    required this.target,
    required this.child,
    this.enabled = true,
    this.trackpad = false,
    this.mouseDrag = true,
  });

  final DesktopZoomTarget target;
  final Widget child;

  /// Off: the wheel and the clicks go on to [child] (the details of the asset viewer)
  final bool enabled;

  /// Whether the pinch and the two finger pan of a trackpad are read here; the PhotoView of the asset viewer reads
  /// them itself
  final bool trackpad;

  /// Whether a drag with the left button pans the zoomed picture; off where the view reads the drag itself
  final bool mouseDrag;

  @override
  State<DesktopPhotoZoom> createState() => _DesktopPhotoZoomState();
}

class _DesktopPhotoZoomState extends State<DesktopPhotoZoom> with TickerProviderStateMixin {
  /// The zoom used last on this picture, relative to its fit, for the next double click
  double? _lastZoom;

  /// The left button that pans the picture, while it is down
  int? _panPointer;

  Offset? _doubleClickAt;

  /// The scale of the last pinch event of a trackpad
  double _pinchScale = 1;

  bool _zoomed = false;
  bool _indicatorShown = false;
  double? _shownScale;
  DesktopZoomFrame? _shownFrame;
  Timer? _indicatorTimer;

  @override
  void initState() {
    super.initState();
    widget.target.addListener(_onTarget);
    _attachTicker(widget.target, this);
    _zoomed = desktopZoomed(widget.target);
    _shownFrame = widget.target.frame;
    _shownScale = _shownFrame == null ? null : widget.target.scale;
  }

  @override
  void didUpdateWidget(DesktopPhotoZoom oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.target, widget.target)) {
      oldWidget.target.removeListener(_onTarget);
      _attachTicker(oldWidget.target, null);
      widget.target.addListener(_onTarget);
      _attachTicker(widget.target, this);
      _lastZoom = null;
      _shownScale = null;
      _shownFrame = null;
      _onTarget();
    }
  }

  @override
  void dispose() {
    widget.target.removeListener(_onTarget);
    _attachTicker(widget.target, null);
    _indicatorTimer?.cancel();
    super.dispose();
  }

  static void _attachTicker(DesktopZoomTarget target, TickerProvider? vsync) {
    if (target is DesktopZoomAnimator) {
      target.attachTicker(vsync);
    }
  }

  void _onTarget() {
    if (!mounted) {
      return;
    }
    final target = widget.target;
    final zoomed = desktopZoomed(target);
    final frame = target.frame;
    final scale = frame == null ? null : target.scale;
    if (zoomed && frame != null) {
      _lastZoom = target.scale / frame.fitScale;
    }
    // The level shows after a change of the zoom, never for a new layout: another picture, the original in place of
    // the preview (the same zoom at another scale), another size of the window
    final changed =
        _shownScale != null &&
        scale != null &&
        frame == _shownFrame &&
        (scale - _shownScale!).abs() > _shownScale! * 1e-4;
    if (scale != null) {
      _shownScale = scale;
      _shownFrame = frame;
    }
    if (changed) {
      _indicatorTimer?.cancel();
      _indicatorTimer = Timer(desktopZoomIndicatorFor, () {
        if (mounted) {
          setState(() => _indicatorShown = false);
        }
      });
    }
    if (zoomed != _zoomed || changed) {
      setState(() {
        _zoomed = zoomed;
        if (changed) {
          _indicatorShown = true;
        }
        if (!zoomed) {
          _panPointer = null;
        }
      });
    }
  }

  Offset _fromMiddle(Offset local) {
    final frame = widget.target.frame;
    return frame == null ? Offset.zero : local - frame.viewport.center(Offset.zero);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    final target = widget.target;
    if (!widget.enabled || target.frame == null) {
      return;
    }
    if (event is PointerScaleEvent) {
      GestureBinding.instance.pointerSignalResolver.register(event, (event) {
        desktopZoomBy(target, (event as PointerScaleEvent).scale, focal: _fromMiddle(event.localPosition));
      });
      return;
    }
    if (event is! PointerScrollEvent) {
      return;
    }
    final delta = event.scrollDelta;
    final sideways =
        (delta.dy == 0 && delta.dx != 0) ||
        (HardwareKeyboard.instance.isShiftPressed && delta.dy != 0 && delta.dx == 0);
    if (sideways) {
      // A zoomed picture pans; at fit the page keeps the move (Shift and the wheel turn the pages of the asset viewer)
      if (desktopZoomed(target)) {
        final dx = delta.dx != 0 ? delta.dx : delta.dy;
        GestureBinding.instance.pointerSignalResolver.register(event, (_) => desktopZoomPan(target, Offset(-dx, 0)));
      }
      return;
    }
    final factor = wheelZoomFactor(event);
    if (factor == null) {
      return;
    }
    // Taken even out at fit, where nothing happens: the wheel never does anything else over the picture
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      desktopZoomBy(target, 1 / factor, focal: _fromMiddle(event.localPosition));
    });
  }

  void _onPointerDown(PointerDownEvent event) {
    if (widget.enabled &&
        widget.mouseDrag &&
        event.kind == PointerDeviceKind.mouse &&
        event.buttons == kPrimaryMouseButton &&
        desktopZoomed(widget.target)) {
      setState(() => _panPointer = event.pointer);
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer == _panPointer) {
      desktopZoomPan(widget.target, event.localDelta);
    }
  }

  void _onPointerEnd(PointerEvent event) {
    if (event.pointer == _panPointer) {
      setState(() => _panPointer = null);
    }
  }

  void _onPanZoomStart(PointerPanZoomStartEvent event) => _pinchScale = 1;

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    final target = widget.target;
    if (!widget.enabled) {
      return;
    }
    if (event.scale > 0 && (event.scale - _pinchScale).abs() > 1e-6) {
      desktopZoomBy(target, event.scale / _pinchScale, focal: _fromMiddle(event.localPosition));
      _pinchScale = event.scale;
    }
    if (event.localPanDelta != Offset.zero) {
      desktopZoomPan(target, event.localPanDelta);
    }
  }

  void _onDoubleClick() {
    final target = widget.target;
    final frame = target.frame;
    if (frame == null) {
      return;
    }
    final focal = _fromMiddle(_doubleClickAt ?? frame.viewport.center(Offset.zero));
    final animate = !desktopReducedMotion(context);
    if (desktopZoomed(target)) {
      desktopZoomFit(target, animate: animate);
      return;
    }
    final oneToOne = frame.oneToOneScale;
    // A picture smaller than the window shows larger than its pixels already: a zoom that shows something
    final first = oneToOne > frame.fitScale * 1.25 ? oneToOne : frame.fitScale * 2.5;
    final next = _lastZoom != null ? frame.fitScale * _lastZoom! : first;
    final moved = desktopZoomAround(frame, target.scale, target.position, next, focal);
    animate ? unawaited(target.animateTo(moved.scale, moved.position)) : target.apply(moved.scale, moved.position);
  }

  String _levelText(BuildContext context) {
    final level = desktopZoomLevel(widget.target) ?? 1;
    final locale = Localizations.maybeLocaleOf(context)?.toLanguageTag() ?? 'en';
    try {
      return NumberFormat.percentPattern(locale).format(level);
    } on ArgumentError {
      return NumberFormat.percentPattern('en').format(level);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The same tree when off, so that the view under it keeps its state (the details of the asset viewer open and
    // close over it): nothing is read then
    final enabled = widget.enabled;
    final grabbing = _panPointer != null;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerSignal: _onPointerSignal,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      onPointerPanZoomStart: widget.trackpad ? _onPanZoomStart : null,
      onPointerPanZoomUpdate: widget.trackpad ? _onPanZoomUpdate : null,
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: {
          DoubleTapGestureRecognizer: GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
            () => DoubleTapGestureRecognizer(debugOwner: this),
            (recognizer) => recognizer
              ..onDoubleTapDown = enabled ? ((details) => _doubleClickAt = details.localPosition) : null
              ..onDoubleTap = enabled ? _onDoubleClick : null,
          ),
        },
        child: MouseRegion(
          opaque: false,
          cursor: enabled && _zoomed && widget.mouseDrag
              ? (grabbing ? SystemMouseCursors.grabbing : SystemMouseCursors.grab)
              : MouseCursor.defer,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              widget.child,
              Positioned(
                left: 0,
                right: 0,
                bottom: 96,
                child: IgnorePointer(
                  child: Center(
                    child: AnimatedOpacity(
                      key: const Key('desktop_zoom_level'),
                      opacity: enabled && _indicatorShown ? 1 : 0,
                      duration: MediaQuery.maybeDisableAnimationsOf(context) ?? false
                          ? Duration.zero
                          : Durations.medium2,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: const BorderRadius.all(Radius.circular(16)),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          child: Text(_levelText(context), style: const TextStyle(color: Colors.white, fontSize: 14)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
