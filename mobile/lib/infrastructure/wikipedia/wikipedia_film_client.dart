// The Wikipedia block of the film page: the lead of the film's article, in the first language of the chain that has
// one. The article is found through Wikidata from the IMDb number of the film, else its TMDB number, never from its
// title: a film without a match gets no block rather than another film's. Three requests for a new film (the item,
// its sitelinks in the chain's wikis, the text), none for a film seen within 30 days (see wikipedia_film_cache.dart).
//
// Every install sends the same User-Agent, as the Wikimedia User-Agent policy asks of a client (its name, version and
// contact, then its library), and Wikimedia counts the requests of all of them against one budget per minute keyed by
// that contact. So the client sends one request at a time, stops every request when told to slow down (429, or 503
// with a Retry-After), and remembers the films without an article as well as the others. The Api-User-Agent header
// is not sent: the policy asks for it only from scripts in a browser, which cannot set User-Agent, and the app sets
// User-Agent itself on every platform it runs on.
//
// Nothing here throws to the page: a film not found, an answer that is not JSON, a failure of the network or no
// answer in time all give null, and the page shows the rest of its information.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_film_cache.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_languages.dart';
import 'package:logging/logging.dart';

final _log = Logger('WikipediaFilmClient');

final _imdbId = RegExp(r'^tt\d{5,10}$');
final _tmdbId = RegExp(r'^\d{1,10}$');
final _wikidataItemId = RegExp(r'^Q\d+$');

/// The numbers of a film at IMDb ("tt0133093") and at TMDB ("603"), from the guids Plex gives it. A number that does
/// not have its usual form is left out, so that nothing else ends up in a search of Wikidata.
class FilmExternalIds {
  const FilmExternalIds({this.imdb, this.tmdb});

  final String? imdb;
  final String? tmdb;

  /// The IMDb number when it has the form "tt" and digits
  String? get validImdb => _valid(imdb, _imdbId);

  /// The TMDB number when it has the form of digits
  String? get validTmdb => _valid(tmdb, _tmdbId);

  /// Whether no number can be searched: such a film gets no Wikipedia block
  bool get isEmpty => validImdb == null && validTmdb == null;

  static String? _valid(String? value, RegExp form) {
    final trimmed = value?.trim();
    return trimmed != null && form.hasMatch(trimmed) ? trimmed : null;
  }

  @override
  bool operator ==(Object other) =>
      other is FilmExternalIds && other.validImdb == validImdb && other.validTmdb == validTmdb;

  @override
  int get hashCode => Object.hash(validImdb, validTmdb);

  @override
  String toString() => 'FilmExternalIds(imdb: $imdb, tmdb: $tmdb)';
}

/// The key of the answer for [ids] read through [chain] in the cache: another chain (the app's language changed) may
/// find another article
String wikipediaFilmCacheKey(FilmExternalIds ids, List<WikipediaLanguage> chain) {
  final wikis = chain.map(
    (language) => language.variant == null ? language.wiki : '${language.wiki}:${language.variant}',
  );
  return 'imdb=${ids.validImdb ?? ''};tmdb=${ids.validTmdb ?? ''};${wikis.join(',')}';
}

/// The BCP 47 language of the wikis whose subdomain is not one
const _wikiLanguages = {
  'zh-yue': 'yue',
  'no': 'nb',
  'als': 'gsw',
  'simple': 'en',
  'zh-min-nan': 'nan',
  'zh-classical': 'lzh',
  'be-tarask': 'be',
  'be-x-old': 'be',
  'bat-smg': 'sgs',
  'fiu-vro': 'vro',
  'roa-rup': 'rup',
};

/// The scripts the server converts to, as BCP 47 script subtags
const _variantScripts = {'zh-hans': 'Hans', 'zh-hant': 'Hant', 'sr-el': 'Latn', 'sr-ec': 'Cyrl'};

