// The blocks of the months and the years. A month: its name with the year and its count, then the first K thumbnails
// of the month in the order of the timeline. A year: the year and its count, then its twelve months in calendar order,
// each with its first asset, its short name and a tint for its count; a month without assets is greyed and does
// nothing. A tap on a month or a cell opens the grid at that month, a tap on the header of a year at that year.
//
// The thumbnails are bare (no selection, no badges): the same picture of the server as the grid, decoded at the size
// of the cell, and the thumbnail of the device asked smaller than the grid's.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_asset_loader.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_layout.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/timeline_anchor.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:intl/intl.dart' hide TextDirection;

/// The thumbnails of the device are asked at this size in the months and the years (320 on the grid): the cells are
/// about 63 dp, 190 px on a phone at 3x
const kOverviewDeviceThumbnailSide = 192.0;

/// What the blocks need from the timeline: where their thumbnails come from, and the way back to the grid
class OverviewHost {
  const OverviewHost({required this.loader, required this.onOpen});

  final OverviewAssetLoader loader;

  /// Opens the grid at a month or a year
  final ValueChanged<TimelineAnchor> onOpen;
}

/// The name of a month with its year, as the headers of the grid write it: "October 2024"
String overviewMonthTitle(DateTime date) => toBeginningOfSentenceCase(DateFormat.yMMMM().format(date));

/// One month of the timeline
class OverviewMonthBlock extends StatelessWidget {
  const OverviewMonthBlock({super.key, required this.month, required this.layout, required this.host});

  final OverviewMonth month;
  final OverviewLayout layout;
  final OverviewHost host;

