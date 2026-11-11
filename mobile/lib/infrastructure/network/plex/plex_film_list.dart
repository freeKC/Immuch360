// The films of a Plex film library (lot A1 of the films study, 10 November 2026): one list of every film of the
// library, newest year first, read page by page from /library/sections/{key}/all?type=1, with the year breaks of the
// whole list known first from one light pass over it (the years only), as the Immich timeline lays out its buckets
// before it loads the assets. Plain Dart without I/O; PlexFileSystem asks the server (see PlexFilmsSource).
//
// Each film gets a path of its own in the file system of its server, /.films/<section>/<ratingKey>/<partId>/<file>,
// stable whatever page lists it, so that the media bridge, the players, the uploads to Immich and the watch records
// treat it as any file of the share. PlexFileSystem finds the part of such a path again through
// /library/metadata/{ratingKey} when the path was not listed by this connection (a page opened again after a restart).
//
// Titles, years and the server's answers are shown to the user only: never logged, never stored, never sent anywhere
// but to the server they came from (Plex's terms call its metadata Content).

import 'package:collection/collection.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/infrastructure/network/entry_names.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart';

/// The order of a films list, as Plex sorts it
enum PlexFilmListSort {
  /// The default of the films page: the newest year first, then the titles in Plex's order ("The", "Le", "La" left
  /// out of it) within a year
  yearNewest('year:desc,titleSort'),

  /// The oldest year first
  yearOldest('year,titleSort');

  const PlexFilmListSort(this.plex);

  /// The value of the sort parameter of /all
  final String plex;
}

/// What a films list asks the server for: the films of the section [sectionKey], in the order [sort], those whose
/// title holds [title] when it is given, narrowed by [filters]
class PlexFilmListQuery {
  const PlexFilmListQuery({
    required this.sectionKey,
    this.sort = PlexFilmListSort.yearNewest,
    this.title,
    this.filters = const {},
  });

  final String sectionKey;
  final PlexFilmListSort sort;

  /// The text typed in the search field; Plex's "=" on a text field means "contains"
  final String? title;

  /// More parameters of /all, read from the filters the server gives (lot A2: "year", "decade", "contentRating",
  /// "unwatched"...), never built from a guess. A name holds its operator when it has one ("year>>" for after a year).
  final Map<String, String> filters;

  /// The page size of the films pages, read as the list scrolls
  static const pageSize = 100;

  /// The page size of the light pass that gives the years
  static const yearsPageSize = 1000;

  /// The films a library lists at most: beyond, the first ones only
  static const maxFilms = 50000;

  /// The elements left out of the light pass: everything inside an item (python-plexapi's own list, plus the pictures
  /// and the colours), which leaves the item's attributes, a few hundred bytes a film
  static const lightElements =
      'Media,Genre,Country,Guid,Rating,Collection,Director,Writer,Role,Producer,Similar,Style,Mood,Format,Image,'
      'UltraBlurColors,Label,Field';
  static const lightFields = 'summary,tagline';

  /// The parameters a query cannot take from [filters]: they are the query's own
  static const _own = {'type', 'sort', 'includeCollections', 'title', 'excludeElements', 'excludeFields'};

  String get path => '/library/sections/${Uri.encodeComponent(sectionKey)}/all';

  String? get searchedTitle {
    final text = title?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// The query of /all: films only (type 1), in [sort], without the collections standing for their films (a library
  /// set to hide the items of its collections), [filters], the title searched; [light] for the pass of the years
  Map<String, String> queryParameters({bool light = false}) => {
    'type': '1',
    'sort': sort.plex,
    'includeCollections': '0',
    for (final MapEntry(:key, :value) in filters.entries)
      if (!_own.contains(key)) key: value,
    'title': ?searchedTitle,
    if (light) 'excludeElements': lightElements,
    if (light) 'excludeFields': lightFields,
  };

  PlexFilmListQuery copyWith({
    PlexFilmListSort? sort,
    String? title,
    bool clearTitle = false,
    Map<String, String>? filters,
  }) => PlexFilmListQuery(
    sectionKey: sectionKey,
    sort: sort ?? this.sort,
    title: clearTitle ? null : (title ?? this.title),
    filters: filters ?? this.filters,
  );

  @override
  bool operator ==(Object other) =>
      other is PlexFilmListQuery &&
      other.sectionKey == sectionKey &&
      other.sort == sort &&
      other.searchedTitle == searchedTitle &&
      const MapEquality<String, String>().equals(other.filters, filters);

  @override
  int get hashCode => Object.hash(sectionKey, sort, searchedTitle, const MapEquality<String, String>().hash(filters));
}

/// One film of a listing: what its poster, its caption and its page need, and its files
class PlexFilm {
  const PlexFilm({
    required this.ratingKey,
    required this.title,
    this.titleSort,
    this.originalTitle,
    this.year,
    this.thumb,
    this.addedAt,
    this.durationMs,
    this.viewOffsetMs,
    this.viewCount = 0,
    this.contentRating,
    this.librarySectionId,
    this.parts = const [],
  });

