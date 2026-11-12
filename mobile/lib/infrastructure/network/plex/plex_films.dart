// What a Plex Media Server tells of the films of a movie library, beyond the folder view of plex_api.dart: the full
// item of one film (/library/metadata/{ratingKey}: synopsis, cast, the streams of each file, the ids of the film at
// IMDb and TMDB), the filters of a library (/library/sections/{id}/filters and the values behind each one), and the
// query of a filtered list of films (/library/sections/{id}/all?type=1). Plain Dart without I/O, like plex_api.dart:
// the requests are made by PlexFileSystem. Shapes after the official reference (https://developer.plex.tv/pms/, schemas
// metadata, media, part, stream, filter) and python-plexapi; checked against no server yet (study of 10 November 2026,
// store/m2/plex-films-2026-11-10/plex-api.md section 12 lists the captures to make).
//
// What these answers hold is the owner's library: it is shown to the user of the device and never copied out of the
// app's memory (Plex's terms call metadata Content), logged or sent anywhere else. The film's IMDb or TMDB number alone
// goes to Wikidata when the film page asks for its Wikipedia article (wikipedia_film_client.dart).

import 'package:immich_mobile/infrastructure/network/entry_names.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart' show plexPersonalMediaAgents;

/// Whether a section of [type] matched by [agent] is a library of films: a movie section whose agent looks the films
/// up (Plex Movie, the legacy IMDb and TMDB agents). A section without an agent counts as one.
bool isPlexFilmLibrary(String type, String? agent) => type == 'movie' && !plexPersonalMediaAgents.contains(agent);

/// The kind of a stream of a part (Plex streamType)
enum PlexStreamType { video, audio, subtitle, other }

/// One stream of a file: a track inside it, or a side file Plex knows (a subtitle next to the film, or one it
/// downloaded), which has a [key] of its own
class PlexStream {
  const PlexStream({
    required this.id,
    required this.type,
    this.index,
    this.key,
    this.codec,
    this.profile,
    this.language,
    this.languageCode,
    this.languageTag,
    this.title,
    this.displayTitle,
    this.extendedDisplayTitle,
    this.channels,
    this.isDefault = false,
    this.selected = false,
    this.forced = false,
    this.hearingImpaired = false,
  });

  /// The id of the stream, what PUT /library/parts/{id} takes
  final int id;
  final PlexStreamType type;

  /// Its place in the file (an embedded track), null for a side file
  final int? index;

  /// The request path of a stream that is a file of its own ("/library/streams/123"), null for one inside the file
  final String? key;
  final String? codec;

  /// The profile of its codec as the server names it ("high 10", "main 10", "advanced simple", "ma" for DTS-HD
  /// Master Audio), what the choice of the player reads (film_player_choice.dart)
  final String? profile;

  /// The name of its language in the server's words ("Français"), its three letter code ("fra"), its BCP 47 tag ("fr")
  final String? language;
  final String? languageCode;
  final String? languageTag;
  final String? title;

  /// The server's line for it ("Français (AC3 5.1)", "English (SRT External)"), and the longer one with its title and
  /// Forced
  final String? displayTitle;
  final String? extendedDisplayTitle;
  final int? channels;
  final bool isDefault;

  /// The stream the account picked last, in any Plex app
  final bool selected;
  final bool forced;
  final bool hearingImpaired;

  /// A subtitle file of its own beside the film, which the players do not see in the file
  bool get isSidecar => type == PlexStreamType.subtitle && key != null;

  /// A subtitle a player can draw from a text file: the side files that are not pictures (image subtitles, PGS and
  /// VobSub, need burning in by the transcoder, which the app does not ask for)
  bool get isTextSubtitle => type == PlexStreamType.subtitle && !_imageSubtitleCodecs.contains(codec?.toLowerCase());

  /// The line of its menu: the server's longer line, else its shorter one, else its language
  String? get label => extendedDisplayTitle ?? displayTitle ?? title ?? language;
}

const _imageSubtitleCodecs = {'pgs', 'hdmv_pgs_subtitle', 'vobsub', 'dvd_subtitle', 'dvb_subtitle', 'dvdsub'};