/// The wikis written from right to left
const _rightToLeftWikis = {
  'ar',
  'arc',
  'arz',
  'azb',
  'ckb',
  'dv',
  'fa',
  'glk',
  'he',
  'ks',
  'lrc',
  'mzn',
  'pnb',
  'ps',
  'sd',
  'ug',
  'ur',
  'yi',
};

/// The lead of the article of a film on the wiki [wiki], converted to the script of [variant] when there is one.
/// [extract] is plain text, one paragraph per line; its licence is CC BY-SA 4.0, so the page shows it with [title]
/// and a link to [articleUrl].
class WikipediaFilmSummary {
  const WikipediaFilmSummary({
    required this.wiki,
    this.variant,
    required this.title,
    required this.extract,
    required this.articleUrl,
  });

  final String wiki;
  final String? variant;
  final String title;
  final String extract;
  final Uri articleUrl;

  /// The language of the text as a BCP 47 tag, for the chip that tells it when it is not the app's: "fr", "yue" for
  /// the Cantonese wiki, "nb" for the Norwegian one, "gsw" for the Alemannic one, and the script after the language
  /// when the server converted the text ("zh-Hans", "sr-Latn")
  String get languageTag {
    final language = _wikiLanguages[wiki] ?? wiki;
    final script = _variantScripts[variant];
    return script == null ? language : '$language-$script';
  }

  /// Whether the text reads from right to left, whatever the direction of the app
  bool get isRightToLeft => _rightToLeftWikis.contains(wiki);

  Map<String, Object?> toJson() => {
    'wiki': wiki,
    'variant': ?variant,
    'title': title,
    'extract': extract,
    'url': articleUrl.toString(),
  };

  /// The summary [toJson] wrote, null for anything else
  static WikipediaFilmSummary? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final wiki = json['wiki'];
    final variant = json['variant'];
    final title = json['title'];
    final extract = json['extract'];
    final url = json['url'];
    if (wiki is! String || (variant != null && variant is! String) || title is! String || extract is! String) {
      return null;
    }
    final articleUrl = url is String ? Uri.tryParse(url) : null;
    if (articleUrl == null || articleUrl.scheme != 'https' || extract.isEmpty) {
      return null;
    }
    return WikipediaFilmSummary(
      wiki: wiki,
      variant: variant as String?,
      title: title,
      extract: extract,
      articleUrl: articleUrl,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WikipediaFilmSummary &&
      other.wiki == wiki &&
      other.variant == variant &&
      other.title == title &&
      other.extract == extract &&
      other.articleUrl == articleUrl;

  @override
  int get hashCode => Object.hash(wiki, variant, title, extract, articleUrl);

  @override
  String toString() => 'WikipediaFilmSummary($wiki${variant == null ? '' : ' $variant'}, $title)';
}

/// [text] without its empty lines and the spaces around each line: the plain text of an extract keeps the blank
/// lines of the article's markup
String cleanWikipediaExtract(String text) =>
    text.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).join('\n');

/// The address of the article [title] on the wiki of [language], in the script of its variant
Uri wikipediaArticleUrl(WikipediaLanguage language, String title) => Uri(
  scheme: 'https',
  host: '${language.wiki}.wikipedia.org',
  pathSegments: ['wiki', title.replaceAll(' ', '_')],
  queryParameters: language.variant == null ? null : {'variant': language.variant},
);