  /// The id of the film on its server (/library/metadata/{ratingKey}); a new one when the film is removed and added
  /// again
  final String ratingKey;
  final String title;
  final String? titleSort;

  /// The title in the film's own language, when the library's language gives another one
  final String? originalTitle;
  final int? year;

  /// The request path of its poster, for the photo transcoder of the server
  final String? thumb;
  final DateTime? addedAt;
  final int? durationMs;

  /// Where the account of the token stopped watching it, by Plex
  final int? viewOffsetMs;
  final int viewCount;

  /// The audience rating as the agent wrote it ("fr/12", "PG-13"), for the filters of lot A2
  final String? contentRating;
  final String? librarySectionId;

  /// Its files: one per version and per part, the first one is played
  final List<PlexFileItem> parts;

  PlexFileItem? get part => parts.firstOrNull;
}

/// The film of one element of a listing, null when it is no film (a collection, a folder) or has no id
PlexFilm? parsePlexFilm(Map<String, Object?> element) {
  if (!_isFilm(element)) {
    return null;
  }
  final ratingKey = _string(element['ratingKey'])!;
  final title = _string(element['title'])!.trim();
  final added = _int(element['addedAt']);
  final year = _int(element['year']);
  return PlexFilm(
    ratingKey: ratingKey,
    title: title,
    titleSort: _string(element['titleSort']),
    originalTitle: _string(element['originalTitle']),
    year: year != null && year > 0 ? year : null,
    thumb: _string(element['thumb']),
    addedAt: added != null && added > 0 ? DateTime.fromMillisecondsSinceEpoch(added * 1000, isUtc: true) : null,
    durationMs: _int(element['duration']),
    viewOffsetMs: _int(element['viewOffset']),
    viewCount: _int(element['viewCount']) ?? 0,
    contentRating: _string(element['contentRating']),
    librarySectionId: _string(element['librarySectionID']),
    parts: plexPartsOf(element),
  );
}

/// One page of films
class PlexFilmListPage {
  const PlexFilmListPage({required this.films, required this.count, required this.offset, this.totalSize});

  final List<PlexFilm> films;

  /// The elements the page held, those left out included: what the next page starts after
  final int count;
  final int offset;

  /// Null when the server does not tell
  final int? totalSize;
}

PlexFilmListPage parsePlexFilmListPage(Object? json) {
  final elements = _metadata(json);
  final container = _container(json);
  return PlexFilmListPage(
    films: [for (final element in elements) ?parsePlexFilm(element)],
    count: elements.length,
    offset: _int(container?['offset']) ?? 0,
    totalSize: _total(container),
  );
}

/// One page of the light pass: the year of each element in the order of the list (null for a film without one)
typedef PlexYearsPage = ({List<int?> years, int count, int offset, int? totalSize});

PlexYearsPage parsePlexYearsPage(Object? json) {
  final elements = _metadata(json);
  final container = _container(json);
  return (
    years: [
      for (final element in elements)
        if (_isFilm(element)) _positiveYear(element['year']),
    ],
    count: elements.length,
    offset: _int(container?['offset']) ?? 0,
    totalSize: _total(container),
  );
}

/// The films of a search of the whole server (/hubs/search) that belong to the section [sectionKey]: the items of
/// its film hub. The query "gives context" only, the other libraries answer too.
List<PlexFilm> parsePlexHubFilms(Object? json, String sectionKey) {
  final hubs = _container(json)?['Hub'];
  if (hubs is! List) {
    return const [];
  }
  final films = <PlexFilm>[];
  for (final hub in hubs.whereType<Map>()) {
    final type = hub['type'];
    final items = hub['Metadata'];
    if ((type != null && type != 'movie') || items is! List) {
      continue;
    }
    for (final item in items.whereType<Map>()) {
      final film = parsePlexFilm(item.cast<String, Object?>());
      if (film == null) {
        continue;
      }
      final section = film.librarySectionId;
      if (section == null || section == sectionKey) {
        films.add(film);
      }
    }
  }
  return films;
}

/// The years of a films list as Immich lays out its buckets: one group per run of the same year in the order of the
/// list, with its count and the index of its first film. Films without a year make a group of their own (null).
class PlexFilmYear {
  const PlexFilmYear({required this.year, required this.count, required this.firstIndex});

