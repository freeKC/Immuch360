import 'dart:async';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/constants.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/row.dart';
import 'package:immich_mobile/presentation/widgets/timeline/header.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment_builder.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_drag_region.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/is_motion_video_playing.provider.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/routing/router.dart';

class FixedSegment extends Segment {
  final double tileHeight;
  final int columnCount;
  final double mainAxisExtend;

  const FixedSegment({
    required super.firstIndex,
    required super.lastIndex,
    required super.startOffset,
    required super.endOffset,
    required super.firstAssetIndex,
    required super.bucket,
    required this.tileHeight,
    required this.columnCount,
    required super.headerExtent,
    required super.spacing,
    required super.header,
  }) : assert(tileHeight != 0),
       mainAxisExtend = tileHeight + spacing;

  @override
  double indexToLayoutOffset(int index) {
    final relativeIndex = index - gridIndex;
    return relativeIndex < 0 ? startOffset : gridOffset + (mainAxisExtend * relativeIndex);
  }

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) {
    final adjustedOffset = scrollOffset - gridOffset;
    if (!adjustedOffset.isFinite || adjustedOffset < 0) {
      return firstIndex;
    }
    return gridIndex + (adjustedOffset / mainAxisExtend).floor();
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    final adjustedOffset = scrollOffset - gridOffset;
    if (!adjustedOffset.isFinite || adjustedOffset < 0) {
      return firstIndex;
    }
    return gridIndex + (adjustedOffset / mainAxisExtend).ceil() - 1;
  }

  @override
  Widget builder(BuildContext context, int index) {
    final rowIndexInSegment = index - (firstIndex + 1);
    final assetIndex = rowIndexInSegment * columnCount;
    final assetCount = bucket.assetCount;
    final numberOfAssets = math.min(columnCount, assetCount - assetIndex);

    if (index == firstIndex) {
      return TimelineHeader(bucket: bucket, header: header, height: headerExtent, assetOffset: firstAssetIndex);
    }

    return _FixedSegmentRow(
      assetIndex: firstAssetIndex + assetIndex,
      assetCount: numberOfAssets,
      tileHeight: tileHeight,
      spacing: spacing,
      columnCount: columnCount,
    );
  }
}

/// The size to ask the device for the thumbnail of [asset] in a tile of [tile] physical pixels, in the remote control
/// layout. Android fits the thumbnail inside the size asked, aspect kept, and the tile crops it: a 360° photo (2:1)
/// asked 320 x 320 came 320 x 160 and was stretched to twice that in a TV tile, blurred. A square of the tile's side
/// times the aspect covers the tile whichever way the photo turns, its rotation included. At most 768 px, the largest
/// the device makes as a thumbnail rather than by decoding the whole file.
@visibleForTesting
Size tvThumbnailDecodeSize(BaseAsset asset, Size tile) {
  final width = asset.width;
  final height = asset.height;
  final aspect = width != null && height != null && width > 0 && height > 0 ? width / height : 1.0;
  final side = math.max(tile.width, tile.height) * math.max(aspect, 1 / aspect);
  return Size.square(math.min(side, _maxThumbnailSide).ceilToDouble());
}

const _maxThumbnailSide = 768.0;

class _FixedSegmentRow extends ConsumerWidget {
  final int assetIndex;
  final int assetCount;
  final double tileHeight;
  final double spacing;
  final int columnCount;

