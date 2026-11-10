// The list of the downloaded films (films.json): kept as written, the setting with it, the copies whose file is gone
// dropped, the partial copies at the length of their file, and a list that cannot be read replaced by an empty one.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/film_download.model.dart';
import 'package:immich_mobile/domain/services/film_download/film_download_store.dart';

FilmDownload _film(String id, String localPath, FilmDownloadState state, {int received = 0}) => FilmDownload(
  id: id,
  sourceId: 'plex-1',
  path: '/Movies/$id.mkv',
  fileName: '$id.mkv',
  title: 'Film $id',
  localPath: localPath,
  state: state,
  addedAt: DateTime.utc(2026, 11, 10, 22),
  size: 1000,
  modified: DateTime.utc(2020, 9, 13),
  mimeType: 'video/x-matroska',
  durationMs: 7200000,
  identity: '/library/parts/$id/1/file.mkv|1000',
  received: received,
  completedAt: state == FilmDownloadState.done ? DateTime.utc(2026, 11, 10, 23) : null,
);

void main() {
  late Directory folder;
  late FilmDownloadStore store;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('film_store_test');
    store = FilmDownloadStore(folder);
  });
  tearDown(() => folder.delete(recursive: true));

  String inFolder(String name) => '${folder.path}${Platform.pathSeparator}$name';

  test('an empty list with Download only on Wi-Fi on before anything is written', () async {
    final index = await store.load();
    expect(index.films, isEmpty);
    expect(index.wifiOnly, isTrue);
  });

  test('the list comes back as written', () async {
    final done = _film('a', inFolder('a.mkv'), FilmDownloadState.done, received: 1000);
    await File(done.localPath).writeAsBytes(List.filled(1000, 1));
    final paused = _film('b', inFolder('b.mkv'), FilmDownloadState.paused, received: 300);
    await File('${paused.localPath}.part').writeAsBytes(List.filled(300, 2));
    await store.save(FilmDownloadIndex(wifiOnly: false, films: [done, paused]));

    final index = await store.load();
    expect(index.wifiOnly, isFalse);
    expect(index.films.map((film) => film.id), ['a', 'b']);
    final a = index.films.first;
    expect(a.state, FilmDownloadState.done);
    expect(a.title, 'Film a');
    expect(a.size, 1000);
    expect(a.modified, DateTime.utc(2020, 9, 13));
    expect(a.identity, '/library/parts/a/1/file.mkv|1000');
    expect(a.completedAt, DateTime.utc(2026, 11, 10, 23));
    // The entry the player and the watch progress use is the one of the share
    expect(a.entry.sourceId, 'plex-1');
    expect(a.entry.path, '/Movies/a.mkv');
    expect(a.entry.size, 1000);
    expect(index.films.last.received, 300);
  });

  test('a whole copy whose file is gone leaves the list', () async {
    await store.save(FilmDownloadIndex(films: [_film('a', inFolder('a.mkv'), FilmDownloadState.done)]));
    expect((await store.load()).films, isEmpty);
  });

  test('a partial copy takes the length of its file', () async {
    final film = _film('b', inFolder('b.mkv'), FilmDownloadState.running, received: 900);
    await File('${film.localPath}.part').writeAsBytes(List.filled(120, 2));
    await store.save(FilmDownloadIndex(films: [film]));
    expect((await store.load()).films.single.received, 120);
  });

  test('a list that cannot be read gives an empty one', () async {
    await File(inFolder(FilmDownloadStore.fileName)).writeAsString('{not json');
    final index = await store.load();
    expect(index.films, isEmpty);
    expect(index.wifiOnly, isTrue);
  });

  test('an entry this build cannot read is left out, the others kept', () async {
    final done = _film('a', inFolder('a.mkv'), FilmDownloadState.done, received: 1000);
    await File(done.localPath).writeAsBytes(List.filled(1000, 1));
    await store.save(FilmDownloadIndex(films: [done]));
    final file = File(inFolder(FilmDownloadStore.fileName));
    final text = (await file.readAsString()).replaceFirst('"films":[', '"films":[{"id":3,"state":"from the future"},');
    await file.writeAsString(text);
    expect((await store.load()).films.map((film) => film.id), ['a']);
  });

  test('the title shown is the given one, else the file name without its extension', () {
    expect(_film('a', '/x', FilmDownloadState.done).shownTitle, 'Film a');
    final untitled = FilmDownload(
      id: 'c',
      sourceId: 's',
      path: '/Le Fabuleux Destin.mkv',
      fileName: 'Le Fabuleux Destin.mkv',
      localPath: '/x',
      state: FilmDownloadState.queued,
      addedAt: DateTime.utc(2026),
    );
    expect(untitled.shownTitle, 'Le Fabuleux Destin');
    expect(untitled.fraction, isNull);
  });
}
