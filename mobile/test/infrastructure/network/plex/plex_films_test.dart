import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';

import 'fake_plex_server.dart';

Object? _fixture(String name) => jsonDecode(File('test/fixtures/plex/$name').readAsStringSync());

NetworkSource _source() => const NetworkSource(
  id: '0123456789abcdef',
  type: NetworkSourceType.plex,
  name: 'Test Plex',
  host: '192.0.2.20',
  rootPath: '/',
  useTls: true,
  discoveryId: plexTestMachine,
  plex: PlexServerInfo(hash: plexTestHash),
);

Map<String, Object?> _filmElement(int id, {int year = 2001, String rating = 'fr/12'}) => {
  'ratingKey': '$id',
  'key': '/library/metadata/$id',
  'type': 'movie',
  'title': 'Film $id',
  'year': year,
  'contentRating': rating,
  'thumb': '/library/metadata/$id/thumb/1700000000',
  'addedAt': 1600000000 + id,
  'Media': [
    {
      'id': id,
      'width': 1920,
      'height': 1080,
      'duration': 7200000,
      'container': 'mkv',
      'Part': [
        {
          'id': id * 10,
          'key': '/library/parts/${id * 10}/1700000000/file.mkv',
          'file': '/data/movies/Film $id ($year)/Film $id ($year).mkv',
          'size': 1000,
          'container': 'mkv',
        },
      ],
    },
  ],
};

