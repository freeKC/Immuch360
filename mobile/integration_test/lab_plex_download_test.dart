// Lab test of Download for the Plex films (request 5 of the Plex films study, release 45), on the Android 14 emulator
// of the CI with CheckJNI on (immuch360-android-lab.yml), never on a device of the owner nor on a real Plex server: the
// Plex server is the one of test_utils/lab_plex_server.dart, inside the app on 127.0.0.1, and the fake Immich server
// of the lab only runs the LAB_HOST commands (Home, open, logcat). The copy runs through the app's own pieces: the
// Plex client over plain HTTP (the test address of PlexFileSystem.open), FilmDownloadsNotifier, FilmTransfer, the
// app's files, the free room of StatFs, and FilmDownloadService, the foreground service, with its notification.
//
//   plex-download-pause       the service starts with the copy, a pause keeps the bytes and stops the service, the
//                             resume asks the rest with a Range from them, the copy is whole and equal to the film
//   plex-download-background  the app goes to the background with the Home key while the copy runs: the service keeps
//                             it going until the film is whole, then stops; the app comes back
//
// By hand: see lab_server_smoke_test.dart for the fake server, then
//   flutter test integration_test/lab_plex_download_test.dart -d emulator-5554 --flavor phone

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/platform/desktop_apis.dart';
import 'package:immich_mobile/domain/models/film_download.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/infrastructure/film_download/film_download_keep_alive.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/providers/network/film_downloads.provider.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'test_utils/lab_plex_server.dart';
import 'test_utils/lab_server.dart';

const _source = NetworkSource(
  id: 'lab-plex-0000000',
  type: NetworkSourceType.plex,
  name: 'Lab Plex',
  host: '127.0.0.1',
  rootPath: '/',
  useTls: true,
  discoveryId: labPlexMachine,
  plex: PlexServerInfo(hash: labPlexHash),
);

const _started = r'FilmDownloadService\s*: Foreground service started';
const _stopped = r'FilmDownloadService\s*: Foreground service stopped';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('a Plex film downloads, pauses, resumes, and goes on in the background', (tester) async {
    final lab = LabServer.fromEnvironment();
    final host = LabHost(lab);
    labLog('Fake server ${lab.url}, permissions: ${await host.grant()}');
    final plexServer = await LabPlexServer.start();
    final plex = await PlexFileSystem.open(
      _source,
      labPlexToken,
      baseOverride: plexServer.base,
      clientIdentifier: 'lab-plex-download',
    );
    final root = Directory('${(await getApplicationSupportDirectory()).path}/lab_plex_download');
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
    final environment = FilmDownloadEnvironment(
      fileSystem: (_) async => plex,
      indexFolder: () async => Directory('${root.path}/index'),
      filmsFolder: () => Directory('${root.path}/films').create(recursive: true),
      capabilities: () => PlatformApis.connectivity().getCapabilities(),
      networkChanges: () => const Stream.empty(),
      keepAlive: AndroidFilmDownloadKeepAlive(),
      isDesktop: false,
      texts: (film, received, speed) => (
        channelName: 'Film downloads',
        title: 'Downloading ${film.shownTitle}',
        text: '${received ~/ (1024 * 1024)} MiB',
        pause: 'Pause',
        cancel: 'Cancel',
      ),
    );
    final container = ProviderContainer(overrides: [filmDownloadEnvironmentProvider.overrideWithValue(environment)]);
    final notifier = container.read(filmDownloadsProvider.notifier);
    FilmDownload? film(String id) => container.read(filmDownloadsProvider).byId(id);

    try {
      await notifier.ready;
      labLog(
        'Plex download lab: network ${await PlatformApis.connectivity().getCapabilities()}, '
        'free room ${await notifier.freeBytes()} bytes',
      );
      // The emulator may tell a mobile network: the Wi-Fi rule has its own unit tests
      await notifier.setWifiOnly(false);
      final entry = await plex.stat(labPlexFilmPath);
      expect(entry.size, plexServer.film.length);

      await labScenario('plex-download-pause', () async {
        final mark = await host.mark();
        final asked = await notifier.download(entry, title: 'Lab Film');
        await host.waitFor(mark, _started, timeout: const Duration(seconds: 30));
        await waitUntil(
          () => (film(asked.id)?.received ?? 0) > 2 * 1024 * 1024,
          reason: 'the copy moves',
          describe: () => '${film(asked.id)?.state} ${film(asked.id)?.received}',
        );
        notifier.pause(asked.id);
        await waitUntil(() => film(asked.id)?.state == FilmDownloadState.paused, reason: 'the copy pauses');
        await host.waitFor(mark, _stopped, timeout: const Duration(seconds: 30));
        final partial = File('${asked.localPath}.part');
        await waitUntil(() => partial.existsSync(), reason: 'the bytes of the pause are kept');
        final kept = partial.lengthSync();
        labLog('Paused with $kept bytes of ${plexServer.film.length}');
        expect(kept, greaterThan(0));
        expect(kept, lessThan(plexServer.film.length));

        notifier.resume(asked.id);
        await waitUntil(
          () => film(asked.id)?.isDone ?? false,
          reason: 'the resumed copy ends',
          timeout: const Duration(seconds: 120),
          describe: () => '${film(asked.id)?.state} ${film(asked.id)?.received} ${film(asked.id)?.failure}',
        );
        expect(plexServer.partRequests.first.range, 'none');
        expect(plexServer.partRequests.last.range, 'bytes=$kept-');
        expect(plexServer.partRequests.every((request) => request.query == 'download=1' && !request.token), isTrue);
        expect(listEquals(File(asked.localPath).readAsBytesSync(), plexServer.film), isTrue);
        await notifier.delete(asked.id);
        expect(File(asked.localPath).existsSync(), isFalse);
      });

      await labScenario('plex-download-background', () async {
        final mark = await host.mark();
        final asked = await notifier.download(entry, title: 'Lab Film');
        await host.waitFor(mark, _started, timeout: const Duration(seconds: 30));
        // No frame is drawn from here until the app is opened again: no pump
        await host.home();
        await waitUntil(
          () => film(asked.id)?.isDone ?? false,
          reason: 'the copy ends with the app in the background',
          timeout: const Duration(seconds: 150),
          describe: () => '${film(asked.id)?.state} ${film(asked.id)?.received} ${film(asked.id)?.failure}',
        );
        await host.waitFor(mark, _stopped, timeout: const Duration(seconds: 30));
        await host.open();
        expect(listEquals(File(asked.localPath).readAsBytesSync(), plexServer.film), isTrue);
        await notifier.delete(asked.id);
      });
    } finally {
      container.dispose();
      await plex.close();
      await plexServer.close();
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
