import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/extensions/scroll_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/download_status_floating_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_page.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_preloader.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_stack.provider.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_bottom_app_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_top_app_bar.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/cast.provider.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/utils/system_ui.utils.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';

/// Moves the asset viewer on screen to another asset of its timeline, for what follows the timeline away from the
/// viewer: the immersive viewer of the Meta Quest goes through it on its own (see TimelineImmersiveNavigator), and the
/// asset viewer shows the asset it closed on. Each asset viewer route has its own (see [AssetViewerPage]), read when
/// the immersive viewer opens: a viewer stacked over another one later does not take its place.
///
/// The immersive viewer searches the very timeline of the asset viewer, whose buffer the pages are built from (see
/// TimelineService.getAssetSafe): a search leaves that buffer where it looked, possibly far from the page on screen.
/// Both moves load the timeline around their page first, see [jumpTo] and [recenter].
class AssetViewerJump {
  _AssetViewerState? _viewer;

  /// The index in the timeline of the asset on screen, null when no viewer is there
  int? get currentIndex => _viewer?._currentPage;

  /// Shows the asset at [index] of the timeline, as a tap on the side of the viewer does, once the timeline is loaded
  /// around it. When it cannot go there (the timeline no longer has that index), and for the asset already on screen,
  /// the viewer stays where it is and loads the timeline around its page again, as [recenter] does. Nothing once the
  /// viewer is gone.
  Future<void> jumpTo(int index) async => _viewer?._jumpToLoaded(index);

  /// Loads the timeline around the asset on screen again, and what the viewer preloads around it, after something
  /// else read the timeline elsewhere
  Future<void> recenter() async => _viewer?._recenter();

  void _attach(_AssetViewerState viewer) => _viewer = viewer;

  void _detach(_AssetViewerState viewer) {
    if (identical(_viewer, viewer)) {
      _viewer = null;
    }
  }
}

/// The [AssetViewerJump] of the asset viewer on screen, overridden in each asset viewer route
final assetViewerJumpProvider = Provider<AssetViewerJump>((_) => AssetViewerJump());

@RoutePage()
class AssetViewerPage extends StatelessWidget {
  final int initialIndex;
  final TimelineService timelineService;
  final int? heroOffset;
  final RemoteAlbum? currentAlbum;

  const AssetViewerPage({
    super.key,
    required this.initialIndex,
    required this.timelineService,
    this.heroOffset,
    this.currentAlbum,
  });

  @override
  Widget build(BuildContext context) {
    // This is necessary to ensure that the timeline service is available
    // since the Timeline and AssetViewer are on different routes / Widget subtrees.
    return ProviderScope(
      overrides: [
        timelineServiceProvider.overrideWithValue(timelineService),
        currentRemoteAlbumScopedProvider.overrideWithValue(currentAlbum),
        assetViewerJumpProvider.overrideWith((_) => AssetViewerJump()),
      ],
      child: AssetViewer(initialIndex: initialIndex, heroOffset: heroOffset),
    );
  }
}

class AssetViewer extends ConsumerStatefulWidget {
  final int initialIndex;
  final int? heroOffset;

  const AssetViewer({super.key, required this.initialIndex, this.heroOffset});

  @override
  ConsumerState createState() => _AssetViewerState();

  /// Sets the asset and thumbnail size before opening the viewer.
  static void setAsset(WidgetRef ref, BaseAsset asset, {Size? thumbnailSize}) {
    ref.read(assetViewerProvider.notifier).reset();

    // Hide controls by default for videos
    if (asset.isVideo) {
      ref.read(assetViewerProvider.notifier).setControls(false);
    }

    ref.read(assetViewerProvider.notifier).setAsset(asset, thumbnailSize: thumbnailSize);
  }
}

class _AssetViewerState extends ConsumerState<AssetViewer> {
  static const _viewerOverlayStyle = SystemUiOverlayStyle(
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarIconBrightness: Brightness.light,
  );

  late final _heroOffset = widget.heroOffset ?? TabsRouterScope.of(context)?.controller.activeIndex ?? 0;
  late final _pageController = PageController(initialPage: widget.initialIndex);
  late final _preloader = AssetPreloader(timelineService: ref.read(timelineServiceProvider), mounted: () => mounted);

  late int _currentPage = widget.initialIndex;
  late int _totalAssets = ref.read(timelineServiceProvider).totalAssets;

  StreamSubscription? _reloadSubscription;
  KeepAliveLink? _stackChildrenKeepAlive;
  // Read once: the provider is scoped to this route, and dispose may no longer read it
  late final _jump = ref.read(assetViewerJumpProvider);

  void _onTapNavigate(int direction) {
    final page = _pageController.page?.toInt();
    if (page == null) {
      return;
    }
    _jumpTo(page + direction);
  }