void main() {
  group('parsePlexFilmDetails', () {
    final film = parsePlexFilmDetails(_fixture('metadata_film.json'))!;

    test('reads the texts, the people, the ratings and the resume point', () {
      expect(film.ratingKey, '401');
      expect(film.type, 'movie');
      expect(film.title, 'A Made Up Film');
      expect(film.originalTitle, 'Un film inventé');
      expect(film.year, 2001);
      expect(film.tagline, 'Nothing is real.');
      expect(film.summary, startsWith('Made up for the tests.'));
      expect(film.contentRating, 'fr/12');
      expect(film.durationMs, 7320000);
      expect(film.viewOffsetMs, 4323000);
      expect(film.genres, ['Comedy', 'Romance']);
      expect(film.countries, ['France']);
      expect(film.directors.single.name, 'Jeanne Exemple');
      expect(film.writers.single.name, 'Paul Exemple');
      expect([for (final role in film.roles) '${role.name}/${role.role}'], ['Alice Test/Amélie', 'Bob Sample/Nino']);
      expect(film.sectionKey, '1');
      expect(film.thumb, '/library/metadata/401/thumb/1700000000');
      expect(film.art, '/library/metadata/401/art/1700000000');
      expect(
        [for (final rating in film.ratings) '${rating.source} ${rating.text} ${rating.audience}'],
        ['Rotten Tomatoes 91 % false', 'Rotten Tomatoes 84 % true'],
      );
    });

    test('reads the IMDb and TMDB numbers of the Guid array', () {
      expect(film.externalIds.imdb, 'tt0000401');
      expect(film.externalIds.tmdb, '401');
    });

    test('reads the files and their streams, the side files apart', () {
      final part = film.parts.single;
      expect(part.id, 4010);
      expect(part.fileName, 'A Made Up Film (2001).mkv');
      expect(part.size, 8804682956);
      expect(film.mediaOf(part)!.videoResolution, '1080');
      final audio = part.streamsOf(PlexStreamType.audio);
      expect([for (final stream in audio) stream.label], ['Français (AC3 5.1)', 'English (AC3 5.1)']);
      expect(audio.first.selected, isTrue);
      final subtitles = part.streamsOf(PlexStreamType.subtitle);
      expect([for (final stream in subtitles) stream.isSidecar], [false, true, true]);
      expect([for (final stream in subtitles) stream.isTextSubtitle], [true, true, false]);
      expect(subtitles[1].forced, isTrue);
      expect(subtitles[1].label, 'Français Forced (SRT External)');
      expect(film.partOf(4010), same(part));
      expect(film.partOf(999), same(part), reason: 'the first file when the part asked for is gone');
    });

    test('is null without an item', () {
      expect(
        parsePlexFilmDetails({
          'MediaContainer': {'size': 0},
        }),
        isNull,
      );
      expect(parsePlexFilmDetails('nothing'), isNull);
    });
  });

  group('parsePlexExternalIds', () {
    test('reads the guid of the legacy agents', () {
      expect(parsePlexExternalIds({'guid': 'com.plexapp.agents.imdb://tt0133093?lang=fr'}).imdb, 'tt0133093');
      expect(parsePlexExternalIds({'guid': 'com.plexapp.agents.themoviedb://603?lang=fr'}).tmdb, '603');
    });

    test('leaves out a plex guid, other schemes and malformed numbers', () {
      final ids = parsePlexExternalIds({
        'guid': 'plex://movie/5d776825880197001ec967c8',
        'Guid': [
          {'id': 'tvdb://12'},
          {'id': 'imdb://nm0000206'},
          {'id': 'tmdb://abc'},
        ],
      });
      expect(ids.isEmpty, isTrue);
    });
  });

  group('filters', () {
    test('reads the filters of a library and the values of one', () {
      final filters = parsePlexSectionFilters(_fixture('section_filters.json'));
      expect([for (final filter in filters) filter.filter], ['genre', 'year', 'decade', 'contentRating']);
      expect(filters[1].key, '/library/sections/1/year');
      final years = parsePlexFilterChoices(_fixture('filter_year.json'));
      expect([for (final year in years) year.key], ['2001', '1994', '1999']);
      expect(years.first.count, isNull, reason: 'the server tells no count here');
      expect(
        parsePlexFilterChoices({
          'MediaContainer': {
            'Directory': [
              {'key': 'PG', 'title': 'PG', 'size': 4},
            ],
          },
        }).single.count,
        4,
      );
    });

    test('the values PMS 1.42.1 sends percent encoded are kept as the films hold them', () {
      final values = parsePlexFilterChoices({
        'MediaContainer': {
          'Directory': [
            for (final (key, title) in [
              ('fr%2F12', 'fr/12'),
              ('fr%2F12%20avec%20avertissement', 'fr/12 avec avertissement'),
              ('Not%20Rated', 'Not Rated'),
              ('13%2B', '13+'),
              ('PG-13', 'PG-13'),
              ('100%zz', '100%zz'),
            ])
              {'fastKey': '/library/sections/1/all?contentRating=$key', 'key': key, 'title': title},
          ],
        },
      });
      expect(
        [for (final value in values) value.key],
        ['fr/12', 'fr/12 avec avertissement', 'Not Rated', '13+', 'PG-13', '100%zz'],
      );
      expect(values.first.title, 'fr/12');
      expect(audienceBandOf(values.first.key), AudienceBand.age12, reason: 'the band reads the decoded value');
      final query = PlexFilmsQuery(contentRatings: {values.first.key, values[2].key}).toQueryParameters();
      expect(
        Uri(path: '/all', queryParameters: query).query,
        contains('contentRating=Not+Rated%2Cfr%2F12'),
        reason: 'encoded once, by the query',
      );
    });
  });

  group('PlexFilmsQuery', () {
    test('films sorted by year, newest first, by default', () {
      expect(const PlexFilmsQuery().toQueryParameters(), {'type': '1', 'sort': 'year:desc,titleSort'});
      expect(const PlexFilmsQuery().isFiltered, isFalse);
    });

    test('years alone, decades alone, both as one list of years', () {
      expect(const PlexFilmsQuery(years: {2001, 1994}).toQueryParameters()['year'], '1994,2001');
      expect(const PlexFilmsQuery(decades: {2000, 1990}).toQueryParameters()['decade'], '1990,2000');
      final both = const PlexFilmsQuery(years: {2015}, decades: {1990}).toQueryParameters();
      expect(both['decade'], isNull);
      expect(both['year'], '1990,1991,1992,1993,1994,1995,1996,1997,1998,1999,2015');
    });

    test('content ratings as Plex stores them, OR inside, and not watched', () {
      final query = const PlexFilmsQuery(
        contentRatings: {'fr/12', 'PG-13'},
        unwatched: true,
        sort: PlexFilmSort.title,
      ).toQueryParameters();
      expect(query['contentRating'], 'PG-13,fr/12');
      expect(query['unwatched'], '1');
      expect(query['sort'], 'titleSort');
    });

    test('compares by value, so that a provider keyed by it is shared', () {
      expect(const PlexFilmsQuery(years: {1, 2}), const PlexFilmsQuery(years: {2, 1}));
      expect(const PlexFilmsQuery(years: {1}).hashCode, const PlexFilmsQuery(years: {1}).hashCode);
      expect(const PlexFilmsQuery(years: {1}), isNot(const PlexFilmsQuery(decades: {1})));
    });
  });

  group('audienceBandOf', () {
    test('the named ratings of the main systems', () {
      final bands = {
        'G': AudienceBand.all,
        'PG': AudienceBand.age10,
        'PG-13': AudienceBand.age12,
        'R': AudienceBand.age16,
        'NC-17': AudienceBand.age18,
        'TV-MA': AudienceBand.age18,
        'fr/U': AudienceBand.all,
        'fr/Tous publics': AudienceBand.all,
        'gb/U': AudienceBand.all,
        'gb/PG': AudienceBand.age10,
        'gb/12A': AudienceBand.age12,
        'gb/15': AudienceBand.age16,
        'gb/18': AudienceBand.age18,
        'au/MA15+': AudienceBand.age16,
        'ca/14A': AudienceBand.age16,
        'NR': AudienceBand.unrated,
        'Not Rated': AudienceBand.unrated,
        // The French values of a library of PMS 1.42.1 (11 November 2026)
        'fr/TP': AudienceBand.all,
        'fr/Tous publics avec avertissement': AudienceBand.all,
        'fr/12 avec avertissement': AudienceBand.age12,
        'fr/Accord parental': AudienceBand.age12,
        'fr/NR': AudienceBand.unrated,
        'fr/Not Rated': AudienceBand.unrated,
        'None': AudienceBand.unrated,
        'fr/14+': AudienceBand.age16,
        '13+': AudienceBand.age16,
      };
      for (final MapEntry(:key, :value) in bands.entries) {
        expect(audienceBandOf(key), value, reason: key);
      }
    });

    test('a number after a country goes to the band at or above it', () {
      final bands = {
        'de/0': AudienceBand.all,
        'de/6': AudienceBand.all,
        'nl/9': AudienceBand.age10,
        'fr/10': AudienceBand.age10,
        'fr/12': AudienceBand.age12,
        'it/14': AudienceBand.age16,
        'de/16': AudienceBand.age16,
        'fr/18': AudienceBand.age18,
        '18+': AudienceBand.age18,
        'FSK 12': AudienceBand.age12,
      };
      for (final MapEntry(:key, :value) in bands.entries) {
        expect(audienceBandOf(key), value, reason: key);
      }
    });

    test('no rating is not rated, a word the table does not know is left as it is', () {
      expect(audienceBandOf(null), AudienceBand.unrated);
      expect(audienceBandOf(' '), AudienceBand.unrated);
      expect(audienceBandOf('xx/Q'), isNull);
      expect(audienceBandOf('Banned'), isNull);
    });
  });

  group('plexFilmPath', () {
    test('goes there and back, a file name made safe', () {
      final path = plexFilmPath(sectionKey: '1', ratingKey: '401', partId: 4010, name: 'A/B: film.mkv');
      expect(path, startsWith('/.films/1/401/4010/'));
      expect(path.split('/').length, 6);
      expect(parsePlexFilmPath(path), (sectionKey: '1', ratingKey: '401', partId: 4010));
      expect(parsePlexFilmPath('/Movies/a.mkv'), isNull);
      expect(parsePlexFilmPath('/.films/1/x/4010/a.mkv'), isNull);
    });
  });

  group('sections', () {
    test('keep their agent and language, a library of films told from other videos', () {
      final sections = parsePlexSections(_fixture('sections.json'));
      final movies = sections.firstWhere((section) => section.type == 'movie');
      expect(movies.agent, 'tv.plex.agents.movie');
      expect(movies.language, 'en-US');
      expect(movies.isFilms, isTrue);
      expect(const PlexSection(key: '9', title: 'Clips', type: 'movie', agent: 'tv.plex.agents.none').isFilms, isFalse);
      expect(const PlexSection(key: '8', title: 'Photos', type: 'photo').isFilms, isFalse);
    });
  });

  group('PlexFileSystem', () {
    late FakePlexServer server;

    setUp(() async {
      server = await FakePlexServer.start();
      server.metadata['401'] = _fixture('metadata_film.json');
      server.listings['/library/sections/1/filters'] = [
        for (final element in (_fixture('section_filters.json')! as Map)['MediaContainer']['Directory'] as List)
          (element as Map).cast<String, Object?>(),
      ];
      for (final (name, file) in [
        ('year', 'filter_year.json'),
        ('decade', 'filter_decade.json'),
        ('contentRating', 'filter_content_rating.json'),
      ]) {
        server.listings['/library/sections/1/$name'] = [
          for (final element in (_fixture(file)! as Map)['MediaContainer']['Directory'] as List)
            (element as Map).cast<String, Object?>(),
        ];
      }
      server.partSizes[4010] = 2000;
    });
    tearDown(() => server.close());

    Future<PlexFileSystem> open() async {
      final fileSystem = await PlexFileSystem.open(
        _source(),
        plexTestToken,
        baseOverride: server.base,
        clientIdentifier: 'client-test-0000',
      );
      addTearDown(fileSystem.close);
      return fileSystem;
    }

    test('reads the full item of a film with its Guid elements', () async {
      final plex = await open();
      final film = await plex.filmDetails('401');
      expect(film.title, 'A Made Up Film');
      final request = server.requests.lastWhere((r) => r.path == '/library/metadata/401');
      expect(request.query, 'includeGuids=1');
      expect(request.headers['x-plex-token'], plexTestToken);
    });

    test('a film the server no longer has is not found', () async {
      final plex = await open();
      await expectLater(
        plex.filmDetails('999'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
    });

    test('a path of a film opens the file of its item, never met in a listing', () async {
      final plex = await open();
      final path = plexFilmPath(sectionKey: '1', ratingKey: '401', partId: 4010, name: 'A Made Up Film (2001).mkv');
      final entry = await plex.stat(path);
      expect(entry.isDirectory, isFalse);
      expect(entry.size, 8804682956);
      expect(entry.mimeType, 'video/x-matroska');
      final item = plex.itemAt(path)!;
      expect(item.ratingKey, '401');
      expect(item.partId, 4010);
      expect(item.opensFilmPage, isTrue);
      final bytes = await plex.readRange(path, 0, 16);
      expect(bytes, plexPartBytes(4010, 2000).sublist(0, 16));
    });

    test('a path of a film whose file is gone is not found', () async {
      final plex = await open();
      final path = plexFilmPath(sectionKey: '1', ratingKey: '401', partId: 77, name: 'gone.mkv');
      await expectLater(
        plex.stat(path),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
    });

    test('the items of the folder view of a library of films open the film page', () async {
      final plex = await open();
      final entries = await plex.list('/Movies');
      final file = entries.firstWhere((entry) => !entry.isDirectory && entry.isVideo);
      final item = plex.itemAt(file.path)!;
      expect(item.ratingKey, '11');
      expect(item.section?.isFilms, isTrue);
      expect(item.opensFilmPage, isTrue);
      expect(plex.sectionAt('/Movies')?.key, '1');
      expect(plex.sectionAt('/Movies/Holidays'), isNull);
      expect(plex.itemAt('/Movies/Holidays'), isNull);
    });

    test('Show the folders: the folder of a listed file, the folder of the library for a film path', () async {
      final plex = await open();
      final filmPath = plexFilmPath(sectionKey: '1', ratingKey: '401', partId: 4010, name: 'A Made Up Film (2001).mkv');
      // The root is listed on the way when this connection has not listed it
      expect(await plex.folderOfFilm(filmPath, '1'), '/Movies');
      expect(await plex.folderOfFilm('/Movies/Holidays/Film.mkv', '1'), '/Movies/Holidays');
      expect(await plex.folderOfFilm(null, '1'), '/Movies');
      expect(await plex.folderOfFilm(filmPath, '99'), isNull, reason: 'a library the server no longer lists');
      expect(await plex.folderOfFilm(null, null), isNull);
    });

    test('lists the films a query keeps, under their own paths, with the query on /all', () async {
      const query = PlexFilmsQuery(decades: {2000}, contentRatings: {'fr/12'});
      final key = Uri(path: '/library/sections/1/all', queryParameters: query.toQueryParameters()).toString();
      server.listings[key] = [_filmElement(501), _filmElement(502, year: 2005), _filmElement(503, year: 2009)];
      final plex = await open();
      await plex.list('/');
      final films = await plex.allFilms('1', query);
      expect([for (final film in films) film.item.title], ['Film 501', 'Film 502', 'Film 503']);
      final first = films.first.entry;
      expect(first.path, startsWith('/.films/1/501/5010/'));
      expect(first.size, 1000);
      expect(plex.itemAt(first.path)!.section?.key, '1');
      final request = server.requests.lastWhere((r) => r.path == '/library/sections/1/all');
      expect(Uri.splitQueryString(request.query!), {
        'type': '1',
        'sort': 'year:desc,titleSort',
        'decade': '2000',
        'contentRating': 'fr/12',
      });
      expect(request.headers['x-plex-container-start'], '0');
      // Its thumbnail comes from the server's transcoder like any file of the share
      server.thumbnails['/library/metadata/501/thumb/1700000000'] = Uint8List.fromList([1, 2, 3]);
      expect(await plex.thumbnail(first, 200), [1, 2, 3]);
    });

    test('reads the filters of a library and the values behind their keys', () async {
      final plex = await open();
      final filters = await plex.sectionFilters('1');
      final ratings = await plex.filterChoices('1', filters.firstWhere((f) => f.filter == 'contentRating'));
      expect([for (final rating in ratings) rating.key], ['fr/12', 'PG-13', 'G', 'NR', 'xx/Q']);
      final relative = await plex.filterChoices('1', const PlexSectionFilter(filter: 'year', key: 'year'));
      expect(relative, hasLength(3), reason: 'a relative key is read from the section');
    });

    test('a picture of the server goes through its transcoder, an address of Plex never', () async {
      server.thumbnails['/library/metadata/401/art/1700000000'] = Uint8List.fromList([9, 9]);
      final plex = await open();
      expect(await plex.picture('/library/metadata/401/art/1700000000', width: 640, height: 360), [9, 9]);
      final request = server.requests.lastWhere((r) => r.path == '/photo/:/transcode');
      expect(Uri.splitQueryString(request.query!)['width'], '640');
      expect(Uri.splitQueryString(request.query!)['height'], '360');
      final before = server.requests.length;
      expect(await plex.picture('https://metadata-static.plex.tv/1/people/1.jpg', width: 64, height: 64), isNull);
      expect(server.requests.length, before, reason: 'nothing sent anywhere');
    });

    test('reads a text subtitle file beside a film from its key, never an image one', () async {
      server.subtitles[40105] = Uint8List.fromList(utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nBonjour\n'));
      final plex = await open();
      final part = (await plex.filmDetails('401')).parts.single;
      final subtitles = part.streamsOf(PlexStreamType.subtitle);
      expect(utf8.decode((await plex.subtitleFile(subtitles[1]))!), contains('Bonjour'));
      final request = server.requests.lastWhere((r) => r.path == '/library/streams/40105');
      expect(Uri.splitQueryString(request.query!), {'encoding': 'utf-8'});
      expect(request.headers['x-plex-token'], plexTestToken, reason: 'the token as a header, never in the address');
      expect(await plex.subtitleFile(subtitles[2]), isNull, reason: 'PGS is an image subtitle');
      expect(await plex.subtitleFile(subtitles[0]), isNull, reason: 'inside the file');
    });

    // The side files of a Plex Media Server 1.42.1 (11 November 2026): served as they are on the disk at their key, a
    // .srt path for a file Plex calls WebVTT answered 404, and three SubRip files of 24 were Latin-1
    test('reads every side file of a real server: WebVTT by name, Latin-1 in UTF-8', () async {
      server.metadata['501'] = _fixture('metadata_film_sidecars.json');
      server.subtitles[50103] = Uint8List.fromList(utf8.encode('1\n00:01:20,874 --> 00:01:22,917\nHow do you feel?\n'));
      server.subtitles[50104] = Uint8List.fromList(latin1.encode('1\n00:00:01,000 --> 00:00:02,000\nÉté à la mer\n'));
      server.subtitles[50105] = Uint8List.fromList([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('[Script Info]\nScriptType: v4.00+\n'),
      ]);
      final plex = await open();
      final sidecars = (await plex.filmDetails('501')).parts.single.streamsOf(PlexStreamType.subtitle);
      expect(
        [for (final stream in sidecars) (stream.codec, stream.isSidecar, stream.isTextSubtitle)],
        [('srt', true, true), ('srt', true, true), ('vtt', true, true)],
      );
      expect(utf8.decode((await plex.subtitleFile(sidecars[0]))!), contains('How do you feel?'));
      expect(utf8.decode((await plex.subtitleFile(sidecars[1]))!), contains('Été à la mer'));
      expect(utf8.decode((await plex.subtitleFile(sidecars[2]))!), contains('[Script Info]'));
      final paths = [for (final r in server.requests.where((r) => r.path.startsWith('/library/streams/'))) r.path];
      expect(paths, ['/library/streams/50103', '/library/streams/50104', '/library/streams/50105']);
    });

    test('writes the track picked back to the part, 0 for subtitles off', () async {
      final plex = await open();
      await plex.selectStreams(4010, audioStreamId: 40103);
      await plex.selectStreams(4010, subtitleStreamId: 0);
      final puts = server.requests.where((r) => r.method == 'PUT').toList();
      expect([for (final put in puts) put.path], ['/library/parts/4010', '/library/parts/4010']);
      expect(Uri.splitQueryString(puts[0].query!), {'audioStreamID': '40103', 'allParts': '1'});
      expect(Uri.splitQueryString(puts[1].query!), {'subtitleStreamID': '0', 'allParts': '1'});
      expect(puts.every((put) => put.headers['x-plex-token'] == plexTestToken), isTrue);
    });
  });
}