/// One file of a version of a film
class PlexFilmPart {
  const PlexFilmPart({
    required this.id,
    required this.key,
    this.file,
    this.size,
    this.container,
    this.durationMs,
    this.streams = const [],
  });

  final int id;

  /// The request path of the bytes (/library/parts/{id}/{changestamp}/file.{ext})
  final String key;

  /// Its path on the server's disk; only its last segment is ever used, as the file's name
  final String? file;
  final int? size;
  final String? container;
  final int? durationMs;
  final List<PlexStream> streams;

  /// The last segment of [file], else null
  String? get fileName {
    final path = file;
    if (path == null) {
      return null;
    }
    final name = path.split(RegExp(r'[/\\]')).last.trim();
    return name.isEmpty ? null : name;
  }

  List<PlexStream> streamsOf(PlexStreamType type) => [
    for (final stream in streams)
      if (stream.type == type) stream,
  ];
}

/// One version of a film (Plex Media): a film in 4K and in 1080p has two
class PlexFilmMedia {
  const PlexFilmMedia({
    required this.id,
    this.videoResolution,
    this.videoCodec,
    this.audioCodec,
    this.audioChannels,
    this.container,
    this.bitrate,
    this.width,
    this.height,
    this.parts = const [],
  });

  final int? id;

  /// "1080", "4k", "sd"
  final String? videoResolution;
  final String? videoCodec;
  final String? audioCodec;
  final int? audioChannels;
  final String? container;

  /// kbit/s
  final int? bitrate;
  final int? width;
  final int? height;
  final List<PlexFilmPart> parts;
}

/// A person of the film: a director, a writer, an actor and the character played
class PlexFilmPerson {
  const PlexFilmPerson({required this.name, this.role, this.thumb});

  final String name;

  /// The character, for the cast
  final String? role;

  /// A picture of the person: an absolute address of Plex's own servers most of the time, which the app never loads
  /// (the device talks to the user's server only); a path of the server is read through its transcoder
  final String? thumb;
}

/// A rating of the film as text: its source and its value, never a logo (the logos are their owners' marks)
class PlexFilmRating {
  const PlexFilmRating({required this.source, required this.value, this.audience = false});

  /// "IMDb", "Rotten Tomatoes", "TMDB", or null when Plex does not say
  final String? source;

  /// The value as the source gives it: 0 to 10
  final double value;

  /// The audience's rating rather than the critics'
  final bool audience;

  /// The value as the source shows it: "8.7" for IMDb and TMDB, "93 %" for Rotten Tomatoes
  String get text => source == 'Rotten Tomatoes' ? '${(value * 10).round()} %' : value.toStringAsFixed(1);
}

/// The numbers of a film at IMDb and at TMDB, from its Guid elements, or from the guid of a legacy agent
class PlexExternalIds {
  const PlexExternalIds({this.imdb, this.tmdb});

  /// "tt0133093"
  final String? imdb;

  /// "603"
  final String? tmdb;

  bool get isEmpty => imdb == null && tmdb == null;
}

/// The full item of a film, from /library/metadata/{ratingKey}?includeGuids=1
class PlexFilmDetails {
  const PlexFilmDetails({
    required this.ratingKey,
    required this.title,
    this.type,
    this.originalTitle,
    this.year,
    this.tagline,
    this.summary,
    this.studio,
    this.contentRating,
    this.durationMs,
    this.viewOffsetMs,
    this.viewCount,
    this.thumb,
    this.art,
    this.genres = const [],
    this.countries = const [],
    this.directors = const [],
    this.writers = const [],
    this.roles = const [],
    this.ratings = const [],
    this.externalIds = const PlexExternalIds(),
    this.sectionKey,
    this.medias = const [],
  });

  final String ratingKey;

  /// "movie" for a film; "clip", "episode"... for other items
  final String? type;
  final String title;
  final String? originalTitle;
  final int? year;
  final String? tagline;

  /// In the language of the library, set on the server
  final String? summary;
  final String? studio;

  /// As Plex stores it: "PG-13", "fr/12", "de/16", "NR"
  final String? contentRating;
  final int? durationMs;

