import 'dart:async';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/asyncvalue_extensions.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/download_status_floating_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/general_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/constants.dart';
import 'package:immich_mobile/presentation/widgets/timeline/multi_select_status_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_asset_loader.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_blocks.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_layout.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_level_chip.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_segment.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/timeline_anchor.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/timeline_wheel_zoom.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/timeline_zoom.dart';
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
import 'package:immich_mobile/providers/infrastructure/timeline_overview.provider.dart';
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

/// What a change of level or of tiles per row brings back to the top: [anchor], measured from the top of the list once
/// the band above it has scrolled away ([belowBand]), or from the top of the scroll view as before
typedef _TopAnchor = ({TimelineAnchor anchor, bool belowBand});

/// The tiles per row of a timeline in the remote control layout: the setting (4 by default) is meant for a phone held
/// upright, and gave tiles of 240 dp on a TV of 960 x 540 dp, half the height of the screen, a single row cut by its
/// bottom. Tiles of at most [kTvTimelineTileExtent] dp instead, or more per row when the setting asks for more.
@visibleForTesting
int tvTimelineColumnCount(double width, int tilesPerRow) =>
    width <= 0 ? tilesPerRow : math.max(tilesPerRow, (width / kTvTimelineTileExtent).ceil());

/// The widest tile of a timeline on a TV, in dp: six per row on a 1080p TV, two whole rows under the headers
const kTvTimelineTileExtent = 160.0;

/// How far the focus ring of a TV reaches out of the focused tile, its dark outline included
const kTvFocusRingReach = TvFocusRing.reach;

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

