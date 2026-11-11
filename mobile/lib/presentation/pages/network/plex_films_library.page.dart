// The films page of a Plex film library (lot A1 of the films study of 10 November 2026, requests 1, 4 and 2): every
// film of the library in one list, newest year first, under a header per year with its count, read 100 at a time as
// the grid shows their rows (see PagedPlexFilms); 2:3 posters with the title and the year under each; a search field
// (the titles that hold the text, plus what the server's spelling tolerant search adds); the year scrubber.
//
// A movie library of a Plex server opens here from the folder view of its share, and from the Films button of the
// Library tab; its folders stay one menu line away ("Show the folders"). "Other videos", where the 360° files live,
// keep the folder view. A long press on a poster opens its menu: there is no selection mode.
//
// On a TV: 7 posters a row, no scrubber, the first poster focused, OK on the search field opens the TV keyboard dialog
// (TvTextEntry). The Quest window gets the tablet layout. Computers: Ctrl (Command on a Mac) and the wheel change the
// number of columns, Ctrl or Command F and "/" go to the search field, Escape clears it.

import 'dart:async';
import 'dart:math';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_list.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/widgets/network/network_status.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_upload.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/plex_film_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/timeline_wheel_zoom.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_text_entry.widget.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/network/plex_film_list.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:logging/logging.dart';

final _log = Logger('PlexFilmsLibraryPage');

/// Opens the films page of a film library of the Plex servers of the app, for the Films button of the Library tab:
/// the only one at once, else the one picked in a dialog; a message when there is none
Future<void> openPlexFilms(BuildContext context, WidgetRef ref) async {
  final servers = [
    for (final source in ref.read(networkSourcesProvider))
      if (source.type == NetworkSourceType.plex) source,
  ];
  final opener = ref.read(plexFilmsSourceProvider);
  final found = await Future.wait([
    for (final server in servers)
      () async {
        try {
          final source = await opener(server.id);
          return [
            for (final library in await source.filmLibraries())
              (sourceId: server.id, serverName: server.name, section: library.section, folderPath: library.folderPath),
          ];
        } catch (error) {
          // A server that does not answer now: the others are offered
          _log.info('The film libraries of a Plex server could not be read: ${error.runtimeType}');
          return <PlexFilmLibrary>[];
        }
      }(),
  ]);
  final libraries = found.expand((libraries) => libraries).toList();
  if (!context.mounted) {
    return;
  }
  if (libraries.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t.plex_films_no_library)));
    return;
  }
  final PlexFilmLibrary? chosen = libraries.length == 1
      ? libraries.single
      : await showDialog<PlexFilmLibrary>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(context.t.plex_films_choose_library),
            children: [
              for (final (i, library) in libraries.indexed)
                ListTile(
                  autofocus: i == 0,
                  leading: const Icon(Icons.movie_outlined),
                  title: Text(library.section.title),
                  // The server, when there are several
                  subtitle: servers.length > 1 ? Text(library.serverName) : null,
                  onTap: () => Navigator.of(context).pop(library),
                ),
            ],
          ),
        );
  if (chosen == null || !context.mounted) {
    return;
  }
  unawaited(
    context.pushRoute(
      PlexFilmsLibraryRoute(
        sourceId: chosen.sourceId,
        sectionKey: chosen.section.key,
        title: chosen.section.title,
        folderPath: chosen.folderPath,
      ),
    ),
  );
}

/// The films page of the film library [sectionKey] of the Plex server of [sourceId]
@RoutePage()
class PlexFilmsLibraryPage extends ConsumerStatefulWidget {
  const PlexFilmsLibraryPage({
    super.key,
    required this.sourceId,
    required this.sectionKey,
    required this.title,
    required this.folderPath,
  });

  final String sourceId;
  final String sectionKey;

  /// The name of the library, the title of the page
  final String title;

  /// The folder of the library at the root of its share, which "Show the folders" opens
  final String folderPath;