  /// Where the account stopped the film in a Plex app, in ms
  final int? viewOffsetMs;
  final int? viewCount;

  /// The request paths of the poster and the background, for the server's photo transcoder
  final String? thumb;
  final String? art;
  final List<String> genres;
  final List<String> countries;
  final List<PlexFilmPerson> directors;
  final List<PlexFilmPerson> writers;
  final List<PlexFilmPerson> roles;
  final List<PlexFilmRating> ratings;
  final PlexExternalIds externalIds;

  /// The library it belongs to
  final String? sectionKey;
  final List<PlexFilmMedia> medias;

  /// Every file of every version, in the server's order
  List<PlexFilmPart> get parts => [for (final media in medias) ...media.parts];

  /// The part [partId], else the first one
  PlexFilmPart? partOf(int? partId) {
    final all = parts;
    return all.where((part) => part.id == partId).firstOrNull ?? all.firstOrNull;
  }

  /// The version holding [part]
  PlexFilmMedia? mediaOf(PlexFilmPart part) => medias.where((media) => media.parts.contains(part)).firstOrNull;
}

/// The film of [json], an answer of /library/metadata/{ratingKey}; null when it holds no item
PlexFilmDetails? parsePlexFilmDetails(Object? json) {
  final container = _container(json);
  final element = _elements(json).firstOrNull;
  final ratingKey = _string(element?['ratingKey']);
  if (element == null || ratingKey == null) {
    return null;
  }
  final section = _string(element['librarySectionID']) ?? _string(container?['librarySectionID']);
  final ratings = <PlexFilmRating>[];
  final critic = _double(element['rating']);
  if (critic != null) {
    ratings.add(PlexFilmRating(source: _ratingSource(_string(element['ratingImage'])), value: critic));
  }
  final audience = _double(element['audienceRating']);
  if (audience != null) {
    ratings.add(
      PlexFilmRating(source: _ratingSource(_string(element['audienceRatingImage'])), value: audience, audience: true),
    );
  }
  return PlexFilmDetails(
    ratingKey: ratingKey,
    type: _string(element['type']),
    title: _string(element['title']) ?? '',
    originalTitle: _string(element['originalTitle']),
    year: _int(element['year']),
    tagline: _text(element['tagline']),
    summary: _text(element['summary']),
    studio: _string(element['studio']),
    contentRating: _string(element['contentRating']),
    durationMs: _int(element['duration']),
    viewOffsetMs: _int(element['viewOffset']),
    viewCount: _int(element['viewCount']),
    thumb: _string(element['thumb']),
    art: _string(element['art']),
    genres: _tags(element['Genre']),
    countries: _tags(element['Country']),
    directors: _people(element['Director']),
    writers: _people(element['Writer']),
    roles: _people(element['Role']),
    ratings: ratings,
    externalIds: parsePlexExternalIds(element),
    sectionKey: section,
    medias: [
      if (element['Media'] case final List medias)
        for (final media in medias.whereType<Map>()) _media(media.cast<String, Object?>()),
    ],
  );
}

/// The IMDb and TMDB numbers of [element]: its Guid array ("imdb://tt0088763", "tmdb://105"), else its guid when a
/// legacy agent matched it ("com.plexapp.agents.imdb://tt0088763?lang=fr", "com.plexapp.agents.themoviedb://603?lang=fr")
PlexExternalIds parsePlexExternalIds(Map<String, Object?> element) {
  String? imdb;
  String? tmdb;
  void read(String? guid) {
    if (guid == null) {
      return;
    }
    final match = RegExp(r'^([a-z.]+)://([^?/]+)').firstMatch(guid.trim().toLowerCase());
    if (match == null) {
      return;
    }
    final scheme = match.group(1)!;
    final value = match.group(2)!;
    if ((scheme == 'imdb' || scheme == 'com.plexapp.agents.imdb') && RegExp(r'^tt\d{5,}$').hasMatch(value)) {
      imdb ??= value;
    } else if ((scheme == 'tmdb' || scheme == 'com.plexapp.agents.themoviedb') && RegExp(r'^\d+$').hasMatch(value)) {
      tmdb ??= value;
    }
  }

  if (element['Guid'] case final List guids) {
    for (final guid in guids.whereType<Map>()) {
      read(_string(guid['id']));
    }
  }
  read(_string(element['guid']));
  return PlexExternalIds(imdb: imdb, tmdb: tmdb);
}

