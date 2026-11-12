// The Plex films lots of release 45 (films page, film page and filters, download) against a real Plex Media Server,
// through the app's own Plex layer (PlexFileSystem, the films list, the film details, the Wikipedia client). Skipped
// unless IMMUCH_NET_TESTS=1, IMMUCH_PLEX_URL (the https://<ipv4-dashes>.<hash>.plex.direct:<port> address of the
// server) and IMMUCH_PLEX_TOKEN are set, as plex_integration_test.dart (IMMUCH_PLEX_SIDECAR_FILM, the rating key of a
// film with a subtitle file beside it, is optional). The shell loads them from the secrets file, which never goes into
// the repository, and never into the CI.
//
// Read only. Every request goes through a recording client that answers any method but GET and HEAD itself (the PUT
// of the track write back is checked on its URL, never sent) and bounds every download=1 request to its first 64 KiB.
// What it prints is counts, booleans, statuses, header names, rating strings and filter names: never the token, an
// address, a hash, a title, a file name or a path.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/infrastructure/network/http_range_reader.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_direct.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_list.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_pairing.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_tracks.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_film_cache.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_film_client.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_languages.dart';
import 'package:immich_mobile/providers/network/plex_film_list.provider.dart';

void _report(String line) => stdout.writeln('plex films: $line');

/// [action] within [limit], null when the server did not answer in time (counted in [missed]): the path to a server
/// outside home may lose a request now and then, which the app shows as an error and these tests leave aside
Future<T?> _inTime<T>(
  Future<T> Function() action,
  List<int> missed, {
  Duration limit = const Duration(seconds: 20),
}) async {
  try {
    return await action().timeout(limit);
  } catch (error) {
    if (error is TimeoutException || isPlexNetworkFailure(error)) {
      missed[0]++;
      return null;
    }
    rethrow;
  }
}

/// Bytes asked at most of a download=1 request
const _downloadWindow = 64 * 1024;

/// The client under PlexFileSystem: records what the app sends, answers the writes itself, bounds the downloads
class _Recorder extends http.BaseClient {
  _Recorder(this._inner);

  final http.Client _inner;
  final requests = <({String method, Uri url, Map<String, String> headers})>[];
  final writes = <({String method, Uri url})>[];
  final downloads = <({int status, Map<String, String> headers})>[];

  /// The time to the headers of each answer, by the form of its path
  final timings = <({String shape, int ms, int status})>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add((method: request.method, url: request.url, headers: Map.of(request.headers)));
    if (request.method != 'GET' && request.method != 'HEAD') {
      writes.add((method: request.method, url: request.url));
      return http.StreamedResponse(const Stream.empty(), 204, request: request);
    }
    final download = request.url.queryParameters['download'] == '1';
    if (download) {
      final from =
          int.tryParse(RegExp(r'bytes=(\d+)-').firstMatch(request.headers['range'] ?? '')?.group(1) ?? '') ?? 0;
      request.headers['range'] = 'bytes=$from-${from + _downloadWindow - 1}';
    }
    final watch = Stopwatch()..start();
    final response = await _inner.send(request);
    timings.add((shape: _shape(request.url.path), ms: watch.elapsedMilliseconds, status: response.statusCode));
    if (download) {
      downloads.add((status: response.statusCode, headers: Map.of(response.headers)));
    }
    return response;
  }

  @override
  void close() => _inner.close();
}

/// What the whole library gave, walked once for every test
class _Library {
  _Library(this.section, this.folderPath);

  final PlexSection section;
  final String folderPath;
  final years = <int?>[];
  final films = <PlexFilm>[];
  int? totalSize;
  final pageCounts = <int>[];
}