  @override
  ConsumerState<PlexFilmsLibraryPage> createState() => _PlexFilmsLibraryPageState();
}

enum _PageAction { showFolders, refresh }

class _PlexFilmsLibraryPageState extends ConsumerState<PlexFilmsLibraryPage> {
  final _scroll = ScrollController();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'plex_films_search');

  /// The page's own focus, which its keys reach through when nothing inside it has the focus
  final _pageFocus = FocusNode(debugLabel: 'plex_films_page');

  /// Ctrl or Command held, for the wheel to change the columns (computers only)
  TimelineZoomModifier? _zoomModifier;
  Timer? _debounce;

  PlexFilmsSource? _source;

  /// Every film of the library, once its years came
  PagedPlexFilms? _all;
  Object? _error;

  /// The results of the search of [_searched], null before the first one came
  StaticPlexFilms? _found;
  String _searched = '';
  Object? _searchError;
  bool _searching = false;
  String _lastText = '';

  /// Columns added to the default of the width, by a pinch or by Ctrl and the wheel
  int _columnsDelta = 0;
  double _pinchBase = 1;

  int _loadGeneration = 0;
  int _searchGeneration = 0;

  PlexFilmLibraryKey get _key => (sourceId: widget.sourceId, sectionKey: widget.sectionKey);

  PlexFilmListQuery get _query =>
      PlexFilmListQuery(sectionKey: widget.sectionKey, filters: ref.read(plexFilmFiltersProvider(_key)));

  String get _text => _searchController.text.trim();

  @override
  void initState() {
    super.initState();
    if (CurrentPlatform.isDesktop) {
      _zoomModifier = TimelineZoomModifier();
    }
    _searchController.addListener(_onSearchText);
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController
      ..removeListener(_onSearchText)
      ..dispose();
    _searchFocus.dispose();
    _pageFocus.dispose();
    _scroll.dispose();
    _zoomModifier?.dispose();
    _all?.dispose();
    super.dispose();
  }

  /// Reads the years of the films and their first page; what was shown stays until they came
  Future<void> _load() async {
    final generation = ++_loadGeneration;
    if (_error != null) {
      setState(() => _error = null);
    }
    try {
      final source = _source ??= await ref.read(plexFilmsSourceProvider)(widget.sourceId);
      final list = await PagedPlexFilms.load(source, _query);
      if (!mounted || generation != _loadGeneration) {
        list.dispose();
        return;
      }
      final previous = _all;
      setState(() => _all = list);
      // Once the grid listens to the new list
      WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
      if (_text.isNotEmpty) {
        // The filters changed while a search was shown, or the source was not open yet when it was typed
        unawaited(_search());
      }
    } catch (error) {
      _log.info('The films could not be read: ${error.runtimeType}');
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = error);
      }
    }
  }

  Future<void> _refresh() => _load();

  void _onSearchText() {
    final text = _text;
    if (text == _lastText) {
      // A move of the cursor
      return;
    }
    _lastText = text;
    _debounce?.cancel();
    if (text.isEmpty) {
      ++_searchGeneration;
      setState(() {
        _found = null;
        _searched = '';
        _searchError = null;
        _searching = false;
      });
      return;
    }
    // The results 300 ms after the last key
    _debounce = Timer(const Duration(milliseconds: 300), () => unawaited(_search()));
    setState(() {});
  }

  Future<void> _search() async {
    _debounce?.cancel();
    final text = _text;
    final source = _source;
    if (text.isEmpty || source == null) {
      return;
    }
    final generation = ++_searchGeneration;
    setState(() => _searching = true);
    try {
      final found = await searchPlexFilms(source, _query.copyWith(title: text));
      if (!mounted || generation != _searchGeneration) {
        return;
      }
      setState(() {
        _found = found;
        _searched = text;
        _searchError = null;
        _searching = false;
      });
      if (_scroll.hasClients) {
        _scroll.jumpTo(0);
      }
    } catch (error) {
      _log.info('The search failed: ${error.runtimeType}');
      if (mounted && generation == _searchGeneration) {
        setState(() {
          _searchError = error;
          _searching = false;
        });
      }
    }
  }

  void _clearSearch() {
    _searchController.clear();
    if (_searchFocus.hasFocus) {
      // Back to the page, whose keys ("/", Ctrl F) still work
      _pageFocus.requestFocus();
    }
  }

  /// Ctrl or Command F and "/" go to the search field, Escape clears it (computers, a keyboard on a tablet)
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.keyF && (keyboard.isControlPressed || keyboard.isMetaPressed)) {
      _searchFocus.requestFocus();
      _searchController.selection = TextSelection(baseOffset: 0, extentOffset: _searchController.text.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.slash && !_searchFocus.hasFocus) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && (_searchFocus.hasFocus || _text.isNotEmpty)) {
      _clearSearch();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The target of a menu or a tap on the film at [index], null while its page has not come or for a film without file
  PlexFilmMenuTarget? _targetAt(PlexFilmsList list, int index) {
    final film = list.filmAt(index);
    final source = _source;
    if (film == null || source == null) {
      return null;
    }
    final entry = plexFilmEntry(source.filmsSourceId, widget.sectionKey, film);
    return entry == null ? null : (sourceId: widget.sourceId, sectionKey: widget.sectionKey, film: film, entry: entry);
  }

  /// Opens the film at [index]: the page another lot gives (the film page), else the video page with the films around
  /// it for previous and next
  Future<void> _open(PlexFilmsList list, int index) async {
    final target = _targetAt(list, index);
    if (target == null) {
      return;
    }
    final route = ref.read(plexFilmOpenRouteProvider)(target);
    if (route != null) {
      unawaited(context.pushRoute(route));
      return;
    }
    final source = _source!;
    final around = list.around(index, radius: 10);
    final entries = <NetworkEntry>[];
    var opened = 0;
    for (final (i, film) in around.films.indexed) {
      final entry = plexFilmEntry(source.filmsSourceId, widget.sectionKey, film);
      if (entry == null) {
        continue;
      }
      if (i == around.index) {
        opened = entries.length;
      }
      entries.add(entry);
    }
    final connections = ref.read(networkConnectionsProvider);
    final urls = <String, Uri>{};
    await Future.wait([
      for (final entry in entries)
        connections
            .mediaUrl(widget.sourceId, entry.path)
            .then((url) => urls[entry.path] = url)
            .catchError((Object _) => Uri()),
    ]);
    if (!mounted) {
      return;
    }
    final path = target.entry.path;
    unawaited(
      context.pushRoute(
        NetworkVideoRoute(
          key: networkFilePageKey(widget.sourceId, path),
          sourceId: widget.sourceId,
          path: path,
          folder: NetworkFolderMedia(entries: entries, urls: urls, index: opened),
        ),
      ),
    );
  }

  /// The menu of a long press on the film at [index]: Play, what other lots add, Upload to Immich
  Future<void> _menu(PlexFilmsList list, int index) async {
    final target = _targetAt(list, index);
    if (target == null) {
      return;
    }
    final tvMode = ref.read(tvModeProvider);
    final hasServer = ref.read(hasServerProvider);
    final extra = [
      for (final action in ref.read(plexFilmMenuActionsProvider))
        if (action.isShown?.call(ref, target) ?? true) action,
    ];
    final lines = <({Key key, IconData icon, String label, Future<void> Function() run})>[
      (
        key: const Key('plex_film_menu_play'),
        icon: Icons.play_arrow_rounded,
        label: context.t.play,
        run: () => _open(list, index),
      ),
      for (final action in extra)
        (
          key: ValueKey('plex_film_menu_${action.icon.codePoint}'),
          icon: action.icon,
          label: action.label(context),
          run: () => action.onSelected(context, ref, target),
        ),
      // On a TV the app is a viewer: nothing is sent to the server from it
      if (!tvMode && hasServer)
        (
          key: const Key('plex_film_menu_upload'),
          icon: Icons.backup_outlined,
          label: context.t.network_upload_action,
          run: () => uploadNetworkEntries(context, ref, widget.sourceId, [target.entry]),
        ),
    ];
    final film = target.film;
    final year = film.year;
    final chosen = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: !tvMode,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                film.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.titleMedium,
              ),
              subtitle: year == null ? null : Text('$year'),
            ),
            for (final (i, line) in lines.indexed)
              ListTile(
                key: line.key,
                autofocus: i == 0,
                leading: Icon(line.icon),
                title: Text(line.label),
                onTap: () => Navigator.of(context).pop(i),
              ),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) {
      await lines[chosen].run();
    }
  }

  void _onPageAction(_PageAction action) {
    switch (action) {
      case _PageAction.showFolders:
        unawaited(context.pushRoute(NetworkBrowserRoute(sourceId: widget.sourceId, path: widget.folderPath)));
      case _PageAction.refresh:
        unawaited(_refresh());
    }
  }

  void _changeColumns(int steps) {
    if (steps != 0) {
      setState(() => _columnsDelta += steps);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The chips of the filters (lot A2) set the parameters of /all: the list is read again with them
    ref.listen(plexFilmFiltersProvider(_key), (_, _) => unawaited(_load()));
    final tvMode = ref.watch(tvModeProvider);
    final source = ref.watch(networkSourceProvider(widget.sourceId));
    final searching = _text.isNotEmpty;
    return PopScope(
      // Back clears the search before it leaves the page
      canPop: !searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _clearSearch();
        }
      },
      child: Focus(
        focusNode: _pageFocus,
        // The keys of the page reach it from the start; on a TV the first poster takes the focus
        autofocus: !tvMode,
        onKeyEvent: _onKey,
        child: Scaffold(
          appBar: AppBar(
            title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            elevation: 0,
            centerTitle: false,
            actions: [
              PopupMenuButton<_PageAction>(
                key: const Key('plex_films_menu'),
                onSelected: _onPageAction,
                itemBuilder: (context) => [
                  PopupMenuItem(
                    key: const Key('plex_films_show_folders'),
                    value: _PageAction.showFolders,
                    child: ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(context.t.plex_films_show_folders),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem(
                    value: _PageAction.refresh,
                    child: ListTile(
                      leading: const Icon(Icons.refresh_rounded),
                      title: Text(context.t.refresh),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                _searchField(tvMode),
                if (_searching) const LinearProgressIndicator(minHeight: 2) else const SizedBox(height: 2),
                Expanded(child: _body(source, tvMode: tvMode)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchField(bool tvMode) {
    final label = context.t.plex_films_search_hint;
    final field = TextField(
      key: const Key('plex_films_search'),
      controller: _searchController,
      focusNode: _searchFocus,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => unawaited(_search()),
      decoration: InputDecoration(
        hintText: label,
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: _text.isEmpty
            ? null
            : IconButton(
                key: const Key('plex_films_search_clear'),
                icon: const Icon(Icons.close_rounded),
                tooltip: context.t.clear,
                onPressed: _clearSearch,
              ),
        isDense: true,
        border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(tvMode ? 32 : 12, 8, tvMode ? 32 : 12, 6),
      child: TvTextEntry(
        controller: _searchController,
        label: label,
        kind: TvTextKind.text,
        onSubmitted: (_) => unawaited(_search()),
        child: field,
      ),
    );
  }

  Widget _body(NetworkSource? source, {required bool tvMode}) {
    final all = _all;
    if (all == null) {
      final error = _error;
      return error == null
          ? const NetworkLoadingView()
          : NetworkErrorView(error: error, onRetry: () => unawaited(_load()), source: source);
    }
    final searching = _text.isNotEmpty;
    final searchError = _searchError;
    if (searching && searchError != null && _found == null) {
      return NetworkErrorView(error: searchError, onRetry: () => unawaited(_search()), source: source);
    }
    // Every film stays until the first results come, the bar under the field telling the search runs
    final PlexFilmsList list = searching ? (_found ?? all) : all;
    if (list.count == 0) {
      return _Message(
        icon: searching ? Icons.search_off_rounded : Icons.movie_outlined,
        text: searching ? context.t.plex_films_no_results(text: _searched) : context.t.plex_films_empty,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _GridLayout.of(
          constraints.maxWidth,
          tvMode: tvMode,
          columnsDelta: _columnsDelta,
          scaler: MediaQuery.textScalerOf(context),
        );
        return ListenableBuilder(
          listenable: list,
          builder: (context, _) => Column(
            children: [
              if (list.hasFailures) _FailureBar(onRetry: list.retryFailures),
              Expanded(child: _grid(list, layout, tvMode: tvMode)),
            ],
          ),
        );
      },
    );
  }

  Widget _grid(PlexFilmsList list, _GridLayout layout, {required bool tvMode}) {
    final years = list.years;
    final slivers = <Widget>[];
    for (final group in years) {
      slivers.add(
        SliverToBoxAdapter(
          child: _YearHeader(
            year: group.year,
            count: group.count,
            height: layout.headerExtent,
            padding: layout.padding,
          ),
        ),
      );
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.fromLTRB(layout.padding, 0, layout.padding, layout.groupGap),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: layout.columns,
              mainAxisSpacing: layout.spacing,
              crossAxisSpacing: layout.spacing,
              mainAxisExtent: layout.tileExtent,
            ),
            itemCount: group.count,
            itemBuilder: (context, local) {
              final index = group.firstIndex + local;
              list.want(index);
              final film = list.filmAt(index);
              final target = film == null ? null : _targetAt(list, index);
              if (film == null || target == null) {
                return const PlexFilmPlaceholder();
              }
              return PlexFilmTile(
                key: ValueKey('plex-film:${film.ratingKey}'),
                film: film,
                entry: target.entry,
                tvMode: tvMode,
                autofocus: tvMode && index == 0,
                onTap: () => unawaited(_open(list, index)),
                onLongPress: () => unawaited(_menu(list, index)),
              );
            },
          ),
        ),
      );
    }
    final held = _zoomModifier;
    Widget scrollView(bool zoomHeld) => CustomScrollView(
      controller: _scroll,
      physics: timelineWheelZoomPhysics(const AlwaysScrollableScrollPhysics(), held: zoomHeld),
      slivers: slivers,
    );
    Widget view = held == null
        ? scrollView(false)
        : ValueListenableBuilder<bool>(
            valueListenable: held,
            builder: (context, zoomHeld, _) =>
                TimelineWheelZoom(enabled: true, held: zoomHeld, onSteps: _changeColumns, child: scrollView(zoomHeld)),
          );
    if (tvMode) {
      // Seven posters a row, the remote moves the focus: no pinch, no scrubber, no pull to refresh
      return view;
    }
    view = RawGestureDetector(
      gestures: {
        _PinchRecognizer: GestureRecognizerFactoryWithHandlers<_PinchRecognizer>(_PinchRecognizer.new, (pinch) {
          pinch.onStart = (_) {
            _pinchBase = 1;
          };
          pinch.onUpdate = (details) {
            if (details.pointerCount < 2) {
              return;
            }
            // Apart: larger posters, fewer columns; together: more columns
            final ratio = details.scale / _pinchBase;
            if (ratio > 1.25) {
              _pinchBase = details.scale;
              _changeColumns(-1);
            } else if (ratio < 0.8) {
              _pinchBase = details.scale;
              _changeColumns(1);
            }
          };
        }),
      },
      child: RefreshIndicator(onRefresh: _refresh, child: view),
    );
    return PlexFilmsScrubber(controller: _scroll, labels: layout.yearMarks(years), child: view);
  }
}

/// A pinch that goes on even when the list claims the pointers, as the pinch of the timeline
class _PinchRecognizer extends ScaleGestureRecognizer {
  @override
  void rejectGesture(int pointer) {
    acceptGesture(pointer);
  }
}

/// The sizes of the grid for a width: the columns (7 on a TV, else about one per 120 logical pixels, moved by a pinch
/// or by Ctrl and the wheel), the poster cells of 2:3 with their caption, the year headers. Every row has the same
/// height, so that the place of each year in the list is known before its films come (the scrubber's marks).
class _GridLayout {
  const _GridLayout({
    required this.columns,
    required this.padding,
    required this.spacing,
    required this.tileExtent,
    required this.headerExtent,
    required this.groupGap,
  });

  factory _GridLayout.of(double width, {required bool tvMode, required int columnsDelta, required TextScaler scaler}) {
    final padding = tvMode ? 32.0 : 8.0;
    final spacing = tvMode ? 12.0 : 8.0;
    final base = max(2, (width / 120).floor());
    final most = max(2, min(12, (width / 60).floor()));
    final columns = tvMode ? 7 : (base + columnsDelta).clamp(2, most);
    final cell = max(40.0, (width - 2 * padding - (columns - 1) * spacing) / columns);
    return _GridLayout(
      columns: columns,
      padding: padding,
      spacing: spacing,
      tileExtent: cell * 1.5 + PlexFilmCaption.height(scaler, tvMode: tvMode),
      headerExtent: scaler.scale(tvMode ? 20 : 18) * 1.3 + 22,
      groupGap: 8,
    );
  }

  final int columns;
  final double padding;
  final double spacing;
  final double tileExtent;
  final double headerExtent;
  final double groupGap;

  /// The height of the header and the rows of a year of [count] films
  double groupExtent(int count) {
    final rows = (count + columns - 1) ~/ columns;
    return headerExtent + rows * tileExtent + max(0, rows - 1) * spacing + groupGap;
  }

  /// Where each year starts in the list, with its label
  List<PlexYearMark> yearMarks(List<PlexFilmYear> years) {
    final marks = <PlexYearMark>[];
    var offset = 0.0;
    for (final group in years) {
      marks.add((offset: offset, year: group.year));
      offset += groupExtent(group.count);
    }
    return marks;
  }
}

/// The start of a year in the list, for the scrubber (null: the films without a year)
typedef PlexYearMark = ({double offset, int? year});

class _YearHeader extends StatelessWidget {
  const _YearHeader({required this.year, required this.count, required this.height, required this.padding});

  final int? year;
  final int count;
  final double height;
  final double padding;

  @override
  Widget build(BuildContext context) {
    final year = this.year;
    return SizedBox(
      height: height,
      child: Padding(
        padding: EdgeInsets.fromLTRB(padding + 4, 12, padding, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: Text(
                year == null ? context.t.plex_films_year_unknown : '$year',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              context.t.plex_films_count(count: count),
              maxLines: 1,
              style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Above the grid when pages of films could not be read: Retry reads them again as their rows show
class _FailureBar extends StatelessWidget {
  const _FailureBar({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('plex_films_failures'),
      color: context.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            Icon(Icons.cloud_off_rounded, size: 18, color: context.colorScheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                context.t.plex_films_page_failed,
                style: TextStyle(color: context.colorScheme.onErrorContainer),
              ),
            ),
            TextButton(onPressed: onRetry, child: Text(context.t.retry)),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: context.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: context.textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}

/// The year scrubber of the films page (phones, tablets, the Quest window, computers; none on a TV): a handle along
/// the right edge, which shows while the list moves; dragged, it moves the list and tells the year it reached, with
/// the years of the list marked along the edge. Its own, rather than the timeline's Scrubber, which reads the time
/// buckets of the timeline and sets its state.
class PlexFilmsScrubber extends StatefulWidget {
  const PlexFilmsScrubber({super.key, required this.controller, required this.labels, required this.child});

  final ScrollController controller;
  final List<PlexYearMark> labels;
  final Widget child;

  @override
  State<PlexFilmsScrubber> createState() => _PlexFilmsScrubberState();
}

class _PlexFilmsScrubberState extends State<PlexFilmsScrubber> {
  static const _width = 36.0;
  static const _handleHeight = 44.0;

  bool _dragging = false;
  bool _shown = false;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) {
      return false;
    }
    if (!_shown) {
      setState(() => _shown = true);
    }
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 1600), () {
      if (mounted && !_dragging) {
        setState(() => _shown = false);
      }
    });
    return false;
  }

  /// The year at [offset] of the list
  int? _yearAt(double offset) {
    final labels = widget.labels;
    var low = 0;
    var high = labels.length - 1;
    var found = 0;
    while (low <= high) {
      final middle = (low + high) ~/ 2;
      if (labels[middle].offset <= offset) {
        found = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return labels.isEmpty ? null : labels[found].year;
  }

  void _dragTo(double dy, double height) {
    final controller = widget.controller;
    if (!controller.hasClients) {
      return;
    }
    final fraction = ((dy - _handleHeight / 2) / max(1, height - _handleHeight)).clamp(0.0, 1.0);
    controller.jumpTo(fraction * controller.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Stack(
        children: [
          widget.child,
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: _width,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final height = constraints.maxHeight;
                // Only while it shows: a drag of the list along the edge does not jump
                final active = _shown || _dragging;
                return GestureDetector(
                  key: const Key('plex_films_scrubber'),
                  behavior: active ? HitTestBehavior.opaque : HitTestBehavior.translucent,
                  onVerticalDragStart: active
                      ? (details) {
                          _hide?.cancel();
                          setState(() => _dragging = true);
                          _dragTo(details.localPosition.dy, height);
                        }
                      : null,
                  onVerticalDragUpdate: active ? (details) => _dragTo(details.localPosition.dy, height) : null,
                  onVerticalDragEnd: active
                      ? (_) {
                          setState(() => _dragging = false);
                          _onScroll(ScrollUpdateNotification(metrics: widget.controller.position, context: context));
                        }
                      : null,
                  child: AnimatedOpacity(
                    opacity: _shown || _dragging ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: AnimatedBuilder(
                      animation: widget.controller,
                      builder: (context, _) => _track(context, height),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _track(BuildContext context, double height) {
    final controller = widget.controller;
    if (!controller.hasClients || !controller.position.hasContentDimensions) {
      return const SizedBox.shrink();
    }
    final position = controller.position;
    final extent = max(1.0, position.maxScrollExtent);
    final fraction = (position.pixels / extent).clamp(0.0, 1.0);
    final top = fraction * (height - _handleHeight);
    final year = _yearAt(position.pixels);
    final total = position.maxScrollExtent + position.viewportDimension;
    final colors = context.colorScheme;
    // The years along the edge while dragging, one every 28 pixels at most
    final marks = <Widget>[];
    if (_dragging) {
      var last = double.negativeInfinity;
      for (final label in widget.labels) {
        final y = label.offset / max(1, total) * height;
        if (y - last < 28 || y > height - 16) {
          continue;
        }
        last = y;
        marks.add(
          Positioned(
            right: _width + 4,
            top: y,
            child: Text(
              label.year == null ? '?' : '${label.year}',
              style: context.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        );
      }
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ...marks,
        Positioned(
          right: 4,
          top: top,
          child: Container(
            width: _width - 8,
            height: _handleHeight,
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: const BorderRadius.all(Radius.circular(14)),
              boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
            ),
            child: Icon(Icons.unfold_more_rounded, size: 18, color: colors.onPrimaryContainer),
          ),
        ),
        if (_dragging)
          Positioned(
            right: _width + 4,
            top: max(0, top + _handleHeight / 2 - 18),
            child: Material(
              key: const Key('plex_films_scrubber_year'),
              color: colors.primary,
              borderRadius: const BorderRadius.all(Radius.circular(18)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Text(
                  year == null ? context.t.plex_films_year_unknown : '$year',
                  style: context.textTheme.titleMedium?.copyWith(color: colors.onPrimary, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