/// The source of a rating by the key of its picture ("imdb://image.rating", "rottentomatoes://image.rating.ripe",
/// "themoviedb://image.rating"), null when it names none the app knows
String? _ratingSource(String? image) {
  final scheme = image?.split('://').first.toLowerCase();
  return switch (scheme) {
    'imdb' => 'IMDb',
    'rottentomatoes' => 'Rotten Tomatoes',
    'themoviedb' || 'tmdb' => 'TMDB',
    _ => null,
  };
}

PlexFilmMedia _media(Map<String, Object?> media) => PlexFilmMedia(
  id: _int(media['id']),
  videoResolution: _string(media['videoResolution']),
  videoCodec: _string(media['videoCodec']),
  audioCodec: _string(media['audioCodec']),
  audioChannels: _int(media['audioChannels']),
  container: _string(media['container']),
  bitrate: _int(media['bitrate']),
  width: _int(media['width']),
  height: _int(media['height']),
  parts: [
    if (media['Part'] case final List parts)
      for (final part in parts.whereType<Map>())
        if (_part(part.cast<String, Object?>(), _string(media['container'])) case final PlexFilmPart parsed) parsed,
  ],
);

PlexFilmPart? _part(Map<String, Object?> part, String? container) {
  final id = _int(part['id']);
  final key = _string(part['key']);
  if (id == null || key == null) {
    return null;
  }
  return PlexFilmPart(
    id: id,
    key: key,
    file: _string(part['file']),
    size: _int(part['size']),
    container: _string(part['container']) ?? container,
    durationMs: _int(part['duration']),
    streams: [
      if (part['Stream'] case final List streams)
        for (final stream in streams.whereType<Map>())
          if (_stream(stream.cast<String, Object?>()) case final PlexStream parsed) parsed,
    ],
  );
}

PlexStream? _stream(Map<String, Object?> stream) {
  final id = _int(stream['id']);
  if (id == null) {
    return null;
  }
  final type = switch (_int(stream['streamType'])) {
    1 => PlexStreamType.video,
    2 => PlexStreamType.audio,
    3 => PlexStreamType.subtitle,
    _ => PlexStreamType.other,
  };
  return PlexStream(
    id: id,
    type: type,
    index: _int(stream['index']),
    key: _string(stream['key']),
    codec: _string(stream['codec']),
    profile: _string(stream['profile']),
    language: _string(stream['language']),
    languageCode: _string(stream['languageCode']),
    languageTag: _string(stream['languageTag']),
    title: _string(stream['title']),
    displayTitle: _string(stream['displayTitle']),
    extendedDisplayTitle: _string(stream['extendedDisplayTitle']),
    channels: _int(stream['channels']),
    isDefault: _bool(stream['default']),
    selected: _bool(stream['selected']),
    forced: _bool(stream['forced']),
    hearingImpaired: _bool(stream['hearingImpaired']),
  );
}

List<String> _tags(Object? list) => [
  if (list is List)
    for (final tag in list.whereType<Map>())
      if (_string(tag['tag']) case final String name) name,
];

List<PlexFilmPerson> _people(Object? list) => [
  if (list is List)
    for (final person in list.whereType<Map>())
      if (_string(person['tag']) case final String name)
        PlexFilmPerson(name: name, role: _string(person['role']), thumb: _string(person['thumb'])),
];

/// A film of a filtered list of a library (/library/sections/{id}/all?type=1): what its tile and its page need before
/// the full item comes
class PlexFilmItem {
  const PlexFilmItem({
    required this.ratingKey,
    required this.title,
    required this.partId,
    required this.partKey,
    required this.fileName,
    this.year,
    this.contentRating,
    this.thumb,
    this.size,
    this.durationMs,
    this.addedAt,
    this.mimeType,
    this.width,
    this.height,
  });

  final String ratingKey;
  final String title;
  final int? year;
  final String? contentRating;
  final String? thumb;

