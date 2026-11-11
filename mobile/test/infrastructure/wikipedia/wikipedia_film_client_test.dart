// The Wikipedia client of the film page against a fake Wikimedia (http's MockClient, nothing leaves the machine): the
// article found through the IMDb number or the TMDB one, the films without an item or without an article in the chain,
// the variants, the pause after a 429, the timeout, the cache in memory and in its file, and the User-Agent.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_film_cache.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_film_client.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_languages.dart';

const matrix = FilmExternalIds(imdb: 'tt0133093', tmdb: '603');
const otherFilm = FilmExternalIds(imdb: 'tt0110912');

/// A Wikidata and some Wikipedias, from the maps the test fills; [answer] replaces every answer while it is set
class FakeWikimedia {
  /// Item by statement ("P345=tt0133093")
  final items = <String, String>{};

  /// Article title by item and site id
  final sitelinks = <String, Map<String, String>>{};

  /// Lead by wiki and title ("fr|Matrix (film)")
  final extracts = <String, String>{};

  final requests = <http.Request>[];
  Future<http.Response> Function(http.Request request)? answer;

  late final client = MockClient((request) async {
    requests.add(request);
    final answer = this.answer;
    if (answer != null) {
      return answer(request);
    }
    return _json(_answerOf(request));
  });

  List<Map<String, String>> get queries => [for (final request in requests) request.url.queryParameters];

  Object _answerOf(http.Request request) {
    final query = request.url.queryParameters;
    final host = request.url.host;
    if (host == 'www.wikidata.org') {
      if (query['action'] == 'query' && query['list'] == 'search') {
        final statement = query['srsearch']!.replaceFirst('haswbstatement:', '');
        final item = items[statement];
        return {
          'batchcomplete': '',
          'query': {
            'searchinfo': {'totalhits': item == null ? 0 : 1},
            'search': [
              if (item != null) {'ns': 0, 'title': item, 'pageid': 1},
            ],
          },
        };
      }
      if (query['action'] == 'wbgetentities') {
        final item = query['ids']!;
        final sites = query['sitefilter']!.split('|');
        final links = sitelinks[item] ?? const {};
        return {
          'entities': {
            item: {
              'type': 'item',
              'id': item,
              'sitelinks': {
                for (final site in sites)
                  if (links[site] != null) site: {'site': site, 'title': links[site], 'badges': <Object>[]},
              },
            },
          },
          'success': 1,
        };
      }
    }
    if (host.endsWith('.wikipedia.org')) {
      final wiki = host.substring(0, host.length - '.wikipedia.org'.length);
      final title = query['titles']!;
      final extract = extracts['$wiki|$title'];
      return {
        'batchcomplete': true,
        'query': {
          'pages': [
            if (extract == null)
              {'ns': 0, 'title': title, 'missing': true}
            else
              {'pageid': 7, 'ns': 0, 'title': title, 'extract': extract},
          ],
        },
      };
    }
    return {
      'error': {'code': 'unknown'},
    };
  }
}