  final int? year;
  final int count;
  final int firstIndex;

  int get endIndex => firstIndex + count;

  @override
  bool operator ==(Object other) =>
      other is PlexFilmYear && other.year == year && other.count == count && other.firstIndex == firstIndex;

  @override
  int get hashCode => Object.hash(year, count, firstIndex);

  @override
  String toString() => 'PlexFilmYear($year, $count from $firstIndex)';
}

/// The year groups of [years], the year of each film in the order of the list
List<PlexFilmYear> plexFilmYears(Iterable<int?> years) {
  final groups = <PlexFilmYear>[];
  int? current;
  var count = 0;
  var first = 0;
  var index = 0;
  for (final year in years) {
    if (count > 0 && year != current) {
      groups.add(PlexFilmYear(year: current, count: count, firstIndex: first));
      count = 0;
    }
    if (count == 0) {
      current = year;
      first = index;
    }
    count++;
    index++;
  }
  if (count > 0) {
    groups.add(PlexFilmYear(year: current, count: count, firstIndex: first));
  }
  return groups;
}

/// [a] before [b] in [sort], for the lists made on the device (a search): Plex's sort title, case left aside, films
/// without a year last
int comparePlexFilms(PlexFilm a, PlexFilm b, PlexFilmListSort sort) {
  final ya = a.year;
  final yb = b.year;
  if (ya != yb) {
    if (ya == null) {
      return 1;
    }
    if (yb == null) {
      return -1;
    }
    return sort == PlexFilmListSort.yearOldest ? ya.compareTo(yb) : yb.compareTo(ya);
  }
  return (a.titleSort ?? a.title).toLowerCase().compareTo((b.titleSort ?? b.title).toLowerCase());
}

/// The results of a search: the films whose title holds the text ([contains], from /all?title=), then those the
/// server's spelling tolerant search adds ([hubs], from /hubs/search), each once, in the order of [sort]
List<PlexFilm> mergePlexSearch(List<PlexFilm> contains, List<PlexFilm> hubs, PlexFilmListSort sort) {
  final seen = <String>{};
  final films = [
    for (final film in [...contains, ...hubs])
      if (seen.add(film.ratingKey)) film,
  ];
  films.sort((a, b) => comparePlexFilms(a, b, sort));
  return films;
}

/// The first folder of the paths of the films, hidden from every listing (a dot name); the same paths as the film page
/// of lot A2 builds (its plexFilmsFolder)
const plexFilmsRoot = '/.films';

/// The path of the file [part] of the film [ratingKey] in the section [sectionKey]:
/// /.films/{section}/{ratingKey}/{partId}/{file name}, the same whatever lists it (the films page, a search, the film
/// page). PlexFileSystem finds the film behind it through /library/metadata/{ratingKey} when it has not met it.
String plexFilmPartPath(String sectionKey, String ratingKey, PlexFileItem part) =>
    '$plexFilmsRoot/${safeEntryName(sectionKey)}/${safeEntryName(ratingKey)}/${part.partId ?? 0}/'
    '${safeEntryName(part.name)}';

/// What a path of [plexFilmPartPath] names, null for any other path (a Plex ratingKey is a number)
({String sectionKey, String ratingKey, int partId})? plexFilmPathParts(String path) {
  final segments = path.split('/').where((segment) => segment.isNotEmpty).toList();
  if (segments.length != 5 || '/${segments.first}' != plexFilmsRoot) {
    return null;
  }
  final partId = int.tryParse(segments[3]);
  if (partId == null || !RegExp(r'^\d+$').hasMatch(segments[2])) {
    return null;
  }
  return (sectionKey: segments[1], ratingKey: segments[2], partId: partId);
}

/// The entry of the file a film plays (its first part), at its path of [plexFilmPartPath]; null for a film without a file
NetworkEntry? plexFilmEntry(String sourceId, String sectionKey, PlexFilm film) {
  final part = film.part;
  if (part == null) {
    return null;
  }
  return plexFilmPartEntry(sourceId, plexFilmPartPath(sectionKey, film.ratingKey, part), part, title: film.title);
}

/// The entry of the file [part] at [path], with the title the server gives
NetworkEntry plexFilmPartEntry(String sourceId, String path, PlexFileItem part, {String? title, int? knownSize}) =>
    NetworkEntry(
      sourceId: sourceId,
      path: path,
      isDirectory: false,
      size: part.size ?? knownSize,
      modified: part.addedAt,
      mimeType: part.mimeType,
      width: part.width,
      height: part.height,
      durationMs: part.durationMs,
      title: title ?? part.title,
    );

/// A film library of a Plex server, for the Films button of the Library tab
typedef PlexFilmLibrary = ({String sourceId, String serverName, PlexSection section, String folderPath});

/// What the films page reads of a Plex server: PlexFileSystem, a fake in the tests
abstract interface class PlexFilmsSource {
  /// The id of the source of the server, for the entries of its films
  String get filmsSourceId;