  const _FixedSegmentRow({
    required this.assetIndex,
    required this.assetCount,
    required this.tileHeight,
    required this.spacing,
    required this.columnCount,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timelineService = ref.watch(timelineServiceProvider);
    final isDynamicLayout = columnCount <= (context.isMobile ? 2 : 3);

    if (timelineService.hasRange(assetIndex, assetCount)) {
      return _buildAssetRow(
        context,
        timelineService.getAssets(assetIndex, assetCount),
        timelineService,
        isDynamicLayout,
      );
    }

    // Purposefully created outside of the FutureBuilder so it's created only once
    late final assets = timelineService.loadAssets(assetIndex, assetCount);
    return _DeferredRowLoader(
      key: ValueKey(assetIndex),
      placeholder: _buildPlaceholder,
      builder: (context) => FutureBuilder<List<BaseAsset>>(
        future: assets,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _buildPlaceholder(context);
          }
          return _buildAssetRow(context, snapshot.requireData, timelineService, isDynamicLayout);
        },
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    return SegmentBuilder.buildPlaceholder(context, assetCount, size: Size.square(tileHeight), spacing: spacing);
  }

  Widget _buildAssetRow(
    BuildContext context,
    List<BaseAsset> assets,
    TimelineService timelineService,
    bool isDynamicLayout,
  ) {
    final widths = List.filled(assets.length, tileHeight);

    if (isDynamicLayout) {
      final aspectRatios = assets.map((e) => (e.width ?? 1) / (e.height ?? 1)).toList();
      final meanAspectRatio = aspectRatios.sum / assets.length;

      // 1: mean width
      // 0.5: width < mean - threshold
      // 1.5: width > mean + threshold
      final arConfiguration = aspectRatios.map((e) {
        if (e - meanAspectRatio > 0.3) {
          return 1.5;
        }
        if (e - meanAspectRatio < -0.3) {
          return 0.5;
        }
        return 1.0;
      });

      // Normalize to get width distribution
      final sum = arConfiguration.sum;

      int index = 0;
      for (final ratio in arConfiguration) {
        // Distribute the available width proportionally based on aspect ratio configuration
        widths[index++] = ((ratio * assets.length) / sum) * tileHeight;
      }
    }

    final children = [
      for (int i = 0; i < assets.length; i++)
        TimelineAssetIndexWrapper(
          assetIndex: assetIndex + i,
          segmentIndex: 0, // For simplicity, using 0 for now
          child: _AssetTileWidget(
            key: ValueKey(Object.hash(assets[i].heroTag, assetIndex + i, timelineService.hashCode)),
            asset: assets[i],
            assetIndex: assetIndex + i,
            size: Size(widths[i], tileHeight),
          ),
        ),
    ];

    return TimelineDragRegion(
      child: TimelineRow(
        height: tileHeight,
        widths: widths,
        spacing: spacing,
        textDirection: Directionality.of(context),
        children: children,
      ),
    );
  }
}

/// Lock to displaying placeholders while the timeline is quickly scrolling
/// Automatically stops watching the deferred loading flag once the row has started loading, preventing ever rebuilding the view and losing state
class _DeferredRowLoader extends ConsumerStatefulWidget {
  final WidgetBuilder placeholder;
  final WidgetBuilder builder;

  const _DeferredRowLoader({super.key, required this.placeholder, required this.builder});

  @override
  ConsumerState<_DeferredRowLoader> createState() => _DeferredRowLoaderState();
}

class _DeferredRowLoaderState extends ConsumerState<_DeferredRowLoader> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    if (!_isLoading && ref.watch(timelineStateProvider.select((state) => state.recommendDeferredLoading))) {
      return widget.placeholder(context);
    }

    _isLoading = true;
    return widget.builder(context);
  }
}

class _AssetTileWidget extends ConsumerStatefulWidget {
  final BaseAsset asset;
  final int assetIndex;
  final Size size;

  const _AssetTileWidget({super.key, required this.asset, required this.assetIndex, required this.size});

  @override
  ConsumerState<_AssetTileWidget> createState() => _AssetTileWidgetState();
}

class _AssetTileWidgetState extends ConsumerState<_AssetTileWidget> {
  final _focusNode = FocusNode(debugLabel: 'Timeline tile');

  /// A route covered the timeline while this tile showed the asset of the viewer
  bool _coveredWhileCurrent = false;

