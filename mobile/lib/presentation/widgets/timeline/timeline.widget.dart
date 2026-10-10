import 'dart:async';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/asyncvalue_extensions.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/download_status_floating_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/general_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/constants.dart';
import 'package:immich_mobile/presentation/widgets/timeline/multi_select_status_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/scrubber.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/sliver_segmented_list.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_drag_selection.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_pinch_zoom.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/routing/app_navigation_observer.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/debounce.dart';
import 'package:immich_mobile/widgets/common/immich_sliver_app_bar.dart';
import 'package:immich_mobile/widgets/common/mesmerizing_sliver_app_bar.dart';
import 'package:immich_mobile/widgets/common/selection_sliver_app_bar.dart';

class Timeline extends ConsumerWidget {
  const Timeline({
    super.key,
    this.topSliverWidget,
    this.topSliverWidgetHeight,
    this.bottomSliverWidget,
    this.showStorageIndicator = false,
    this.withStack = false,
    this.appBar = const ImmichSliverAppBar(floating: true, pinned: false, snap: false),
    this.bottomSheet = const GeneralBottomSheet(minChildSize: 0.23),
    this.groupBy,
    this.withScrubber = true,
    this.snapToMonth = true,
    this.readOnly = false,
    this.persistentBottomBar = false,
    this.loadingWidget,
    this.tvFocusFirstAsset = false,
  });

  final Widget? topSliverWidget;
  final double? topSliverWidgetHeight;
  final Widget? bottomSliverWidget;
  final bool showStorageIndicator;
  final Widget? appBar;
  final Widget? bottomSheet;
  final bool withStack;
  final GroupAssetsBy? groupBy;
  final bool withScrubber;
  final bool snapToMonth;
  final bool readOnly;
  final bool persistentBottomBar;
  final Widget? loadingWidget;

  /// The remote control layout: the first tile asks for the focus, so that a page arrives on its first photo rather
  /// than on a chip of a bar above the grid (the 360° list)
  final bool tvFocusFirstAsset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tilesPerRow = ref.watch(appConfigProvider.select((config) => config.timeline.tilesPerRow));
    final tvMode = ref.watch(tvModeProvider);
    final timeline = LayoutBuilder(
      builder: (_, constraints) {
        final columnCount = tvMode ? tvTimelineColumnCount(constraints.maxWidth, tilesPerRow) : tilesPerRow;
        return ProviderScope(
          overrides: [
            // overrideWithValue keeps the scoped args in sync with the latest constraints on rebuilds,
            // a function override would stay locked to the first frame's constraints for the whole session
            timelineArgsProvider.overrideWithValue(
              TimelineArgs(
                maxWidth: constraints.maxWidth,
                maxHeight: constraints.maxHeight,
                columnCount: columnCount,
                showStorageIndicator: showStorageIndicator,
                withStack: withStack,
                groupBy: groupBy,
                tvFocusFirstAsset: tvFocusFirstAsset,
              ),
            ),
            if (readOnly) readonlyModeProvider.overrideWith(() => _AlwaysReadOnlyNotifier()),
          ],
          child: _SliverTimeline(
            topSliverWidget: topSliverWidget,
            topSliverWidgetHeight: topSliverWidgetHeight,
            bottomSliverWidget: bottomSliverWidget,
            appBar: appBar,
            bottomSheet: bottomSheet,
            withScrubber: withScrubber,
            persistentBottomBar: persistentBottomBar,
            snapToMonth: snapToMonth,
            maxWidth: constraints.maxWidth,
            loadingWidget: loadingWidget,
          ),
        );
      },
    );
    if (!tvMode) {
      return timeline;
    }
    // The overscan margins of the TV shell on the sides too: the tiles of the grid ran to the edges of the screen,
    // which a TV may cut. The bars inside get the margins from here rather than from the padding.
    final padding = MediaQuery.paddingOf(context);
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Padding(
        padding: EdgeInsets.only(left: padding.left, right: padding.right),
        child: MediaQuery.removePadding(context: context, removeLeft: true, removeRight: true, child: timeline),
      ),
    );
  }
}

