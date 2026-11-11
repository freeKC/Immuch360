// What the film page keeps of Wikipedia between two openings: per film and chain of languages, the summary found or
// the answer that there is none, so that a film opened again sends no request (every install shares one budget of
// requests per minute, see the top of wikipedia_film_client.dart). The keys hold the public IMDb and TMDB numbers of
// the films, the values the text of a free article and its address: no title, summary or picture of Plex is written
// here. An entry lasts 30 days; the file holds the 500 newest.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_film_client.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('WikipediaFilmCache');

/// How long a summary, or the answer that there is none, stays good: an article's lead seldom changes, and a film
/// without an article seldom gets one within a month
const wikipediaCacheLifetime = Duration(days: 30);

/// One remembered answer: [summary] is null when no article was found, [at] tells when it was found
class WikipediaFilmCacheEntry {
  const WikipediaFilmCacheEntry(this.summary, this.at);

  final WikipediaFilmSummary? summary;
  final DateTime at;

  /// Whether this entry is too old to be used at [now]. One dated more than a day ahead comes from a clock that was
  /// wrong when it was written; it is dropped too.
  bool isExpiredAt(DateTime now) =>
      now.difference(at) >= wikipediaCacheLifetime || at.isAfter(now.add(const Duration(days: 1)));
}

/// Where the client keeps its answers. No method throws for a store that cannot be read or written: it reads as empty.
abstract interface class WikipediaFilmCache {
  /// The answer kept under [key], null when there is none (or it expired)
  Future<WikipediaFilmCacheEntry?> read(String key);

  /// Keeps [summary] under [key], dated now; null tells that no article was found
  Future<void> write(String key, WikipediaFilmSummary? summary);

  /// Forgets every answer
  Future<void> clear();
}

/// The answers in one JSON file of a folder, read once and written again after each change. The oldest go first
/// past [maxEntries]; those past [wikipediaCacheLifetime] are neither read nor written back. A file that cannot be
/// read, or holds anything else than what [write] puts there, reads as empty and is replaced at the next write.
class FileWikipediaFilmCache implements WikipediaFilmCache {
  /// The cache in [directory], created at the first write
  FileWikipediaFilmCache(Directory directory, {DateTime Function()? clock})
    : this.deferred(() async => directory, clock: clock);

