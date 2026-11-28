// A pinch on the touchpad of a computer (28 November 2026): what tells it from a two finger scroll, for every view of
// the desktop app that zooms.
//
// The three systems send the two fingers of a touchpad as one pan and zoom sequence (PointerPanZoomStart, Update, End):
// a scale since the start and a pan since the start. Windows reads a precision touchpad through DirectManipulation and
// the Flutter engine passes on the translation of its content unchanged (direct_manipulation.cc): as it scales that
// content around a point, a pinch comes with a pan of its own, about that point times (1 - scale), hundreds of pixels
// for a pinch that doubles. A drag of the view under the fingers took it as a two finger scroll as soon as it passed
// the touch slop, before the scale recognizer saw five per cent of zoom: the pinch turned a page, opened the details,
// closed the viewer or turned a sphere, and zoomed nothing. macOS and Linux send a pinch with little or no pan.
//
// So, as Chromium does with DirectManipulation: once the scale of a sequence leaves 1 by [desktopPinchSlop], the
// sequence is a pinch to its end, its pan is no move of its own, and the zoom goes around the point where it started
// (the pointer). A sequence whose scale stays 1 is a scroll, as before. A pure scroll keeps a scale of exactly 1 on
// the three systems (Windows rounds its scale so that steady fingers do not jitter).

import 'package:flutter/gestures.dart';

/// How far the scale of a touchpad gesture leaves 1 before the gesture is a pinch: half a per cent, reached by real
/// fingers within the first reports, while the pan that comes with it on Windows is a few pixels, below the touch slop
/// of the drags under it for any window narrower than 3600 logical pixels
const desktopPinchSlop = 0.005;

/// One two finger gesture of a touchpad at a time: whether it is a pinch, and the zoom of each of its reports
class TrackpadPinchLatch {
  int? _pointer;
  double _scale = 1;
  bool _pinching = false;
  Offset _start = Offset.zero;

  /// Whether the gesture going on, or the one that ended last, is a pinch: its pans are no drag, and it leaves no
  /// inertia; a new gesture or a pointer that goes down ([reset]) starts again
  bool get pinching => _pinching;

  /// Where the gesture started, in the coordinates of the events given: the pointer on Windows and macOS
  Offset get start => _start;

  /// The pointer of the gesture going on, or of the one that ended last
  int? get pointer => _pointer;

  void begin(PointerPanZoomStartEvent event) {
    _pointer = event.pointer;
    _scale = 1;
    _pinching = false;
    _start = event.localPosition;
  }

  /// The zoom [event] adds to the previous report, once the gesture is a pinch (above 1 zooms in); 1 otherwise. The
  /// first report past the slop gives the whole scale since the start, so that nothing of the pinch is lost.
  double update(PointerPanZoomUpdateEvent event) {
    if (event.pointer != _pointer) {
      _pointer = event.pointer;
      _scale = 1;
      _pinching = false;
      _start = event.localPosition;
    }
    final scale = event.scale;
    if (!scale.isFinite || scale <= 0) {
      return 1;
    }
    if (!_pinching && (scale - 1).abs() > desktopPinchSlop) {
      _pinching = true;
    }
    if (!_pinching) {
      return 1;
    }
    final factor = scale / _scale;
    _scale = scale;
    return factor;
  }

  /// A pointer went down (a mouse, a finger): the gesture before it is over
  void reset() {
    _pinching = false;
    _scale = 1;
  }
}

/// Takes a touchpad gesture away from the drags and the scale recognizers under and around a view, when its owner
/// says so ([take]) from a Listener of the same view: a Listener has every pointer event before any recognizer, so a
/// pinch is taken on the very report that makes it one, before a drag can count that report's pan. Until then it waits
/// and lets them be; it gives up at the end of the gesture.
class TrackpadGestureClaim extends OneSequenceGestureRecognizer {
  TrackpadGestureClaim({super.debugOwner}) : super(supportedDevices: const {PointerDeviceKind.trackpad});

  /// Whether a gesture that starts may be taken at all (the view zooms now)
  bool Function() active = _always;

  /// The gesture of [pointer] is this view's
  void Function(int pointer)? onAccepted;

  /// The gesture of [pointer] is no longer this view's, or never was: another recognizer took it, or it ended
  void Function(int pointer)? onReleased;

  static bool _always() => true;

  final _tracked = <int>{};
  final _won = <int>{};

  @override
  bool isPointerAllowed(PointerDownEvent event) => false;

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) => super.isPointerPanZoomAllowed(event) && active();

  @override
  void addAllowedPointerPanZoom(PointerPanZoomStartEvent event) {
    super.addAllowedPointerPanZoom(event);
    _tracked.add(event.pointer);
    startTrackingPointer(event.pointer, event.transform);
  }

  /// Takes the gesture of [pointer], if it is tracked here and nobody has it yet. Whether it is this view's now (at
  /// once when the arena is closed, at its closing during the start).
  bool take(int pointer) {
    if (_won.contains(pointer)) {
      return true;
    }
    if (!_tracked.contains(pointer)) {
      return false;
    }
    resolvePointer(pointer, GestureDisposition.accepted);
    return _won.contains(pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerPanZoomEndEvent || event is PointerCancelEvent) {
      final pointer = event.pointer;
      if (_won.remove(pointer)) {
        _tracked.remove(pointer);
        onReleased?.call(pointer);
      } else {
        resolvePointer(pointer, GestureDisposition.rejected);
      }
      stopTrackingPointer(pointer);
    }
  }

  @override
  void acceptGesture(int pointer) {
    if (_tracked.contains(pointer) && _won.add(pointer)) {
      onAccepted?.call(pointer);
    }
  }

  @override
  void rejectGesture(int pointer) {
    final was = _won.remove(pointer);
    if (_tracked.remove(pointer) || was) {
      onReleased?.call(pointer);
    }
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _tracked.clear();
    _won.clear();
  }

  @override
  String get debugDescription => 'touchpad pinch';
}