/// A request that brought no usable answer: the film is not known to have no article, so nothing is cached
class _Unanswered implements Exception {
  const _Unanswered(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Finds the Wikipedia lead of a film, see the top of this file
class WikipediaFilmClient {
  WikipediaFilmClient({
    required http.Client client,
    required this._userAgent,
    this._cache,
    this.timeout = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : _http = client,
       _clock = clock ?? DateTime.now;

  final http.Client _http;
  final String _userAgent;
  final WikipediaFilmCache? _cache;
  final DateTime Function() _clock;

  /// Longest wait for one answer, its body included
  final Duration timeout;

  static final wikidataApi = Uri.https('www.wikidata.org', '/w/api.php');

  /// The pause after a 429 that does not tell how long to wait
  static const defaultPause = Duration(minutes: 10);

  /// The shortest pause after a 429, whatever its Retry-After says
  static const shortestPause = Duration(seconds: 60);

  /// The longest pause: past it, a Retry-After is taken for a mistake rather than kept for the whole session
  static const longestPause = Duration(hours: 1);

  /// Largest answer read: the lead of a long article takes some tens of kilobytes
  static const maxAnswerSize = 1024 * 1024;

  /// The User-Agent of the app for its version [appVersion], as the Wikimedia User-Agent policy wants it: the name and
  /// version of the client, how to reach its makers (the site and the repository, no personal address), its library
  static String userAgentFor(String? appVersion) {
    final version = appVersion?.trim().replaceAll(RegExp(r'[^0-9A-Za-z.+_-]'), '');
    return 'Immuch360/${version == null || version.isEmpty ? 'unknown' : version} '
        '(https://immuch360.com; https://github.com/freeKC/Immuch360) dart-http';
  }

  final _pending = <String, Future<WikipediaFilmSummary?>>{};
  Future<void> _lastRequest = Future.value();
  DateTime? _pausedUntil;

  /// Bumped by [clearCache], so that a lookup under way then does not write its answer after the cache was emptied
  int _generation = 0;
  bool _closed = false;

  /// Whether Wikimedia asked to slow down and the time it asked for has not passed: no request goes out meanwhile
  bool get isPaused {
    final until = _pausedUntil;
    return until != null && _clock().isBefore(until);
  }

  /// The lead of the article of the film [ids] on the first wiki of [chain] that has one (see [wikipediaChainFor]),
  /// from the cache when it was found, or not found, within 30 days. Null when there is none, when the film has no
  /// usable number, and on any failure; never throws. Two calls for the same film and chain share one lookup.
  Future<WikipediaFilmSummary?> summary(FilmExternalIds ids, List<WikipediaLanguage> chain) {
    if (ids.isEmpty || chain.isEmpty || _closed) {
      return Future.value();
    }
    final key = wikipediaFilmCacheKey(ids, chain);
    final pending = _pending[key];
    if (pending != null) {
      return pending;
    }
    final lookup = _lookUp(key, ids, chain);
    _pending[key] = lookup;
    unawaited(
      lookup.whenComplete(() {
        if (identical(_pending[key], lookup)) {
          unawaited(_pending.remove(key));
        }
      }),
    );
    return lookup;
  }

  /// Forgets every answer kept, for the switch that turns the block off
  Future<void> clearCache() async {
    _generation++;
    try {
      await _cache?.clear();
    } catch (error) {
      _log.warning('The Wikipedia cache could not be cleared: ${error.runtimeType}');
    }
  }

  /// Closes the HTTP client; every later call gives null
  void close() {
    _closed = true;
    _http.close();
  }

  Future<WikipediaFilmSummary?> _lookUp(String key, FilmExternalIds ids, List<WikipediaLanguage> chain) async {
    final generation = _generation;
    try {
      final cached = await _cached(key);
      if (cached != null) {
        return cached.summary;
      }
      if (isPaused) {
        return null;
      }
      final found = await _find(ids, chain);
      if (generation == _generation && !_closed) {
        await _keep(key, found);
      }
      return found;
    } on _Unanswered catch (reason) {
      _log.fine('No Wikipedia lead for now: $reason');
      return null;
    } catch (error) {
      // The type only: the message of an unexpected error may hold an address
      _log.fine('No Wikipedia lead for now: ${error.runtimeType}');
      return null;
    }
  }

  Future<WikipediaFilmCacheEntry?> _cached(String key) async {
    try {
      final entry = await _cache?.read(key);
      return entry == null || entry.isExpiredAt(_clock()) ? null : entry;
    } catch (error) {
      _log.fine('The Wikipedia cache could not be read: ${error.runtimeType}');
      return null;
    }
  }

  Future<void> _keep(String key, WikipediaFilmSummary? summary) async {
    try {
      await _cache?.write(key, summary);
    } catch (error) {
      _log.fine('The Wikipedia cache could not be written: ${error.runtimeType}');
    }
  }

  /// The lead found for [ids] in [chain], null when the film has no article there; throws [_Unanswered] when a
  /// request brought no usable answer
  Future<WikipediaFilmSummary?> _find(FilmExternalIds ids, List<WikipediaLanguage> chain) async {
    final item = await _wikidataItem(ids);
    if (item == null) {
      return null;
    }
    final titles = await _sitelinks(item, chain);
    for (final language in chain) {
      final title = titles[language.siteId];
      if (title == null) {
        continue;
      }
      // An article without a lead in this wiki leaves the next one of the chain a chance
      final found = await _lead(language, title);
      if (found != null) {
        return found;
      }
    }
    return null;
  }

  /// The Wikidata item ("Q83495") that holds the IMDb number of the film (P345), else its TMDB number (P4947)
  Future<String?> _wikidataItem(FilmExternalIds ids) async {
    for (final (property, value) in [('P345', ids.validImdb), ('P4947', ids.validTmdb)]) {
      if (value == null) {
        continue;
      }
      final json = await _getJson(
        wikidataApi.replace(
          queryParameters: {
            'action': 'query',
            'list': 'search',
            'srsearch': 'haswbstatement:$property=$value',
            'srlimit': '1',
            'srprop': '',
            'format': 'json',
          },
        ),
      );
      final query = json['query'];
      final hits = query is Map ? query['search'] : null;
      if (hits is! List) {
        throw const _Unanswered('a search of Wikidata without results');
      }
      final first = hits.isEmpty ? null : hits.first;
      final title = first is Map ? first['title'] : null;
      if (title is String && _wikidataItemId.hasMatch(title)) {
        return title;
      }
    }
    return null;
  }

  /// The titles of the articles of [item] in the wikis of [chain], by site id ("frwiki")
  Future<Map<String, String>> _sitelinks(String item, List<WikipediaLanguage> chain) async {
    final json = await _getJson(
      wikidataApi.replace(
        queryParameters: {
          'action': 'wbgetentities',
          'ids': item,
          'props': 'sitelinks',
          'sitefilter': chain.map((language) => language.siteId).join('|'),
          'format': 'json',
        },
      ),
    );
    final entities = json['entities'];
    if (entities is! Map) {
      throw const _Unanswered('Wikidata gave no entities');
    }
    // An item merged into another comes under the id asked for or under the new one: there is one either way
    final entity = entities[item] ?? entities.values.whereType<Map>().firstOrNull;
    final sitelinks = entity is Map ? entity['sitelinks'] : null;
    if (sitelinks is! Map) {
      return const {};
    }
    return {
      for (final MapEntry(:key, :value) in sitelinks.entries)
        if (value is Map && value['title'] is String && (value['title'] as String).isNotEmpty)
          '$key': value['title'] as String,
    };
  }

  /// The lead of the article [title] on the wiki of [language], null when it has none or the article is gone
  Future<WikipediaFilmSummary?> _lead(WikipediaLanguage language, String title) async {
    final variant = language.variant;
    final json = await _getJson(
      language.apiUri.replace(
        queryParameters: {
          'action': 'query',
          'prop': 'extracts',
          'exintro': '1',
          'explaintext': '1',
          'redirects': '1',
          'titles': title,
          'format': 'json',
          'formatversion': '2',
          'variant': ?variant,
        },
      ),
    );
    final query = json['query'];
    final pages = query is Map ? query['pages'] : null;
    if (pages is! List) {
      throw const _Unanswered('Wikipedia gave no pages');
    }
    final page = pages.whereType<Map>().firstOrNull;
    if (page == null || page['missing'] == true || page['invalid'] == true) {
      return null;
    }
    final text = page['extract'];
    final extract = text is String ? cleanWikipediaExtract(text) : '';
    if (extract.isEmpty) {
      return null;
    }
    // The title after the redirects, which the attribution names
    final found = page['title'];
    final articleTitle = found is String && found.isNotEmpty ? found : title;
    return WikipediaFilmSummary(
      wiki: language.wiki,
      variant: variant,
      title: articleTitle,
      extract: extract,
      articleUrl: wikipediaArticleUrl(language, articleTitle),
    );
  }

  /// GETs the JSON object at [uri], after the requests before it, within [timeout]. Throws [_Unanswered] for a pause, a
  /// status other than 200, an answer too large or not a JSON object, an error of the API, a failure of the network
  /// and no answer in time.
  Future<Map<String, Object?>> _getJson(Uri uri) {
    final result = _lastRequest.then((_) => _request(uri));
    _lastRequest = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<Map<String, Object?>> _request(Uri uri) async {
    // Checked when the request's turn comes: one before it may have been told to slow down
    if (isPaused) {
      throw const _Unanswered('Wikimedia asked to slow down');
    }
    if (_closed) {
      throw const _Unanswered('the client is closed');
    }
    final abort = Completer<void>();
    final request = http.AbortableRequest('GET', uri, abortTrigger: abort.future)
      ..headers['user-agent'] = _userAgent
      ..headers['accept'] = 'application/json';
    try {
      return await _answer(request).timeout(timeout);
    } on TimeoutException {
      throw const _Unanswered('no answer in time');
    } on _Unanswered {
      rethrow;
    } catch (error) {
      throw _Unanswered('the request failed (${error.runtimeType})');
    } finally {
      // Cuts the connection of an answer still coming; nothing happens once it ended
      if (!abort.isCompleted) {
        abort.complete();
      }
    }
  }

  Future<Map<String, Object?>> _answer(http.AbortableRequest request) async {
    final response = await _http.send(request);
    final status = response.statusCode;
    final retryAfter = response.headers['retry-after'];
    if (status == 429 || (status == 503 && retryAfter != null)) {
      _pause(retryAfter);
      await _drop(response);
      throw _Unanswered('HTTP $status, every request stops until ${_pausedUntil?.toUtc().toIso8601String()}');
    }
    if (status != 200) {
      await _drop(response);
      throw _Unanswered('HTTP $status');
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(await _body(response)));
    } on FormatException {
      throw const _Unanswered('an answer that is not JSON');
    }
    if (json is! Map<String, Object?>) {
      throw const _Unanswered('an answer that is not a JSON object');
    }
    if (json['error'] != null) {
      throw const _Unanswered('an error of the API');
    }
    return json;
  }

  /// Stops every request for the time [retryAfter] tells (seconds or an HTTP date), between [shortestPause] and
  /// [longestPause], or for [defaultPause] when it tells nothing readable
  void _pause(String? retryAfter) {
    final now = _clock();
    Duration? told;
    if (retryAfter != null) {
      final seconds = int.tryParse(retryAfter.trim());
      if (seconds != null) {
        told = Duration(seconds: seconds);
      } else {
        try {
          told = HttpDate.parse(retryAfter.trim()).difference(now);
        } catch (_) {
          // Neither seconds nor a date: the default pause
          told = null;
        }
      }
    }
    var pause = told ?? defaultPause;
    if (pause < shortestPause) {
      pause = shortestPause;
    } else if (pause > longestPause) {
      pause = longestPause;
    }
    final until = now.add(pause);
    final current = _pausedUntil;
    if (current == null || until.isAfter(current)) {
      _pausedUntil = until;
    }
  }

  static Future<Uint8List> _body(http.StreamedResponse response) async {
    final declared = response.contentLength;
    if (declared != null && declared > maxAnswerSize) {
      await response.stream.listen(null).cancel();
      throw const _Unanswered('too large an answer');
    }
    final body = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      body.add(chunk);
      if (body.length > maxAnswerSize) {
        // Leaving the loop stops the transfer
        throw const _Unanswered('too large an answer');
      }
    }
    return body.takeBytes();
  }

  /// Reads and drops the small body of an error, so that its connection serves the next request
  static Future<void> _drop(http.StreamedResponse response) async {
    try {
      await _body(response);
    } catch (_) {
      // Nothing to do with a body nobody reads
    }
  }
}
