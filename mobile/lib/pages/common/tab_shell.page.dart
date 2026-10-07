import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/search/paginated_search.provider.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/search/search_input_focus.provider.dart';
import 'package:immich_mobile/providers/tab.provider.dart';
import 'package:immich_mobile/routing/router.dart';

@RoutePage()
class TabShellPage extends ConsumerStatefulWidget {
  const TabShellPage({super.key});

  @override
  ConsumerState<TabShellPage> createState() => _TabShellPageState();
}

class _TabShellPageState extends ConsumerState<TabShellPage> {
  /// Around the navigation rail (landscape) and around the bottom bar (portrait): whether the focus is in them, and
  /// their destinations to focus. Two nodes, one per place, so that the bottom bar stays at the same place of the tree
  /// whatever the orientation: turning a phone during a selection must not build it again, shown.
  final _railFocus = FocusNode(debugLabel: 'Tab rail', canRequestFocus: false, skipTraversal: true);
  final _bottomBarFocus = FocusNode(debugLabel: 'Tab bottom bar', canRequestFocus: false, skipTraversal: true);

  @override
  void dispose() {
    _railFocus.dispose();
    _bottomBarFocus.dispose();
    super.dispose();
  }

  bool get _navigationHasFocus => _railFocus.hasFocus || _bottomBarFocus.hasFocus;

  /// Which destinations are enabled, as last built
  List<bool> _destinationsEnabled = const [];

  /// Focuses the destination of the tab [index] in the rail or the bottom bar: one focusable item per destination in
  /// directional navigation (the remote control layout), where a disabled one stays focusable, one per enabled
  /// destination otherwise
  void _focusDestination(int index) {
    // The one of the orientation has them: the bottom bar is empty in landscape, the rail out of the tree in portrait
    final nodes = [..._railFocus.traversalDescendants, ..._bottomBarFocus.traversalDescendants];
    if (nodes.isEmpty) {
      return;
    }
    final position = nodes.length == _destinationsEnabled.length
        ? index
        : _destinationsEnabled.take(index).where((enabled) => enabled).length;
    nodes[position < nodes.length ? position : 0].requestFocus();
  }

  /// Back in the remote control layout, the left navigation pattern of the TV guidelines: from the content of a tab to
  /// its destination in the rail, from there to Photos, from Photos out of the app. Three presses at most from anywhere
  /// in a tab to the TV home, never a confirmation.
  void _onTvBack(TabsRouter tabsRouter) {
    if (!_navigationHasFocus) {
      _focusDestination(tabsRouter.activeIndex);
      return;
    }
    if (tabsRouter.activeIndex != kPhotoTabIndex) {
      _onNavigationSelected(tabsRouter, kPhotoTabIndex, ref);
      _focusDestination(kPhotoTabIndex);
      return;
    }
    unawaited(SystemNavigator.pop());
  }