  /// The cache in the folder [directory] gives, asked at the first use: the support folder of the app comes from an
  /// asynchronous call
  FileWikipediaFilmCache.deferred(this._directory, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  static const fileName = 'films.json';

  /// The most films remembered: a lead takes a few kilobytes, so the file stays within a few megabytes
  static const maxEntries = 500;

  static const _version = 1;

  final Future<Directory> Function() _directory;
  final DateTime Function() _clock;

  Future<Map<String, WikipediaFilmCacheEntry>>? _loading;

  /// The text to write next, in a record so that a deletion (null) is told from nothing to do
  (String?,)? _next;
  Future<void>? _saving;

  Future<File> _file() async => File(p.join((await _directory()).path, fileName));

  Future<Map<String, WikipediaFilmCacheEntry>> _load() => _loading ??= () async {
    final entries = <String, WikipediaFilmCacheEntry>{};
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return entries;
      }
      final json = jsonDecode(await file.readAsString());
      if (json is! Map || json['version'] != _version || json['entries'] is! List) {
        return entries;
      }
      final now = _clock();
      final read = <(int, String, WikipediaFilmCacheEntry)>[];
      for (final item in json['entries'] as List) {
        final entry = _entryOf(item);
        if (entry != null && !entry.$2.isExpiredAt(now)) {
          read.add((read.length, entry.$1, entry.$2));
        }
      }
      // Oldest first, so that the first entry is the one to drop; entries of the same time keep the order of the file
      read.sort((a, b) {
        final byTime = a.$3.at.compareTo(b.$3.at);
        return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
      });
      for (final (_, key, entry) in read.skip(read.length > maxEntries ? read.length - maxEntries : 0)) {
        entries.remove(key);
        entries[key] = entry;
      }
    } catch (error) {
      _log.warning('The Wikipedia cache could not be read, it starts empty: ${error.runtimeType}');
      entries.clear();
    }
    return entries;
  }();

  static (String, WikipediaFilmCacheEntry)? _entryOf(Object? item) {
    if (item is! Map) {
      return null;
    }
    final key = item['key'];
    final at = item['at'];
    if (key is! String || at is! int) {
      return null;
    }
    final summary = item['summary'];
    final parsed = summary == null ? null : WikipediaFilmSummary.fromJson(summary);
    if (summary != null && parsed == null) {
      return null;
    }
    return (key, WikipediaFilmCacheEntry(parsed, DateTime.fromMillisecondsSinceEpoch(at, isUtc: true)));
  }

  @override
  Future<WikipediaFilmCacheEntry?> read(String key) async {
    final entries = await _load();
    final entry = entries[key];
    if (entry != null && entry.isExpiredAt(_clock())) {
      // Dropped from the file at the next write
      entries.remove(key);
      return null;
    }
    return entry;
  }

  @override
  Future<void> write(String key, WikipediaFilmSummary? summary) async {
    final entries = await _load();
    final now = _clock();
    entries.removeWhere((_, entry) => entry.isExpiredAt(now));
    entries.remove(key);
    entries[key] = WikipediaFilmCacheEntry(summary, now);
    while (entries.length > maxEntries) {
      entries.remove(entries.keys.first);
    }
    final text = jsonEncode({
      'version': _version,
      'entries': [
        for (final MapEntry(:key, value: entry) in entries.entries)
          {'key': key, 'at': entry.at.millisecondsSinceEpoch, 'summary': entry.summary?.toJson()},
      ],
    });
    await _save(text);
  }

  @override
  Future<void> clear() async {
    (await _load()).clear();
    await _save(null);
  }

  /// Writes [text] to the file, or deletes the file when null, once the write under way ended. Several changes that
  /// come during one write make one more write, of the last of them. A new file takes the place of the old one only
  /// once whole, so that an app stopped while writing leaves the previous one; it is not flushed to the disk, since a
  /// cache lost with the power costs only some requests.
  Future<void> _save(String? text) {
    _next = (text,);
    return _saving ??= _writeAll();
  }

  Future<void> _writeAll() async {
    try {
      for (var next = _next; next != null; next = _next) {
        _next = null;
        await _writeFile(next.$1);
      }
    } finally {
      _saving = null;
    }
  }

  Future<void> _writeFile(String? text) async {
    try {
      final file = await _file();
      if (text == null) {
        if (file.existsSync()) {
          await file.delete();
        }
        return;
      }
      await file.parent.create(recursive: true);
      final partial = File('${file.path}.part');
      await partial.writeAsString(text);
      await partial.rename(file.path);
    } catch (error) {
      _log.warning('The Wikipedia cache could not be written: ${error.runtimeType}');
    }
  }
}

/// The answers in memory only, for the tests and for a platform without a support folder
class MemoryWikipediaFilmCache implements WikipediaFilmCache {
  MemoryWikipediaFilmCache({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final _entries = <String, WikipediaFilmCacheEntry>{};

  /// What is kept, for the tests
  Map<String, WikipediaFilmCacheEntry> get entries => Map.unmodifiable(_entries);

  @override
  Future<WikipediaFilmCacheEntry?> read(String key) async {
    final entry = _entries[key];
    if (entry != null && entry.isExpiredAt(_clock())) {
      _entries.remove(key);
      return null;
    }
    return entry;
  }

  @override
  Future<void> write(String key, WikipediaFilmSummary? summary) async {
    _entries.remove(key);
    _entries[key] = WikipediaFilmCacheEntry(summary, _clock());
    while (_entries.length > FileWikipediaFilmCache.maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  @override
  Future<void> clear() async => _entries.clear();
}
