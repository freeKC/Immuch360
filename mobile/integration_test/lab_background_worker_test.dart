// Lab test of the background runs of the phone app (BackgroundWorker and BackgroundTeardown of the lifecycle family of
// release 44) against the fake Immich server of the Android lab (.github/android-lab/fake_immich.py), on an Android 14
// emulator of the CI with CheckJNI on (immuch360-android-lab.yml), never on a device of the owner. The app goes to the
// background with the Home key and comes back through its launcher intent, both sent by the fake server on the
// emulator (LAB_HOST lines); a photo saved to the gallery starts each run, as a new photo does on a phone.
//
//   background-end     a run that ends by itself: its engine started, the sync with the server, its work ended and
//                      its engine destroyed (the "Phase:" lines of BackgroundWorker)
//   background-cancel  a run whose sync the server holds, cancelled by opening the app: the lock of the foreground
//                      engine cancels it, Dart confirms its cleanup, the engine is destroyed after the cancel, the held
//                      sync is closed by the app, and the app draws its timeline again
//
// By hand: see lab_server_smoke_test.dart for the fake server, then
//   flutter test integration_test/lab_background_worker_test.dart -d emulator-5554 --flavor phone

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/platform/desktop_apis.dart';
import 'package:immich_mobile/domain/services/background_worker.service.dart';
import 'package:immich_mobile/pages/common/tab_shell.page.dart';
import 'package:immich_mobile/repositories/file_media.repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'test_utils/lab_server.dart';

/// The logcat lines of a background run, from BackgroundWorker.phase and BackgroundEngineLock
const _phase = r'BackgroundWorker\s*: Phase: ';
const _lock = r'BackgroundEngineLock\s*: ';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'a background run ends by itself, another one is cancelled by opening the app',
    (tester) async {
      final server = LabServer.fromEnvironment();
      final host = LabHost(server);
      labLog('Fake server ${server.url}, permissions: ${await host.grant()}');
      await startLabApp(tester);
      await signInThroughLabServer(tester, server);
      await waitForLabTimeline(tester, server);

      // A run soon after a new photo: 5 s after the change of the gallery, whether charging or not
      final foreground = BackgroundWorkerFgService(PlatformApis.backgroundWorkerFg());
      await foreground.configure(minimumDelaySeconds: 5, requireCharging: false);
      final photo = await server.fixture('lab_photo.jpg');
      final folder = (await getTemporaryDirectory()).path;
      Future<void> savePhoto(String name) async {
        final file = File('$folder/$name')..writeAsBytesSync(photo);
        final saved = await const FileMediaRepository().saveImageWithFile(file.path, title: name);
        expect(saved, isNotNull, reason: '$name saved to the gallery');
        labLog('Saved $name to the gallery');
      }

      Future<int> streamCount() async => (await server.state()).streams.length;

      try {
        await labScenario('background-end', () async {
          final mark = await host.mark();
          final streamsBefore = await streamCount();
          // No frame is drawn from here until the app is opened again: no pump
          await host.home();
          await host.waitFor(mark, '${_lock}Background worker is unlocked', timeout: const Duration(seconds: 30));
          await savePhoto('lab_background_1.jpg');
          await host.waitFor(mark, '${_phase}work started', timeout: const Duration(seconds: 150));
          await host.waitFor(mark, '${_phase}work ended', timeout: const Duration(seconds: 120));
          final destroyed = await host.waitFor(
            mark,
            '${_phase}engine destroyed at',
            timeout: const Duration(seconds: 60),
          );
          labLog('Background run ended: ${destroyed.split('Phase: ').last}');
          final streams = (await server.state()).streams.skip(streamsBefore).toList();
          expect(streams, isNotEmpty, reason: 'the background engine synced with the server');
          expect(streams.last['endedBy'], 'server', reason: 'its sync stream read to its end ($streams)');
        });

        await labScenario('background-cancel', () async {
          final mark = await host.mark();
          final streamsBefore = await streamCount();
          await server.holdNextSync();
          await savePhoto('lab_background_2.jpg');
          await host.waitFor(mark, '${_phase}work started', timeout: const Duration(seconds: 150));
          await waitUntil(
            () async {
              final streams = (await server.state()).streams.skip(streamsBefore);
              return streams.any((stream) => stream['held'] == true && stream['endedAt'] == null);
            },
            reason: 'the sync of the background run held open by the server',
            timeout: const Duration(seconds: 90),
            describe: () async => 'streams ${(await server.state()).streams}',
          );
          await host.open();
          await host.waitFor(
            mark,
            '${_lock}Background worker is locked, cancelling the background worker',
            timeout: const Duration(seconds: 60),
          );
          await host.waitFor(mark, '${_phase}cancel asked', timeout: const Duration(seconds: 30));
          final confirmed = await host.waitFor(
            mark,
            '${_phase}Dart cleanup confirmed after the cancel',
            timeout: const Duration(seconds: 60),
          );
          final destroyed = await host.waitFor(
            mark,
            '${_phase}engine destroyed after the cancel',
            timeout: const Duration(seconds: 90),
          );
          labLog('Cancelled run: ${confirmed.split('Phase: ').last}; ${destroyed.split('Phase: ').last}');
          final held = (await server.state()).streams.skip(streamsBefore).firstWhere((s) => s['held'] == true);
          expect(held['endedBy'], 'client', reason: 'the held sync closed by the app when it cancelled ($held)');
          // Back in the foreground: frames again, and the timeline
          await pumpUntil(
            tester,
            () => find.byType(TabShellPage).evaluate().isNotEmpty,
            reason: 'the timeline after the app came back',
          );
          await waitForLabTimeline(tester, server);
        });
      } finally {
        await server.releaseSyncs();
        // A scenario that failed in the background leaves the app there, where the end of the test would wait for a
        // frame forever: open it again
        try {
          await host.open();
        } catch (error) {
          labLog('Could not open the app again after the scenarios: $error');
        }
        await foreground.disable();
      }
      // The syncs of the resume end before the test does, which would cancel them
      await waitForQuietSyncs(tester);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