  /// Whether the server is read through its address outside home
  bool get isOutsideHome;

  /// The year of every film of [query] in its order, from the light pass (pages of [PlexFilmListQuery.yearsPageSize])
  Future<List<int?>> filmYears(PlexFilmListQuery query);

  /// The films of [query] from [start], [size] of them at most; their files get their paths in the file system
  Future<PlexFilmListPage> filmsPage(PlexFilmListQuery query, {required int start, required int size});

  /// The films of the section that the server's spelling tolerant search finds for [text]; empty when the server has
  /// no such search
  Future<List<PlexFilm>> searchFilms(String sectionKey, String text);

  /// The film libraries of the server, with the path of the folder of each at the root of the share
  Future<List<({PlexSection section, String folderPath})>> filmLibraries();

  /// The film library whose folder is [path] at the root of the share, once the root was listed: what the folder view
  /// opens on its films page rather than on its folders; null for any other path
  PlexSection? filmLibraryAt(String path);
}

/// Whether [element] of a listing is a film the list shows: one rule for the light pass and the pages, so that the
/// index of a film among the years is its index among the pages
bool _isFilm(Map<String, Object?> element) {
  final type = _string(element['type']);
  final title = _string(element['title'])?.trim();
  return _string(element['ratingKey']) != null &&
      (type == null || type == 'movie') &&
      title != null &&
      title.isNotEmpty;
}

Map<String, Object?>? _container(Object? json) {
  final container = json is Map ? json['MediaContainer'] : null;
  return container is Map ? container.cast<String, Object?>() : null;
}

List<Map<String, Object?>> _metadata(Object? json) {
  final container = _container(json);
  final list = container?['Metadata'];
  return list is List ? [for (final element in list.whereType<Map>()) element.cast<String, Object?>()] : const [];
}

int? _total(Map<String, Object?>? container) {
  final total = _int(container?['totalSize']);
  return total != null && total >= 0 ? total : null;
}

int? _positiveYear(Object? value) {
  final year = _int(value);
  return year != null && year > 0 ? year : null;
}

String? _string(Object? value) => switch (value) {
  final String text when text.isNotEmpty => text,
  final num number => '$number',
  _ => null,
};

int? _int(Object? value) => switch (value) {
  final int number => number,
  final double number when number.isFinite => number.round(),
  final String text => int.tryParse(text),
  _ => null,
};