  /// Its first file, the one Play opens
  final int partId;
  final String partKey;
  final String fileName;
  final int? size;
  final int? durationMs;
  final DateTime? addedAt;
  final String? mimeType;
  final int? width;
  final int? height;
}

/// One page of a filtered list of films
class PlexFilmsPage {
  const PlexFilmsPage({required this.items, required this.count, required this.offset, this.totalSize});

  final List<PlexFilmItem> items;

  /// The elements the page held, those left out included (an item without a file)
  final int count;
  final int offset;
  final int? totalSize;
}

/// A page of /library/sections/{id}/all?type=1, each film with its first file
PlexFilmsPage parsePlexFilmsPage(Object? json) {
  final container = _container(json);
  final elements = _elements(json);
  final items = <PlexFilmItem>[];
  for (final element in elements) {
    final ratingKey = _string(element['ratingKey']);
    final media = switch (element['Media']) {
      final List medias => medias.whereType<Map>().firstOrNull,
      _ => null,
    };
    final part = switch (media?['Part']) {
      final List parts => parts.whereType<Map>().firstOrNull,
      _ => null,
    };
    final partId = _int(part?['id']);
    final partKey = _string(part?['key']);
    if (ratingKey == null || partId == null || partKey == null) {
      continue;
    }
    final title = _string(element['title']) ?? '';
    final container = _string(part?['container']) ?? _string(media?['container']);
    final fileName = _baseName(_string(part?['file'])) ?? _titleName(title, container) ?? 'film-$ratingKey';
    final added = _int(element['addedAt']);
    items.add(
      PlexFilmItem(
        ratingKey: ratingKey,
        title: title,
        year: _int(element['year']),
        contentRating: _string(element['contentRating']),
        thumb: _string(element['thumb']),
        partId: partId,
        partKey: partKey,
        fileName: fileName,
        size: _int(part?['size']),
        durationMs: _int(part?['duration']) ?? _int(media?['duration']) ?? _int(element['duration']),
        addedAt: added != null && added > 0 ? DateTime.fromMillisecondsSinceEpoch(added * 1000, isUtc: true) : null,
        mimeType: plexMimeTypeOf(container),
        width: _int(media?['width']),
        height: _int(media?['height']),
      ),
    );
  }
  final offset = container?['offset'];
  final total = container?['totalSize'];
  return PlexFilmsPage(
    items: items,
    count: elements.length,
    offset: offset is int ? offset : 0,
    totalSize: total is int && total >= 0 ? total : null,
  );
}

/// A filter a library offers, from /library/sections/{id}/filters: [filter] is the parameter of /all it sets ("year",
/// "decade", "contentRating"), [key] the request path of its values, read from the answer and never built (the
/// reference warns that walked keys are no contract)
class PlexSectionFilter {
  const PlexSectionFilter({required this.filter, required this.key, this.title, this.filterType});

  final String filter;
  final String key;
  final String? title;

  /// "string", "integer", "boolean", "tag"
  final String? filterType;
}

/// The filters of [json], an answer of /library/sections/{id}/filters (a Directory each), in server order
List<PlexSectionFilter> parsePlexSectionFilters(Object? json) => [
  for (final element in _elements(json))
    if ((_string(element['filter']), _string(element['key'])) case (final String filter, final String key))
      PlexSectionFilter(
        filter: filter,
        key: key,
        title: _string(element['title']),
        filterType: _string(element['filterType']),
      ),
];

/// One value of a filter: what goes to /all ([key]), and what to show ([title]); the number of films with it when the
/// server tells ([size] or count), which it may not
class PlexFilterChoice {
  const PlexFilterChoice({required this.key, required this.title, this.count});

  final String key;
  final String title;
  final int? count;
}

/// The values of a filter, from GET of its key (a Directory each). PMS 1.42.1 sends the key of a value percent
/// encoded ("fr%2F12", "Not%20Rated", "13%2B", the title being "fr/12"): the value is kept decoded, as the films hold
/// it, so that the audience bands read it and the query encodes it once.
List<PlexFilterChoice> parsePlexFilterChoices(Object? json) => [
  for (final element in _elements(json))
    if (_string(element['key']) case final String key)
      PlexFilterChoice(
        key: _decodedValue(key),
        title: _string(element['title']) ?? _decodedValue(key),
        count: _int(element['size']) ?? _int(element['count']),
      ),
];

