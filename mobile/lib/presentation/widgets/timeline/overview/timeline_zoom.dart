// The zoom ladder of the timeline: the grid of tiles (2 to 6 per row, the persisted setting), then one block a month,
// then one block a year. A pinch moves along it by its scale, Ctrl and the mouse wheel one rung a notch.
//
// The months and years are a state of the page, never saved: the app always opens on the grid.

import 'package:flutter/foundation.dart';

/// The levels of the timeline, from the closest to the farthest
enum TimelineZoomLevel { grid, months, years }

/// Where the timeline stands on its zoom ladder: a level, and for the grid its tiles per row
@immutable
class TimelineZoom {
  const TimelineZoom.grid(this.columns) : level = TimelineZoomLevel.grid;

  const TimelineZoom.months() : level = TimelineZoomLevel.months, columns = 0;

  const TimelineZoom.years() : level = TimelineZoomLevel.years, columns = 0;

  final TimelineZoomLevel level;

  /// The tiles per row of the grid, 0 for the months and the years
  final int columns;

  bool get isOverview => level != TimelineZoomLevel.grid;

  @override
  bool operator ==(Object other) => other is TimelineZoom && other.level == level && other.columns == columns;

  @override
  int get hashCode => Object.hash(level, columns);

  @override
  String toString() => switch (level) {
    TimelineZoomLevel.grid => 'TimelineZoom.grid($columns)',
    TimelineZoomLevel.months => 'TimelineZoom.months()',
    TimelineZoomLevel.years => 'TimelineZoom.years()',
  };
}

/// The fewest and the most tiles per row of the grid
const kTimelineMinColumns = 2;
const kTimelineMaxColumns = 6;

/// The pinch scale of the grid runs from 1 (6 per row) to 5 (2 per row), as it always did; the months and the years
/// take the scales below 1, down to [kTimelineMinOverviewScale]
const kTimelineMaxScale = 5.0;
const kTimelineMinGridScale = 1.0;
const kTimelineMinOverviewScale = 0.35;

/// The months come below 0.8 (a squeeze of 20 % from the rest of 6 per row) and go back to the grid at 1; the years
/// come below 0.5 and go back to the months at 0.62. The gap between the two edges of a level keeps a hand that
/// hesitates on an edge from going back and forth.
const kZoomMonthsEnterScale = 0.8;
const kZoomMonthsLeaveScale = 1.0;
const kZoomYearsEnterScale = 0.5;
const kZoomYearsLeaveScale = 0.62;

/// Where the next pinch starts from in the months and in the years, half way to each edge
const kZoomMonthsRestScale = 0.7;
const kZoomYearsRestScale = 0.42;

/// The tiles per row of the grid for a pinch scale: 7-floor(scale) on [1, 5], 6 to 2
int gridColumnsForScale(double scale) => 7 - scale.clamp(kTimelineMinGridScale, kTimelineMaxScale).floor();

/// A pinch scale kept inside the ladder: down to the years when the timeline has them, down to 6 per row otherwise
double clampTimelineScale(double scale, {required bool overviewAvailable}) =>
    scale.clamp(overviewAvailable ? kTimelineMinOverviewScale : kTimelineMinGridScale, kTimelineMaxScale);

/// The rung a pinch at [scale] reaches from [current]. Without months and years (search, map, TV) the grid stops at 6
/// per row.
TimelineZoom zoomForScale(double scale, TimelineZoom current, {required bool overviewAvailable}) {
  final clamped = clampTimelineScale(scale, overviewAvailable: overviewAvailable);
  if (!overviewAvailable) {
    return TimelineZoom.grid(gridColumnsForScale(clamped));
  }
  switch (current.level) {
    case TimelineZoomLevel.grid:
      if (clamped < kZoomYearsEnterScale) {
        return const TimelineZoom.years();
      }
      if (clamped < kZoomMonthsEnterScale) {
        return const TimelineZoom.months();
      }
      return TimelineZoom.grid(gridColumnsForScale(clamped));
    case TimelineZoomLevel.months:
      if (clamped >= kZoomMonthsLeaveScale) {
        return TimelineZoom.grid(gridColumnsForScale(clamped));
      }
      if (clamped < kZoomYearsEnterScale) {
        return const TimelineZoom.years();
      }
      return const TimelineZoom.months();
    case TimelineZoomLevel.years:
      if (clamped >= kZoomMonthsLeaveScale) {
        return TimelineZoom.grid(gridColumnsForScale(clamped));
      }
      if (clamped >= kZoomYearsLeaveScale) {
        return const TimelineZoom.months();
      }
      return const TimelineZoom.years();
  }
}

/// The scale a pinch starts from on [zoom]: 7 less the tiles per row on the grid, as before; inside the band of the
/// months or of the years otherwise
double restScaleFor(TimelineZoom zoom) => switch (zoom.level) {
  TimelineZoomLevel.grid => (7 - zoom.columns.clamp(kTimelineMinColumns, kTimelineMaxColumns)).toDouble(),
  TimelineZoomLevel.months => kZoomMonthsRestScale,
  TimelineZoomLevel.years => kZoomYearsRestScale,
};

/// [steps] rungs farther from [from] (more tiles per row, then the months, then the years), or closer when negative,
/// stopping at either end: Ctrl and the mouse wheel, one rung a notch
TimelineZoom stepZoom(TimelineZoom from, int steps, {required bool overviewAvailable}) {
  final rungs = <TimelineZoom>[
    for (var columns = kTimelineMinColumns; columns <= kTimelineMaxColumns; columns++) TimelineZoom.grid(columns),
    if (overviewAvailable) ...const [TimelineZoom.months(), TimelineZoom.years()],
  ];
  final start = switch (from.level) {
    TimelineZoomLevel.grid => from.columns.clamp(kTimelineMinColumns, kTimelineMaxColumns) - kTimelineMinColumns,
    TimelineZoomLevel.months => kTimelineMaxColumns - kTimelineMinColumns + 1,
    TimelineZoomLevel.years => kTimelineMaxColumns - kTimelineMinColumns + 2,
  };
  return rungs[(start + steps).clamp(0, rungs.length - 1)];
}

/// Steps from one column to the next further apart than this are no longer one climb towards the months
const kTimelineClimbPause = Duration(seconds: 20);

/// The grid that a tap or Back brings back from the months and the years. From the 4 tiles per row of the setting, the
/// months are three steps away (5, 6, then the months), each column written to the setting: the grid to come back to
/// is the one before those steps when they followed each other less than [kTimelineClimbPause] apart, rather than the
/// 6 per row passed on the way; the grid the months were entered from otherwise.
class TimelineZoomClimb {
  int? _from;
  DateTime? _stepAt;

  /// The tiles per row to come back to, null out of the months and the years
  int? gridBefore;

  /// The timeline goes from [current] to [next] at [now]
  void note(TimelineZoom current, TimelineZoom next, DateTime now) {
    final stepAt = _stepAt;
    final climbing = _from != null && stepAt != null && now.difference(stepAt) <= kTimelineClimbPause;
    if (!current.isOverview && !next.isOverview) {
      if (next.columns > current.columns) {
        _from = climbing ? _from : current.columns;
        _stepAt = now;
      } else {
        _from = null;
      }
    } else if (!current.isOverview) {
      gridBefore = climbing ? _from : current.columns;
      _from = null;
    } else if (!next.isOverview) {
      // Out of the months: a pinch stays on the grid it reaches, a tap and Back have asked for theirs already
      gridBefore = null;
    }
  }
}