  @override
  Widget build(BuildContext context) {
    final title = overviewMonthTitle(month.date);
    final count = context.t.items_count(count: month.assetCount);
    final shown = month.assetCount < layout.monthTiles ? month.assetCount : layout.monthTiles;
    final side = layout.monthTileSide;
    return SizedBox(
      height: layout.monthBlockExtent,
      // The tap goes on the node too: excludeSemantics leaves out that of the InkWell, and a screen reader's with it
      child: Semantics(
        button: true,
        label: '$title, $count',
        onTap: () => host.onOpen(MonthAnchor(month.year, month.month)),
        excludeSemantics: true,
        child: InkWell(
          onTap: () => host.onOpen(MonthAnchor(month.year, month.month)),
          child: Padding(
            padding: const EdgeInsets.only(
              left: kOverviewSidePadding,
              right: kOverviewSidePadding,
              bottom: kOverviewBlockGap,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: kOverviewHeaderExtent,
                  child: _BlockHeader(title: title, count: count, style: context.textTheme.titleMedium),
                ),
                SizedBox(
                  height: side,
                  child: OverviewAssets(
                    loader: host.loader,
                    index: month.firstAssetIndex,
                    count: shown,
                    builder: (context, assets) => Row(
                      children: [
                        for (var i = 0; i < shown; i++)
                          Padding(
                            padding: EdgeInsetsDirectional.only(start: i == 0 ? 0 : kOverviewSpacing),
                            child: SizedBox.square(
                              dimension: side,
                              child: ClipRRect(
                                borderRadius: const BorderRadius.all(Radius.circular(4)),
                                child: assets != null && i < assets.length
                                    ? OverviewThumbnail(asset: assets[i], side: side)
                                    : ColoredBox(color: context.colorScheme.surfaceContainerHighest),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One year of the timeline
class OverviewYearBlock extends StatelessWidget {
  const OverviewYearBlock({super.key, required this.year, required this.layout, required this.host});

  final OverviewYear year;
  final OverviewLayout layout;
  final OverviewHost host;

  @override
  Widget build(BuildContext context) {
    final count = context.t.items_count(count: year.assetCount);
    final largest = year.largestMonthCount;
    final columns = layout.yearColumns;
    return SizedBox(
      height: layout.yearBlockExtent,
      child: Padding(
        padding: const EdgeInsets.only(
          left: kOverviewSidePadding,
          right: kOverviewSidePadding,
          bottom: kOverviewBlockGap,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: kOverviewHeaderExtent,
              child: Semantics(
                button: true,
                label: '${year.year}, $count',
                onTap: () => host.onOpen(YearAnchor(year.year)),
                excludeSemantics: true,
                child: InkWell(
                  onTap: () => host.onOpen(YearAnchor(year.year)),
                  child: _BlockHeader(title: '${year.year}', count: count, style: context.textTheme.headlineSmall),
                ),
              ),
            ),
            for (var row = 0; row < layout.yearRows; row++)
              Padding(
                padding: EdgeInsets.only(top: row == 0 ? 0 : kOverviewSpacing),
                child: Row(
                  children: [
                    for (var column = 0; column < columns; column++)
                      Padding(
                        padding: EdgeInsetsDirectional.only(start: column == 0 ? 0 : kOverviewSpacing),
                        child: OverviewYearCell(
                          year: year.year,
                          month: row * columns + column + 1,
                          content: year.months[row * columns + column],
                          largest: largest,
                          side: layout.yearCellSide,
                          host: host,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A month in the block of its year
class OverviewYearCell extends StatelessWidget {
  const OverviewYearCell({
    super.key,
    required this.year,
    required this.month,
    required this.content,
    required this.largest,
    required this.side,
    required this.host,
  });

  final int year;

  /// 1 for January
  final int month;

  /// Null for a month without assets
  final OverviewMonth? content;

  /// The assets of the fullest month of the year
  final int largest;

  final double side;
  final OverviewHost host;

  @override
  Widget build(BuildContext context) {
    final date = DateTime(year, month);
    final name = DateFormat.MMM().format(date);
    final colors = context.colorScheme;
    final content = this.content;
    if (content == null) {
      return SizedBox.square(
        dimension: side,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
            borderRadius: const BorderRadius.all(Radius.circular(6)),
          ),
          child: Center(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: context.textTheme.labelSmall?.copyWith(color: colors.onSurface.withValues(alpha: 0.38)),
            ),
          ),
        ),
      );
    }
    final share = largest <= 0 ? 0.0 : content.assetCount / largest;
    return Semantics(
      button: true,
      label: '${overviewMonthTitle(date)}, ${context.t.items_count(count: content.assetCount)}',
      onTap: () => host.onOpen(MonthAnchor(year, month)),
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => host.onOpen(MonthAnchor(year, month)),
        child: SizedBox.square(
          dimension: side,
          child: ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(6)),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // The tint of the count, seen until the cover comes
                ColoredBox(color: colors.primary.withValues(alpha: 0.12 + 0.5 * share)),
                OverviewAssets(
                  loader: host.loader,
                  index: content.firstAssetIndex,
                  count: 1,
                  builder: (context, assets) => assets == null || assets.isEmpty
                      ? const SizedBox.shrink()
                      : OverviewThumbnail(asset: assets.first, side: side),
                ),
                const Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    height: 22,
                    width: double.infinity,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00000000), Color(0x99000000)],
                        ),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 3, left: 2, right: 2),
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: context.textTheme.labelSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BlockHeader extends StatelessWidget {
  const _BlockHeader({required this.title, required this.count, required this.style});

  final String title;
  final String count;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
        ),
        const SizedBox(width: 8),
        Text(
          count,
          maxLines: 1,
          style: context.textTheme.labelMedium?.copyWith(color: context.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// A bare thumbnail of a block, [side] dp square
class OverviewThumbnail extends StatelessWidget {
  const OverviewThumbnail({super.key, required this.asset, required this.side});

  final BaseAsset asset;
  final double side;

  @override
  Widget build(BuildContext context) {
    final physical = (side * MediaQuery.devicePixelRatioOf(context)).ceilToDouble();
    return Thumbnail.fromAsset(
      asset: asset,
      size: const Size.square(kOverviewDeviceThumbnailSide),
      remoteSize: Size.square(physical),
    );
  }
}

/// Builds with the [count] assets of the timeline from [index] once [loader] has them, null until then; when the
/// buckets change, the previous ones until the new ones come (a sync adds photos often). Nothing is asked while the
/// timeline scrolls fast; a block that leaves the screen drops its request.
class OverviewAssets extends ConsumerStatefulWidget {
  const OverviewAssets({
    super.key,
    required this.loader,
    required this.index,
    required this.count,
    required this.builder,
  });

  final OverviewAssetLoader loader;
  final int index;
  final int count;
  final Widget Function(BuildContext context, List<BaseAsset>? assets) builder;

  @override
  ConsumerState<OverviewAssets> createState() => _OverviewAssetsState();
}

class _OverviewAssetsState extends ConsumerState<OverviewAssets> {
  /// The assets shown, maybe of a previous read while a new one is under way
  List<BaseAsset>? _assets;

  /// Whether [_assets] are those of the current range and buckets
  bool _fresh = false;

  OverviewAssetRequest? _request;
  int? _generation;

  @override
  void didUpdateWidget(covariant OverviewAssets oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loader != widget.loader) {
      _stale();
      _assets = null;
    } else if (oldWidget.index != widget.index || oldWidget.count != widget.count) {
      // The same month whose assets moved (a photo added above it, or to it): its pictures stay until the new ones come
      _stale();
    }
  }

  @override
  void dispose() {
    _request?.cancel();
    super.dispose();
  }

  void _stale() {
    _request?.cancel();
    _request = null;
    _fresh = false;
  }

  void _onLoaded(List<BaseAsset> assets) {
    if (mounted) {
      setState(() {
        _assets = assets;
        _fresh = true;
        _request = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loader = widget.loader;
    if (_generation != loader.generation) {
      // The buckets changed since: the indexes may point at other assets, read again
      _stale();
      _generation = loader.generation;
    }
    if (!_fresh) {
      final cached = widget.count <= 0 ? const <BaseAsset>[] : loader.cached(widget.index, widget.count);
      if (cached != null) {
        _assets = cached;
        _fresh = true;
      }
    }
    if (!_fresh &&
        _request == null &&
        !ref.watch(timelineStateProvider.select((state) => state.recommendDeferredLoading))) {
      _request = loader.request(widget.index, widget.count, _onLoaded);
    }
    return widget.builder(context, _assets);
  }
}