/// The tiles per row of a timeline in the remote control layout: the setting (4 by default) is meant for a phone held
/// upright, and gave tiles of 240 dp on a TV of 960 x 540 dp, half the height of the screen, a single row cut by its
/// bottom. Tiles of at most [kTvTimelineTileExtent] dp instead, or more per row when the setting asks for more.
@visibleForTesting
int tvTimelineColumnCount(double width, int tilesPerRow) =>
    width <= 0 ? tilesPerRow : math.max(tilesPerRow, (width / kTvTimelineTileExtent).ceil());

/// The widest tile of a timeline on a TV, in dp: six per row on a 1080p TV, two whole rows under the headers
const kTvTimelineTileExtent = 160.0;

/// How far the focus ring of a TV reaches out of the focused tile, its dark outline included
const kTvFocusRingReach = TvFocusRing.gap + TvFocusRing.strokeWidth + 1;

/// The margin a timeline keeps at the bottom of a TV: the bottom padding, never less than the overscan margin of the
/// TV shell. The Scaffold of the tab shell takes the bottom padding away from the tabs for its bottom bar, which is
/// empty in landscape: the Photos tab saw none, and its focused row stopped flush with the bottom of the screen.
double _tvBottomMargin(BuildContext context) => math.max(MediaQuery.paddingOf(context).bottom, TvShell.overscan.bottom);

class _AlwaysReadOnlyNotifier extends ReadOnlyModeNotifier {
  @override
  bool build() => true;

  @override
  void setReadonlyMode(bool value) {}

  @override
  void toggleReadonlyMode() {}
}

class _SliverTimeline extends ConsumerStatefulWidget {
  const _SliverTimeline({
    this.topSliverWidget,
    this.topSliverWidgetHeight,
    this.bottomSliverWidget,
    this.appBar,
    this.bottomSheet,
    this.withScrubber = true,
    this.persistentBottomBar = false,
    this.snapToMonth = true,
    this.maxWidth,
    this.loadingWidget,
  });

  final Widget? topSliverWidget;
  final double? topSliverWidgetHeight;
  final Widget? bottomSliverWidget;
  final Widget? appBar;
  final Widget? bottomSheet;
  final bool withScrubber;
  final bool persistentBottomBar;
  final bool snapToMonth;
  final double? maxWidth;
  final Widget? loadingWidget;

  @override
  ConsumerState createState() => _SliverTimelineState();
}

class _SliverTimelineState extends ConsumerState<_SliverTimeline> with WidgetsBindingObserver {
  late final ScrollController _scrollController;
  StreamSubscription? _eventSubscription;

  int? _restoreAssetIndex;

  final Debouncer _fastScrollDebouncer = Debouncer(interval: const Duration(milliseconds: 100));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController = ScrollController(onAttach: _restoreAssetPosition);
    _eventSubscription = EventStream.shared.listen(_onEvent);
    FocusManager.instance.addListener(_keepFocusInsideTvMargins);