/// [key] without its percent encoding; as it came when it is not valid percent encoding
String _decodedValue(String key) {
  if (!key.contains('%')) {
    return key;
  }
  try {
    return Uri.decodeComponent(key);
  } on ArgumentError {
    return key;
  } on FormatException {
    return key;
  }
}

/// How a filtered list of films is ordered
enum PlexFilmSort {
  /// Newest year first, then by title, as the Immich timeline is newest first
  yearNewest('year:desc,titleSort'),
  yearOldest('year,titleSort'),
  title('titleSort'),
  recentlyAdded('addedAt:desc');

  const PlexFilmSort(this.query);

  /// The sort parameter of /all
  final String query;
}

/// The filters of a list of films: the years and decades (they add up), the content ratings as Plex stores them (they
/// add up too: the audience bands of the sheet become the ratings they hold), and the films not watched yet. Between
/// two kinds, the filters narrow the list.
class PlexFilmsQuery {
  const PlexFilmsQuery({
    this.years = const {},
    this.decades = const {},
    this.contentRatings = const {},
    this.unwatched = false,
    this.sort = PlexFilmSort.yearNewest,
  });

  final Set<int> years;

  /// The first year of each decade: 1990 for the 1990s
  final Set<int> decades;
  final Set<String> contentRatings;
  final bool unwatched;
  final PlexFilmSort sort;

  /// Whether any filter is on (the sort alone is none)
  bool get isFiltered => years.isNotEmpty || decades.isNotEmpty || contentRatings.isNotEmpty || unwatched;

  PlexFilmsQuery copyWith({
    Set<int>? years,
    Set<int>? decades,
    Set<String>? contentRatings,
    bool? unwatched,
    PlexFilmSort? sort,
  }) => PlexFilmsQuery(
    years: years ?? this.years,
    decades: decades ?? this.decades,
    contentRatings: contentRatings ?? this.contentRatings,
    unwatched: unwatched ?? this.unwatched,
    sort: sort ?? this.sort,
  );

  /// The query parameters of /library/sections/{id}/all for these filters: type=1 (films), the sort, decade= for
  /// decades alone, year= for years alone, and the years of the decades with the years when both are picked (Plex
  /// joins two parameters with AND; a comma inside one is OR); contentRating= with its values as Plex stores them
  /// (case counts); unwatched=1
  Map<String, String> toQueryParameters() {
    final parameters = <String, String>{'type': '1', 'sort': sort.query};
    if (years.isNotEmpty && decades.isNotEmpty) {
      final all = {
        ...years,
        for (final decade in decades)
          for (var year = decade; year < decade + 10; year++) year,
      }.toList()..sort();
      parameters['year'] = all.join(',');
    } else if (years.isNotEmpty) {
      parameters['year'] = (years.toList()..sort()).join(',');
    } else if (decades.isNotEmpty) {
      parameters['decade'] = (decades.toList()..sort()).join(',');
    }
    if (contentRatings.isNotEmpty) {
      parameters['contentRating'] = (contentRatings.toList()..sort()).join(',');
    }
    if (unwatched) {
      parameters['unwatched'] = '1';
    }
    return parameters;
  }

  @override
  bool operator ==(Object other) =>
      other is PlexFilmsQuery &&
      _setEquals(other.years, years) &&
      _setEquals(other.decades, decades) &&
      _setEquals(other.contentRatings, contentRatings) &&
      other.unwatched == unwatched &&
      other.sort == sort;

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(years),
    Object.hashAllUnordered(decades),
    Object.hashAllUnordered(contentRatings),
    unwatched,
    sort,
  );
}

bool _setEquals<T>(Set<T> a, Set<T> b) => a.length == b.length && a.containsAll(b);

/// The audience bands of the filter sheet: a film is in the band of the age its rating asks for, as a filter, never
/// a parental lock (decision 5 of the study of 10 November 2026)
enum AudienceBand { all, age10, age12, age16, age18, unrated }