  BaseAsset get asset => widget.asset;
  int get assetIndex => widget.assetIndex;
  Size get size => widget.size;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// Remote control layout: back from the viewer, the tile of the asset shown last takes the focus, not the tile the
  /// viewer was opened from (the user may have moved to other assets meanwhile). Only a tile that is built can.
  void _focusWhenBackFromViewer(BuildContext context) {
    final routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (!routeIsCurrent) {
      _coveredWhileCurrent = true;
      return;
    }
    if (!_coveredWhileCurrent) {
      return;
    }
    _coveredWhileCurrent = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _focusNode.requestFocus();
      unawaited(Scrollable.ensureVisible(this.context, alignment: 0.5, duration: const Duration(milliseconds: 200)));
    });
  }

  Future _handleOnTap(
    BuildContext ctx,
    WidgetRef ref,
    int assetIndex,
    BaseAsset asset,
    int? heroOffset,
    Size remoteSize,
  ) async {
    final multiSelectState = ref.read(multiSelectProvider);

    if (multiSelectState.forceEnable || multiSelectState.isEnabled) {
      ref.read(multiSelectProvider.notifier).toggleAssetSelection(asset);
    } else {
      await ref.read(timelineServiceProvider).loadAssets(assetIndex, 1);
      if (!ctx.mounted) {
        return;
      }

      ref.read(isPlayingMotionVideoProvider.notifier).playing = false;
      AssetViewer.setAsset(ref, asset, thumbnailSize: remoteSize);
      unawaited(
        ctx.pushRoute(
          AssetViewerRoute(
            initialIndex: assetIndex,
            timelineService: ref.read(timelineServiceProvider),
            heroOffset: heroOffset,
            currentAlbum: ref.read(currentRemoteAlbumProvider),
          ),
        ),
      );
    }
  }

  void _handleOnLongPress(WidgetRef ref, BaseAsset asset) {
    final multiSelectState = ref.read(multiSelectProvider);
    if (multiSelectState.isEnabled || multiSelectState.forceEnable) {
      return;
    }

    ref.read(hapticFeedbackProvider.notifier).heavyImpact();
    ref.read(multiSelectProvider.notifier).toggleAssetSelection(asset);
  }

  bool _getLockSelectionStatus(WidgetRef ref) {
    final lockSelectionAssets = ref.read(multiSelectProvider.select((state) => state.lockedSelectionAssets));

    if (lockSelectionAssets.isEmpty) {
      return false;
    }

    // Iterate with `==` instead of `Set.contains` because `RemoteAsset.hashCode`
    // includes `localId` while `==` does not — so the same server asset can
    // hash to a different bucket when its `localId` differs (e.g., album-fetched
    // copy has localId=null, merged-timeline copy has it populated).
    return lockSelectionAssets.any((a) => a == asset);
  }

  @override
  Widget build(BuildContext context) {
    final remoteSize = size * MediaQuery.devicePixelRatioOf(context);
    final tvMode = ref.watch(tvModeProvider);

    final heroOffset = TabsRouterScope.of(context)?.controller.activeIndex ?? 0;

    final lockSelection = _getLockSelectionStatus(ref);
    final showStorageIndicator = ref.watch(timelineArgsProvider.select((args) => args.showStorageIndicator));
    final askFocus =
        tvMode && assetIndex == 0 && ref.watch(timelineArgsProvider.select((args) => args.tvFocusFirstAsset));
    // The read only mode, or a TV: no selection (a long press has no equivalent on a remote anyway)
    final isViewOnly = ref.watch(viewOnlyProvider);
    final showStackIndicator = ref.watch(timelineServiceProvider).origin != TimelineOrigin.trash;
    if (tvMode && ref.watch(assetViewerProvider.select((state) => state.currentAsset == asset))) {
      _focusWhenBackFromViewer(context);
    }

    return RepaintBoundary(
      // The remote of a TV reaches the tile: the arrows focus it, OK opens it
      child: RemoteFocusable(
        focusNode: _focusNode,
        autofocus: askFocus,
        onTap: () => lockSelection ? null : _handleOnTap(context, ref, assetIndex, asset, heroOffset, remoteSize),
        onLongPress: () => lockSelection || isViewOnly ? null : _handleOnLongPress(ref, asset),
        child: ThumbnailTile(
          asset,
          // The device thumbnails of a phone are 320 px; the tiles of a TV are larger on its screen
          size: tvMode ? tvThumbnailDecodeSize(asset, remoteSize) : kThumbnailResolution,
          remoteSize: remoteSize,
          lockSelection: lockSelection,
          showStorageIndicator: showStorageIndicator,
          showStackIndicator: showStackIndicator,
          heroOffset: heroOffset,
        ),
      ),
    );
  }
}