/// How often a held arrow moves the focus in the grid of a TV: 10 rows a second, see _SliverTimelineState
@visibleForTesting
const tvHeldArrowInterval = Duration(milliseconds: 100);

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

  /// What stays in place once the segments reload (other tiles per row, another width): the scroll view comes back and
  /// its position attaches, see [_restoreAnchor]
  _TopAnchor? _pendingAnchor;

  /// The band between the bar and the list (the memories of the Photos tab), see [_topSliverExtent]
  final _topSliverKey = GlobalKey();

  /// The grid that a tap or Back brings back from the months and the years (overview/timeline_zoom.dart)
  final _climb = TimelineZoomClimb();

  /// The months or the years: a state of the page, never saved (overview/timeline_zoom.dart)
  TimelineZoomLevel _level = TimelineZoomLevel.grid;

  /// The level and the segments on screen, those of the last build
  TimelineZoomLevel _shownLevel = TimelineZoomLevel.grid;
  List<Segment> _shownSegments = const [];

  /// Ctrl (Command on Apple systems) held: the mouse wheel zooms instead of scrolling
  late final TimelineZoomModifier _zoomModifier;

  // The months and the years of the grid's segments, built again when the buckets or the width change
  List<Segment>? _datesCheckedFor;
  bool _segmentsHaveDates = false;
  List<Segment>? _overviewSource;
  double? _overviewWidth;
  List<OverviewMonth> _overviewMonths = const [];
  int _overviewTotal = 0;
  List<Segment>? _monthSegments;
  List<Segment>? _yearSegments;
  OverviewAssetLoader? _overviewLoader;
  Object? _overviewLoaderService;

  final Debouncer _fastScrollDebouncer = Debouncer(interval: const Duration(milliseconds: 100));

  /// Runs for [tvHeldArrowInterval] after an arrow moved the focus in the grid of a TV, see [_throttleHeldArrows]
  Timer? _heldArrowCooldown;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController = ScrollController(onAttach: _restoreAnchor);
    _zoomModifier = TimelineZoomModifier()..addListener(_onZoomModifierChanged);
    _eventSubscription = EventStream.shared.listen(_onEvent);
    FocusManager.instance.addListener(_keepFocusInsideTvMargins);

    ref.listenManual(multiSelectProvider.select((s) => s.isEnabled), _onMultiSelectionToggled);
  }

  @override
  void didUpdateWidget(covariant _SliverTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.maxWidth != oldWidget.maxWidth) {
      // The updated args already regenerate the segments, only remember the scroll position to restore it afterwards
      if (_shownSegments.isNotEmpty && _scrollController.hasClients) {
        _pendingAnchor = _anchorAtTop(to: _shownLevel);
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
        // The service reloaded its buffer, which the months and the years may have read while it held the assets of
        // the buckets before: they read again, keeping their pictures until then
        _overviewLoader?.clear();
        setState(() {});
      default:
        break;
    }
  }

  /// The scroll view came back after a reload of the segments: what was at the top goes back there
  void _restoreAnchor(ScrollPosition _) {
    final anchor = _pendingAnchor;
    if (anchor == null) {
      return;
    }
    _pendingAnchor = null;
    _jumpToAnchorAfterFrame(anchor);
  }

  /// Brings [target] to the top once the frame shows the segments of the level it is meant for
  void _jumpToAnchorAfterFrame(_TopAnchor target) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      final offset = anchorOffset(
        target.anchor,
        _shownSegments,
        level: _shownLevel,
        columnCount: ref.read(timelineArgsProvider).columnCount,
      );
      if (offset != null) {
        final band = target.belowBand ? _topSliverExtent() : 0.0;
        _scrollController.jumpTo((offset + band).clamp(0.0, _scrollController.position.maxScrollExtent));
      }
    });
  }

  /// What is at the top of the screen now, to keep there on the level [to]. Once the band above the list has scrolled
  /// away, the top of the screen is that much less far into the list than the scroll offset.
  _TopAnchor? _anchorAtTop({required TimelineZoomLevel to}) {
    if (!_scrollController.hasClients) {
      return null;
    }
    final offset = _scrollController.offset.clamp(0.0, _scrollController.position.maxScrollExtent);
    final band = _topSliverExtent();
    final belowBand = band > 0 && offset >= band;
    final anchor = anchorAtOffset(
      _shownSegments,
      belowBand ? offset - band : offset,
      from: _shownLevel,
      to: to,
      columnCount: ref.read(timelineArgsProvider).columnCount,
    );
    return anchor == null ? null : (anchor: anchor, belowBand: belowBand);
  }

  /// The scroll extent of the band between the bar and the list, 0 without one
  double _topSliverExtent() {
    final band = _topSliverKey.currentContext?.findRenderObject();
    return band is RenderSliver ? band.geometry?.scrollExtent ?? 0 : 0;
  }

  static TimelineZoom _zoomOf(TimelineZoomLevel level, int tilesPerRow) => switch (level) {
    TimelineZoomLevel.grid => TimelineZoom.grid(tilesPerRow),
    TimelineZoomLevel.months => const TimelineZoom.months(),
    TimelineZoomLevel.years => const TimelineZoom.years(),
  };

  /// Moves the timeline to [next] on its zoom ladder (a pinch, the wheel, a tap, Back), keeping in place what was at
  /// the top, or bringing [anchor] (the month or the year tapped) to the top, under the bar. Other tiles per row are
  /// the setting, as they always were: its write reloads the segments. The months and the years change nothing else,
  /// so a pinch goes on.
  void _changeZoom(TimelineZoom next, {TimelineAnchor? anchor}) {
    if (!mounted) {
      return;
    }
    final tilesPerRow = ref.read(appConfigProvider).timeline.tilesPerRow;
    final current = _zoomOf(_shownLevel, tilesPerRow);
    if (next == current) {
      return;
    }
    _climb.note(current, next, DateTime.now());
    final target = anchor != null ? (anchor: anchor, belowBand: true) : _anchorAtTop(to: next.level);
    if (next.level == TimelineZoomLevel.grid && next.columns != tilesPerRow) {
      setState(() {
        _level = TimelineZoomLevel.grid;
        _pendingAnchor = target;
      });
      unawaited(ref.read(settingsProvider).write(.timelineTilesPerRow, next.columns));
      return;
    }
    setState(() => _level = next.level);
    if (target != null) {
      _jumpToAnchorAfterFrame(target);
    }
  }

  /// A tap on a month or a year: the grid there, at the tiles per row it had before the climb to the months
  void _openGridAt(TimelineAnchor anchor) => _changeZoom(_gridToComeBack(), anchor: anchor);

  /// Back in the months or the years: the grid, at the month or the year at the top, rather than leaving the page
  void _backToGrid() => _changeZoom(_gridToComeBack());

  TimelineZoom _gridToComeBack() =>
      TimelineZoom.grid(_climb.gridBefore ?? ref.read(appConfigProvider).timeline.tilesPerRow);

  void _onZoomModifierChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// The screens built above and below the one shown, see the scroll view in [build]
  static double _cacheScreens({required bool tvMode, required TimelineZoomLevel level}) {
    if (tvMode) {
      return 1;
    }
    return level == TimelineZoomLevel.grid ? 2 : 0.5;
  }

  /// Whether every segment of the grid has a date, checked once per list
  bool _hasDates(List<Segment> segments) {
    if (!identical(segments, _datesCheckedFor)) {
      _datesCheckedFor = segments;
      _segmentsHaveDates = bucketsHaveDates(segments.map((segment) => segment.bucket));
    }
    return _segmentsHaveDates;
  }

  /// The segments of [level]: the grid's as they are, or its months or years, built once per list and width
  List<Segment> _segmentsOf(TimelineZoomLevel level, List<Segment> grid, double width) {
    if (level == TimelineZoomLevel.grid) {
      return grid;
    }
    final service = ref.read(timelineServiceProvider);
    if (!identical(service, _overviewLoaderService)) {
      _overviewLoader?.dispose();
      _overviewLoader = _newOverviewLoader(service);
      _overviewLoaderService = service;
      _overviewSource = null;
    }
    final loader = _overviewLoader!;
    if (!identical(grid, _overviewSource) || width != _overviewWidth) {
      if (!identical(grid, _overviewSource)) {
        // The buckets changed: an index may point at another asset
        loader.clear();
      }
      _overviewSource = grid;
      _overviewWidth = width;
      _overviewMonths = overviewMonths(grid.map((segment) => segment.bucket));
      _overviewTotal = _overviewMonths.fold(0, (total, month) => total + month.assetCount);
      _monthSegments = null;
      _yearSegments = null;
    }
    final layout = OverviewLayout.forWidth(width);
    final host = OverviewHost(loader: loader, onOpen: _openGridAt);
    return switch (level) {
      TimelineZoomLevel.months => _monthSegments ??= overviewMonthSegments(_overviewMonths, layout, host),
      TimelineZoomLevel.years => _yearSegments ??= overviewYearSegments(overviewYears(_overviewMonths), layout, host),
      TimelineZoomLevel.grid => grid,
    };
  }

  /// The reads behind the thumbnails of the months and the years: from the buffer of the grid or a range of the
  /// timeline, both of the buckets the indexes come from; on the main timeline, the deep ones in one pass
  OverviewAssetLoader _newOverviewLoader(TimelineService service) {
    final users = service.mergedTimelineUsers;
    final repository = users == null ? null : ref.read(timelineOverviewRepositoryProvider);
    return OverviewAssetLoader(
      (index, count) => service.peekAssets(index, count, expectedTotal: _overviewTotal),
      indexedSource: repository == null
          ? null
          : (indexes) async {
              final expected = _overviewTotal;
              final read = await repository.mergedAssetsAt(users!, indexes);
              return read.total == expected ? read.assets : null;
            },
    );
  }

  void _onMultiSelectionToggled(_, bool isEnabled) {
    EventStream.shared.emit(MultiSelectToggleEvent(isEnabled));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_keepFocusInsideTvMargins);
    _fastScrollDebouncer.dispose();
    _heldArrowCooldown?.cancel();
    _zoomModifier.dispose();
    _overviewLoader?.dispose();
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

  /// A held arrow in the grid of a TV moves the focus at most once every [tvHeldArrowInterval]: the remote repeats a
  /// held key some 20 times a second, and each row passed built its tiles and asked for their pictures, more than a TV
  /// keeps up with (the grid went on moving well after the key was released). A press always moves.
  KeyEventResult _throttleHeldArrows(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !_arrowKeys.contains(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent && (_heldArrowCooldown?.isActive ?? false)) {
      return KeyEventResult.handled;
    }
    _heldArrowCooldown?.cancel();
    _heldArrowCooldown = Timer(tvHeldArrowInterval, () {});
    return KeyEventResult.ignored;
  }

  static final _arrowKeys = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  };

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
    if (_shownLevel != TimelineZoomLevel.grid) {
      // The date is a day of the grid
      _climb.gridBefore = null;
      setState(() => _level = TimelineZoomLevel.grid);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollToDate(date);
        }
      });
      return;
    }
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
    final maxWidth = ref.watch(timelineArgsProvider.select((args) => args.maxWidth));
    final tilesPerRow = ref.watch(appConfigProvider.select((config) => config.timeline.tilesPerRow));
    final isSelectionMode = ref.watch(multiSelectProvider.select((s) => s.forceEnable));
    final isMultiSelectEnabled = ref.watch(multiSelectProvider.select((s) => s.isEnabled));
    final isMultiSelectStatusVisible = !isSelectionMode && isMultiSelectEnabled;
    final isBottomWidgetVisible =
        widget.bottomSheet != null && (isMultiSelectStatusVisible || widget.persistentBottomBar);
    final tvMode = ref.watch(tvModeProvider);
    // A TV without a server has no photos of its own: the page says where they are instead of staying empty
    final tvWithoutServer = tvMode && !ref.watch(hasServerProvider);
    // The months and the years: a timeline with a scrubber whose segments all have a date, out of the remote control
    // layout; search and lists without dates keep the grid
    final loadedSegments = asyncSegments.valueOrNull;
    final overviewAvailable = widget.withScrubber && !tvMode && loadedSegments != null && _hasDates(loadedSegments);
    final level = overviewAvailable ? _level : TimelineZoomLevel.grid;
    final wheelZoomHeld = !tvMode && _zoomModifier.value;

    return PopScope(
      canPop: !isMultiSelectEnabled && level == TimelineZoomLevel.grid,
      onPopInvokedWithResult: (_, _) {
        if (isMultiSelectEnabled) {
          ref.read(multiSelectProvider.notifier).reset();
        } else if (level != TimelineZoomLevel.grid) {
          _backToGrid();
        }
      },
      child: BackButtonListener(
        onBackButtonPressed: () async {
          if (isMultiSelectEnabled) {
            ref.read(multiSelectProvider.notifier).reset();
            return true;
          }
          if (level != TimelineZoomLevel.grid) {
            _backToGrid();
            return true;
          }
          return false;
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
              onData: (gridSegments) {
                // The months and the years show segments of their own, built from those of the grid (overview/)
                final segments = _segmentsOf(level, gridSegments, maxWidth);
                _shownLevel = level;
                _shownSegments = segments;
                final childCount = (segments.lastOrNull?.lastIndex ?? -1) + 1;
                final double appBarExpandedHeight = widget.appBar != null && widget.appBar is MesmerizingSliverAppBar
                    ? 200
                    : 0;
                final topPadding = context.padding.top + (widget.appBar == null ? 0 : kToolbarHeight) + 10;

                const bottomSheetOpenModifier = 120.0;
                // On a TV the last row may stop as far from the bottom as the others (see _keepFocusInsideTvMargins).
                // The rows of a segment start a spacing under its header, a spacing the extent of the segment leaves
                // out: the last row reaches that far into this padding.
                final contentBottomPadding =
                    (tvMode
                        ? _tvBottomMargin(context) + kTvFocusRingReach + kTimelineSpacing
                        : context.padding.bottom) +
                    (isMultiSelectEnabled ? bottomSheetOpenModifier : 0);
                final scrubberBottomPadding = contentBottomPadding + kScrubberThumbHeight;

                return TimelinePinchZoom(
                  zoom: _zoomOf(level, tilesPerRow),
                  overviewAvailable: overviewAvailable,
                  onZoomChanged: _changeZoom,
                  // Ctrl and the mouse wheel, out of the remote control layout
                  wheelEnabled: !tvMode,
                  wheelHeld: wheelZoomHeld,
                  child: TimelineDragSelection(
                    builder: (physics) {
                      final grid = CustomScrollView(
                        primary: true,
                        // While Ctrl is held the list refuses the wheel, which zooms instead (overview/)
                        physics: timelineWheelZoomPhysics(physics, held: wheelZoomHeld),
                        // A screen above and below the one shown on a TV, two on a phone: the tiles built there keep
                        // their pictures alive, larger on a TV (see tvPreviewDecodeSize), whose memory is smaller, and
                        // the remote moves one row at a time. Half a screen in the months and the years, whose blocks
                        // come many to a screen.
                        scrollCacheExtent: .pixels(maxHeight * _cacheScreens(tvMode: tvMode, level: level)),
                        slivers: [
                          if (isSelectionMode)
                            // A picker brings its own selection bar, with its title (the kiosk media)
                            widget.appBar is SelectionSliverAppBar ? widget.appBar! : const SelectionSliverAppBar()
                          else if (widget.appBar != null)
                            widget.appBar!,
                          if (widget.topSliverWidget != null)
                            KeyedSubtree(key: _topSliverKey, child: widget.topSliverWidget!),
                          SliverSegmentedList(
                            // A new list for each level: the segments of another level are another layout
                            key: ValueKey(level),
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
                          yearLabels: level == TimelineZoomLevel.years,
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
                                ? Focus(
                                    canRequestFocus: false,
                                    skipTraversal: true,
                                    onKeyEvent: _throttleHeldArrows,
                                    child: Actions(actions: {DirectionalFocusIntent: _tvArrows}, child: timeline),
                                  )
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
                          // "Months" or "Years" for a moment when the timeline enters them
                          if (overviewAvailable)
                            Positioned(
                              top: MediaQuery.paddingOf(context).top + kToolbarHeight + 8,
                              left: 0,
                              right: 0,
                              child: Center(child: OverviewLevelChip(level: level)),
                            ),
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