/// The band of [contentRating] as Plex stores it ("PG-13", "fr/12", "de/16", "gb/15", "NR"); null for a value the
/// table does not know, which the sheet then shows as Plex gives it. Named ratings of the main systems first (the
/// United States' films and TV, the United Kingdom, Australia, Canada, Spain, the Netherlands, Germany's FSK), then a
/// number after a country prefix ("fr/12", "it/14", "nl/16", "18+"), put in the band at or above it so that a film
/// never lands in a younger band than its rating says: up to 6 all audiences, then 10, 12, 16 and 18.
AudienceBand? audienceBandOf(String? contentRating) {
  final raw = contentRating?.trim();
  if (raw == null || raw.isEmpty) {
    return AudienceBand.unrated;
  }
  final slash = raw.indexOf('/');
  final country = slash > 0 ? raw.substring(0, slash).toLowerCase() : null;
  final value = (slash > 0 ? raw.substring(slash + 1) : raw).trim();
  final upper = value.toUpperCase();
  // France: "12 avec avertissement", "Tous publics avec avertissement" (with a warning) are in the band of the rating
  final warned = RegExp(r'^(.+?)\s+AVEC AVERTISSEMENT$').firstMatch(upper)?.group(1);
  if (warned != null) {
    return audienceBandOf(country == null ? warned : '$country/$warned');
  }
  final named = _namedBands[upper] ?? (country == null ? null : _countryBands['$country/$upper']);
  if (named != null) {
    return named;
  }
  final number = RegExp(r'^(?:FSK\s*)?(\d{1,2})\+?$').firstMatch(upper)?.group(1);
  if (number != null) {
    final age = int.parse(number);
    return age <= 6
        ? AudienceBand.all
        : age <= 10
        ? AudienceBand.age10
        : age <= 12
        ? AudienceBand.age12
        : age <= 16
        ? AudienceBand.age16
        : AudienceBand.age18;
  }
  return null;
}

/// Ratings whose word means the same in every system that uses it, compared in capitals
const _namedBands = {
  // The United States, films (MPA) and television
  'G': AudienceBand.all,
  'PG': AudienceBand.age10,
  'PG-13': AudienceBand.age12,
  'R': AudienceBand.age16,
  'NC-17': AudienceBand.age18,
  'X': AudienceBand.age18,
  'TV-Y': AudienceBand.all,
  'TV-Y7': AudienceBand.all,
  'TV-Y7-FV': AudienceBand.all,
  'TV-G': AudienceBand.all,
  'TV-PG': AudienceBand.age10,
  'TV-14': AudienceBand.age16,
  'TV-MA': AudienceBand.age18,
  'APPROVED': AudienceBand.all,
  'PASSED': AudienceBand.all,
  // Not rated, in the words of the agents
  'NR': AudienceBand.unrated,
  'NOT RATED': AudienceBand.unrated,
  'UNRATED': AudienceBand.unrated,
  'UNKNOWN': AudienceBand.unrated,
  // The value of the films without a rating in the content rating filter of PMS 1.42.1
  'NONE': AudienceBand.unrated,
  // France and the United Kingdom
  'U': AudienceBand.all,
  'TP': AudienceBand.all,
  'TOUS PUBLICS': AudienceBand.all,
  'UC': AudienceBand.all,
  // "Accord parental" of the older French ratings: "souhaitable" was under 10, "indispensable" under 12; the higher
  // one, so that no film lands in a younger band than its rating
  'ACCORD PARENTAL': AudienceBand.age12,
  '12A': AudienceBand.age12,
  'R18': AudienceBand.age18,
  // Australia
  'M': AudienceBand.age16,
  'MA15+': AudienceBand.age16,
  'R18+': AudienceBand.age18,
  'X18+': AudienceBand.age18,
  // Spain, the Netherlands
  'APTA': AudienceBand.all,
  'AL': AudienceBand.all,
};