  // Whether the viewer moved to [target]: not when the timeline has no such page, nor before the pages are laid out
  bool _jumpTo(int target) {
    final maxPage = _totalAssets - 1;
    if (target < 0 || target > maxPage || !_pageController.hasClients) {
      return false;
    }
    _pageController.jumpToPage(target);
    unawaited(_onAssetChanged(target));
    return true;
  }

  // See AssetViewerJump.jumpTo: unlike a tap, the target may be far from the buffer of the timeline, and its page would
  // find no asset to show (see AssetPage) if it was built before the buffer got there
  Future<void> _jumpToLoaded(int target) async {
    if (target != _currentPage && await _loadAround(target) && mounted && _jumpTo(target)) {
      return;
    }
    // No move: whatever read the timeline before (a search of the immersive viewer, or the load above) left its buffer
    // away from the page on screen, whose AssetPage would be left on its spinner by the next reload of the timeline.
    // Through the hook rather than this state, which may be gone now: the viewer attached in its place, if any, loads
    // around its own page.
    await _jump.recenter();
  }

  // See AssetViewerJump.recenter
  Future<void> _recenter() async {
    final page = _currentPage;
    if (!await _loadAround(page) || !mounted || page != _currentPage) {
      return;
    }
    // Only what the viewer does on a page change that has to do with the buffer: the asset on screen is the same, and
    // a cast going on is left alone
    _preloader.preload(page, context.sizeData, thumbnailSize: ref.read(assetViewerProvider).thumbnailSize);
    // A reload of the timeline while its buffer was elsewhere left the page on screen without its asset, which it
    // reads again from the buffer on this event only. The event is the one every reload of a timeline sends, cheap
    // for the pages that had theirs.
    EventStream.shared.emit(const TimelineReloadEvent());
  }

  // Loads the timeline around [index], as a page change does; false when it has no such index now
  Future<bool> _loadAround(int index) async {
    if (index < 0 || index >= _totalAssets) {
      return false;
    }
    try {
      await ref.read(timelineServiceProvider).preloadAssets(index);
      return true;
    } catch (_) {
      // The timeline shrank meanwhile: the reload that follows sets the viewer again
      return false;
    }
  }

  @override
  void initState() {
    super.initState();

    final asset = ref.read(assetViewerProvider).currentAsset;
    assert(asset != null, "Current asset should not be null when opening the AssetViewer");
    if (asset != null) {
      _stackChildrenKeepAlive = ref.read(stackChildrenNotifier(asset).notifier).ref.keepAlive();
    }

    _reloadSubscription = EventStream.shared.listen(_onEvent);
    _jump._attach(this);

    WidgetsBinding.instance.addPostFrameCallback(_onAssetInit);

    final assetViewer = ref.read(assetViewerProvider);
    unawaited(_setSystemUIMode(assetViewer.showingControls, assetViewer.showingDetails));
  }

  @override
  void dispose() {
    _jump._detach(this);
    _pageController.dispose();
    _preloader.dispose();
    unawaited(_reloadSubscription?.cancel());
    _stackChildrenKeepAlive?.close();

    unawaited(restoreEdgeToEdge());

    super.dispose();
  }

  // The normal onPageChange callback listens to OnScrollUpdate events, and will
  // round the current page and update whenever that value changes. In practise,
  // this means that the page will change when swiped half way, and may flip
  // whilst dragging.
  //
  // Changing the page at the end of a scroll should be more robust, and allow
  // the page to be dragged more than half way whilst keeping the current video
  // playing, and preventing the video on the next page from becoming ready
  // unnecessarily.
  bool _onScrollEnd(ScrollEndNotification notification) {
    if (notification.depth != 0) {
      return false;
    }

    final page = _pageController.page?.round();
    if (page != null && page != _currentPage) {
      unawaited(_onAssetChanged(page));
    }
    return false;
  }

  void _onAssetInit(Duration timeStamp) {
    _preloader.preload(
      widget.initialIndex,
      context.sizeData,
      thumbnailSize: ref.read(assetViewerProvider).thumbnailSize,
    );
    _handleCasting();
  }

  Future<void> _onAssetChanged(int index) async {
    _currentPage = index;

    final asset = await ref.read(timelineServiceProvider).getAssetAsync(index);
    if (asset == null) {
      return;
    }

    // The viewer is closing; don't flip the current asset now. Flipping it swaps
    // the grid tile hero keys mid pop and animates the close on two tiles (#23779).
    if (!mounted || !(ModalRoute.of(context)?.isActive ?? true)) {
      return;
    }

    ref.read(assetViewerProvider.notifier).setAsset(asset);
    _preloader.preload(index, context.sizeData, thumbnailSize: ref.read(assetViewerProvider).thumbnailSize);
    _handleCasting();
    _stackChildrenKeepAlive?.close();
    _stackChildrenKeepAlive = ref.read(stackChildrenNotifier(asset).notifier).ref.keepAlive();
  }

