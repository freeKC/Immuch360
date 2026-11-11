// The films list of a Plex film library for its films page (lot A1 of the films study): the years of the whole list
// first, then the films page by page as the grid shows their rows, as the Immich timeline lays out its buckets before
// it loads its assets. A search makes a list of its own, all in memory: the films whose title holds the text, and
// those the server's spelling tolerant search adds.

import 'dart:async';
import 'dart:math';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_list.dart';
import 'package:immich_mobile/presentation/pages/network/plex_film_menu_actions.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:logging/logging.dart';

final _log = Logger('PlexFilms');

/// Opens the films of the Plex server of the source [sourceId]: its connection, which reads them
typedef PlexFilmsSourceOpener = Future<PlexFilmsSource> Function(String sourceId);

final plexFilmsSourceProvider = Provider<PlexFilmsSourceOpener>((ref) {
  final connections = ref.watch(networkConnectionsProvider);
  return (sourceId) async {
    final fileSystem = await connections.fileSystem(sourceId);
    if (fileSystem is! PlexFilmsSource) {
      throw const NetworkFileSystemException('This share is no Plex server');
    }
    return fileSystem as PlexFilmsSource;
  };
});

/// The library of a films page: the source of its server and its section
typedef PlexFilmLibraryKey = ({String sourceId, String sectionKey});

/// The filters of the films page of a library, parameters of /all read from the filters the server gives (the filter
/// sheet of lot A2 sets them, its PlexFilmsQuery.toQueryParameters); empty for every film. Kept while the page is open.
final plexFilmFiltersProvider = StateProvider.autoDispose.family<Map<String, String>, PlexFilmLibraryKey>(
  (ref, key) => const {},
);

/// What a long press on a film offers beside Play, added by other lots: Download (lot B) and "Play on..." (lot C)
final plexFilmMenuActionsProvider = Provider<List<PlexFilmMenuAction>>((ref) => plexFilmMenuActions);

/// The film a menu action is for
typedef PlexFilmMenuTarget = ({String sourceId, String sectionKey, PlexFilm film, NetworkEntry entry});

/// The page a tap on a poster opens; null for the video page of today, which plays the film at once
typedef PlexFilmOpenRoute = PageRouteInfo? Function(PlexFilmMenuTarget target);

/// What a tap on a poster of the films page opens: the film page of lot A2, for the file Play opens there (the path
/// of the entry, the same as plexFilmPath of lot A2 builds, so that both pages share one watch record)
final plexFilmOpenRouteProvider = Provider<PlexFilmOpenRoute>(
  (ref) =>
      (target) => PlexFilmRoute(sourceId: target.sourceId, ratingKey: target.film.ratingKey, path: target.entry.path),
);

/// One line of the long press menu of a film
class PlexFilmMenuAction {
  const PlexFilmMenuAction({required this.icon, required this.label, required this.onSelected, this.isShown});

  final IconData icon;
  final String Function(BuildContext context) label;
  final Future<void> Function(BuildContext context, WidgetRef ref, PlexFilmMenuTarget target) onSelected;

  /// Whether the line shows for [target]; always when null
  final bool Function(WidgetRef ref, PlexFilmMenuTarget target)? isShown;
}

/// The films a page shows: how many, their year groups, and each film once it came. Tells its listeners when films
/// come.
abstract class PlexFilmsList extends ChangeNotifier {
  int get count;

  /// The year groups of the list, in its order (see plexFilmYears)
  List<PlexFilmYear> get years;

  /// The film at [index], null while its page has not come
  PlexFilm? filmAt(int index);

  /// Asks for the page of the film at [index] when it did not come yet: the grid calls it for the rows it builds
  void want(int index) {}

  /// Whether pages could not be read: the page offers to try them again
  bool get hasFailures => false;

  /// Tries the pages that failed again, as the rows ask for them
  void retryFailures() {}

  /// The films around [index] that came, at most [radius] each way, with the index of the one at [index] among them
  ({List<PlexFilm> films, int index}) around(int index, {int radius = 50}) {
    final films = <PlexFilm>[];
    var position = -1;
    for (var i = max(0, index - radius); i < min(count, index + radius + 1); i++) {
      final film = filmAt(i);
      if (film == null) {
        continue;
      }
      if (i == index) {
        position = films.length;
      }
      films.add(film);
    }
    return (films: films, index: position);
  }
}

/// The films of a whole library, read page by page: the years first ([load]), then the pages as the grid wants them,
/// [maxConcurrent] at a time, the last ones asked first (the rows on screen after a fling)
class PagedPlexFilms extends PlexFilmsList {
  PagedPlexFilms._(this._source, this.query, this.years, this.count, this.pageSize, this.maxConcurrent);