http.Response _json(Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// A Wikimedia that knows The Matrix in French and English, and Pulp Fiction in English only
FakeWikimedia matrixWikimedia() => FakeWikimedia()
  ..items['P345=tt0133093'] = 'Q83495'
  ..items['P4947=603'] = 'Q83495'
  ..items['P345=tt0110912'] = 'Q104123'
  ..sitelinks['Q83495'] = {'frwiki': 'Matrix (film)', 'enwiki': 'The Matrix', 'zhwiki': '黑客帝国'}
  ..sitelinks['Q104123'] = {'enwiki': 'Pulp Fiction'}
  ..extracts['fr|Matrix (film)'] = '\n\nMatrix est un film de science-fiction.  \n\n\n  Il sort en 1999.\n\n'
  ..extracts['en|The Matrix'] = 'The Matrix is a 1999 science fiction action film.'
  ..extracts['zh|黑客帝国'] = '《黑客帝国》是1999年的科幻电影。'
  ..extracts['en|Pulp Fiction'] = 'Pulp Fiction is a 1994 crime film.';

void main() {
  late FakeWikimedia wikimedia;
  late DateTime now;
  late MemoryWikipediaFilmCache cache;
  late WikipediaFilmClient client;
  final french = wikipediaChainFor('fr');

  DateTime clock() => now;

  WikipediaFilmClient newClient({Duration timeout = const Duration(seconds: 5)}) => WikipediaFilmClient(
    client: wikimedia.client,
    userAgent: WikipediaFilmClient.userAgentFor('1.2.3'),
    cache: cache,
    timeout: timeout,
    clock: clock,
  );

  setUp(() {
    wikimedia = matrixWikimedia();
    now = DateTime.utc(2026, 11, 10, 12);
    cache = MemoryWikipediaFilmCache(clock: clock);
    client = newClient();
  });

  test('finds the article through the IMDb number, in the first language of the chain', () async {
    final summary = await client.summary(matrix, french);

    expect(summary, isNotNull);
    expect(summary!.wiki, 'fr');
    expect(summary.variant, isNull);
    expect(summary.title, 'Matrix (film)');
    expect(summary.extract, 'Matrix est un film de science-fiction.\nIl sort en 1999.');
    expect(summary.articleUrl, Uri.parse('https://fr.wikipedia.org/wiki/Matrix_(film)'));
    expect(summary.languageTag, 'fr');
    expect(summary.isRightToLeft, isFalse);

    expect(wikimedia.requests, hasLength(3));
    final [search, sitelinks, lead] = wikimedia.queries;
    expect(wikimedia.requests[0].url.host, 'www.wikidata.org');
    expect(search, {
      'action': 'query',
      'list': 'search',
      'srsearch': 'haswbstatement:P345=tt0133093',
      'srlimit': '1',
      'srprop': '',
      'format': 'json',
    });
    expect(sitelinks, {
      'action': 'wbgetentities',
      'ids': 'Q83495',
      'props': 'sitelinks',
      'sitefilter': 'frwiki|enwiki',
      'format': 'json',
    });
    expect(wikimedia.requests[2].url.host, 'fr.wikipedia.org');
    expect(wikimedia.requests[2].url.path, '/w/api.php');
    expect(lead, {
      'action': 'query',
      'prop': 'extracts',
      'exintro': '1',
      'explaintext': '1',
      'redirects': '1',
      'titles': 'Matrix (film)',
      'format': 'json',
      'formatversion': '2',
    });
  });

  test('finds the article through the TMDB number when the film has no IMDb one', () async {
    final summary = await client.summary(const FilmExternalIds(tmdb: '603'), french);

    expect(summary?.title, 'Matrix (film)');
    expect(wikimedia.queries.first['srsearch'], 'haswbstatement:P4947=603');
    expect(wikimedia.requests, hasLength(3));
  });

  test('tries the TMDB number when Wikidata does not know the IMDb one', () async {
    final summary = await client.summary(const FilmExternalIds(imdb: 'tt9999999', tmdb: '603'), french);

    expect(summary?.title, 'Matrix (film)');
    expect(wikimedia.queries.take(2).map((query) => query['srsearch']), [
      'haswbstatement:P345=tt9999999',
      'haswbstatement:P4947=603',
    ]);
  });

  test('a film without a Wikidata item gives null, and the miss is kept', () async {
    const unknown = FilmExternalIds(imdb: 'tt9999999', tmdb: '999999');

    expect(await client.summary(unknown, french), isNull);
    expect(wikimedia.requests, hasLength(2));
    expect(cache.entries.values.single.summary, isNull);

    // Asked again: the cached miss sends nothing
    expect(await client.summary(unknown, french), isNull);
    expect(await newClient().summary(unknown, french), isNull);
    expect(wikimedia.requests, hasLength(2));
  });

  test('a film without an article in the first wiki reads the next one of the chain', () async {
    final summary = await client.summary(otherFilm, french);

    expect(summary?.wiki, 'en');
    expect(summary?.title, 'Pulp Fiction');
    expect(summary?.languageTag, 'en');
    expect(summary?.articleUrl, Uri.parse('https://en.wikipedia.org/wiki/Pulp_Fiction'));
    expect(wikimedia.requests.map((request) => request.url.host), [
      'www.wikidata.org',
      'www.wikidata.org',
      'en.wikipedia.org',
    ]);
  });

  test('an article without a lead leaves the next wiki of the chain a chance', () async {
    wikimedia.extracts['fr|Matrix (film)'] = '\n \n';

    final summary = await client.summary(matrix, french);

    expect(summary?.wiki, 'en');
    expect(summary?.title, 'The Matrix');
    expect(wikimedia.requests.map((request) => request.url.host).skip(2), ['fr.wikipedia.org', 'en.wikipedia.org']);
  });

  test('no article in any wiki of the chain gives null, and the miss is kept', () async {
    wikimedia.sitelinks['Q83495'] = {'dewiki': 'Matrix (Film)'};

    expect(await client.summary(matrix, french), isNull);
    expect(wikimedia.requests, hasLength(2));
    expect(await client.summary(matrix, french), isNull);
    expect(wikimedia.requests, hasLength(2));
  });

  test('the variant of zh_Hans goes to the server and into the address of the article', () async {
    final chain = wikipediaChainFor('zh_Hans');
    final summary = await client.summary(matrix, chain);

    expect(wikimedia.queries[1]['sitefilter'], 'zhwiki|enwiki');
    expect(wikimedia.requests[2].url.host, 'zh.wikipedia.org');
    expect(wikimedia.queries[2]['variant'], 'zh-hans');
    expect(summary?.variant, 'zh-hans');
    expect(summary?.languageTag, 'zh-Hans');
    expect(summary?.articleUrl.queryParameters, {'variant': 'zh-hans'});
    expect(summary?.articleUrl.host, 'zh.wikipedia.org');
    expect(summary?.extract, '《黑客帝国》是1999年的科幻电影。');
  });

  test('the Cantonese chain asks the site id of its wiki, and the language tags of other wikis', () async {
    await client.summary(matrix, wikipediaChainFor('yue_Hant'));
    expect(wikimedia.queries[1]['sitefilter'], 'zh_yuewiki|zhwiki|enwiki');

    WikipediaFilmSummary of(String wiki, [String? variant]) => WikipediaFilmSummary(
      wiki: wiki,
      variant: variant,
      title: 't',
      extract: 'e',
      articleUrl: Uri.parse('https://$wiki.wikipedia.org/wiki/t'),
    );
    expect(of('zh-yue').languageTag, 'yue');
    expect(of('no').languageTag, 'nb');
    expect(of('als').languageTag, 'gsw');
    expect(of('sr', 'sr-el').languageTag, 'sr-Latn');
    expect(of('sr', 'sr-ec').languageTag, 'sr-Cyrl');
    expect(of('zh', 'zh-hant').languageTag, 'zh-Hant');
    expect(of('he').isRightToLeft, isTrue);
    expect(of('ar').isRightToLeft, isTrue);
  });

  group('a request to slow down', () {
    test('a 429 stops every request for its Retry-After', () async {
      wikimedia.answer = (_) async => http.Response('Too many requests', 429, headers: {'retry-after': '120'});

      expect(await client.summary(matrix, french), isNull);
      expect(wikimedia.requests, hasLength(1));
      expect(client.isPaused, isTrue);
      // The failure is not kept as a miss
      expect(cache.entries, isEmpty);

      wikimedia.answer = null;
      now = now.add(const Duration(seconds: 119));
      expect(await client.summary(matrix, french), isNull);
      expect(await client.summary(otherFilm, french), isNull);
      expect(wikimedia.requests, hasLength(1));

      now = now.add(const Duration(seconds: 2));
      expect(client.isPaused, isFalse);
      expect((await client.summary(matrix, french))?.title, 'Matrix (film)');
      expect(wikimedia.requests, hasLength(4));
    });

    test('a 429 without Retry-After stops them for 10 minutes', () async {
      wikimedia.answer = (_) async => http.Response('', 429);
      expect(await client.summary(matrix, french), isNull);
      wikimedia.answer = null;

      now = now.add(const Duration(minutes: 9, seconds: 59));
      expect(await client.summary(matrix, french), isNull);
      expect(wikimedia.requests, hasLength(1));

      now = now.add(const Duration(seconds: 2));
      expect(await client.summary(matrix, french), isNotNull);
    });

    test('a short Retry-After still stops them for 60 seconds, and an HTTP date is read', () async {
      wikimedia.answer = (_) async => http.Response('', 429, headers: {'retry-after': '5'});
      expect(await client.summary(matrix, french), isNull);
      now = now.add(const Duration(seconds: 59));
      expect(client.isPaused, isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(client.isPaused, isFalse);

      final until = now.add(const Duration(minutes: 5));
      wikimedia.answer = (_) async => http.Response('', 429, headers: {'retry-after': HttpDate.format(until)});
      expect(await client.summary(matrix, french), isNull);
      now = until.subtract(const Duration(seconds: 2));
      expect(client.isPaused, isTrue);
      now = until.add(const Duration(seconds: 1));
      expect(client.isPaused, isFalse);
    });

    test('a 503 with Retry-After stops them, one without is a plain failure', () async {
      wikimedia.answer = (_) async => http.Response('', 503);
      expect(await client.summary(matrix, french), isNull);
      expect(client.isPaused, isFalse);
      expect(cache.entries, isEmpty);

      wikimedia.answer = (_) async => http.Response('', 503, headers: {'retry-after': '90'});
      expect(await client.summary(matrix, french), isNull);
      expect(client.isPaused, isTrue);
      now = now.add(const Duration(seconds: 91));
      expect(client.isPaused, isFalse);
    });
  });

  test('no answer in time gives null, and the next request goes out', () async {
    client = newClient(timeout: const Duration(milliseconds: 50));
    wikimedia.answer = (_) => Completer<http.Response>().future;

    final watch = Stopwatch()..start();
    expect(await client.summary(matrix, french), isNull);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    expect(cache.entries, isEmpty);

    wikimedia.answer = null;
    expect((await client.summary(matrix, french))?.title, 'Matrix (film)');
  });

  test('an answer that is not JSON, or an error of the API, gives null and is not kept', () async {
    wikimedia.answer = (_) async => http.Response('<html>Wikimedia error</html>', 200);
    expect(await client.summary(matrix, french), isNull);
    wikimedia.answer = (_) async => _json({
      'error': {'code': 'internal_api_error'},
    });
    expect(await client.summary(matrix, french), isNull);
    wikimedia.answer = (_) async => http.Response('Forbidden', 403);
    expect(await client.summary(matrix, french), isNull);
    wikimedia.answer = (_) async => throw const SocketException('unreachable');
    expect(await client.summary(matrix, french), isNull);
    expect(cache.entries, isEmpty);

    wikimedia.answer = null;
    expect(await client.summary(matrix, french), isNotNull);
  });

  group('the cache', () {
    test('a film found sends no request the next time, from this client or another', () async {
      final first = await client.summary(matrix, french);
      expect(wikimedia.requests, hasLength(3));

      expect(await client.summary(matrix, french), first);
      expect(await newClient().summary(matrix, french), first);
      expect(wikimedia.requests, hasLength(3));
    });

    test('another chain is another entry', () async {
      await client.summary(matrix, french);
      final english = await client.summary(matrix, wikipediaChainFor('en'));
      expect(english?.title, 'The Matrix');
      expect(wikimedia.requests, hasLength(6));
    });

    test('an entry expires after 30 days', () async {
      await client.summary(matrix, french);
      now = now.add(const Duration(days: 29, hours: 23));
      await client.summary(matrix, french);
      expect(wikimedia.requests, hasLength(3));

      now = now.add(const Duration(hours: 2));
      expect((await client.summary(matrix, french))?.title, 'Matrix (film)');
      expect(wikimedia.requests, hasLength(6));
    });

    test('clearCache forgets every answer', () async {
      await client.summary(matrix, french);
      await client.clearCache();
      expect(cache.entries, isEmpty);
      await client.summary(matrix, french);
      expect(wikimedia.requests, hasLength(6));
    });

    test('two calls at once share one lookup', () async {
      final both = await Future.wait([client.summary(matrix, french), client.summary(matrix, french)]);
      expect(both.first, isNotNull);
      expect(both.last, both.first);
      expect(wikimedia.requests, hasLength(3));
    });
  });

  test('a film without a usable number, an empty chain or a closed client send nothing', () async {
    expect(const FilmExternalIds().isEmpty, isTrue);
    expect(const FilmExternalIds(imdb: 'tt0133093 OR x', tmdb: 'abc').isEmpty, isTrue);
    expect(const FilmExternalIds(imdb: ' tt0133093 ').validImdb, 'tt0133093');
    expect(await client.summary(const FilmExternalIds(imdb: 'nm0000206'), french), isNull);
    expect(await client.summary(matrix, const []), isNull);
    client.close();
    expect(await client.summary(matrix, french), isNull);
    expect(wikimedia.requests, isEmpty);
  });

  test('every request names the app in its User-Agent, without any e-mail address, and accepts JSON', () async {
    await client.summary(matrix, french);
    await client.summary(otherFilm, french);
    expect(wikimedia.requests, hasLength(6));
    for (final request in wikimedia.requests) {
      final userAgent = request.headers['user-agent'];
      expect(userAgent, 'Immuch360/1.2.3 (https://immuch360.com; https://github.com/freeKC/Immuch360) dart-http');
      expect(userAgent, isNot(contains('@')));
      expect(request.headers['accept'], 'application/json');
      expect(request.headers.keys.map((name) => name.toLowerCase()), isNot(contains('api-user-agent')));
      expect(request.method, 'GET');
      expect(request.url.scheme, 'https');
    }
    expect(WikipediaFilmClient.userAgentFor(null), startsWith('Immuch360/unknown ('));
    expect(WikipediaFilmClient.userAgentFor('  '), startsWith('Immuch360/unknown ('));
    expect(WikipediaFilmClient.userAgentFor('2.6.0+3000 (x)'), startsWith('Immuch360/2.6.0+3000x ('));
  });

  group('the summary in JSON', () {
    test('reads back what it wrote', () {
      final summary = WikipediaFilmSummary(
        wiki: 'sr',
        variant: 'sr-el',
        title: 'Matriks',
        extract: 'Matriks je film.',
        articleUrl: wikipediaArticleUrl(const WikipediaLanguage('sr', variant: 'sr-el'), 'Matriks'),
      );
      expect(WikipediaFilmSummary.fromJson(jsonDecode(jsonEncode(summary.toJson()))), summary);
      expect(summary.articleUrl.toString(), 'https://sr.wikipedia.org/wiki/Matriks?variant=sr-el');
    });

    test('anything else reads as null', () {
      expect(WikipediaFilmSummary.fromJson(null), isNull);
      expect(WikipediaFilmSummary.fromJson('text'), isNull);
      expect(WikipediaFilmSummary.fromJson({'wiki': 'fr', 'title': 't', 'extract': 'e'}), isNull);
      expect(
        WikipediaFilmSummary.fromJson({'wiki': 'fr', 'title': 't', 'extract': '', 'url': 'https://fr.wikipedia.org'}),
        isNull,
      );
    });
  });

  group('the file cache', () {
    late Directory directory;

    setUp(() async => directory = await Directory.systemTemp.createTemp('wikipedia_cache_test'));
    tearDown(() async => directory.delete(recursive: true));

    WikipediaFilmSummary summaryOf(int index) => WikipediaFilmSummary(
      wiki: 'en',
      title: 'Film $index',
      extract: 'Film $index is a film.',
      articleUrl: Uri.parse('https://en.wikipedia.org/wiki/Film_$index'),
    );

    File fileOf() => File('${directory.path}/${FileWikipediaFilmCache.fileName}');

    test('keeps the answers for the next run, misses included', () async {
      final first = FileWikipediaFilmCache(directory, clock: clock);
      await first.write('a', summaryOf(1));
      await first.write('b', null);

      final next = FileWikipediaFilmCache(directory, clock: clock);
      expect((await next.read('a'))?.summary, summaryOf(1));
      final miss = await next.read('b');
      expect(miss, isNotNull);
      expect(miss!.summary, isNull);
      expect(miss.at, now);
      expect(await next.read('c'), isNull);
    });

    test('keeps the 500 newest', () async {
      final cache = FileWikipediaFilmCache(directory, clock: clock);
      for (var i = 0; i < 505; i++) {
        now = now.add(const Duration(seconds: 1));
        await cache.write('film $i', summaryOf(i));
      }
      for (var i = 0; i < 5; i++) {
        expect(await cache.read('film $i'), isNull, reason: 'film $i');
      }
      expect((await cache.read('film 5'))?.summary, summaryOf(5));
      expect((await cache.read('film 504'))?.summary, summaryOf(504));

      final json = jsonDecode(await fileOf().readAsString()) as Map;
      expect(json['entries'], hasLength(FileWikipediaFilmCache.maxEntries));
      final next = FileWikipediaFilmCache(directory, clock: clock);
      expect(await next.read('film 4'), isNull);
      expect((await next.read('film 5'))?.summary, summaryOf(5));
    });

    test('writes that come together are all kept, and a clear after them wins', () async {
      final cache = FileWikipediaFilmCache(directory, clock: clock);
      await Future.wait([for (var i = 0; i < 20; i++) cache.write('film $i', summaryOf(i))]);
      final next = FileWikipediaFilmCache(directory, clock: clock);
      for (var i = 0; i < 20; i++) {
        expect((await next.read('film $i'))?.summary, summaryOf(i), reason: 'film $i');
      }

      await Future.wait([cache.write('last', summaryOf(99)), cache.clear()]);
      expect(fileOf().existsSync(), isFalse);
      expect(await FileWikipediaFilmCache(directory, clock: clock).read('last'), isNull);
    });

    test('a broken file reads as empty and is replaced at the next write', () async {
      await fileOf().writeAsString('{"version": 1, "entries": [{"key": ');
      final cache = FileWikipediaFilmCache(directory, clock: clock);
      expect(await cache.read('a'), isNull);

      await cache.write('a', summaryOf(1));
      expect(jsonDecode(await fileOf().readAsString()), isA<Map>());
      expect((await FileWikipediaFilmCache(directory, clock: clock).read('a'))?.summary, summaryOf(1));
    });

    test('an entry of another form is skipped, the others are read', () async {
      await fileOf().writeAsString(
        jsonEncode({
          'version': 1,
          'entries': [
            {'key': 'bad', 'at': 'yesterday', 'summary': null},
            {'key': 'odd', 'at': now.millisecondsSinceEpoch, 'summary': 'text'},
            {'key': 'good', 'at': now.millisecondsSinceEpoch, 'summary': summaryOf(2).toJson()},
          ],
        }),
      );
      final cache = FileWikipediaFilmCache(directory, clock: clock);
      expect(await cache.read('bad'), isNull);
      expect(await cache.read('odd'), isNull);
      expect((await cache.read('good'))?.summary, summaryOf(2));
    });

    test('an entry older than 30 days is ignored and dropped', () async {
      final cache = FileWikipediaFilmCache(directory, clock: clock);
      await cache.write('old', summaryOf(1));
      now = now.add(const Duration(days: 10));
      await cache.write('recent', summaryOf(2));

      now = now.add(const Duration(days: 21));
      expect(await cache.read('old'), isNull);
      expect(await FileWikipediaFilmCache(directory, clock: clock).read('old'), isNull);
      expect((await cache.read('recent'))?.summary, summaryOf(2));

      await cache.write('new', summaryOf(3));
      final keys = [
        for (final entry in (jsonDecode(await fileOf().readAsString()) as Map)['entries'] as List) entry['key'],
      ];
      expect(keys, ['recent', 'new']);
    });

    test('clear deletes the file', () async {
      final cache = FileWikipediaFilmCache(directory, clock: clock);
      await cache.write('a', summaryOf(1));
      expect(fileOf().existsSync(), isTrue);
      await cache.clear();
      expect(fileOf().existsSync(), isFalse);
      expect(await cache.read('a'), isNull);
    });

    test('serves the client between two runs', () async {
      final first = newClientWith(wikimedia, FileWikipediaFilmCache(directory, clock: clock), clock);
      expect((await first.summary(matrix, french))?.title, 'Matrix (film)');
      final next = newClientWith(wikimedia, FileWikipediaFilmCache(directory, clock: clock), clock);
      expect((await next.summary(matrix, french))?.title, 'Matrix (film)');
      expect(wikimedia.requests, hasLength(3));
    });
  });
}

WikipediaFilmClient newClientWith(FakeWikimedia wikimedia, WikipediaFilmCache cache, DateTime Function() clock) =>
    WikipediaFilmClient(
      client: wikimedia.client,
      userAgent: WikipediaFilmClient.userAgentFor('1.2.3'),
      cache: cache,
      clock: clock,
    );
