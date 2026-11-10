// The list of the film downloads and the copy under way (FilmDownloadsNotifier): one copy at a time into the app's
// storage, the Wi-Fi rule, pause, resume, cancel from the notification, delete, the list kept for the next start, and a
// copy cut by the end of the app going on.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/film_download.model.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/providers/network/film_downloads.provider.dart';

import 'film_download_fakes.dart';

void main() {
  late Directory root;
  late FakeFilmEnvironment fake;
  final containers = <ProviderContainer>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('film_downloads_test');
    fake = FakeFilmEnvironment(
      root,
      FakeDownloadShare({'/Movies/Heat.mkv': filmTestBytes(3000), '/Movies/Ronin.mkv': filmTestBytes(2000)}),
    );
  });
  tearDown(() async {
    for (final container in containers) {
      container.dispose();
    }
    containers.clear();
    await fake.network.close();
    await root.delete(recursive: true);
  });

  Future<(ProviderContainer, FilmDownloadsNotifier)> start() async {
    final container = ProviderContainer(
      overrides: [filmDownloadEnvironmentProvider.overrideWithValue(fake.environment)],
    );
    containers.add(container);
    final notifier = container.read(filmDownloadsProvider.notifier);
    await notifier.ready;
    return (container, notifier);
  }

  test('a film downloads into the app storage, with the notification shown then stopped', () async {
    final (container, notifier) = await start();
    final asked = await notifier.download(filmTestEntry('/Movies/Heat.mkv', 3000), title: 'Heat');
    await waitUntil(() => filmOf(container.read(filmDownloadsProvider), '/Movies/Heat.mkv')?.isDone ?? false);

    final film = filmOf(container.read(filmDownloadsProvider), '/Movies/Heat.mkv')!;
    expect(film.id, asked.id);
    expect(film.received, 3000);
    expect(film.localPath, startsWith(fake.films.path));
    expect(film.localPath, endsWith('.mkv'));
    expect(await File(film.localPath).readAsBytes(), filmTestBytes(3000));
    expect(fake.keepAlive.shown, isNotEmpty);
    await waitUntil(() => fake.keepAlive.stops > 0);
    expect((await notifier.completedCopy(film.sourceId, film.path))?.path, film.localPath);
    expect(container.read(filmDownloadsProvider).bytesOnDevice, 3000);
  });

  test('the list is kept for the next start', () async {
    final (container, notifier) = await start();
    await notifier.download(filmTestEntry('/Movies/Heat.mkv', 3000), title: 'Heat');
    await waitUntil(() => filmOf(container.read(filmDownloadsProvider), '/Movies/Heat.mkv')?.isDone ?? false);
    await notifier.setWifiOnly(false);
    await notifier.flush();

    final (next, _) = await start();
    final state = next.read(filmDownloadsProvider);
    expect(state.wifiOnly, isFalse);
    expect(filmOf(state, '/Movies/Heat.mkv')?.title, 'Heat');
    expect(filmOf(state, '/Movies/Heat.mkv')?.isDone, isTrue);
  });

  test('copies run one at a time, in the order asked', () async {
    final (container, notifier) = await start();
    fake.share.hold = Completer<void>();
    await notifier.download(filmTestEntry('/Movies/Heat.mkv', 3000));
    await notifier.download(filmTestEntry('/Movies/Ronin.mkv', 2000));
    await waitUntil(
      () => filmOf(container.read(filmDownloadsProvider), '/Movies/Heat.mkv')?.state == FilmDownloadState.running,
    );
    expect(filmOf(container.read(filmDownloadsProvider), '/Movies/Ronin.mkv')?.state, FilmDownloadState.queued);
    fake.share.hold!.complete();
    fake.share.hold = null;
    await waitUntil(() => container.read(filmDownloadsProvider).films.every((film) => film.isDone));
    expect(fake.share.asked, [0, 0]);
  });

  test('on mobile data with Download only on Wi-Fi a copy waits, and goes on once on Wi-Fi', () async {
    fake.capabilities = const [NetworkCapability.cellular];
    final (container, notifier) = await start();
    await notifier.download(filmTestEntry('/Movies/Heat.mkv', 3000));
    await waitUntil(
      () =>
          filmOf(container.read(filmDownloadsProvider), '/Movies/Heat.mkv')?.state == FilmDownloadState.waitingForWifi,
    );
    expect(fake.share.asked, isEmpty);

    fake.capabilities = const [NetworkCapability.wifi];
    fake.network.add(null);
    await waitUntil(() => filmOf(container.read(filmDownloadsProvider), '/Movies/Heat.mkv')?.isDone ?? false);
  });

  test('over mobile data this time, a copy runs on mobile data', () async {
    fake.capabilities = const [NetworkCapability.cellular];
    final (container, notifier) = await start();
    await notifier.download(filmTestEntry('/Movies/Heat.mkv', 3000), mobileDataThisTime: true);
    await waitUntil(() => filmOf(container.read(filmDownloadsProvider), '/Movies/Heat.mkv')?.isDone ?? false);
  });

  test('turning Download only on Wi-Fi off lets a waiting copy go on', () async {
    fake.capabilities = const [NetworkCapability.cellular];
    final (container, notifier) = await start();
    await notifier.download(filmTestEntry('/Movies/Heat.mkv', 3000));
    await waitUntil(
      () =>
          filmOf(container.read(filmDownloadsProvider), '/Movies/Heat.mkv')?.state == FilmDownloadState.waitingForWifi,
    );
    await notifier.setWifiOnly(false);
    await waitUntil(() => filmOf(container.read(filmDownloadsProvider), '/Movies/Heat.mkv')?.isDone ?? false);
  });

  test('pause keeps the copy in the list, resume ends it', () async {
    final (container, notifier) = await start();
    fake.share.hold = Completer<void>();
    final film = await notifier.download(filmTestEntry('/Movies/Heat.mkv', 3000));
    await waitUntil(() => container.read(filmDownloadsProvider).byId(film.id)?.state == FilmDownloadState.running);
    notifier.pause(film.id);
    await waitUntil(() => fake.keepAlive.stops > 0);
    expect(container.read(filmDownloadsProvider).byId(film.id)?.state, FilmDownloadState.paused);

    fake.share.hold = null;
    notifier.resume(film.id);
    await waitUntil(() => container.read(filmDownloadsProvider).byId(film.id)?.isDone ?? false);
  });

  test('Cancel of the notification stops the copy and takes it off the list', () async {
    final (container, notifier) = await start();
    fake.share.hold = Completer<void>();
    final film = await notifier.download(filmTestEntry('/Movies/Heat.mkv', 3000));
    await waitUntil(() => container.read(filmDownloadsProvider).byId(film.id)?.state == FilmDownloadState.running);
    fake.keepAlive.onCancel!();
    await waitUntil(() => container.read(filmDownloadsProvider).films.isEmpty);
    await waitUntil(() => !File('${film.localPath}.part').existsSync());
  });

  test('delete takes the copy off the device and the list', () async {
    final (container, notifier) = await start();
    final film = await notifier.download(filmTestEntry('/Movies/Heat.mkv', 3000));
    await waitUntil(() => container.read(filmDownloadsProvider).byId(film.id)?.isDone ?? false);
    await notifier.delete(film.id);
    expect(container.read(filmDownloadsProvider).films, isEmpty);
    expect(File(film.localPath).existsSync(), isFalse);
    expect(await notifier.completedCopy(film.sourceId, film.path), isNull);
  });

  test('a film gone from the server fails with its reason, and stays in the list', () async {
    final (container, notifier) = await start();
    final film = await notifier.download(filmTestEntry('/Movies/Gone.mkv', 10));
    await waitUntil(() => container.read(filmDownloadsProvider).byId(film.id)?.state == FilmDownloadState.failed);
    expect(container.read(filmDownloadsProvider).byId(film.id)?.failure, FilmDownloadFailure.gone);
  });

  test('a copy that ran when the app ended goes on at the next start, from its bytes', () async {
    final index = Directory('${root.path}${Platform.pathSeparator}index');
    await index.create(recursive: true);
    await fake.films.create(recursive: true);
    final localPath = '${fake.films.path}${Platform.pathSeparator}0011223344556677.mkv';
    await File('$localPath.part').writeAsBytes(filmTestBytes(3000).sublist(0, 1000));
    final film = FilmDownload(
      id: '0011223344556677',
      sourceId: filmTestSource.id,
      path: '/Movies/Heat.mkv',
      fileName: 'Heat.mkv',
      localPath: localPath,
      state: FilmDownloadState.running,
      addedAt: DateTime.utc(2026, 11, 10),
      size: 3000,
      identity: 'id:/Movies/Heat.mkv',
      received: 1000,
    );
    await File('${index.path}${Platform.pathSeparator}films.json').writeAsString(
      jsonEncode({
        'version': 1,
        'wifiOnly': true,
        'films': [film.toJson()],
      }),
    );
    final (container, _) = await start();
    await waitUntil(() => container.read(filmDownloadsProvider).byId(film.id)?.isDone ?? false);
    expect(fake.share.asked, [1000]);
    expect(await File(localPath).readAsBytes(), filmTestBytes(3000));
  });
}