/// Ratings whose word differs by country, keyed by the country prefix of Plex and the word in capitals
const _countryBands = {
  'gb/PG': AudienceBand.age10,
  'gb/15': AudienceBand.age16,
  'ca/PG': AudienceBand.age10,
  'ca/14A': AudienceBand.age16,
  'ca/18A': AudienceBand.age18,
  'ca/R': AudienceBand.age18,
  'ca/A': AudienceBand.age18,
  'ca/E': AudienceBand.all,
  'au/PG': AudienceBand.age10,
  'es/A': AudienceBand.all,
  'it/T': AudienceBand.all,
  'it/VM14': AudienceBand.age16,
  'it/VM18': AudienceBand.age18,
};

/// The content type of a container Plex names, for the players; null for one the extension of the name tells
String? plexMimeTypeOf(String? container) => _mimeTypes[container?.toLowerCase()];

const _mimeTypes = {
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'mov': 'video/quicktime',
  'mkv': 'video/x-matroska',
  'matroska': 'video/x-matroska',
  'webm': 'video/webm',
  'avi': 'video/x-msvideo',
  'mpegts': 'video/mp2t',
  'ts': 'video/mp2t',
};

/// The path of a film in the share of a Plex server, the same whatever lists it (the films page of lot A1, a filtered
/// list, the film page): /.films/{section}/{ratingKey}/{partId}/{file name}. PlexFileSystem finds the film behind it
/// through /library/metadata/{ratingKey} when it has not met it; the dot keeps it out of every listing.
String plexFilmPath({
  required String sectionKey,
  required String ratingKey,
  required int partId,
  required String name,
}) => '/$plexFilmsFolder/${safeEntryName(sectionKey)}/${safeEntryName(ratingKey)}/$partId/${safeEntryName(name)}';

/// The first segment of the paths of [plexFilmPath]
const plexFilmsFolder = '.films';

/// The ratingKey and the part of a path of [plexFilmPath], null for any other path
({String sectionKey, String ratingKey, int partId})? parsePlexFilmPath(String path) {
  final segments = path.split('/').where((segment) => segment.isNotEmpty).toList();
  if (segments.length != 5 || segments.first != plexFilmsFolder) {
    return null;
  }
  final partId = int.tryParse(segments[3]);
  if (partId == null || !RegExp(r'^\d+$').hasMatch(segments[2])) {
    return null;
  }
  return (sectionKey: segments[1], ratingKey: segments[2], partId: partId);
}

String? _baseName(String? path) {
  if (path == null) {
    return null;
  }
  final name = path.split(RegExp(r'[/\\]')).last.trim();
  return name.isEmpty ? null : name;
}

String? _titleName(String title, String? container) {
  if (title.trim().isEmpty || container == null) {
    return null;
  }
  final extension = switch (container.toLowerCase()) {
    'matroska' => 'mkv',
    'mpegts' => 'ts',
    final other => other,
  };
  return '${title.trim()}.$extension';
}

Map<String, Object?>? _container(Object? json) {
  final container = json is Map ? json['MediaContainer'] : null;
  return container is Map ? container.cast<String, Object?>() : null;
}

/// The elements of both arrays of the container, Directory first, in order
List<Map<String, Object?>> _elements(Object? json) {
  final container = _container(json);
  if (container == null) {
    return const [];
  }
  return [
    for (final name in const ['Directory', 'Metadata'])
      if (container[name] case final List list)
        for (final element in list)
          if (element is Map) element.cast<String, Object?>(),
  ];
}

String? _string(Object? value) => switch (value) {
  final String text when text.isNotEmpty => text,
  final num number => '$number',
  _ => null,
};

/// A text of the item, null when empty or blank
String? _text(Object? value) => value is String && value.trim().isNotEmpty ? value.trim() : null;

int? _int(Object? value) => switch (value) {
  final int number => number,
  final double number when number.isFinite => number.round(),
  final String text => int.tryParse(text),
  _ => null,
};

double? _double(Object? value) => switch (value) {
  final num number when number.isFinite => number.toDouble(),
  final String text => double.tryParse(text),
  _ => null,
};

/// Plex writes its flags as booleans in JSON, and as 0 or 1 in some versions
bool _bool(Object? value) => value == true || value == 1 || value == '1' || value == 'true';
