import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_list.dart';
import 'package:immich_mobile/providers/network/plex_film_list.provider.dart';

import 'fake_plex_server.dart';

Object? _fixture(String name) => jsonDecode(File('test/fixtures/plex/$name').readAsStringSync());

PlexFilm _film(String id, String title, int? year) => PlexFilm(ratingKey: id, title: title, year: year);

/// A films source in memory: the films of one section, in their order, with what it was asked
class _FakeFilms implements PlexFilmsSource {
  _FakeFilms(this.films);

  final List<PlexFilm> films;
  final List<int> pageStarts = [];
  final List<String> searched = [];
  final Set<int> failingStarts = {};
  List<PlexFilm> hubFilms = const [];
  Exception? hubError;

  /// Pages wait for this when set
  Completer<void>? gate;
  int concurrent = 0;
  int mostConcurrent = 0;

  @override
  String get filmsSourceId => 'plex';

  @override
  bool get isOutsideHome => false;

  List<PlexFilm> _of(PlexFilmListQuery query) {
    final text = query.searchedTitle?.toLowerCase();
    return text == null
        ? films
        : [
            for (final f in films)
              if (f.title.toLowerCase().contains(text)) f,
          ];
  }

  @override
  Future<List<int?>> filmYears(PlexFilmListQuery query) async => [for (final f in _of(query)) f.year];

  @override
  Future<PlexFilmListPage> filmsPage(PlexFilmListQuery query, {required int start, required int size}) async {
    pageStarts.add(start);
    concurrent++;
    mostConcurrent = concurrent > mostConcurrent ? concurrent : mostConcurrent;
    try {
      await gate?.future;
      if (failingStarts.contains(start)) {
        throw const PlexHttpStatus(500);
      }
      final all = _of(query);
      final page = all.skip(start).take(size).toList();
      return PlexFilmListPage(films: page, count: page.length, offset: start, totalSize: all.length);
    } finally {
      concurrent--;
    }
  }

  @override
  Future<List<PlexFilm>> searchFilms(String sectionKey, String text) async {
    searched.add(text);
    final error = hubError;
    if (error != null) {
      throw error;
    }
    return hubFilms;
  }

  @override
  Future<List<({PlexSection section, String folderPath})>> filmLibraries() async => const [];

  @override
  PlexSection? filmLibraryAt(String path) => null;
}

