// The zoom ladder of the timeline: the pinch scale to the tiles per row as before, then the months and the years with
// a gap between the edges of each level, the rest a pinch starts from, and the rungs Ctrl and the mouse wheel step on.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/timeline_zoom.dart';

void main() {
  const months = TimelineZoom.months();
  const years = TimelineZoom.years();

  group('the grid', () {
    test('keeps 7 - floor(scale) tiles per row between 1 and 5, as before', () {
      expect(gridColumnsForScale(1), 6);
      expect(gridColumnsForScale(1.99), 6);
      expect(gridColumnsForScale(2), 5);
      expect(gridColumnsForScale(3.5), 4);
      expect(gridColumnsForScale(4), 3);
      expect(gridColumnsForScale(5), 2);
      expect(gridColumnsForScale(9), 2, reason: 'clamped at 2 per row');
      expect(gridColumnsForScale(0.4), 6, reason: 'clamped at 6 per row');
    });

    test('stops at 6 per row when the timeline has no months and years (search, map, TV)', () {
      expect(clampTimelineScale(0.2, overviewAvailable: false), 1);
      expect(zoomForScale(0.3, const TimelineZoom.grid(6), overviewAvailable: false), const TimelineZoom.grid(6));
      expect(zoomForScale(0.3, months, overviewAvailable: false), const TimelineZoom.grid(6));
      expect(stepZoom(const TimelineZoom.grid(6), 1, overviewAvailable: false), const TimelineZoom.grid(6));
      expect(stepZoom(const TimelineZoom.grid(5), 3, overviewAvailable: false), const TimelineZoom.grid(6));
    });

    test('goes down to 0.35 when the timeline has them', () {
      expect(clampTimelineScale(0.1, overviewAvailable: true), kTimelineMinOverviewScale);
      expect(clampTimelineScale(7, overviewAvailable: true), kTimelineMaxScale);
    });
  });

  group('the edges', () {
    test('the months come below 0.8 from the grid, the years below 0.5', () {
      const grid = TimelineZoom.grid(6);
      expect(zoomForScale(0.81, grid, overviewAvailable: true), grid);
      expect(zoomForScale(0.79, grid, overviewAvailable: true), months);
      expect(zoomForScale(0.49, grid, overviewAvailable: true), years, reason: 'a quick pinch may pass both edges');
    });

    test('the months go back to the grid at 1 only, and on to the years below 0.5', () {
      expect(zoomForScale(0.95, months, overviewAvailable: true), months, reason: 'between the two edges');
      expect(zoomForScale(1.0, months, overviewAvailable: true), const TimelineZoom.grid(6));
      expect(zoomForScale(2.5, months, overviewAvailable: true), const TimelineZoom.grid(5));
      expect(zoomForScale(0.51, months, overviewAvailable: true), months);
      expect(zoomForScale(0.49, months, overviewAvailable: true), years);
    });

    test('the years go back to the months at 0.62 only, and to the grid at 1', () {
      expect(zoomForScale(0.55, years, overviewAvailable: true), years, reason: 'between the two edges');
      expect(zoomForScale(0.62, years, overviewAvailable: true), months);
      expect(zoomForScale(0.99, years, overviewAvailable: true), months);
      expect(zoomForScale(1.2, years, overviewAvailable: true), const TimelineZoom.grid(6));
      expect(zoomForScale(0.2, years, overviewAvailable: true), years, reason: 'the far end');
    });
  });

  test('a pinch starts from 7 - tiles per row on the grid, from inside the band of the months or the years', () {
    expect(restScaleFor(const TimelineZoom.grid(4)), 3);
    expect(restScaleFor(const TimelineZoom.grid(6)), 1);
    expect(restScaleFor(months), kZoomMonthsRestScale);
    expect(restScaleFor(years), kZoomYearsRestScale);
    // Each rest stays on its own level
    expect(zoomForScale(restScaleFor(months), months, overviewAvailable: true), months);
    expect(zoomForScale(restScaleFor(years), years, overviewAvailable: true), years);
    expect(
      zoomForScale(restScaleFor(const TimelineZoom.grid(6)), const TimelineZoom.grid(6), overviewAvailable: true),
      const TimelineZoom.grid(6),
    );
  });

  group('the wheel', () {
    test('steps one rung a notch from 2 per row to the years, and back', () {
      var zoom = const TimelineZoom.grid(2);
      final seen = <TimelineZoom>[zoom];
      for (var i = 0; i < 6; i++) {
        zoom = stepZoom(zoom, 1, overviewAvailable: true);
        seen.add(zoom);
      }
      expect(seen, const [
        TimelineZoom.grid(2),
        TimelineZoom.grid(3),
        TimelineZoom.grid(4),
        TimelineZoom.grid(5),
        TimelineZoom.grid(6),
        months,
        years,
      ]);
      expect(stepZoom(years, -1, overviewAvailable: true), months);
      expect(stepZoom(months, -1, overviewAvailable: true), const TimelineZoom.grid(6));
      expect(stepZoom(years, -6, overviewAvailable: true), const TimelineZoom.grid(2));
    });

    test('stops at either end', () {
      expect(stepZoom(years, 1, overviewAvailable: true), years);
      expect(stepZoom(years, 5, overviewAvailable: true), years);
      expect(stepZoom(const TimelineZoom.grid(2), -1, overviewAvailable: true), const TimelineZoom.grid(2));
      expect(stepZoom(const TimelineZoom.grid(4), -9, overviewAvailable: true), const TimelineZoom.grid(2));
    });

    test('several notches at once pass several rungs', () {
      expect(stepZoom(const TimelineZoom.grid(4), 3, overviewAvailable: true), months);
      expect(stepZoom(months, -3, overviewAvailable: true), const TimelineZoom.grid(4));
    });
  });

  test('equality', () {
    expect(const TimelineZoom.grid(4), const TimelineZoom.grid(4));
    expect(const TimelineZoom.grid(4) == const TimelineZoom.grid(5), isFalse);
    expect(months == years, isFalse);
    expect(months.isOverview, isTrue);
    expect(const TimelineZoom.grid(3).isOverview, isFalse);
  });
}