    ref.listenManual(multiSelectProvider.select((s) => s.isEnabled), _onMultiSelectionToggled);
  }

  @override
  void didUpdateWidget(covariant _SliverTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.maxWidth != oldWidget.maxWidth) {
      // The updated args already regenerate the segments, only remember the scroll position to restore it afterwards
      final segments = ref.read(timelineSegmentProvider).valueOrNull;
      if (segments != null && _scrollController.hasClients) {
        _restoreAssetIndex = _getCurrentAssetIndex(segments);
      }
    }
  }

  // Capture iOS status bar tap
  @override
  void handleStatusBarTap() {
    // Routes may be pushed non-opaquely on top of the timeline (such as the asset viewer), or the timeline
    // may be in a background tab. In either case, `handleStatusBarTap()` still fires
    // Make sure the timeline is the primary route before scrolling to the top
    final routeData = context.findAncestorWidgetOfExactType<RouteDataScope>()?.routeData;
    // The tap is generated async, so it can arrive after a route pop has started (due to a back button or similar)
    // Check if route is alive and not exiting before taking action
    final observers = Navigator.maybeOf(context)?.widget.observers ?? const <NavigatorObserver>[];
    final isRouteTransitioning = observers.whereType<TransitioningRouteObserver>().any(
      (observer) => observer.hasTransitioningRoute,
    );

    if (ModalRoute.of(context)?.isCurrent == true && routeData?.isActive == true && !isRouteTransitioning) {
      _scrollToTop();
    }
  }

  void _onEvent(Event event) {
    switch (event) {
      case ScrollToTopEvent():
        _scrollToTop();
      case final ScrollToDateEvent scrollToDateEvent:
        _scrollToDate(scrollToDateEvent.date);
      case TimelineReloadEvent():
        setState(() {});
      default:
        break;
    }
  }

  void _restoreAssetPosition(_) {
    if (_restoreAssetIndex == null) {
      return;
    }

    final asyncSegments = ref.read(timelineSegmentProvider);
    asyncSegments.whenData((segments) {
      final targetSegment = segments.lastWhereOrNull((segment) => segment.firstAssetIndex <= _restoreAssetIndex!);
      if (targetSegment != null) {
        final assetIndexInSegment = _restoreAssetIndex! - targetSegment.firstAssetIndex;
        final newColumnCount = ref.read(timelineArgsProvider).columnCount;
        final rowIndexInSegment = (assetIndexInSegment / newColumnCount).floor();
        final targetRowIndex = targetSegment.firstIndex + 1 + rowIndexInSegment;
        final targetOffset = targetSegment.indexToLayoutOffset(targetRowIndex);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _scrollController.jumpTo(targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent));
          }
        });
      }
    });
    _restoreAssetIndex = null;
  }

  void _onMultiSelectionToggled(_, bool isEnabled) {
    EventStream.shared.emit(MultiSelectToggleEvent(isEnabled));
  }

  int? _getCurrentAssetIndex(List<Segment> segments) {
    final currentOffset = _scrollController.offset.clamp(0.0, _scrollController.position.maxScrollExtent);
    final segment = segments.findByOffset(currentOffset) ?? segments.lastOrNull;
    int? targetAssetIndex;
    if (segment != null) {
      final rowIndex = segment.getMinChildIndexForScrollOffset(currentOffset);
      if (rowIndex > segment.firstIndex) {
        final rowIndexInSegment = rowIndex - (segment.firstIndex + 1);
        final assetsPerRow = ref.read(timelineArgsProvider).columnCount;
        final assetIndexInSegment = rowIndexInSegment * assetsPerRow;
        targetAssetIndex = segment.firstAssetIndex + assetIndexInSegment;
      } else {
        targetAssetIndex = segment.firstAssetIndex;
      }
    }
    return targetAssetIndex;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_keepFocusInsideTvMargins);
    _fastScrollDebouncer.dispose();
    _scrollController.dispose();
    unawaited(_eventSubscription?.cancel());
    super.dispose();
  }

  /// The remote control layout: the item of the grid that has the focus, a tile most of all, stays with its ring
  /// inside the overscan margins of the TV. The arrows scroll it just into view, flush with the bottom of the screen
  /// (or with the bar going up), where a TV may cut it and the ring was cut. Called once the focus moved, after that
  /// first scroll and before the frame; a scroll in an animation (back from a viewer, the tile centred) is left alone.
  void _keepFocusInsideTvMargins() {
    if (!mounted || _scrollController.positions.length != 1 || !ref.read(tvModeProvider)) {
      return;
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null || !focused.mounted || !_scrollsWithGrid(focused)) {
      return;
    }
    final position = _scrollController.position;
    final object = focused.findRenderObject();
    if (position.isScrollingNotifier.value || object is! RenderBox || !object.attached || !object.hasSize) {
      return;
    }
    final padding = MediaQuery.paddingOf(context);
    object.showOnScreen(
      rect: Rect.fromLTRB(
        0,
        -padding.top - kTvFocusRingReach,
        object.size.width,
        object.size.height + _tvBottomMargin(context) + kTvFocusRingReach,
      ),
    );
  }

  /// The arrows of a remote on the items of the grid, the TV only. Up from an item of the content goes to the nearest
  /// item above it that scrolls with the grid, the row above first: Flutter takes the item whose middle is the
  /// nearest, and the Back button of the pinned bar won over the chips or the row above once they had scrolled under
  /// the bar. The bar comes when no item of the content is above. The other arrows as Flutter moves them.
  late final _tvArrows = CallbackAction<DirectionalFocusIntent>(
    onInvoke: (intent) {
      final focused = FocusManager.instance.primaryFocus;
      if (focused != null && (intent.direction != TraversalDirection.up || !_focusUpInGrid(focused))) {
        focused.focusInDirection(intent.direction);
      }
      return null;
    },
  );

  bool _focusUpInGrid(FocusNode focused) {
    final context = focused.context;
    final scope = focused.nearestScope;
    if (context == null || scope == null || !_isContentItem(focused)) {
      return false;
    }
    final from = focused.rect;
    FocusNode? best;
    (bool, double, double)? bestDistance;
    for (final node in scope.traversalDescendants) {
      if (node == focused || !_isContentItem(node)) {
        continue;
      }
      final rect = node.rect;
      if (rect.center.dy > from.top) {
        continue;
      }
      // Above the focused item first, then the nearest row, then the nearest across
      final inBand = rect.right > from.left && rect.left < from.right;
      final across = inBand ? 0.0 : math.max(rect.left - from.right, from.left - rect.right);
      final distance = (!inBand, from.center.dy - rect.center.dy, across);
      if (bestDistance == null || _closer(distance, bestDistance)) {
        best = node;
        bestDistance = distance;
      }
    }
    if (best == null) {
      return false;
    }
    // Flutter's memory of the moves, to come back the way one went, no longer fits
    FocusTraversalGroup.maybeOf(context)?.invalidateScopeData(scope);
    best.requestFocus();
    unawaited(
      Scrollable.ensureVisible(best.context!, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart),
    );
    return true;
  }

  static bool _closer((bool, double, double) a, (bool, double, double) b) {
    if (a.$1 != b.$1) {
      return !a.$1;
    }
    if (a.$2 != b.$2) {
      return a.$2 < b.$2;
    }
    return a.$3 < b.$3;
  }

  /// An item of the content of the grid, laid out, outside its bar
  bool _isContentItem(FocusNode node) {
    final context = node.context;
    final object = context?.findRenderObject();
    return context != null &&
        object is RenderBox &&
        object.attached &&
        object.hasSize &&
        context.findAncestorWidgetOfExactType<AppBar>() == null &&
        _scrollsWithGrid(context);
  }

  /// Whether [context] sits in the grid's scroll view, maybe through a row that scrolls across (the network shares of
  /// the 360° list), rather than in a bar or a dialog over it
  bool _scrollsWithGrid(BuildContext context) {
    final grid = _scrollController.position.context;
    for (
      var scrollable = context.findAncestorStateOfType<ScrollableState>();
      scrollable != null;
      scrollable = scrollable.context.findAncestorStateOfType<ScrollableState>()
    ) {
      if (scrollable == grid) {
        return true;
      }
    }
    return false;
  }

  /// Track whether the timeline is moving fast enough to defer per-row asset loading
  bool _onScrollVelocityNotification(ScrollNotification notification) {
    // Only consider the primary timeline ScrollView (no nested views) and update events
    if (notification.depth != 0 || notification is! ScrollUpdateNotification) {
      return false;
    }

    // Use Flutter's built in fast velocity tracking
    if (_scrollController.position.recommendDeferredLoading(context)) {
      ref.read(timelineStateProvider.notifier).setRecommendDeferredLoading(true);

      // We cannot rely on scroll end events, as the timeline scrubber jumps from position
      // to position, resulting in large spikes in velocity followed by low velocity
      _fastScrollDebouncer.run(() => ref.read(timelineStateProvider.notifier).setRecommendDeferredLoading(false));
    }
    return false;
  }

  void _scrollToTop() {
    if (!_scrollController.hasClients) {
      return;
    }

    _scrollController.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeInOut);
  }

  void _scrollToDate(DateTime date) {
    final asyncSegments = ref.read(timelineSegmentProvider);
    asyncSegments.whenData((segments) {
      // Find the segment that contains assets from the target date
      final targetSegment = segments.firstWhereOrNull((segment) {
        if (segment.bucket is TimeBucket) {
          final segmentDate = (segment.bucket as TimeBucket).date;
          // Check if the segment date matches the target date (year, month, day)
          return segmentDate.year == date.year && segmentDate.month == date.month && segmentDate.day == date.day;
        }
        return false;
      });

      // If exact date not found, try to find the closest month
      final fallbackSegment =
          targetSegment ??
          segments.firstWhereOrNull((segment) {
            if (segment.bucket is TimeBucket) {
              final segmentDate = (segment.bucket as TimeBucket).date;
              return segmentDate.year == date.year && segmentDate.month == date.month;
            }
            return false;
          });

      if (fallbackSegment != null) {
        // Scroll to the segment with a small offset to show the header
        final targetOffset = fallbackSegment.startOffset - 50;
        _scrollController.animateTo(
          targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext _) {
    final asyncSegments = ref.watch(timelineSegmentProvider);
    final maxHeight = ref.watch(timelineArgsProvider.select((args) => args.maxHeight));
    final isSelectionMode = ref.watch(multiSelectProvider.select((s) => s.forceEnable));
    final isMultiSelectEnabled = ref.watch(multiSelectProvider.select((s) => s.isEnabled));
    final isMultiSelectStatusVisible = !isSelectionMode && isMultiSelectEnabled;
    final isBottomWidgetVisible =
        widget.bottomSheet != null && (isMultiSelectStatusVisible || widget.persistentBottomBar);
    final tvMode = ref.watch(tvModeProvider);
    // A TV without a server has no photos of its own: the page says where they are instead of staying empty
    final tvWithoutServer = tvMode && !ref.watch(hasServerProvider);

    return PopScope(
      canPop: !isMultiSelectEnabled,
      onPopInvokedWithResult: (_, _) {
        if (isMultiSelectEnabled) {
          ref.read(multiSelectProvider.notifier).reset();
        }
      },
      child: BackButtonListener(
        onBackButtonPressed: () async {
          if (!isMultiSelectEnabled) {
            return false;
          }
          ref.read(multiSelectProvider.notifier).reset();
          return true;
        },
        child: PrimaryScrollController(
          controller: _scrollController,
          child: Scaffold(
            // This removes the built in Scaffold `handleStatusBarTap` implementation, preventing duplicate
            // events when we provide our own
            primary: false,
            resizeToAvoidBottomInset: false,
            floatingActionButton: const DownloadStatusFloatingButton(),
            body: asyncSegments.widgetWhen(
              onLoading: widget.loadingWidget != null ? () => widget.loadingWidget! : null,
              onData: (segments) {
                final childCount = (segments.lastOrNull?.lastIndex ?? -1) + 1;
                final double appBarExpandedHeight = widget.appBar != null && widget.appBar is MesmerizingSliverAppBar
                    ? 200
                    : 0;
                final topPadding = context.padding.top + (widget.appBar == null ? 0 : kToolbarHeight) + 10;

                const bottomSheetOpenModifier = 120.0;
                // On a TV the last row may stop as far from the bottom as the others (see _keepFocusInsideTvMargins)
                final contentBottomPadding =
                    (tvMode ? _tvBottomMargin(context) + kTvFocusRingReach : context.padding.bottom) +
                    (isMultiSelectEnabled ? bottomSheetOpenModifier : 0);
                final scrubberBottomPadding = contentBottomPadding + kScrubberThumbHeight;

                return TimelinePinchZoom(
                  onColumnCountWillChange: () {
                    final targetAssetIndex = _getCurrentAssetIndex(segments);
                    setState(() {
                      _restoreAssetIndex = targetAssetIndex;
                    });
                  },
                  child: TimelineDragSelection(
                    builder: (physics) {
                      final grid = CustomScrollView(
                        primary: true,
                        physics: physics,
                        scrollCacheExtent: .pixels(maxHeight * 2),
                        slivers: [
                          if (isSelectionMode)
                            const SelectionSliverAppBar()
                          else if (widget.appBar != null)
                            widget.appBar!,
                          if (widget.topSliverWidget != null) widget.topSliverWidget!,
                          SliverSegmentedList(
                            segments: segments,
                            delegate: SliverChildBuilderDelegate(
                              (ctx, index) {
                                if (index >= childCount) {
                                  return null;
                                }
                                final segment = segments.findByIndex(index);
                                return segment?.builder(ctx, index) ?? const SizedBox.shrink();
                              },
                              childCount: childCount,
                              addAutomaticKeepAlives: false,
                              // We add repaint boundary around tiles, so skip the auto boundaries
                              addRepaintBoundaries: false,
                            ),
                          ),
                          if (widget.bottomSliverWidget != null) widget.bottomSliverWidget!,
                          if (tvWithoutServer && childCount == 0)
                            const SliverFillRemaining(hasScrollBody: false, child: _TvEmptyLocalSession()),
                          SliverPadding(padding: EdgeInsets.only(bottom: contentBottomPadding)),
                        ],
                      );

                      final Widget timeline;
                      if (widget.withScrubber) {
                        timeline = Scrubber(
                          snapToMonth: widget.snapToMonth,
                          layoutSegments: segments,
                          timelineHeight: maxHeight,
                          topPadding: topPadding,
                          bottomPadding: scrubberBottomPadding,
                          monthSegmentSnappingOffset: widget.topSliverWidgetHeight ?? 0 + appBarExpandedHeight,
                          hasAppBar: widget.appBar != null,
                          child: grid,
                        );
                      } else {
                        timeline = grid;
                      }

                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          NotificationListener<ScrollNotification>(
                            onNotification: _onScrollVelocityNotification,
                            child: tvMode
                                ? Actions(actions: {DirectionalFocusIntent: _tvArrows}, child: timeline)
                                : timeline,
                          ),
                          if (isBottomWidgetVisible)
                            Positioned(
                              top: MediaQuery.paddingOf(context).top,
                              left: 25,
                              child: const SizedBox(
                                height: kToolbarHeight,
                                child: Center(child: MultiSelectStatusButton()),
                              ),
                            ),
                          if (isBottomWidgetVisible) widget.bottomSheet!,
                        ],
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The empty timeline of a TV without a server: where its photos and videos are, and a way there with the remote
class _TvEmptyLocalSession extends StatelessWidget {
  const _TvEmptyLocalSession();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lan_outlined, size: 48, color: context.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(context.t.tv_local_session_empty, textAlign: TextAlign.center, style: context.textTheme.titleMedium),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              autofocus: true,
              onPressed: () => context.pushRoute(const NetworkSharesRoute()),
              icon: const Icon(Icons.lan_outlined),
              label: Text(context.t.network_shares),
            ),
          ],
        ),
      ),
    );
  }
}