void main() {
  group('parsers', () {
    test('a page of /all?type=1: the films with their title, year and first file, the counts of the container', () {
      final page = parsePlexFilmListPage(_fixture('films_all_page.json'));
      expect(page.count, 4);
      expect(page.offset, 0);
      expect(page.totalSize, 4);
      expect([for (final f in page.films) f.title], ['The Example Night', 'Élan du matin', 'Ten Rooms', 'Home cut']);
      expect([for (final f in page.films) f.year], [2021, 2021, 2019, null]);
      final elan = page.films[1];
      expect(elan.ratingKey, '302');
      expect(elan.originalTitle, 'Morning Drive');
      expect(elan.contentRating, 'fr/12');
      expect(elan.viewOffsetMs, 1200000);
      expect(elan.thumb, '/library/metadata/302/thumb/1700000000');
      expect(elan.part?.partId, 4302);
      expect(elan.part?.name, 'Élan du matin (2021).mkv');
      expect(elan.part?.title, 'Élan du matin');
      expect(elan.part?.year, 2021);
      expect(elan.part?.isPoster, isTrue);
      expect(page.films.first.titleSort, 'Example Night');
      expect(page.films.first.viewCount, 1);
    });

    test('the light pass gives the year of each film in the order of the list', () {
      final page = parsePlexYearsPage(_fixture('films_years_light.json'));
      expect(page.years, [2021, 2021, 2019, null]);
      expect(page.count, 4);
      expect(page.totalSize, 4);
    });

    test('the elements that are no film are left out of both, so that the indexes agree', () {
      final json = {
        'MediaContainer': {
          'size': 3,
          'Metadata': [
            {'ratingKey': '1', 'type': 'movie', 'title': 'A', 'year': 2000},
            {'ratingKey': '2', 'type': 'collection', 'title': 'Box', 'year': 1999},
            {'ratingKey': '3', 'type': 'movie', 'title': ' ', 'year': 1998},
          ],
        },
      };
      expect(parsePlexYearsPage(json).years, [2000]);
      expect([for (final f in parsePlexFilmListPage(json).films) f.ratingKey], ['1']);
      expect(parsePlexFilmListPage(json).count, 3, reason: 'the next page starts after every element');
    });

    test('the hub search keeps the films of the section, from the movie hub only', () {
      final films = parsePlexHubFilms(_fixture('hubs_search.json'), '1');
      expect([for (final f in films) f.ratingKey], ['302']);
      expect(parsePlexHubFilms(_fixture('hubs_search.json'), '3').single.title, 'Elan');
      expect(
        parsePlexHubFilms({
          'MediaContainer': {'size': 0},
        }, '1'),
        isEmpty,
      );
    });

    test('a movie section of the Plex Movie agent is a film library, "Other videos" are not', () {
      const films = PlexSection(key: '1', title: 'Movies', type: 'movie', agent: 'tv.plex.agents.movie');
      const others = PlexSection(key: '4', title: 'Home', type: 'movie', agent: 'tv.plex.agents.none');
      const legacy = PlexSection(key: '5', title: 'Old', type: 'movie', agent: 'com.plexapp.agents.none');
      const photos = PlexSection(key: '2', title: 'Photos', type: 'photo', agent: 'com.plexapp.agents.none');
      expect([films.isFilms, others.isFilms, legacy.isFilms, photos.isFilms], [true, false, false, false]);
      final parsed = parsePlexSections(_fixture('sections.json'));
      expect(parsed.first.agent, 'tv.plex.agents.movie');
      expect(parsed.first.language, 'en-US');
      expect(parsed.first.isFilms, isTrue);
    });
  });

  group('the list', () {
    test('year groups in the order of the list, with their counts and first indexes, the unknown years together', () {
      expect(plexFilmYears([2021, 2021, 2019, null, null]), const [
        PlexFilmYear(year: 2021, count: 2, firstIndex: 0),
        PlexFilmYear(year: 2019, count: 1, firstIndex: 2),
        PlexFilmYear(year: null, count: 2, firstIndex: 3),
      ]);
      expect(plexFilmYears(const []), isEmpty);
    });

    test('the query: films only, newest year first, no collections, the filters but not over its own parameters', () {
      const query = PlexFilmListQuery(sectionKey: '1');
      expect(query.path, '/library/sections/1/all');
      expect(query.queryParameters(), {'type': '1', 'sort': 'year:desc,titleSort', 'includeCollections': '0'});
      final searched = query.copyWith(
        title: '  élan ',
        filters: {'year': '2021', 'type': '2', 'contentRating': 'fr/12'},
      );
      expect(searched.queryParameters(), {
        'type': '1',
        'sort': 'year:desc,titleSort',
        'includeCollections': '0',
        'year': '2021',
        'contentRating': 'fr/12',
        'title': 'élan',
      });
      expect(query.queryParameters(light: true), containsPair('excludeElements', startsWith('Media,')));
      expect(query.queryParameters(light: true), containsPair('excludeFields', 'summary,tagline'));
      expect(query.copyWith(title: ' '), query, reason: 'a blank search is none');
      expect(searched.copyWith(clearTitle: true).searchedTitle, isNull);
    });

    test('the path of a film: the same as the film page builds, read back, other paths refused', () {
      final part = parsePlexFilmListPage(_fixture('films_all_page.json')).films[1].part!;
      final path = plexFilmPartPath('1', '302', part);
      expect(path, '/.films/1/302/4302/Élan du matin (2021).mkv');
      expect(plexFilmPathParts(path), (sectionKey: '1', ratingKey: '302', partId: 4302));
      expect(plexFilmPathParts('/Movies/a.mp4'), isNull);
      expect(plexFilmPathParts('/.films/1/abc/4302/a.mkv'), isNull);
      expect(plexFilmPathParts('/.films/1/302/a.mkv'), isNull);
      final entry = plexFilmEntry('plex', '1', parsePlexFilmListPage(_fixture('films_all_page.json')).films[1])!;
      expect(entry.path, path);
      expect(entry.shownName, 'Élan du matin');
      expect(entry.name, 'Élan du matin (2021).mkv');
      expect(entry.size, 4000004302);
    });

    test('a search: the titles that hold the text, then what the tolerant search adds, each once, newest first', () {
      final merged = mergePlexSearch(
        [_film('1', 'Elan', 2001), _film('2', 'Elan II', 2005)],
        [_film('2', 'Elan II', 2005), _film('3', 'Elán', null), _film('4', 'Alan', 2010)],
        PlexFilmListSort.yearNewest,
      );
      expect([for (final f in merged) f.ratingKey], ['4', '2', '1', '3']);
    });

    test('pages as the grid wants them, two at a time, the last asked first, each once', () async {
      final source = _FakeFilms([for (var i = 0; i < 450; i++) _film('$i', 'Film $i', 2020 - i ~/ 100)]);
      final list = await PagedPlexFilms.load(source, const PlexFilmListQuery(sectionKey: '1'));
      addTearDown(list.dispose);
      expect(list.count, 450);
      expect([for (final y in list.years) y.year], [2020, 2019, 2018, 2017, 2016]);
      expect(list.filmAt(5)?.title, 'Film 5', reason: 'the first page comes with the years');
      expect(list.filmAt(150), isNull);
      expect(source.pageStarts, [0]);

      source.gate = Completer<void>();
      var notified = 0;
      list.addListener(() => notified++);
      list
        ..want(150)
        ..want(199)
        ..want(250)
        ..want(420)
        ..want(5);
      expect(source.pageStarts, [0, 100, 200], reason: 'two at a time');
      source.gate!.complete();
      await pumpEventQueue();
      expect(source.mostConcurrent, 2);
      expect(source.pageStarts, [0, 100, 200, 400]);
      expect(list.filmAt(420)?.title, 'Film 420');
      expect(list.filmAt(150)?.title, 'Film 150');
      expect(list.loadedPages.toSet(), {0, 1, 2, 4});
      expect(notified, greaterThanOrEqualTo(3));
    });

    test('a page that failed is asked again only after Retry', () async {
      final source = _FakeFilms([for (var i = 0; i < 250; i++) _film('$i', 'Film $i', 2000)]);
      final list = await PagedPlexFilms.load(source, const PlexFilmListQuery(sectionKey: '1'));
      addTearDown(list.dispose);
      source.failingStarts.add(100);
      list.want(120);
      await pumpEventQueue();
      expect(list.hasFailures, isTrue);
      list.want(130);
      await pumpEventQueue();
      expect(source.pageStarts.where((s) => s == 100), hasLength(1));
      source.failingStarts.clear();
      list.retryFailures();
      expect(list.hasFailures, isFalse);
      list.want(130);
      await pumpEventQueue();
      expect(list.filmAt(130)?.title, 'Film 130');
    });

    test('a list of no film shows its years as none', () async {
      final list = await PagedPlexFilms.load(_FakeFilms(const []), const PlexFilmListQuery(sectionKey: '1'));
      addTearDown(list.dispose);
      expect(list.count, 0);
      expect(list.years, isEmpty);
    });

    test('the films around one, for previous and next, skip those not come yet', () {
      final list = StaticPlexFilms([for (var i = 0; i < 30; i++) _film('$i', 'Film $i', 2000)]);
      final around = list.around(20, radius: 3);
      expect([for (final f in around.films) f.ratingKey], ['17', '18', '19', '20', '21', '22', '23']);
      expect(around.index, 3);
    });

    test('a search asks both, and the tolerant one failing or off with filters loses nothing', () async {
      final source = _FakeFilms([_film('1', 'Elan', 2001), _film('2', 'Other', 2002)])
        ..hubFilms = [_film('9', 'Élan', 1999)];
      final found = await searchPlexFilms(source, const PlexFilmListQuery(sectionKey: '1', title: 'elan'));
      expect([for (final f in found.films) f.ratingKey], ['1', '9']);
      expect(source.searched, ['elan']);

      source.hubError = const PlexHttpStatus(500);
      final without = await searchPlexFilms(source, const PlexFilmListQuery(sectionKey: '1', title: 'elan'));
      expect([for (final f in without.films) f.ratingKey], ['1']);

      final filtered = await searchPlexFilms(
        source,
        const PlexFilmListQuery(sectionKey: '1', title: 'elan', filters: {'year': '2001'}),
      );
      expect(source.searched, hasLength(2), reason: 'the hub search knows no filter');
      expect(filtered.films, hasLength(1));
      expect((await searchPlexFilms(source, const PlexFilmListQuery(sectionKey: '1'))).count, 0);
    });
  });

  group('PlexFileSystem', () {
    late FakePlexServer server;

    setUp(() async => server = await FakePlexServer.start());
    tearDown(() => server.close());

    const source = NetworkSource(
      id: '0123456789abcdef',
      type: NetworkSourceType.plex,
      name: 'Test Plex',
      host: '192.0.2.20',
      rootPath: '/',
      useTls: true,
      discoveryId: plexTestMachine,
      plex: PlexServerInfo(hash: plexTestHash),
    );

    Future<PlexFileSystem> open() async {
      final fileSystem = await PlexFileSystem.open(
        source,
        plexTestToken,
        baseOverride: server.base,
        clientIdentifier: 'client-test-0000',
      );
      addTearDown(fileSystem.close);
      return fileSystem;
    }

    test('the film libraries are the movie sections of a film agent, found at their folders', () async {
      final plex = await open();
      final libraries = await plex.filmLibraries();
      expect([for (final l in libraries) (l.section.key, l.folderPath)], [('1', '/Movies')]);
      expect(plex.filmLibraryAt('/Movies')?.title, 'Movies');
      expect(plex.filmLibraryAt('/Photos'), isNull);
      expect(plex.filmLibraryAt('/Movies/Holidays'), isNull);
    });

    test(
      'the years in pages of 1000 trimmed, the films in pages with the paging headers, the token in a header',
      () async {
        server.films['1'] = [for (var i = 0; i < 2300; i++) plexFilmElement(i + 1, 'Film $i', 2020 - i ~/ 500)];
        final plex = await open();
        const query = PlexFilmListQuery(sectionKey: '1');
        final years = await plex.filmYears(query);
        expect(years, hasLength(2300));
        expect(years.first, 2020);
        expect(years.last, 2016);
        final light = server.requests.where((r) => r.path == '/library/sections/1/all').toList();
        expect([for (final r in light) r.headers['x-plex-container-start']], ['0', '1000', '2000']);
        expect([for (final r in light) r.headers['x-plex-container-size']], ['1000', '1000', '1000']);
        final parameters = Uri(query: light.first.query).queryParameters;
        expect(parameters['type'], '1');
        expect(parameters['sort'], 'year:desc,titleSort');
        expect(parameters['includeCollections'], '0');
        expect(parameters['excludeElements'], startsWith('Media,'));
        expect(light.first.query, isNot(contains(plexTestToken)));
        expect(light.first.headers['x-plex-token'], plexTestToken);

        final page = await plex.filmsPage(query, start: 100, size: 100);
        expect(page.films.first.title, 'Film 100');
        expect(page.totalSize, 2300);
        final asked = server.requests.last;
        expect(asked.headers['x-plex-container-start'], '100');
        expect(Uri(query: asked.query).queryParameters.containsKey('excludeElements'), isFalse);

        // The file of a film listed is a file of the share, with its title
        final path = plexFilmEntry(plex.filmsSourceId, '1', page.films.first)!.path;
        final entry = await plex.stat(path);
        expect(entry.size, 1101);
        expect(entry.title, 'Film 100');
      },
    );

    test('a film path not met by this connection is found again through its metadata', () async {
      server.films['1'] = [plexFilmElement(7, 'Seven', 2001)];
      final plex = await open();
      final entry = await plex.stat('/.films/1/7/1007/Seven.mkv');
      expect(entry.title, 'Seven');
      expect(entry.size, 1007);
      expect(server.requests.any((r) => r.path == '/library/metadata/7'), isTrue);
      await expectLater(plex.stat('/.films/1/8/1008/Gone.mkv'), throwsA(anything));
    });

    test('a film poster is asked at 2:3, the frames of other files square', () async {
      server.films['1'] = [plexFilmElement(7, 'Seven', 2001)];
      server.thumbnails['/library/metadata/7/thumb/1700000000'] = Uint8List.fromList([0xff, 0xd8, 1]);
      final plex = await open();
      final page = await plex.filmsPage(const PlexFilmListQuery(sectionKey: '1'), start: 0, size: 100);
      final entry = plexFilmEntry(plex.filmsSourceId, '1', page.films.single)!;
      expect(await plex.thumbnail(entry, 360), isNotNull);
      final asked = Uri(query: server.requests.last.query).queryParameters;
      expect((asked['width'], asked['height']), ('240', '360'));
    });

    test('the tolerant search keeps the films of the section; a server without it finds nothing', () async {
      server.hubs = _fixture('hubs_search.json');
      final plex = await open();
      expect([for (final f in await plex.searchFilms('1', 'elan')) f.ratingKey], ['302']);
      final asked = Uri(query: server.requests.last.query).queryParameters;
      expect(asked, {'query': 'elan', 'sectionId': '1', 'limit': '30'});
      server.hubs = null;
      expect(await plex.searchFilms('1', 'elan'), isEmpty);
    });

    test('the title search of /all is "contains" on the server', () async {
      server.films['1'] = [plexFilmElement(1, 'Alpha', 2001), plexFilmElement(2, 'Beta', 2002)];
      final plex = await open();
      final found = await searchPlexFilms(plex, const PlexFilmListQuery(sectionKey: '1', title: 'LPH'));
      expect([for (final f in found.films) f.title], ['Alpha']);
    });

    test('the folder view of a film library shows the titles, "Other videos" keep the file names', () async {
      final plex = await open();
      final movies = await plex.list('/Movies');
      expect(movies.firstWhere((e) => e.name == 'a.mp4').title, 'Title 11');
      expect(movies.firstWhere((e) => e.name == 'a.mp4').shownName, 'Title 11');
    });
  });
}
