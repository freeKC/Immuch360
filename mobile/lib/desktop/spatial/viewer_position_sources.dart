// Spatial 2.5D on the computers (release 53, lot P2): the sources of the viewer's position that need no camera
// (viewer_position.dart). The head tracked by the webcam is the lot feat-25d-tracker-53.
// - Mouse: the pointer over the picture is where the viewer looks from; the view follows it within 80 ms, so that the
//   steps of a mouse never show. Leaving the picture counts as no one seen: the view glides back to its centre.
// - Automatic sway: a slow back and forth (p from about 0.29 to 0.71 every four seconds), with no input at all.
// - Keys: the left and right arrows move the view by steps, which it glides through.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:immich_mobile/desktop/spatial/viewer_position.dart';

/// The monotonic clock of the 2.5D views and of the sources of this file
final Stopwatch _clock = Stopwatch()..start();

/// The time on the monotonic clock of the 2.5D views
Duration spatialClock() => _clock.elapsed;

/// Common part: the broadcast stream and the latest position
abstract class _BaseSource implements ViewerPositionSource {
  _BaseSource(this._now);

  final Duration Function() _now;
  final _controller = StreamController<ViewerPosition>.broadcast(sync: true);
  ViewerPosition? _latest;

  @override
  Stream<ViewerPosition> get positions => _controller.stream;

  @override
  ViewerPosition? get latest => _latest;

  void _send(double x, {double y = 0, double confidence = 1}) {
    if (_controller.isClosed) {
      return;
    }
    final position = confidence > 0
        ? ViewerPosition(x: x, y: y, timestamp: _now(), confidence: confidence)
        : ViewerPosition.lost(_now());
    _latest = position;
    _controller.add(position);
  }

  @override
  Future<void> close() => _controller.close();
}

/// The pointer over the picture
class MousePositionSource extends _BaseSource {
  MousePositionSource({Duration Function() clock = spatialClock}) : super(clock);

  /// The follow that hides the steps of a mouse
  static const follow = Duration(milliseconds: 80);

  double _centre = 0;
  double _rawX = 0;

  @override
  ViewerPositionKind get kind => ViewerPositionKind.mouse;

  @override
  Duration get followTime => follow;

  /// The pointer is at [local] in a picture of [size]
  void pointerAt(Offset local, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }
    _rawX = (local.dx / size.width * 2 - 1).clamp(-1.0, 1.0);
    final y = (local.dy / size.height * 2 - 1).clamp(-1.0, 1.0);
    _send(_rawX - _centre, y: y);
  }

  /// The pointer left the picture
  void pointerLeft() => _send(0, confidence: 0);

  @override
  void recenter() {
    _centre = _rawX;
    _send(0);
  }
}

/// A slow back and forth, with no input: x = [amplitude] sin(2 pi t / [period])
class SwayPositionSource extends _BaseSource {
  SwayPositionSource({Duration Function() clock = spatialClock, bool start = true}) : super(clock) {
    _origin = _now();
    if (start) {
      _timer = Timer.periodic(step, (_) => tick());
    }
    tick();
  }

  static const period = Duration(seconds: 4);
  static const amplitude = 0.6;

  /// About the frame rate of a screen: the follow covers the rest
  static const step = Duration(milliseconds: 16);

  late Duration _origin;
  Timer? _timer;

  @override
  ViewerPositionKind get kind => ViewerPositionKind.sway;

  @override
  Duration get followTime => const Duration(milliseconds: 30);

  /// The position of the sway at [elapsed] from its start
  static double swayAt(Duration elapsed) =>
      amplitude * math.sin(2 * math.pi * elapsed.inMicroseconds / period.inMicroseconds);

  /// Sends the position of now (the timer calls it)
  void tick() => _send(swayAt(_now() - _origin));

  @override
  void recenter() {
    _origin = _now();
    tick();
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}

/// The left and right arrows, by steps of [stepSize]
class KeysPositionSource extends _BaseSource {
  KeysPositionSource({Duration Function() clock = spatialClock}) : super(clock) {
    _send(0);
  }

  static const stepSize = 0.2;

  double _x = 0;

  @override
  ViewerPositionKind get kind => ViewerPositionKind.keys;

  @override
  Duration get followTime => const Duration(milliseconds: 120);

  /// Moves the view by [steps] steps, to the right for a positive count
  void nudge(int steps) {
    _x = (_x + steps * stepSize).clamp(-1.0, 1.0);
    _send(_x);
  }

  @override
  void recenter() {
    _x = 0;
    _send(0);
  }
}