void main() {
  final environment = Platform.environment;
  final url = environment['IMMUCH_PLEX_URL'] ?? '';
  final token = environment['IMMUCH_PLEX_TOKEN'] ?? '';
  final enabled = environment['IMMUCH_NET_TESTS'] == '1' && url.isNotEmpty && token.isNotEmpty;
  final Object skip = enabled ? false : 'needs IMMUCH_NET_TESTS=1, IMMUCH_PLEX_URL and IMMUCH_PLEX_TOKEN';
  // Optional: the rating key of a film with subtitle files beside it, read first by test 7 (few films have one)
  final sidecarFilm = environment['IMMUCH_PLEX_SIDECAR_FILM'];

  late PlexServerFound server;
  late _Recorder recorder;
  late PlexFileSystem plex;
  late PlexClient raw;
  final libraries = <_Library>[];
  _Library? main;

  Uri base() => plexDirectUri(server.address, server.port, server.hash);

  setUpAll(() async {
    if (!enabled) {
      return;
    }
    final typed = parsePlexAddress(url);
    server = await PlexPairing().lookUp(typed);
    recorder = _Recorder(IOClient(pinnedPlexHttpClient(server.hash)));
    final source = NetworkSource(
      id: '0123456789abcdef',
      type: NetworkSourceType.plex,
      name: 'Live',
      host: '',
      useTls: true,
      discoveryId: server.machineIdentifier,
      plex: PlexServerInfo(hash: server.hash, publicHost: server.address.address, publicPort: server.port),
    );
    // A fixed client identifier: the server lists the tests as one device
    const clientIdentifier = '1mm0c4360f11e5000000000000000045';
    plex = await PlexFileSystem.open(source, token, client: recorder, clientIdentifier: clientIdentifier);
    raw = PlexClient(recorder, token: token, clientIdentifier: clientIdentifier);
    for (final library in await plex.filmLibraries()) {
      libraries.add(_Library(library.section, library.folderPath));
    }
    // The films page of every film library, as the page reads it: the years first, then the films by pages of 100
    for (final library in libraries) {
      final query = PlexFilmListQuery(sectionKey: library.section.key);
      library.years.addAll(await plex.filmYears(query));
      var start = 0;
      while (start < 5000) {
        final page = await plex.filmsPage(query, start: start, size: PlexFilmListQuery.pageSize);
        library.totalSize ??= page.totalSize;
        library.pageCounts.add(page.count);
        library.films.addAll(page.films);
        if (page.count <= 0) {
          break;
        }
        start += page.count;
        if (page.totalSize == null ? page.count < PlexFilmListQuery.pageSize : start >= page.totalSize!) {
          break;
        }
      }
    }
    main = libraries.isEmpty ? null : libraries.reduce((a, b) => a.films.length >= b.films.length ? a : b);
  });

  tearDown(() {
    if (!enabled || recorder.timings.isEmpty) {
      return;
    }
    final sorted = [...recorder.timings]..sort((a, b) => b.ms - a.ms);
    final total = recorder.timings.fold<int>(0, (sum, t) => sum + t.ms);
    _report(
      'requests ${recorder.timings.length}, ${total ~/ recorder.timings.length} ms on average, slowest '
      '${[for (final t in sorted.take(4)) '${t.shape} ${t.status} ${t.ms} ms']}',
    );
    recorder.timings.clear();
  });

  tearDownAll(() async {
    if (enabled) {
      await plex.close();
    }
  });

  test('1. the sections: agents, languages, which are film libraries', () async {
    final sections = await raw.getJson(base().resolve('/library/sections'), parsePlexSections);
    final shown = <String>[
      for (final section in sections) '${section.type}/${section.agent}/${section.language}/films ${section.isFilms}',
    ];
    _report('outside home ${plex.isOutsideHome}; sections ${sections.length}: $shown');
    _report('film libraries ${libraries.length}, films each ${[for (final l in libraries) l.films.length]}');
    expect(libraries, isNotEmpty, reason: 'the server has a film library');
  }, skip: skip);

  test('2. the films list: pages, totals, the light pass in step with the pages', () {
    for (final library in libraries) {
      final pageYears = [for (final film in library.films) film.year];
      final same = listEquals(pageYears, library.years);
      _report(
        'library: total told ${library.totalSize}, light pass ${library.years.length}, pages ${library.films.length} '
        'in ${library.pageCounts.length} pages (counts ${library.pageCounts.take(3)}...), same years in order $same',
      );
      expect(library.years.length, library.films.length, reason: 'one year per film of the pages');
      expect(same, isTrue, reason: 'the index of a film among the years is its index among the pages');
      if (library.totalSize != null) {
        expect(library.films.length, library.totalSize);
      }
      final keys = {for (final film in library.films) film.ratingKey};
      expect(keys.length, library.films.length, reason: 'no film twice across the pages');
    }
  }, skip: skip);

  test('3. the year segments the page computes', () {
    final library = main!;
    final groups = plexFilmYears(library.years);
    final unknown = groups.where((group) => group.year == null).toList();
    final known = [for (final group in groups) ?group.year];
    final descending = [for (var i = 1; i < known.length; i++) known[i] < known[i - 1]].every((ok) => ok);
    final counts = {for (final group in groups) '${group.year ?? 'unknown'}': group.count};
    _report('year groups ${groups.length}, years strictly newest first $descending, unknown groups ${unknown.length}');
    _report('films per year: $counts');
    expect(groups.fold<int>(0, (sum, group) => sum + group.count), library.years.length);
    expect(descending, isTrue, reason: 'one group per year, newest first');
    expect(unknown.length, lessThanOrEqualTo(1));
    if (unknown.isNotEmpty) {
      expect(groups.last.year, isNull, reason: 'the films without a year come last');
    }
    // The paged list the page holds: the same groups, the first page there at once
  }, skip: skip);

  test('4. PagedPlexFilms.load, as the films page opens', () async {
    final library = main!;
    final list = await PagedPlexFilms.load(plex, PlexFilmListQuery(sectionKey: library.section.key));
    addTearDown(list.dispose);
    _report('paged list: count ${list.count}, groups ${list.years.length}, first film there ${list.filmAt(0) != null}');
    expect(list.count, library.films.length);
    expect(list.years, plexFilmYears(library.years));
    expect(list.filmAt(0)?.ratingKey, library.films.first.ratingKey);
  }, skip: skip);

  test(
    '5. search: title= and /hubs/search, with accents, folded accents, case and a misspelling',
    () async {
      final library = main!;
      final accented = RegExp(r'[À-ÖØ-öø-ÿŒœ]');
      final words = <({PlexFilm film, String word})>[];
      for (final film in library.films) {
        for (final word in film.title.split(RegExp(r'[\s,:;.!?()"«»]+'))) {
          if (word.length >= 4 && accented.hasMatch(word)) {
            words.add((film: film, word: word));
            break;
          }
        }
      }
      _report('titles with an accented word: ${words.length} of ${library.films.length}');
      final checked = words.take(3).toList();
      for (final (index, (:film, :word)) in checked.indexed) {
        final folded = _fold(word);
        Future<bool> holds(String text) async => (await plex.filmsPage(
          PlexFilmListQuery(sectionKey: library.section.key, title: text),
          start: 0,
          size: 100,
        )).films.any((found) => found.ratingKey == film.ratingKey);
        Future<bool> hubs(String text) async =>
            (await plex.searchFilms(library.section.key, text)).any((found) => found.ratingKey == film.ratingKey);
        final results = {
          'title= accented': await holds(word),
          'title= folded': await holds(folded),
          'title= lower case': await holds(word.toLowerCase()),
          'hubs accented': await hubs(word),
          'hubs folded': await hubs(folded),
        };
        _report('word $index (${word.length} letters): $results');
        expect(results['title= accented'], isTrue, reason: 'Plex "contains" finds the word as written');
        final merged = await searchPlexFilms(plex, PlexFilmListQuery(sectionKey: library.section.key, title: word));
        final keys = [for (var i = 0; i < merged.count; i++) merged.filmAt(i)!.ratingKey];
        _report(
          'word $index merged search: ${merged.count} films, the film in ${keys.contains(film.ratingKey)}, '
          'each once ${keys.toSet().length == keys.length}',
        );
        expect(keys, contains(film.ratingKey));
        expect(keys.toSet().length, keys.length);
      }
      // A misspelt title: two inner letters swapped in a long word of a title
      final long = [
        for (final film in library.films)
          for (final word in film.title.split(RegExp(r'\s+')))
            if (word.length >= 7 && RegExp(r'^[A-Za-z]+$').hasMatch(word)) (film: film, word: word),
      ].take(3);
      for (final (index, (:film, :word)) in long.indexed) {
        final letters = word.split('');
        final swap = letters[2];
        letters[2] = letters[3];
        letters[3] = swap;
        final misspelt = letters.join();
        final hub = await plex.searchFilms(library.section.key, misspelt);
        final contains = await plex.filmsPage(
          PlexFilmListQuery(sectionKey: library.section.key, title: misspelt),
          start: 0,
          size: 100,
        );
        _report(
          'misspelt word $index: hubs found the film ${hub.any((f) => f.ratingKey == film.ratingKey)} '
          '(${hub.length} films), title= found it ${contains.films.any((f) => f.ratingKey == film.ratingKey)}',
        );
      }
      final hubStatus = await raw.send(
        'GET',
        base().resolve('/hubs/search').replace(queryParameters: {'query': 'zzqqxx', 'sectionId': library.section.key}),
      );
      await discardHttpBody(hubStatus);
      _report('hubs search for nothing: status ${hubStatus.statusCode}');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '6. the filters: the values of year, decade and content rating, then a filtered list',
    () async {
      final library = main!;
      final filters = await plex.sectionFilters(library.section.key);
      _report('filters offered: ${[for (final f in filters) '${f.filter}(${f.filterType})']}');
      _report('filter keys relative ${filters.where((f) => !f.key.startsWith('/')).length} of ${filters.length}');
      PlexSectionFilter? named(String name) => filters.where((f) => f.filter == name).firstOrNull;
      final ratingFilter = named('contentRating');
      final decadeFilter = named('decade');
      final yearFilter = named('year');
      expect(ratingFilter, isNotNull);
      final ratings = await plex.filterChoices(library.section.key, ratingFilter!);
      final bands = {for (final r in ratings) r.title: audienceBandOf(r.key)?.name};
      _report('content ratings: ${ratings.length}, counts told ${ratings.where((r) => r.count != null).length}');
      _report('content rating keys and titles differ: ${ratings.where((r) => r.key != r.title).length}');
      _report('content ratings and their band: $bands');
      final fromFilms = <String, int>{};
      for (final film in library.films) {
        final rating = film.contentRating ?? '(none)';
        fromFilms[rating] = (fromFilms[rating] ?? 0) + 1;
      }
      _report('content ratings of the films: $fromFilms');
      if (yearFilter != null) {
        final years = await plex.filterChoices(library.section.key, yearFilter);
        _report(
          'year values ${years.length}, counts told ${years.where((y) => y.count != null).length}, '
          'keys ${years.take(3).map((y) => y.key)}',
        );
      }
      if (decadeFilter != null) {
        final decades = await plex.filterChoices(library.section.key, decadeFilter);
        _report('decade values ${decades.length}: ${[for (final d in decades) '${d.key}=${d.title}']}');
      }

      // A filtered list as the films page reads it from the sheet: the decade of the most films, then one rating
      final byDecade = <int, int>{};
      for (final year in library.years.whereType<int>()) {
        byDecade[year ~/ 10 * 10] = (byDecade[year ~/ 10 * 10] ?? 0) + 1;
      }
      final decade = byDecade.entries.reduce((a, b) => a.value >= b.value ? a : b);
      final sheet = PlexFilmsQuery(decades: {decade.key});
      final filtered = await plex.allFilms(library.section.key, sheet);
      final inDecade = filtered.every((f) => f.item.year != null && f.item.year! ~/ 10 * 10 == decade.key);
      _report(
        'decade ${decade.key}: expected ${decade.value}, the sheet query gave ${filtered.length}, all in it $inDecade',
      );
      expect(filtered.length, decade.value);
      expect(inDecade, isTrue);
      final pageQuery = PlexFilmListQuery(sectionKey: library.section.key, filters: sheet.toQueryParameters());
      final pageYears = await plex.filmYears(pageQuery);
      _report('the films page with that filter: ${pageYears.length} films');
      expect(pageYears.length, decade.value);

      final rated = fromFilms.entries.where((e) => e.key != '(none)').toList();
      if (rated.isNotEmpty) {
        final rating = rated.reduce((a, b) => a.value >= b.value ? a : b);
        final byRating = await plex.allFilms(library.section.key, PlexFilmsQuery(contentRatings: {rating.key}));
        _report('rating filter: expected ${rating.value}, gave ${byRating.length}');
        expect(byRating.length, rating.value);
      }
      final unwatched = await plex.allFilms(library.section.key, const PlexFilmsQuery(unwatched: true));
      final watched = library.films.where((f) => f.viewCount > 0).length;
      _report('not watched: ${unwatched.length}, watched by the list $watched, total ${library.films.length}');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '7. a film: details, streams, a sidecar, the subtitle file, the track write back (not sent)',
    () async {
      final library = main!;
      final random = Random(45);
      final candidates = [
        ...library.films.where((film) => film.ratingKey == sidecarFilm),
        ...library.films.take(15),
        ...List.generate(25, (_) => library.films[random.nextInt(library.films.length)]),
      ];
      PlexFilmDetails? withSidecar;
      PlexFilmDetails? first;
      var checked = 0;
      var withExternal = 0;
      var embeddedSubs = 0;
      final codecs = <String, int>{};
      final missed = [0];
      // Two minutes at most: a server outside home may leave a few answers hanging
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      for (final film in candidates) {
        if (DateTime.now().isAfter(deadline)) {
          break;
        }
        final details = await _inTime(() => plex.filmDetails(film.ratingKey), missed);
        if (details == null) {
          continue;
        }
        checked++;
        first ??= details;
        final streams = [for (final part in details.parts) ...part.streams];
        if (streams.any((s) => s.type == PlexStreamType.subtitle && s.key == null)) {
          embeddedSubs++;
        }
        for (final s in streams.where((s) => s.isSidecar)) {
          codecs[s.codec ?? '?'] = (codecs[s.codec ?? '?'] ?? 0) + 1;
        }
        if (streams.any((s) => s.isSidecar)) {
          withExternal++;
          withSidecar ??= details;
        }
        if (withSidecar != null && checked >= 15) {
          break;
        }
      }
      _report('details not in time: ${missed[0]}');
      _report(
        'films read $checked: with a subtitle file beside $withExternal, with subtitles inside $embeddedSubs, '
        'codecs of the files beside $codecs',
      );
      final film = withSidecar ?? first!;
      final part = film.parts.first;
      final audio = part.streams.where((s) => s.type == PlexStreamType.audio).toList();
      final subtitles = part.streams.where((s) => s.type == PlexStreamType.subtitle).toList();
      _report(
        'the film: medias ${film.medias.length}, parts ${film.parts.length}, audio ${audio.length} '
        '(labels ${audio.where((s) => s.label != null).length}, selected ${audio.where((s) => s.selected).length}), '
        'subtitles ${subtitles.length} (beside ${subtitles.where((s) => s.isSidecar).length}, '
        'selected ${subtitles.where((s) => s.selected).length}), section told ${film.sectionKey != null}, '
        'imdb ${film.externalIds.imdb != null}, tmdb ${film.externalIds.tmdb != null}, '
        'genres ${film.genres.length}, roles ${film.roles.length}, cast pictures absolute '
        '${film.roles.where((r) => r.thumb?.startsWith('http') ?? false).length}, ratings ${film.ratings.map((r) => r.source)}',
      );
      expect(audio, isNotEmpty);

      final sidecar = subtitles.where((s) => s.isSidecar && s.isTextSubtitle).firstOrNull;
      if (sidecar != null) {
        final before = recorder.requests.length;
        final bytes = await _inTime(() => plex.subtitleFile(sidecar), missed);
        final sent = recorder.requests.sublist(before).last;
        final format = bytes == null ? null : subtitleTextFormatOf(bytes, codec: sidecar.codec);
        var utf8Text = bytes != null;
        try {
          utf8.decode(bytes ?? const []);
        } on FormatException {
          utf8Text = false;
        }
        _report(
          'subtitle file (${sidecar.codec}): path form ${_shape(sent.url.path)}, query ${sent.url.queryParameters.keys}, '
          'key form ${_shape(sidecar.key!)}, ${bytes?.length} bytes, format ${format?.name}, UTF-8 $utf8Text',
        );
        expect(sent.url.path, '/library/streams/${sidecar.id}');
        expect(sent.url.queryParameters, {'encoding': 'utf-8'});
        expect(format, isNotNull);
        expect(utf8Text, isTrue);
      } else {
        _report('no film with a text subtitle file beside among those read');
      }

      // The PUT of the track write back, answered by the recorder: its URL only
      final selectedAudio = audio.where((s) => s.selected).firstOrNull ?? audio.first;
      await plex.selectStreams(part.id, audioStreamId: selectedAudio.id, subtitleStreamId: sidecar?.id ?? 0);
      final write = recorder.writes.last;
      _report(
        'track write back (not sent): ${write.method} ${_shape(write.url.path)} ${write.url.queryParameters.keys}',
      );
      expect(write.method, 'PUT');
      expect(write.url.path, '/library/parts/${part.id}');
      expect(write.url.queryParameters['allParts'], '1');
      expect(write.url.queryParameters['audioStreamID'], '${selectedAudio.id}');
      expect(write.url.queryParameters.keys, isNot(contains('X-Plex-Token')));
      expect(recorder.writes.length, 1, reason: 'no other write was asked');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    '8. download: the URL the app builds, the first 64 KiB, the same bytes as a range read',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      final library = main!;
      final missed = [0];
      var done = false;
      for (final film in library.films.where((film) => film.part != null).take(6)) {
        final entry = plexFilmEntry(plex.source.id, library.section.key, film)!;
        final before = recorder.requests.length;
        final read = await _inTime(() async {
          final stream = await plex.openDownload(entry.path);
          return (stream: stream, bytes: await stream.bytes.fold<List<int>>([], (all, chunk) => all..addAll(chunk)));
        }, missed);
        final head = read == null ? null : await _inTime(() => plex.readRange(entry.path, 0, _downloadWindow), missed);
        if (read == null || head == null) {
          continue;
        }
        final (:stream, :bytes) = read;
        final sent = recorder.requests.sublist(before).lastWhere((r) => r.url.queryParameters['download'] == '1');
        final answer = recorder.downloads.last;
        final names = answer.headers.keys.toList()..sort();
        _report(
          'download: query ${sent.url.queryParameters.keys}, path form ${_shape(sent.url.path)}, token in the header '
          '${sent.headers.containsKey('x-plex-token')}, status ${answer.status}, ${bytes.length} bytes, start '
          '${stream.start}, total known ${stream.total != null}, size of the listing equal ${stream.total == entry.size}',
        );
        _report('download headers: $names');
        _report(
          'download content-disposition attachment '
          '${answer.headers['content-disposition']?.startsWith('attachment') ?? false}, filename given '
          '${answer.headers['content-disposition']?.contains('filename') ?? false}, accept-ranges '
          '${answer.headers['accept-ranges']}, content-type ${answer.headers['content-type']}',
        );
        expect(sent.url.queryParameters['download'], '1');
        expect(sent.url.queryParameters.keys, isNot(contains('X-Plex-Token')));
        expect(answer.status, anyOf(200, 206));
        expect(bytes.length, _downloadWindow);
        expect(listEquals(bytes, head), isTrue, reason: 'the copy and the player read the same bytes');

        // Resumed from an offset, as FilmTransfer does after a lost link
        final resumed = await _inTime(() async {
          final stream = await plex.openDownload(entry.path, from: 1000);
          return (stream: stream, bytes: await stream.bytes.fold<List<int>>([], (all, chunk) => all..addAll(chunk)));
        }, missed);
        if (resumed != null) {
          final more = resumed.bytes;
          _report(
            'download resumed: start ${resumed.stream.start}, ${more.length} bytes, same as the head '
            '${listEquals(more.sublist(0, 1000), head.sublist(1000, 2000))}',
          );
          expect(resumed.stream.start, 1000);
          expect(listEquals(more.sublist(0, 1000), head.sublist(1000, 2000)), isTrue);
        }
        done = true;
        break;
      }
      _report('download reads not in time: ${missed[0]}');
      expect(done, isTrue, reason: 'one film read in time');
    },
    skip: skip,
  );

  test(
    '9. the pictures: the poster at 2:3, the film page poster and backdrop',
    () async {
      final library = main!;
      final film = library.films.firstWhere((film) => film.part != null && film.thumb != null);
      final entry = plexFilmEntry(plex.source.id, library.section.key, film)!;
      final poster = await plex.thumbnail(entry, 360);
      final details = (await _inTime(() => plex.filmDetails(film.ratingKey), [0]))!;
      final page = details.thumb == null ? null : await plex.picture(details.thumb!, width: 400, height: 600);
      final art = details.art == null ? null : await plex.picture(details.art!, width: 1280, height: 720);
      _report(
        'poster of the grid ${_jpegSize(poster)}, poster of the page ${_jpegSize(page)}, backdrop ${_jpegSize(art)}',
      );
      expect(_jpegSize(poster), isNotNull);
      // The shape of the pictures the server keeps: posters of matched films, frames of the others
      final shapes = <String, int>{};
      for (final film in library.films.where((film) => film.thumb != null).take(24)) {
        final picture = await plex.thumbnail(plexFilmEntry(plex.source.id, library.section.key, film)!, 360);
        final size = _jpegSize(picture);
        final shape = size == null
            ? 'none'
            : (size.width / size.height - 2 / 3).abs() < 0.05
            ? '2:3 ${size.width}x${size.height}'
            : '${(size.width / size.height).toStringAsFixed(2)} ${size.width}x${size.height}';
        final key = '${film.year == null ? 'no year' : 'year'} $shape';
        shapes[key] = (shapes[key] ?? 0) + 1;
      }
      _report('poster shapes asked at 240x360: $shapes');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '10. Wikipedia through the app client, from the guids of the films',
    () async {
      final library = main!;
      final client = WikipediaFilmClient(
        client: http.Client(),
        userAgent: WikipediaFilmClient.userAgentFor('45.0.0-live-test'),
        cache: MemoryWikipediaFilmCache(),
        timeout: const Duration(seconds: 10),
      );
      var tried = 0;
      var found = 0;
      final languages = <String>[];
      for (final film in library.films.take(40)) {
        if (tried >= 3) {
          break;
        }
        final details = await _inTime(() => plex.filmDetails(film.ratingKey), [0]);
        if (details == null) {
          continue;
        }
        final ids = FilmExternalIds(imdb: details.externalIds.imdb, tmdb: details.externalIds.tmdb);
        if (ids.isEmpty) {
          continue;
        }
        tried++;
        final summary = await client.summary(ids, wikipediaChainFor('fr', libraryLanguage: library.section.language));
        if (summary != null && summary.extract.isNotEmpty) {
          found++;
          languages.add(summary.languageTag);
        }
      }
      _report('Wikipedia: films looked up $tried, leads found $found, languages $languages');
      expect(tried, greaterThan(0), reason: 'films with an IMDb or TMDB number');
      expect(found, greaterThan(0));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '11. captures: listing shapes, trimmed sizes, includeMeta, the decision codes',
    () async {
      final library = main!;
      final all = base().resolve('/library/sections/${library.section.key}/all');
      Future<(int, Map<String, Object?>)> page(
        Map<String, String> query, {
        Map<String, String> headers = const {},
      }) async {
        final response = await raw.send(
          'GET',
          all.replace(queryParameters: query),
          headers: {'x-plex-container-start': '0', 'x-plex-container-size': '50', ...headers},
        );
        final body = await response.stream.toBytes();
        final json = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
        return (body.length, (json['MediaContainer']! as Map).cast<String, Object?>());
      }

      final listing = {'type': '1', 'sort': 'year:desc,titleSort', 'includeCollections': '0'};
      final (fullBytes, full) = await page(listing);
      final items = (full['Metadata'] as List? ?? const []).cast<Map>();
      final elements = <String>{};
      var streams = false;
      for (final item in items) {
        elements.addAll(item.entries.where((e) => e.value is List).map((e) => '${e.key}'));
        for (final media in (item['Media'] as List? ?? const []).cast<Map>()) {
          for (final part in (media['Part'] as List? ?? const []).cast<Map>()) {
            streams |= part['Stream'] != null;
          }
        }
      }
      final (lightBytes, _) = await page(
        PlexFilmListQuery(sectionKey: library.section.key).queryParameters(light: true),
      );
      final (fieldsBytes, fields) = await page(
        {...listing, 'includeFields': 'ratingKey,title,year'},
        headers: {'x-plex-pms-api-version': '1.1.0'},
      );
      final fieldItem = ((fields['Metadata'] as List?)?.firstOrNull as Map?)?.keys.toList();
      _report(
        'listing of 50: ${items.length} items, ${fullBytes ~/ max(1, items.length)} bytes a film, elements $elements, '
        'Stream in listings $streams, totalSize ${full['totalSize'] != null}',
      );
      _report(
        'light pass of 50: ${lightBytes ~/ max(1, items.length)} bytes a film; includeFields with API 1.1.0: '
        '${fieldsBytes ~/ max(1, items.length)} bytes a film, fields $fieldItem',
      );

      final metaResponse = await raw.send(
        'GET',
        all.replace(queryParameters: {'type': '1', 'includeMeta': '1'}),
        headers: {'x-plex-container-start': '0', 'x-plex-container-size': '0'},
      );
      final meta = jsonDecode(await metaResponse.stream.bytesToString()) as Map;
      final types = ((meta['MediaContainer'] as Map)['Meta'] as Map?)?['Type'] as List?;
      final movie = types?.cast<Map>().where((t) => t['type'] == 'movie').firstOrNull;
      _report(
        'includeMeta: status ${metaResponse.statusCode}, filters ${(movie?['Filter'] as List?)?.map((f) => (f as Map)['filter'])}, '
        'sorts ${(movie?['Sort'] as List?)?.map((s) => (s as Map)['key'])}, fields ${(movie?['Field'] as List?)?.length}',
      );

      final film = library.films.firstWhere((film) => film.part != null);
      final variants = <String, ({Map<String, String> query, Map<String, String> headers})>{
        'plain http': (query: const {'protocol': 'http'}, headers: const {}),
        'Chrome dash wan': (
          query: const {'protocol': 'dash', 'location': 'wan', 'directStreamAudio': '1', 'subtitles': 'auto'},
          headers: const {'x-plex-platform': 'Chrome'},
        ),
        'Chrome hls': (
          query: const {'protocol': 'hls', 'subtitles': 'auto'},
          headers: const {'x-plex-platform': 'Chrome'},
        ),
      };
      for (final MapEntry(key: name, value: variant) in variants.entries) {
        final decision = await raw.send(
          'GET',
          base()
              .resolve('/video/:/transcode/universal/decision')
              .replace(
                queryParameters: {
                  'path': '/library/metadata/${film.ratingKey}',
                  'mediaIndex': '0',
                  'partIndex': '0',
                  'directPlay': '1',
                  'directStream': '1',
                  'hasMDE': '1',
                  'session': 'immuch360-live-45',
                  ...variant.query,
                },
              ),
          headers: {'x-plex-session-identifier': 'immuch360-live-45', ...variant.headers},
        );
        final decisionText = await decision.stream.bytesToString();
        Map? decided;
        try {
          decided = (jsonDecode(decisionText) as Map)['MediaContainer'] as Map?;
        } catch (_) {}
        final codes = {
          for (final name in [
            'generalDecisionCode',
            'generalDecisionText',
            'directPlayDecisionCode',
            'directPlayDecisionText',
            'transcodeDecisionCode',
            'transcodeDecisionText',
            'mdeDecisionCode',
            'mdeDecisionText',
          ])
            if (decided?[name] != null) name: decided![name],
        };
        _report('decision $name: status ${decision.statusCode}, $codes');
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// The form of a request path, its numbers and names left out: "/library/streams/#"
String _shape(String path) =>
    path.replaceAll(RegExp(r'\d+'), '#').replaceAll(RegExp(r'/[^/]*\.(?!srt)[^/.]+$'), '/file');

/// The letters of [word] without their accents
String _fold(String word) {
  const from = 'ÀÁÂÃÄÅàáâãäåÈÉÊËèéêëÌÍÎÏìíîïÒÓÔÕÖØòóôõöøÙÚÛÜùúûüÇçÑñÝýÿ';
  const to = 'AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOOooooooUUUUuuuuCcNnYyy';
  final buffer = StringBuffer();
  for (final char in word.split('')) {
    final index = from.indexOf(char);
    buffer.write(index < 0 ? char : to[index]);
  }
  return buffer.toString().replaceAll('Œ', 'OE').replaceAll('œ', 'oe');
}

/// The size a JPEG tells in its frame header, null for anything else
({int width, int height})? _jpegSize(Uint8List? bytes) {
  if (bytes == null || bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) {
    return null;
  }
  var i = 2;
  while (i + 9 < bytes.length) {
    if (bytes[i] != 0xff) {
      return null;
    }
    final marker = bytes[i + 1];
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc) {
      return (height: (bytes[i + 5] << 8) | bytes[i + 6], width: (bytes[i + 7] << 8) | bytes[i + 8]);
    }
    i += 2 + length;
  }
  return null;
}
