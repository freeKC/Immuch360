// The sizes of the months and the years from the width alone, and their segments: one after the other, found by their
// offset as the list finds them, each with the TimeBucket the scrubber labels.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_asset_loader.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_blocks.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_layout.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_segment.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';

void main() {
  final host = OverviewHost(loader: OverviewAssetLoader((_, _) async => const <BaseAsset>[]), onOpen: (_) {});

  group('the layout', () {
    test('the thumbnails of a month and the cells of a year by width', () {
      final cases = {
        320.0: (tiles: 5, columns: 6),
        412.0: (tiles: 6, columns: 6),
        600.0: (tiles: 7, columns: 12),
        800.0: (tiles: 10, columns: 12),
        1400.0: (tiles: 16, columns: 12),
      };
      for (final MapEntry(key: width, value: expected) in cases.entries) {
        final layout = OverviewLayout.forWidth(width);
        expect(layout.monthTiles, expected.tiles, reason: 'thumbnails at $width dp');
        expect(layout.yearColumns, expected.columns, reason: 'cells in a row at $width dp');
        expect(layout.yearRows * layout.yearColumns, 12);
        // The row fills the width between the margins
        final row = layout.monthTiles * layout.monthTileSide + (layout.monthTiles - 1) * kOverviewSpacing;
        expect(row, closeTo(width - 2 * kOverviewSidePadding, 0.001), reason: 'month row at $width dp');
        final cells = layout.yearColumns * layout.yearCellSide + (layout.yearColumns - 1) * kOverviewSpacing;
        expect(cells, closeTo(width - 2 * kOverviewSidePadding, 0.001), reason: 'year row at $width dp');
      }
    });

    test('a phone of 412 dp: thumbnails of 63 dp, a month block of about 119 dp', () {
      final layout = OverviewLayout.forWidth(412);
      expect(layout.monthTileSide, closeTo(63.67, 0.01));
      expect(layout.monthBlockExtent, closeTo(119.67, 0.01));
      expect(layout.yearBlockExtent, closeTo(kOverviewHeaderExtent + 2 * 63.67 + kOverviewSpacing + 8, 0.02));
    });

    test('never fewer than 4 thumbnails, nor a negative size', () {
      final narrow = OverviewLayout.forWidth(100);
      expect(narrow.monthTiles, kOverviewMinMonthTiles);
      expect(narrow.monthTileSide, greaterThan(0));
      final none = OverviewLayout.forWidth(0);
      expect(none.monthTileSide, 0);
      expect(none.yearCellSide, 0);
    });
  });

  group('the segments', () {
    final months = overviewMonths([
      for (var month = 12; month >= 1; month--) TimeBucket(date: DateTime(2024, month, 10), assetCount: month),
      for (var month = 12; month >= 7; month--) TimeBucket(date: DateTime(2023, month, 3), assetCount: 2),
    ]);
    final layout = OverviewLayout.forWidth(412);

    test('one month after the other, each with its TimeBucket', () {
      final segments = overviewMonthSegments(months, layout, host);
      expect(segments, hasLength(18));
      for (var i = 0; i < segments.length; i++) {
        final segment = segments[i];
        expect(segment.firstIndex, i);
        expect(segment.lastIndex, i);
        expect(segment.startOffset, closeTo(i * layout.monthBlockExtent, 0.001));
        expect(segment.endOffset - segment.startOffset, closeTo(layout.monthBlockExtent, 0.001));
        if (i > 0) {
          expect(segment.startOffset, segments[i - 1].endOffset, reason: 'contiguous');
        }
        final bucket = segment.bucket;
        expect(bucket, isA<TimeBucket>());
        expect((bucket as TimeBucket).date, months[i].date);
        expect(bucket.assetCount, months[i].assetCount);
        expect(segment.firstAssetIndex, months[i].firstAssetIndex);
      }
    });

    test('found by their offset as the list finds them', () {
      final segments = overviewMonthSegments(months, layout, host);
      final extent = layout.monthBlockExtent;
      expect(segments.findByOffset(0), segments[0]);
      expect(segments.findByOffset(extent * 3.5), segments[3]);
      expect(segments.findByOffset(extent * 17.9), segments[17]);
      expect(segments.findByOffset(extent * 100), segments.last, reason: 'past the end: the last');
      expect(segments.findByIndex(5), segments[5]);
      final fifth = segments[5];
      expect(fifth.getMinChildIndexForScrollOffset(fifth.startOffset + 1), 5);
      expect(fifth.getMaxChildIndexForScrollOffset(fifth.endOffset - 1), 5);
      expect(fifth.indexToLayoutOffset(5), fifth.startOffset);
      expect(fifth.indexToLayoutOffset(6), fifth.endOffset);
    });

    test('one year after the other, January 1st in their bucket', () {
      final years = overviewYears(months);
      final segments = overviewYearSegments(years, layout, host);
      expect(segments, hasLength(2));
      expect((segments[0].bucket as TimeBucket).date, DateTime(2024));
      expect(segments[0].bucket.assetCount, 78);
      expect(segments[0].firstAssetIndex, 0);
      expect((segments[1].bucket as TimeBucket).date, DateTime(2023));
      expect(segments[1].bucket.assetCount, 12);
      expect(segments[1].firstAssetIndex, 78);
      expect(segments[1].startOffset, segments[0].endOffset);
      expect(segments[1].endOffset, closeTo(2 * layout.yearBlockExtent, 0.001));
    });

    test('no months, no segments', () {
      expect(overviewMonthSegments(const [], layout, host), isEmpty);
      expect(overviewYearSegments(const [], layout, host), isEmpty);
    });
  });
}
