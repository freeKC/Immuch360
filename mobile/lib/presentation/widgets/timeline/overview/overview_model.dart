// The months and the years of a timeline, from its buckets: no query, no call to the server. A month is a run of
// consecutive buckets of the same calendar month (day buckets, or a month bucket as it is), in the order of the
// timeline, newest first or oldest first (an album in ascending order); a year is a run of consecutive months of the
// same year.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';

/// A month of the timeline: how many assets, and the index of its first one in the timeline
@immutable
class OverviewMonth {
  const OverviewMonth({
    required this.year,
    required this.month,
    required this.assetCount,
    required this.firstAssetIndex,
  });

  final int year;

  /// 1 for January
  final int month;

  final int assetCount;

  final int firstAssetIndex;

  DateTime get date => DateTime(year, month);

  @override
  bool operator ==(Object other) =>
      other is OverviewMonth &&
      other.year == year &&
      other.month == month &&
      other.assetCount == assetCount &&
      other.firstAssetIndex == firstAssetIndex;

  @override
  int get hashCode => Object.hash(year, month, assetCount, firstAssetIndex);

  @override
  String toString() => 'OverviewMonth($year-$month, $assetCount from $firstAssetIndex)';
}

/// A year of the timeline: its twelve months in calendar order, January first, whatever the order of the timeline
@immutable
class OverviewYear {
  const OverviewYear({
    required this.year,
    required this.assetCount,
    required this.firstAssetIndex,
    required this.months,
  });

  final int year;

  final int assetCount;

  /// The first asset of the year in the order of the timeline: of December when the newest come first
  final int firstAssetIndex;

  /// Twelve entries, January first; null for a month without assets
  final List<OverviewMonth?> months;

  /// The assets of the fullest month, for the tint of the cells
  int get largestMonthCount => months.fold(0, (largest, month) => math.max(largest, month?.assetCount ?? 0));

  @override
  bool operator ==(Object other) =>
      other is OverviewYear &&
      other.year == year &&
      other.assetCount == assetCount &&
      other.firstAssetIndex == firstAssetIndex &&
      listEquals(other.months, months);

  @override
  int get hashCode => Object.hash(year, assetCount, firstAssetIndex, Object.hashAll(months));

  @override
  String toString() => 'OverviewYear($year, $assetCount from $firstAssetIndex)';
}

/// Whether [buckets] can be shown as months and years: there is at least one, and each has a date (a search, or a
/// list of assets without dates, has a single bucket without one)
bool bucketsHaveDates(Iterable<Bucket> buckets) =>
    buckets.isNotEmpty && buckets.every((bucket) => bucket is TimeBucket);

/// The months of [buckets], in their order; empty when a bucket has no date
List<OverviewMonth> overviewMonths(Iterable<Bucket> buckets) {
  if (!bucketsHaveDates(buckets)) {
    return const [];
  }
  final months = <OverviewMonth>[];
  int? year;
  int? month;
  var count = 0;
  var first = 0;
  var index = 0;
  void flush() {
    if (year != null && month != null && count > 0) {
      months.add(OverviewMonth(year: year, month: month, assetCount: count, firstAssetIndex: first));
    }
  }

  for (final bucket in buckets) {
    final date = (bucket as TimeBucket).date;
    if (date.year != year || date.month != month) {
      flush();
      year = date.year;
      month = date.month;
      count = 0;
      first = index;
    }
    count += bucket.assetCount;
    index += bucket.assetCount;
  }
  flush();
  return months;
}

/// The years of [months], in their order. A month met twice in a year (a timeline in no date order) counts once, its
/// first run giving the cover.
List<OverviewYear> overviewYears(List<OverviewMonth> months) {
  final years = <OverviewYear>[];
  var index = 0;
  while (index < months.length) {
    final year = months[index].year;
    final first = months[index].firstAssetIndex;
    final cells = List<OverviewMonth?>.filled(12, null);
    var count = 0;
    for (; index < months.length && months[index].year == year; index++) {
      final month = months[index];
      final known = cells[month.month - 1];
      cells[month.month - 1] = known == null
          ? month
          : OverviewMonth(
              year: year,
              month: month.month,
              assetCount: known.assetCount + month.assetCount,
              firstAssetIndex: known.firstAssetIndex,
            );
      count += month.assetCount;
    }
    years.add(OverviewYear(year: year, assetCount: count, firstAssetIndex: first, months: List.unmodifiable(cells)));
  }
  return years;
}
