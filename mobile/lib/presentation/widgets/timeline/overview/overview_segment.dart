// The months and the years as segments of the timeline's list (SliverSegmentedList), one child a block: the list, the
// scrubber and the anchors read them as they read the segments of the grid. Each carries a TimeBucket of its month or
// year (the first of the month, January 1st of the year) with its count, so the scrubber labels them as usual.

import 'package:flutter/widgets.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_blocks.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_layout.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';

/// A segment of a single child, the whole block
abstract class OverviewSegment extends Segment {
  const OverviewSegment({
    required int index,
    required super.startOffset,
    required super.endOffset,
    required TimeBucket super.bucket,
    required super.firstAssetIndex,
  }) : super(
         firstIndex: index,
         lastIndex: index,
         headerExtent: kOverviewHeaderExtent,
         spacing: 0,
         header: HeaderType.none,
       );

  @override
  double indexToLayoutOffset(int index) => index <= firstIndex ? startOffset : endOffset;

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) => firstIndex;

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) => firstIndex;
}

class OverviewMonthSegment extends OverviewSegment {
  const OverviewMonthSegment({
    required super.index,
    required super.startOffset,
    required super.endOffset,
    required super.bucket,
    required super.firstAssetIndex,
    required this.month,
    required this.layout,
    required this.host,
  });

  final OverviewMonth month;
  final OverviewLayout layout;
  final OverviewHost host;

  @override
  Widget builder(BuildContext context, int index) =>
      OverviewMonthBlock(key: ValueKey(month.date), month: month, layout: layout, host: host);
}

class OverviewYearSegment extends OverviewSegment {
  const OverviewYearSegment({
    required super.index,
    required super.startOffset,
    required super.endOffset,
    required super.bucket,
    required super.firstAssetIndex,
    required this.year,
    required this.layout,
    required this.host,
  });

  final OverviewYear year;
  final OverviewLayout layout;
  final OverviewHost host;

  @override
  Widget builder(BuildContext context, int index) =>
      OverviewYearBlock(key: ValueKey(year.year), year: year, layout: layout, host: host);
}

/// One segment a month, one after the other
List<Segment> overviewMonthSegments(List<OverviewMonth> months, OverviewLayout layout, OverviewHost host) {
  final extent = layout.monthBlockExtent;
  return [
    for (var i = 0; i < months.length; i++)
      OverviewMonthSegment(
        index: i,
        startOffset: i * extent,
        endOffset: (i + 1) * extent,
        bucket: TimeBucket(date: months[i].date, assetCount: months[i].assetCount),
        firstAssetIndex: months[i].firstAssetIndex,
        month: months[i],
        layout: layout,
        host: host,
      ),
  ];
}

/// One segment a year, one after the other
List<Segment> overviewYearSegments(List<OverviewYear> years, OverviewLayout layout, OverviewHost host) {
  final extent = layout.yearBlockExtent;
  return [
    for (var i = 0; i < years.length; i++)
      OverviewYearSegment(
        index: i,
        startOffset: i * extent,
        endOffset: (i + 1) * extent,
        bucket: TimeBucket(date: DateTime(years[i].year), assetCount: years[i].assetCount),
        firstAssetIndex: years[i].firstAssetIndex,
        year: years[i],
        layout: layout,
        host: host,
      ),
  ];
}
