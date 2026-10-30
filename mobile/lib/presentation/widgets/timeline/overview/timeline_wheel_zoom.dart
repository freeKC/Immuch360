// Ctrl and the mouse wheel on the timeline (Command on a Mac or an iPad): one rung of the zoom ladder a notch, towards
// the years when the wheel turns towards the user. While the key is held, the physics of the list refuse the moves of
// the user (TimelineWheelZoomPhysics), so its Scrollable no longer claims the wheel and the timeline gets it; the key
// released, the list scrolls again. A pinch of a touchpad arrives as scale events, through the pinch of the timeline.

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/desktop/window/desktop_shortcuts.dart';

/// Whether the key that turns the wheel into a zoom is held on [keyboard]: Control, or Command on Apple systems
bool zoomModifierPressed(HardwareKeyboard keyboard, TargetPlatform platform) =>
    keyboard.isControlPressed ||
    ((platform == TargetPlatform.macOS || platform == TargetPlatform.iOS) && keyboard.isMetaPressed);

/// Follows [zoomModifierPressed] through the key events of the whole app
class TimelineZoomModifier extends ValueNotifier<bool> {
  TimelineZoomModifier({this._platform}) : super(false) {
    HardwareKeyboard.instance.addHandler(_onKey);
    refresh();
  }

  final TargetPlatform? _platform;

  bool _onKey(KeyEvent _) {
    refresh();
    return false;
  }

  /// Reads the keyboard again (a key may have been released while another window had it)
  void refresh() => value = zoomModifierPressed(HardwareKeyboard.instance, _platform ?? defaultTargetPlatform);

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }
}

/// The physics of the list while the zoom key is held: no move of the user, the wheel included
class TimelineWheelZoomPhysics extends ScrollPhysics {
  const TimelineWheelZoomPhysics({super.parent});

  @override
  TimelineWheelZoomPhysics applyTo(ScrollPhysics? ancestor) => TimelineWheelZoomPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => false;
}

/// [physics] as they are, or wrapped in [TimelineWheelZoomPhysics] while the zoom key is [held]
ScrollPhysics? timelineWheelZoomPhysics(ScrollPhysics? physics, {required bool held}) =>
    held ? TimelineWheelZoomPhysics(parent: physics) : physics;

/// Counts the notches of a wheel: a mouse sends one move a notch, a fine wheel or a touchpad many small ones
class WheelNotchCounter {
  double _sum = 0;

  /// The whole notches [delta] completes, toward the user when positive; the rest waits for the next move. One move
  /// counts for three notches at most.
  int add(double delta, double notch) {
    if (notch <= 0 || delta == 0) {
      return 0;
    }
    _sum += delta;
    final notches = (_sum / notch).truncate();
    _sum -= notches * notch;
    return notches.clamp(-3, 3);
  }

  void reset() => _sum = 0;
}

/// Turns the wheel moves over [child] into [onSteps] while the zoom key is [held]
class TimelineWheelZoom extends StatefulWidget {
  const TimelineWheelZoom({
    super.key,
    required this.enabled,
    required this.held,
    required this.onSteps,
    required this.child,
    this.notch,
  });

  final bool enabled;
  final bool held;

  /// Rungs farther (positive) or closer (negative) on the zoom ladder
  final ValueChanged<int> onSteps;

  final Widget child;

  /// The size of a notch for the tests; by default the notch of this computer (desktopWheelNotch)
  final double? notch;

  @override
  State<TimelineWheelZoom> createState() => _TimelineWheelZoomState();
}

class _TimelineWheelZoomState extends State<TimelineWheelZoom> {
  final _counter = WheelNotchCounter();

  @override
  void didUpdateWidget(covariant TimelineWheelZoom oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.held) {
      _counter.reset();
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (!widget.enabled || !widget.held || event is! PointerScrollEvent || event.scrollDelta.dy == 0) {
      return;
    }
    // The list does not register while the key is held (its physics refuse), so the timeline gets the move
    GestureBinding.instance.pointerSignalResolver.register(event, _onWheel);
  }

  void _onWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !mounted) {
      return;
    }
    final notch = widget.notch ?? desktopWheelNotch(defaultTargetPlatform, MediaQuery.devicePixelRatioOf(context));
    final steps = _counter.add(event.scrollDelta.dy, notch);
    if (steps != 0) {
      widget.onSteps(steps);
    }
  }

  @override
  Widget build(BuildContext context) => Listener(onPointerSignal: _onPointerSignal, child: widget.child);
}