  /// The years of [query] from its light pass, and its first page, asked together: the page shows once both came
  static Future<PagedPlexFilms> load(
    PlexFilmsSource source,
    PlexFilmListQuery query, {
    int pageSize = PlexFilmListQuery.pageSize,
    int maxConcurrent = 2,
  }) async {
    final watch = Stopwatch()..start();
    final first = source.filmsPage(query, start: 0, size: pageSize);
    // The first page's error, when the years fail first, is no unhandled one
    first.ignore();
    final years = await source.filmYears(query);
    final list = PagedPlexFilms._(source, query, plexFilmYears(years), years.length, pageSize, maxConcurrent);
    if (list.count > 0) {
      try {
        list._pages[0] = (await first).films;
      } catch (error) {
        // The rows ask for it again
        _log.info('The first page of the films could not be read: ${error.runtimeType}');
      }
    }
    _log.fine('${list.count} films in ${list.years.length} year groups in ${watch.elapsedMilliseconds} ms');
    return list;
  }

  final PlexFilmsSource _source;
  final PlexFilmListQuery query;
  final int pageSize;
  final int maxConcurrent;

  @override
  final List<PlexFilmYear> years;

  @override
  final int count;

  final Map<int, List<PlexFilm>> _pages = {};
  final Set<int> _loading = {};
  final Set<int> _failed = {};

  /// The pages asked for and not loading yet, the last asked at the end
  final List<int> _queue = [];
  bool _disposed = false;

  /// The pages read so far, for the tests
  @visibleForTesting
  Iterable<int> get loadedPages => _pages.keys;

  @override
  bool get hasFailures => _failed.isNotEmpty;

  @override
  PlexFilm? filmAt(int index) {
    if (index < 0 || index >= count) {
      return null;
    }
    final page = _pages[index ~/ pageSize];
    final offset = index % pageSize;
    return page != null && offset < page.length ? page[offset] : null;
  }

  @override
  void want(int index) {
    if (_disposed || index < 0 || index >= count) {
      return;
    }
    final page = index ~/ pageSize;
    if (_pages.containsKey(page) || _loading.contains(page) || _failed.contains(page)) {
      return;
    }
    _queue
      ..remove(page)
      ..add(page);
    _pump();
  }

  @override
  void retryFailures() {
    if (_failed.isEmpty) {
      return;
    }
    _failed.clear();
    notifyListeners();
  }

  void _pump() {
    while (_loading.length < maxConcurrent && _queue.isNotEmpty) {
      unawaited(_read(_queue.removeLast()));
    }
  }

  Future<void> _read(int page) async {
    _loading.add(page);
    try {
      final read = await _source.filmsPage(query, start: page * pageSize, size: pageSize);
      if (!_disposed) {
        _pages[page] = read.films;
      }
    } catch (error) {
      if (!_disposed) {
        _failed.add(page);
        _log.info('A page of the films could not be read: ${error.runtimeType}');
      }
    } finally {
      _loading.remove(page);
      if (!_disposed) {
        notifyListeners();
        _pump();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _queue.clear();
    super.dispose();
  }
}

/// A list made on the device, all of it in memory: the results of a search
class StaticPlexFilms extends PlexFilmsList {
  StaticPlexFilms(this.films) : years = plexFilmYears(films.map((film) => film.year));

  final List<PlexFilm> films;

  @override
  final List<PlexFilmYear> years;

  @override
  int get count => films.length;

  @override
  PlexFilm? filmAt(int index) => index >= 0 && index < films.length ? films[index] : null;
}

/// The films of [query] whose title holds its text (Plex's /all?title=, the filters kept), then those the server's
/// spelling tolerant search adds when no filter is on (its search knows no filter); [maxContains] of the first at most
const plexSearchMaxContains = 500;

Future<StaticPlexFilms> searchPlexFilms(PlexFilmsSource source, PlexFilmListQuery query) async {
  final text = query.searchedTitle;
  if (text == null) {
    return StaticPlexFilms(const []);
  }
  final watch = Stopwatch()..start();
  final hubs = query.filters.isEmpty ? _tolerantSearch(source, query.sectionKey, text) : Future.value(<PlexFilm>[]);
  final contains = <PlexFilm>[];
  var start = 0;
  while (start < plexSearchMaxContains) {
    final page = await source.filmsPage(query, start: start, size: PlexFilmListQuery.pageSize);
    contains.addAll(page.films);
    if (page.count <= 0) {
      break;
    }
    start += page.count;
    final total = page.totalSize;
    if (total == null ? page.count < PlexFilmListQuery.pageSize : start >= total) {
      break;
    }
  }
  final films = mergePlexSearch(contains, await hubs, query.sort);
  _log.fine('Search: ${films.length} films in ${watch.elapsedMilliseconds} ms');
  return StaticPlexFilms(films);
}

/// The server's spelling tolerant search, which never fails the search: the films that hold the text come anyway
Future<List<PlexFilm>> _tolerantSearch(PlexFilmsSource source, String sectionKey, String text) async {
  try {
    return await source.searchFilms(sectionKey, text);
  } catch (error) {
    _log.info('The spelling tolerant search did not answer: ${error.runtimeType}');
    return const [];
  }
}
