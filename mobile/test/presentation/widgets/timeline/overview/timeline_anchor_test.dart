// What stays in place when the timeline changes level: the month at the top of the grid becomes the block of that
// month, the year at the top of the months the block of that year, and back; a tap on a month opens the grid at the
// first day of that month. An asset keeps its row when the grid changes its tiles per row, as before.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment_builder.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_asset_loader.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_blocks.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_layout.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_segment.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/timeline_anchor.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/timeline_zoom.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';

const grid = TimelineZoomLevel.grid;
const months = TimelineZoomLevel.months;
const years = TimelineZoomLevel.years;

void main() {
  // Two days a month with 5 assets each, from December 2024 down to January 2023, March 2024 missing
  final buckets = <Bucket>[
    for (var year = 2024; year >= 2023; year--)
      for (var month = 12; month >= 1; month--)
        if (!(year == 2024 && month == 3)) ...[
          TimeBucket(date: DateTime(year, month, 20), assetCount: 5),
          TimeBucket(date: DateTime(year, month, 5), assetCount: 5),
        ],
  ];
  const columns = 4;
  final gridSegments = FixedSegmentBuilder(
    buckets: buckets,
    tileHeight: 100,
    columnCount: columns,
    groupBy: GroupAssetsBy.day,
  ).generate();
  final host = OverviewHost(loader: OverviewAssetLoader((_, _) async => const <BaseAsset>[]), onOpen: (_) {});
  final layout = OverviewLayout.forWidth(412);
  final monthList = overviewMonths(buckets);
  final monthSegments = overviewMonthSegments(monthList, layout, host);
  final yearSegments = overviewYearSegments(overviewYears(monthList), layout, host);

  DateTime dateOf(Segment segment) => (segment.bucket as TimeBucket).date;

  Segment firstGridSegmentOf(int year, int month) =>
      gridSegments.firstWhere((s) => dateOf(s).year == year && dateOf(s).month == month);

  group('taken at an offset', () {
    test('the grid keeps the asset when it stays the grid, as before', () {
      final segment = firstGridSegmentOf(2024, 6);
      // The second row of the segment: assets 4 to 7 of it
      final offset = segment.indexToLayoutOffset(segment.gridIndex + 1) + 1;
      final anchor = anchorAtOffset(gridSegments, offset, from: grid, to: grid, columnCount: columns);
      expect(anchor, AssetAnchor(segment.firstAssetIndex + columns));
      expect(
        anchorAtOffset(gridSegments, segment.startOffset + 1, from: grid, to: grid, columnCount: columns),
        AssetAnchor(segment.firstAssetIndex),
        reason: 'on the header: the first asset of the day',
      );
    });

    test('the grid gives its month to the months and the years', () {
      final segment = firstGridSegmentOf(2023, 8);
      expect(
        anchorAtOffset(gridSegments, segment.startOffset + 10, from: grid, to: months, columnCount: columns),
        const MonthAnchor(2023, 8),
      );
      expect(
        anchorAtOffset(gridSegments, segment.startOffset + 10, from: grid, to: years, columnCount: columns),
        const MonthAnchor(2023, 8),
      );
    });

    test('the months give their month, the years their year', () {
      final month = monthSegments[5];
      expect(
        anchorAtOffset(monthSegments, month.startOffset + 3, from: months, to: grid, columnCount: columns),
        MonthAnchor(dateOf(month).year, dateOf(month).month),
      );
      final year = yearSegments[1];
      expect(
        anchorAtOffset(yearSegments, year.startOffset + 3, from: years, to: months, columnCount: columns),
        const YearAnchor(2023),
      );
      expect(anchorAtOffset(const [], 0, from: grid, to: months, columnCount: columns), isNull);
    });
  });

  group('placed on a level', () {
    test('a month of the grid is its block in the months', () {
      final offset = anchorOffset(const MonthAnchor(2023, 8), monthSegments, level: months, columnCount: columns);
      final block = monthSegments.firstWhere((s) => dateOf(s) == DateTime(2023, 8));
      expect(offset, block.startOffset);
    });

    test('a month is its year in the years', () {
      expect(
        anchorOffset(const MonthAnchor(2023, 8), yearSegments, level: years, columnCount: columns),
        yearSegments[1].startOffset,
      );
      expect(
        anchorOffset(const YearAnchor(2024), yearSegments, level: years, columnCount: columns),
        yearSegments[0].startOffset,
      );
    });

    test('a year is its first month in the order of the timeline', () {
      final offset = anchorOffset(const YearAnchor(2023), monthSegments, level: months, columnCount: columns);
      final december = monthSegments.firstWhere((s) => dateOf(s) == DateTime(2023, 12));
      expect(offset, december.startOffset);
    });

    test('a month tapped opens the grid at the first day of that month', () {
      expect(
        anchorOffset(const MonthAnchor(2024, 6), gridSegments, level: grid, columnCount: columns),
        firstGridSegmentOf(2024, 6).startOffset,
      );
      expect(
        anchorOffset(const YearAnchor(2023), gridSegments, level: grid, columnCount: columns),
        firstGridSegmentOf(2023, 12).startOffset,
      );
    });

    test('a month missing gives the nearest, the first in the order of the timeline on a tie', () {
      // March 2024 has no assets: April and February are as near, April comes first
      expect(
        anchorOffset(const MonthAnchor(2024, 3), monthSegments, level: months, columnCount: columns),
        monthSegments.firstWhere((s) => dateOf(s) == DateTime(2024, 4)).startOffset,
      );
      expect(
        anchorOffset(const MonthAnchor(2030, 1), monthSegments, level: months, columnCount: columns),
        monthSegments.first.startOffset,
        reason: 'after the newest: the newest',
      );
      expect(
        anchorOffset(const YearAnchor(1990), yearSegments, level: years, columnCount: columns),
        yearSegments.last.startOffset,
      );
    });

    test('an asset keeps its row on the grid, its block on the months', () {
      // The last of the five assets of June 20th: the second row of 4
      final segment = firstGridSegmentOf(2024, 6);
      final asset = segment.firstAssetIndex + 4;
      expect(
        anchorOffset(AssetAnchor(asset), gridSegments, level: grid, columnCount: columns),
        segment.indexToLayoutOffset(segment.gridIndex + 1),
      );
      expect(
        anchorOffset(AssetAnchor(asset), monthSegments, level: months, columnCount: columns),
        monthSegments.firstWhere((s) => dateOf(s) == DateTime(2024, 6)).startOffset,
      );
    });

    test('nothing to place on no segments', () {
      expect(anchorOffset(const MonthAnchor(2024, 1), const [], level: months, columnCount: columns), isNull);
    });
  });

  test('a round trip from the grid to the months and back lands on the same month', () {
    final start = firstGridSegmentOf(2023, 5);
    final toMonths = anchorAtOffset(gridSegments, start.startOffset + 1, from: grid, to: months, columnCount: columns)!;
    final monthsOffset = anchorOffset(toMonths, monthSegments, level: months, columnCount: columns)!;
    final back = anchorAtOffset(monthSegments, monthsOffset, from: months, to: grid, columnCount: columns)!;
    expect(anchorOffset(back, gridSegments, level: grid, columnCount: columns), start.startOffset);
  });
}