  @override
  Widget build(BuildContext context) {
    final isScreenLandscape = context.orientation == Orientation.landscape;
    final isReadonlyModeEnabled = ref.watch(readonlyModeProvider);
    final tvMode = ref.watch(tvModeProvider);
    // Search and the albums come from the server; the tabs build lazily, so the pages never build without one
    final hasServer = ref.watch(hasServerProvider);

    final navigationDestinations = [
      NavigationDestination(
        label: context.t.photos,
        icon: const Icon(Icons.photo_library_outlined),
        selectedIcon: Icon(Icons.photo_library, color: context.primaryColor),
      ),
      NavigationDestination(
        label: context.t.search,
        icon: const Icon(Icons.search_rounded),
        selectedIcon: Icon(Icons.search, color: context.primaryColor),
        enabled: !isReadonlyModeEnabled && hasServer,
      ),
      NavigationDestination(
        label: context.t.albums,
        icon: const Icon(Icons.photo_album_outlined),
        selectedIcon: Icon(Icons.photo_album_rounded, color: context.primaryColor),
        enabled: !isReadonlyModeEnabled && hasServer,
      ),
      NavigationDestination(
        label: context.t.library$,
        icon: const Icon(Icons.space_dashboard_outlined),
        selectedIcon: Icon(Icons.space_dashboard_rounded, color: context.primaryColor),
        enabled: !isReadonlyModeEnabled,
      ),
    ];

    _destinationsEnabled = [for (final destination in navigationDestinations) destination.enabled];

    Widget navigationRail(TabsRouter tabsRouter) {
      return NavigationRail(
        destinations: navigationDestinations
            .map(
              (e) => NavigationRailDestination(
                icon: e.icon,
                label: Text(e.label),
                selectedIcon: e.selectedIcon,
                disabled: !e.enabled,
              ),
            )
            .toList(),
        onDestinationSelected: (index) => _onNavigationSelected(tabsRouter, index, ref),
        selectedIndex: tabsRouter.activeIndex,
        labelType: NavigationRailLabelType.all,
        groupAlignment: 0.0,
      );
    }

    return AutoTabsRouter(
      routes: const [MainTimelineRoute(), SearchRoute(), AlbumsRoute(), LibraryRoute()],
      duration: const Duration(milliseconds: 600),
      transitionBuilder: (context, child, animation) => FadeTransition(opacity: animation, child: child),
      builder: (context, child) {
        final tabsRouter = AutoTabsRouter.of(context);
        // The rail and the content of the tab are two zones for the keys of a keyboard or a remote: the focus order
        // stays within each, and the arrows go from one to the other
        final content = FocusTraversalGroup(child: child);
        return PopScope(
          canPop: !tvMode && tabsRouter.activeIndex == 0,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) {
              return;
            }
            tvMode ? _onTvBack(tabsRouter) : tabsRouter.setActiveIndex(0);
          },
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: isScreenLandscape
                ? Row(
                    children: [
                      Focus(
                        focusNode: _railFocus,
                        child: FocusTraversalGroup(child: navigationRail(tabsRouter)),
                      ),
                      const VerticalDivider(),
                      Expanded(child: content),
                    ],
                  )
                : content,
            // Empty in landscape, where the rail takes its place
            bottomNavigationBar: Focus(
              focusNode: _bottomBarFocus,
              child: FocusTraversalGroup(
                child: _BottomNavigationBar(tabsRouter: tabsRouter, destinations: navigationDestinations),
              ),
            ),
          ),
        );
      },
    );
  }
}

void _onNavigationSelected(TabsRouter router, int index, WidgetRef ref) {
  // On Photos page menu tapped
  if (router.activeIndex == kPhotoTabIndex && index == kPhotoTabIndex) {
    EventStream.shared.emit(const ScrollToTopEvent());
  }

  if (index == kPhotoTabIndex) {
    ref.invalidate(memoryLaneProvider);
  }

  if (router.activeIndex != kSearchTabIndex && index == kSearchTabIndex) {
    ref.read(searchPreFilterProvider.notifier).clear();
  }

  // On Search page tapped
  if (router.activeIndex == kSearchTabIndex && index == kSearchTabIndex) {
    ref.read(searchInputFocusProvider).requestFocus();
  }

  // Album page
  if (index == kAlbumTabIndex) {
    unawaited(ref.read(remoteAlbumProvider.notifier).refresh());
  }

  ref.read(hapticFeedbackProvider.notifier).selectionClick();
  router.setActiveIndex(index);
  ref.read(tabProvider.notifier).state = TabEnum.values[index];
}

class _BottomNavigationBar extends ConsumerStatefulWidget {
  const _BottomNavigationBar({required this.tabsRouter, required this.destinations});

  final List<Widget> destinations;
  final TabsRouter tabsRouter;

  @override
  ConsumerState createState() => _BottomNavigationBarState();
}

class _BottomNavigationBarState extends ConsumerState<_BottomNavigationBar> {
  bool hideNavigationBar = false;
  StreamSubscription? _eventSubscription;

  @override
  void initState() {
    super.initState();
    _eventSubscription = EventStream.shared.listen<MultiSelectToggleEvent>(_onEvent);
  }

  void _onEvent(MultiSelectToggleEvent event) {
    setState(() {
      hideNavigationBar = event.isEnabled;
    });
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isScreenLandscape = context.orientation == Orientation.landscape;

    if (isScreenLandscape || hideNavigationBar) {
      return const SizedBox.shrink();
    }

    return NavigationBar(
      selectedIndex: widget.tabsRouter.activeIndex,
      onDestinationSelected: (index) => _onNavigationSelected(widget.tabsRouter, index, ref),
      destinations: widget.destinations,
    );
  }
}
