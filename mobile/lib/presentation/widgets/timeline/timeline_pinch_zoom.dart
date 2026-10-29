import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/timeline_wheel_zoom.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/timeline_zoom.dart';

/// Mapping of pinch to zoom on the timeline to its zoom ladder (overview/timeline_zoom.dart): the number of columns of
/// the grid as before, then the months and the years. Ctrl and the mouse wheel step on the same ladder
/// (overview/timeline_wheel_zoom.dart).
///
/// The timeline applies each change ([onZoomChanged]): a change of columns writes the `timelineTilesPerRow` setting,
/// whose reload rebuilds this widget, so one gesture crosses one column; the months and the years are a state of the
/// page, so one gesture may go on from the grid to the years.
class TimelinePinchZoom extends StatefulWidget {
  const TimelinePinchZoom({
    super.key,
    required this.zoom,
    required this.onZoomChanged,
    this.overviewAvailable = false,
    this.wheelEnabled = false,
    this.wheelHeld = false,
    required this.child,
  });

  /// Where the timeline stands
  final TimelineZoom zoom;

  /// Called while the gesture is still resolving, with the rung the pinch or the wheel reached
  final ValueChanged<TimelineZoom> onZoomChanged;

  /// Whether the timeline has months and years
  final bool overviewAvailable;

  /// Whether Ctrl and the mouse wheel zoom, and whether the key is held now
  final bool wheelEnabled;
  final bool wheelHeld;

  final Widget child;

  @override
  State createState() => _TimelinePinchZoomState();
}

class _TimelinePinchZoomState extends State<TimelinePinchZoom> {
  late TimelineZoom _zoom = widget.zoom;
  late double _scaleFactor = restScaleFor(_zoom);
  late double _baseScaleFactor = _scaleFactor;

  @override
  void didUpdateWidget(covariant TimelinePinchZoom oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.zoom != _zoom) {
      // The level changed elsewhere (a tap on a month, Back, the wheel): the next pinch starts from its rest
      _zoom = widget.zoom;
      _scaleFactor = restScaleFor(_zoom);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TimelineWheelZoom(
      enabled: widget.wheelEnabled,
      held: widget.wheelHeld,
      onSteps: (steps) =>
          widget.onZoomChanged(stepZoom(widget.zoom, steps, overviewAvailable: widget.overviewAvailable)),
      child: RawGestureDetector(
        gestures: {
          _CustomScaleGestureRecognizer: GestureRecognizerFactoryWithHandlers<_CustomScaleGestureRecognizer>(
            () => _CustomScaleGestureRecognizer(),
            (_CustomScaleGestureRecognizer scale) {
              scale.onStart = (details) {
                _baseScaleFactor = _scaleFactor;
              };

              scale.onUpdate = (details) {
                final available = widget.overviewAvailable;
                final newScaleFactor = clampTimelineScale(
                  _baseScaleFactor * details.scale,
                  overviewAvailable: available,
                );
                final next = zoomForScale(newScaleFactor, _zoom, overviewAvailable: available);

                if (next != _zoom) {
                  _zoom = next;
                  // Where the next gesture starts; this one goes on from its own start
                  _scaleFactor = next.isOverview ? restScaleFor(next) : newScaleFactor;
                  widget.onZoomChanged(next);
                }
              };
            },
          ),
        },
        child: widget.child,
      ),
    );
  }
}

/// accepts a gesture even though it should reject it (because child won)
class _CustomScaleGestureRecognizer extends ScaleGestureRecognizer {
  @override
  void rejectGesture(int pointer) {
    acceptGesture(pointer);
  }
}