  void _handleCasting() {
    if (!ref.read(castProvider).isCasting) {
      return;
    }
    final asset = ref.read(assetViewerProvider).currentAsset;
    if (asset == null) {
      return;
    }

    if (asset is RemoteAsset) {
      context.scaffoldMessenger.hideCurrentSnackBar();
      ref.read(castProvider.notifier).loadMedia(asset, false);
      return;
    }

    context.scaffoldMessenger.clearSnackBars();
    ref.read(castProvider.notifier).stop();
    context.scaffoldMessenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(
          context.t.local_asset_cast_failed,
          style: context.textTheme.bodyLarge?.copyWith(color: context.primaryColor),
        ),
      ),
    );
  }

  void _onEvent(Event event) {
    switch (event) {
      case TimelineReloadEvent():
        _onTimelineReloadEvent();
      default:
    }
  }

  void _onTimelineReloadEvent() {
    final timelineService = ref.read(timelineServiceProvider);
    final totalAssets = timelineService.totalAssets;

    if (totalAssets == 0) {
      unawaited(context.maybePop());
      return;
    }

    final currentAsset = ref.read(assetViewerProvider).currentAsset;
    final assetIndex = currentAsset != null ? timelineService.getIndex(currentAsset.heroTag) : null;
    final index = (assetIndex ?? _currentPage).clamp(0, totalAssets - 1);

    if (index != _currentPage) {
      _pageController.jumpToPage(index);
      unawaited(_onAssetChanged(index));
    } else if (currentAsset is RemoteAsset && currentAsset.stackId != null && assetIndex == null) {
      final timelineAsset = timelineService.getAssetSafe(index);
      if (timelineAsset is! RemoteAsset || currentAsset.stackId != timelineAsset.stackId) {
        unawaited(_onAssetChanged(index));
      }
    } else if (currentAsset != null && assetIndex == null) {
      unawaited(_onAssetChanged(index));
    }

    if (_totalAssets != totalAssets) {
      setState(() {
        _totalAssets = totalAssets;
      });
    }
  }

  Future<void> _setSystemUIMode(bool controls, bool details) {
    final immersive = !controls || (CurrentPlatform.isIOS && details);
    return immersive ? SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky) : restoreEdgeToEdge();
  }

  @override
  Widget build(BuildContext context) {
    final showingControls = ref.watch(assetViewerProvider.select((s) => s.showingControls));
    final showingDetails = ref.watch(assetViewerProvider.select((s) => s.showingDetails));
    final isZoomed = ref.watch(assetViewerProvider.select((s) => s.isZoomed));
    final backgroundColor = showingDetails
        ? context.colorScheme.surface
        : Colors.black.withValues(alpha: ref.watch(assetViewerProvider.select((s) => s.backgroundOpacity)));

    // Listen for casting changes and send initial asset to the cast provider
    ref.listen(castProvider.select((value) => value.isCasting), (_, isCasting) {
      if (!isCasting) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleCasting();
      });
    });

    ref.listen(assetViewerProvider.select((value) => (value.showingControls, value.showingDetails)), (_, state) {
      final (controls, details) = state;
      unawaited(_setSystemUIMode(controls, details));
    });

    return AnnotatedRegion(
      value: _viewerOverlayStyle,
      child: Scaffold(
        backgroundColor: backgroundColor,
        resizeToAvoidBottomInset: false,
        appBar: const ViewerTopAppBar(),
        extendBody: true,
        extendBodyBehindAppBar: true,
        floatingActionButton: IgnorePointer(
          ignoring: !showingControls,
          child: AnimatedOpacity(
            opacity: showingControls ? 1.0 : 0.0,
            duration: Durations.short2,
            child: const DownloadStatusFloatingButton(),
          ),
        ),
        bottomNavigationBar: const ViewerBottomAppBar(),
        body: Stack(
          children: [
            NotificationListener<ScrollEndNotification>(
              onNotification: _onScrollEnd,
              child: PhotoViewGestureDetectorScope(
                axis: Axis.horizontal,
                child: PageView.builder(
                  controller: _pageController,
                  physics: isZoomed
                      ? const NeverScrollableScrollPhysics()
                      : CurrentPlatform.isIOS
                      ? const FastScrollPhysics()
                      : const FastClampingScrollPhysics(),
                  itemCount: _totalAssets,
                  itemBuilder: (context, index) =>
                      AssetPage(index: index, heroOffset: _heroOffset, onTapNavigate: _onTapNavigate),
                ),
              ),
            ),
            if (!CurrentPlatform.isIOS)
              IgnorePointer(
                child: AnimatedContainer(
                  duration: Durations.short2,
                  color: Colors.black.withValues(alpha: showingDetails ? 0.6 : 0.0),
                  height: context.padding.top,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
