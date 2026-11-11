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
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart';

/// The order of a films list, as Plex sorts it
enum PlexFilmSort {
  /// The default of the films page: the newest year first, then the titles in Plex's order ("The", "Le", "La" left
  /// out of it) within a year
  yearNewest('year:desc,titleSort'),

  /// The oldest year first
  yearOldest('year,titleSort');

  const PlexFilmSort(this.plex);

  /// The value of the sort parameter of /all
  final String plex;
}

/// What a films list asks the server for: the films of the section [sectionKey], in the order [sort], those whose
/// title holds [title] when it is given, narrowed by [filters]
class PlexFilmsQuery {
  const PlexFilmsQuery({required this.sectionKey, this.sort = PlexFilmSort.yearNewest, this.title, this.filters = const {}});

  final String sectionKey;
  final PlexFilmSort sort;

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
    if (searchedTitle case final text?) 'title': text,
    if (light) 'excludeElements': lightElements,
    if (light) 'excludeFields': lightFields,
  };

  PlexFilmsQuery copyWith({PlexFilmSort? sort, String? title, bool clearTitle = false, Map<String, String>? filters}) =>
      PlexFilmsQuery(
        sectionKey: sectionKey,
        sort: sort ?? this.sort,
        title: clearTitle ? null : (title ?? this.title),
        filters: filters ?? this.filters,
      );

  @override
  bool operator ==(Object other) =>
      other is PlexFilmsQuery &&
      other.sectionKey == sectionKey &&
      other.sort == sort &&
      other.searchedTitle == searchedTitle &&
      const MapEquality<String, String>().equals(other.filters, filters);

  @override
  int get hashCode =>
      Object.hash(sectionKey, sort, searchedTitle, const MapEquality<String, String>().hash(filters));
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
  final ratingKey = _string(element['ratingKey']);
  final type = _string(element['type']);
  final title = _string(element['title'])?.trim();
  if (ratingKey == null || (type != null && type != 'movie') || title == null || title.isEmpty) {
    return null;
  }
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
class PlexFilmsPage {
  const PlexFilmsPage({required this.films, required this.count, required this.offset, this.totalSize});

  final List<PlexFilm> films;

  /// The elements the page held, those left out included: what the next page starts after
  final int count;
  final int offset;

  /// Null when the server does not tell
  final int? totalSize;
}

PlexFilmsPage parsePlexFilmsPage(Object? json) {
  final elements = _metadata(json);
  final container = _container(json);
  return PlexFilmsPage(
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
        if (_string(element['type']) case null || 'movie') _positiveYear(element['year']),
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
int comparePlexFilms(PlexFilm a, PlexFilm b, PlexFilmSort sort) {
  final ya = a.year;
  final yb = b.year;
  if (ya != yb) {
    if (ya == null) {
      return 1;
    }
    if (yb == null) {
      return -1;
    }
    return sort == PlexFilmSort.yearOldest ? ya.compareTo(yb) : yb.compareTo(ya);
  }
  return (a.titleSort ?? a.title).toLowerCase().compareTo((b.titleSort ?? b.title).toLowerCase());
}

/// The results of a search: the films whose title holds the text ([contains], from /all?title=), then those the
/// server's spelling tolerant search adds ([hubs], from /hubs/search), each once, in the order of [sort]
List<PlexFilm> mergePlexSearch(List<PlexFilm> contains, List<PlexFilm> hubs, PlexFilmSort sort) {
  final seen = <String>{};
  final films = [
    for (final film in [...contains, ...hubs])
      if (seen.add(film.ratingKey)) film,
  ];
  films.sort((a, b) => comparePlexFilms(a, b, sort));
  return films;
}

/// The first folder of the paths of the films, hidden from every listing (a dot name)
const plexFilmsFolder = '/.films';

/// The path of the file [part] of [film] in the section [sectionKey]: /.films/<section>/<ratingKey>/<partId>/<file>
String plexFilmPath(String sectionKey, String ratingKey, PlexFileItem part) =>
    '$plexFilmsFolder/${Uri.encodeComponent(sectionKey)}/${Uri.encodeComponent(ratingKey)}/${part.partId ?? 0}/'
    '${part.name}';

/// What a path of [plexFilmPath] names, null for any other path
({String sectionKey, String ratingKey, int partId})? parsePlexFilmPath(String path) {
  if (!path.startsWith('$plexFilmsFolder/')) {
    return null;
  }
  final segments = path.substring(plexFilmsFolder.length + 1).split('/');
  if (segments.length != 4 || segments.any((segment) => segment.isEmpty)) {
    return null;
  }
  final partId = int.tryParse(segments[2]);
  if (partId == null) {
    return null;
  }
  try {
    return (
      sectionKey: Uri.decodeComponent(segments[0]),
      ratingKey: Uri.decodeComponent(segments[1]),
      partId: partId,
    );
  } on ArgumentError {
    return null;
  }
}

/// The entry of the file a film plays (its first part), at its path of [plexFilmPath]; null for a film without a file
NetworkEntry? plexFilmEntry(String sourceId, String sectionKey, PlexFilm film) {
  final part = film.part;
  if (part == null) {
    return null;
  }
  return plexFilmPartEntry(sourceId, plexFilmPath(sectionKey, film.ratingKey, part), part, title: film.title);
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

  /// The year of every film of [query] in its order, from the light pass (pages of [PlexFilmsQuery.yearsPageSize])
  Future<List<int?>> filmYears(PlexFilmsQuery query);

  /// The films of [query] from [start], [size] of them at most; their files get their paths in the file system
  Future<PlexFilmsPage> filmsPage(PlexFilmsQuery query, {required int start, required int size});

  /// The films of the section that the server's spelling tolerant search finds for [text]; empty when the server has
  /// no such search
  Future<List<PlexFilm>> searchFilms(String sectionKey, String text);

  /// The film libraries of the server, with the path of the folder of each at the root of the share
  Future<List<({PlexSection section, String folderPath})>> filmLibraries();
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
