// The sizes of the months and the years, from the width of the timeline alone, so that every block of a level has the
// same height and the offsets are known before anything is built.
//
// A month: its header, then one row of K tiny thumbnails, K = clamp(floor((width - 22) / (t + 2)), 4, 16) with tiles
// of about t = 56 dp under 600 dp and 72 dp above (a phone of 412 dp: 6 thumbnails of 63 dp, a block of 119 dp, seven
// months on a screen; a tablet of 800 dp: 10; a computer: 16).
// A year: its header, then its twelve months, 6 x 2 under 600 dp and 12 x 1 above, cells of about 61 dp.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// The margin on each side of the blocks
const kOverviewSidePadding = 10.0;

/// The gap between two thumbnails or two cells
const kOverviewSpacing = 2.0;

/// The header of a block: the month or the year and its count
const kOverviewHeaderExtent = 48.0;

/// The gap under a block
const kOverviewBlockGap = 8.0;

/// From this width the thumbnails grow and the years take a single row
const kOverviewWideWidth = 600.0;

/// The size the thumbnails of a month aim at, under and above [kOverviewWideWidth]
const kOverviewTileTarget = 56.0;
const kOverviewWideTileTarget = 72.0;

const kOverviewMinMonthTiles = 4;
const kOverviewMaxMonthTiles = 16;

@immutable
class OverviewLayout {
  const OverviewLayout._({
    required this.width,
    required this.monthTiles,
    required this.monthTileSide,
    required this.yearColumns,
    required this.yearCellSide,
  });

  factory OverviewLayout.forWidth(double width) {
    final available = math.max(0.0, width);
    final wide = available >= kOverviewWideWidth;
    final target = wide ? kOverviewWideTileTarget : kOverviewTileTarget;
    final tiles = ((available - 2 * kOverviewSidePadding - kOverviewSpacing) / (target + kOverviewSpacing))
        .floor()
        .clamp(kOverviewMinMonthTiles, kOverviewMaxMonthTiles);
    final columns = wide ? 12 : 6;
    return OverviewLayout._(
      width: available,
      monthTiles: tiles,
      monthTileSide: _side(available, tiles),
      yearColumns: columns,
      yearCellSide: _side(available, columns),
    );
  }

  /// The side of [count] squares in a row across [width], margins and gaps left out
  static double _side(double width, int count) =>
      math.max(0.0, (width - 2 * kOverviewSidePadding - kOverviewSpacing * (count - 1)) / count);

  final double width;

  /// The thumbnails of a month, K
  final int monthTiles;

  final double monthTileSide;

  /// The cells of a year in a row: 6 or 12
  final int yearColumns;

  final double yearCellSide;

  int get yearRows => 12 ~/ yearColumns;

  double get monthBlockExtent => kOverviewHeaderExtent + monthTileSide + kOverviewBlockGap;

  double get yearBlockExtent =>
      kOverviewHeaderExtent + yearRows * yearCellSide + (yearRows - 1) * kOverviewSpacing + kOverviewBlockGap;

  @override
  bool operator ==(Object other) => other is OverviewLayout && other.width == width;

  @override
  int get hashCode => width.hashCode;
}
