// The list of the films copied to this device, and the "Download only on Wi-Fi" setting, in one small JSON file of the
// app's files (films.json under plex_films). Kept apart from the settings and the database on purpose: the copies are
// files of their own, and the list goes with them. Written to a temporary file then renamed, so that a crash while it
// is written leaves the previous list.

import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/domain/models/film_download.model.dart';
import 'package:immich_mobile/domain/services/film_download/film_download_rules.dart';
import 'package:logging/logging.dart';

final _log = Logger('FilmDownloadStore');

/// What the file holds
class FilmDownloadIndex {
  const FilmDownloadIndex({this.wifiOnly = true, this.films = const []});

  /// "Download only on Wi-Fi", on by default (decision 4 a)
  final bool wifiOnly;
  final List<FilmDownload> films;

  FilmDownloadIndex copyWith({bool? wifiOnly, List<FilmDownload>? films}) =>
      FilmDownloadIndex(wifiOnly: wifiOnly ?? this.wifiOnly, films: films ?? this.films);

  Map<String, Object?> toJson() => {
    'version': FilmDownloadStore.version,
    'wifiOnly': wifiOnly,
    'films': [for (final film in films) film.toJson()],
  };

  static FilmDownloadIndex fromJson(Object? json) {
    if (json is! Map) {
      return const FilmDownloadIndex();
    }
    final films = json['films'];
    return FilmDownloadIndex(
      wifiOnly: json['wifiOnly'] is bool ? json['wifiOnly'] as bool : true,
      films: [
        if (films is List)
          for (final item in films) ?FilmDownload.fromJson(item),
      ],
    );
  }
}

class FilmDownloadStore {
  FilmDownloadStore(this.folder);

  /// The folder of the list (the app's files, plex_films)
  final Directory folder;

  static const version = 1;
  static const fileName = 'films.json';

  File get _file => File('${folder.path}${Platform.pathSeparator}$fileName');

  /// The list as it was last written, without the copies whose file is gone (the system cleared the caches of an
  /// iPhone, a computer's user deleted the film from the download folder), and with each partial copy at the length
  /// its file has
  Future<FilmDownloadIndex> load() async {
    final FilmDownloadIndex index;
    try {
      final file = _file;
      if (!file.existsSync()) {
        return const FilmDownloadIndex();
      }
      index = FilmDownloadIndex.fromJson(jsonDecode(await file.readAsString()));
    } catch (error) {
      _log.warning('The list of the downloaded films could not be read (${error.runtimeType}): starting a new one');
      return const FilmDownloadIndex();
    }
    final films = <FilmDownload>[];
    for (final film in index.films) {
      if (film.isDone) {
        if (File(film.localPath).existsSync()) {
          films.add(film);
        } else {
          _log.info('A downloaded film is no longer on this device: it leaves the list');
        }
        continue;
      }
      final partial = File('${film.localPath}$filmDownloadPartialSuffix');
      final have = partial.existsSync() ? await partial.length() : 0;
      films.add(film.copyWith(received: have));
    }
    return index.copyWith(films: films);
  }

  Future<void> save(FilmDownloadIndex index) async {
    await folder.create(recursive: true);
    final file = _file;
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(index.toJson()), flush: true);
    await temporary.rename(file.path);
  }
}
