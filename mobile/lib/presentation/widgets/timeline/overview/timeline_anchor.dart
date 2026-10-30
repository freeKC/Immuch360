// What stays in place when the timeline changes its level or its tiles per row: an asset (the grid with fewer or more
// tiles per row, as before), a month, or a year. The anchor is taken on the segments of the level left, and its offset
// computed on the segments of the level shown next.
//
// Offsets follow the convention the grid always had: the offset of a segment is a scroll offset, so the line it brings
// a segment to is as far below the top of the screen as the bars above the list are tall, the place of the list's
// start when it is at its top.

import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/timeline_zoom.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';

@immutable
sealed class TimelineAnchor {
  const TimelineAnchor();
}

/// The asset at [assetIndex] of the timeline
final class AssetAnchor extends TimelineAnchor {
  const AssetAnchor(this.assetIndex);

  final int assetIndex;

  @override
  bool operator ==(Object other) => other is AssetAnchor && other.assetIndex == assetIndex;

  @override
  int get hashCode => assetIndex.hashCode;

  @override
  String toString() => 'AssetAnchor($assetIndex)';
}

/// A calendar month; [month] is 1 for January
final class MonthAnchor extends TimelineAnchor {
  const MonthAnchor(this.year, this.month);

  final int year;
  final int month;

  @override
  bool operator ==(Object other) => other is MonthAnchor && other.year == year && other.month == month;

  @override
  int get hashCode => Object.hash(year, month);

  @override
  String toString() => 'MonthAnchor($year-$month)';
}

/// A year
final class YearAnchor extends TimelineAnchor {
  const YearAnchor(this.year);

  final int year;

  @override
  bool operator ==(Object other) => other is YearAnchor && other.year == year;

  @override
  int get hashCode => year.hashCode;

  @override
  String toString() => 'YearAnchor($year)';
}

/// The index of the asset at [offset] in [segment]: the first of the row there on the grid, whose rows hold
/// [columnCount] assets; the first of the segment on its header, or for a block of the months and years
int assetIndexAtOffset(Segment segment, double offset, int columnCount) {
  final row = segment.getMinChildIndexForScrollOffset(offset);
  if (row <= segment.firstIndex) {
    return segment.firstAssetIndex;
  }
  return segment.firstAssetIndex + (row - segment.gridIndex) * columnCount;
}

/// The anchor at [offset] of [segments] (the level [from]) for a move to the level [to]: the asset when the grid stays
/// the grid; the year when leaving the years; the month otherwise
TimelineAnchor? anchorAtOffset(
  List<Segment> segments,
  double offset, {
  required TimelineZoomLevel from,
  required TimelineZoomLevel to,
  required int columnCount,
}) {
  if (segments.isEmpty) {
    return null;
  }
  // The segment that starts at or above the offset: on the edge between two, the one below, which the offset begins
  // (a jump to an anchor lands on that edge)
  final segment = segments.lastWhereOrNull((candidate) => candidate.startOffset <= offset) ?? segments.first;
  final bucket = segment.bucket;
  if ((from == TimelineZoomLevel.grid && to == TimelineZoomLevel.grid) || bucket is! TimeBucket) {
    return AssetAnchor(assetIndexAtOffset(segment, offset, columnCount));
  }
  if (from == TimelineZoomLevel.years) {
    return YearAnchor(bucket.date.year);
  }
  return MonthAnchor(bucket.date.year, bucket.date.month);
}

/// The scroll offset of [anchor] on [segments] of [level]: its segment's start, its row on the grid for an asset. A
/// month on the years is its year. A month or a year missing gives the nearest in time, the first in the order of the
/// timeline on a tie. Null without segments.
double? anchorOffset(
  TimelineAnchor anchor,
  List<Segment> segments, {
  required TimelineZoomLevel level,
  required int columnCount,
}) {
  if (segments.isEmpty) {
    return null;
  }
  switch (anchor) {
    case AssetAnchor(:final assetIndex):
      final segment =
          segments.lastWhereOrNull((candidate) => candidate.firstAssetIndex <= assetIndex) ?? segments.first;
      if (level != TimelineZoomLevel.grid) {
        return segment.startOffset;
      }
      // The row of the asset, as the grid always restored it
      final row = math.max(0, assetIndex - segment.firstAssetIndex) ~/ math.max(1, columnCount);
      return segment.indexToLayoutOffset(segment.gridIndex + row);
    case MonthAnchor(:final year, :final month):
      final target = level == TimelineZoomLevel.years ? year * 12 : year * 12 + month - 1;
      return _nearest(
        segments,
        target,
        (date) => level == TimelineZoomLevel.years ? date.year * 12 : _monthKey(date),
      )?.startOffset;
    case YearAnchor(:final year):
      return _nearest(segments, year, (date) => date.year)?.startOffset;
  }
}

int _monthKey(DateTime date) => date.year * 12 + date.month - 1;

/// The first segment in the order of the timeline whose key is [target], or else the one whose key is the nearest
Segment? _nearest(List<Segment> segments, int target, int Function(DateTime date) keyOf) {
  Segment? best;
  int? bestDistance;
  for (final segment in segments) {
    final bucket = segment.bucket;
    if (bucket is! TimeBucket) {
      continue;
    }
    final distance = (keyOf(bucket.date) - target).abs();
    if (bestDistance == null || distance < bestDistance) {
      best = segment;
      bestDistance = distance;
      if (distance == 0) {
        break;
      }
    }
  }
  return best;
}
