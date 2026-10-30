// The months and the years of a timeline from its buckets: day buckets newest first as in the Photos tab, an album
// in ascending order, month buckets as they are, and a timeline without dates (a search) that has none.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_model.dart';

TimeBucket day(int year, int month, int day, int count) =>
    TimeBucket(date: DateTime(year, month, day), assetCount: count);

void main() {
  group('months', () {
    test('day buckets newest first come together by month, with their count and first index', () {
      final months = overviewMonths([
        day(2024, 10, 30, 3),
        day(2024, 10, 2, 4),
        day(2024, 9, 15, 1),
        day(2024, 1, 3, 2),
        day(2023, 12, 31, 5),
        day(2023, 12, 1, 1),
      ]);
      expect(months, const [
        OverviewMonth(year: 2024, month: 10, assetCount: 7, firstAssetIndex: 0),
        OverviewMonth(year: 2024, month: 9, assetCount: 1, firstAssetIndex: 7),
        OverviewMonth(year: 2024, month: 1, assetCount: 2, firstAssetIndex: 8),
        OverviewMonth(year: 2023, month: 12, assetCount: 6, firstAssetIndex: 10),
      ]);
    });

    test('an album in ascending order keeps its order', () {
      final months = overviewMonths([day(2022, 3, 1, 2), day(2022, 3, 9, 2), day(2022, 4, 1, 1), day(2023, 1, 1, 3)]);
      expect(months, const [
        OverviewMonth(year: 2022, month: 3, assetCount: 4, firstAssetIndex: 0),
        OverviewMonth(year: 2022, month: 4, assetCount: 1, firstAssetIndex: 4),
        OverviewMonth(year: 2023, month: 1, assetCount: 3, firstAssetIndex: 5),
      ]);
    });

    test('month buckets stay as they are', () {
      final months = overviewMonths([
        TimeBucket(date: DateTime(2025, 6), assetCount: 10),
        TimeBucket(date: DateTime(2025, 5), assetCount: 20),
      ]);
      expect(months, const [
        OverviewMonth(year: 2025, month: 6, assetCount: 10, firstAssetIndex: 0),
        OverviewMonth(year: 2025, month: 5, assetCount: 20, firstAssetIndex: 10),
      ]);
    });

    test('the same month in two years stays two months', () {
      final months = overviewMonths([day(2025, 5, 1, 1), day(2024, 5, 1, 1)]);
      expect(months.map((m) => (m.year, m.month)), [(2025, 5), (2024, 5)]);
    });

    test('a bucket without a date gives no months, nor does an empty timeline', () {
      expect(overviewMonths([const Bucket(assetCount: 12)]), isEmpty);
      expect(overviewMonths([day(2024, 1, 1, 1), const Bucket(assetCount: 3)]), isEmpty);
      expect(overviewMonths(const []), isEmpty);
      expect(bucketsHaveDates(const []), isFalse);
      expect(bucketsHaveDates([day(2024, 1, 1, 1)]), isTrue);
    });
  });

  group('years', () {
    test('twelve cells in calendar order, empty months null, newest first as the timeline', () {
      final years = overviewYears(
        overviewMonths([
          day(2024, 10, 30, 3),
          day(2024, 10, 2, 4),
          day(2024, 9, 15, 1),
          day(2024, 1, 3, 2),
          day(2023, 12, 31, 5),
        ]),
      );
      expect(years.map((y) => y.year), [2024, 2023]);

      final y2024 = years.first;
      expect(y2024.assetCount, 10);
      expect(y2024.firstAssetIndex, 0, reason: 'October comes first in the timeline');
      expect(y2024.months, hasLength(12));
      expect(y2024.months[0], const OverviewMonth(year: 2024, month: 1, assetCount: 2, firstAssetIndex: 8));
      expect(y2024.months[8], const OverviewMonth(year: 2024, month: 9, assetCount: 1, firstAssetIndex: 7));
      expect(y2024.months[9], const OverviewMonth(year: 2024, month: 10, assetCount: 7, firstAssetIndex: 0));
      for (final empty in [1, 2, 3, 4, 5, 6, 7, 10, 11]) {
        expect(y2024.months[empty], isNull, reason: 'month ${empty + 1}');
      }
      expect(y2024.largestMonthCount, 7);

      final y2023 = years.last;
      expect(y2023.assetCount, 5);
      expect(y2023.firstAssetIndex, 10);
      expect(y2023.months[11]?.assetCount, 5);
    });

    test('an ascending album gives its years oldest first, January still the first cell', () {
      final years = overviewYears(overviewMonths([day(2022, 3, 1, 2), day(2022, 11, 1, 1), day(2023, 2, 1, 3)]));
      expect(years.map((y) => y.year), [2022, 2023]);
      expect(years.first.firstAssetIndex, 0);
      expect(years.first.months[2]?.firstAssetIndex, 0);
      expect(years.first.months[10]?.firstAssetIndex, 2);
      expect(years.last.firstAssetIndex, 3);
    });

    test('a month met twice in a year counts once, its first run giving the cover', () {
      final years = overviewYears(overviewMonths([day(2024, 5, 2, 1), day(2024, 4, 1, 2), day(2024, 5, 1, 3)]));
      expect(years.single.months[4], const OverviewMonth(year: 2024, month: 5, assetCount: 4, firstAssetIndex: 0));
      expect(years.single.assetCount, 6);
    });

    test('no months, no years', () {
      expect(overviewYears(const []), isEmpty);
    });
  });
}
