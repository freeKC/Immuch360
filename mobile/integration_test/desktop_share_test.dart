// "Share with Windows…" in a built app (lot share 54): the share window of Windows through the channel of the runner
// (windows/runner/share_channel.cpp, share_sheet.cpp), and the order of desktop build 35 through the real share_plus.
// One scenario per run, given by --dart-define=IMMUCH360_SHARE_SCENARIO=...: a share window that asked for files once
// stays open on the runners ("Try that again", Windows Server has no program to share to), and Windows asks nothing
// for a second window of the same app meanwhile (the probe of lot share 54).
// - old (Windows Server 2025): build 35's order. share_plus 10.1.4 answers before the window asks for the files; build
//   35 deleted a fetched file in that answer. A watcher of the runner, called by the window just before share_plus's
//   own handler, counts the files still there when the window asks: none.
// - new (Windows Server 2025): the share of the Share menu. A missing file fails at once with the reason of Windows
//   and its name only; then a fetched file moves into the folder of the copies, the window takes it (asks for it,
//   one file given), and the folder stays while the window is open, whatever its age.
// - unsupported (Windows Server 2022): DataTransferManager.IsSupported says no, so the menu has no "Share with
//   Windows…"; a share asked anyway gets no request from Windows and says the window did not open.
// Run in the desktop workflow only: it opens the share window of the system.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/clipboard/clipboard_copies.dart';
import 'package:immich_mobile/desktop/share/desktop_share.dart';
import 'package:immich_mobile/desktop/share/system_share_sheet.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:window_manager/window_manager.dart';

const _scenario = String.fromEnvironment('IMMUCH360_SHARE_SCENARIO', defaultValue: 'new');

/// What is in front, as the share window of Windows needs the window of the app there
Future<String> _front() async {
  final answer = await desktopShareChannel.invokeMapMethod<String, Object?>('foreground');
  return 'app in front: ${answer?['isApp']}, front window class: ${answer?['className']}';
}

/// A file of [size] bytes named [name] in a new folder of the temporary folder, as a download for a share is
Future<File> _download(String name, {int size = 64 * 1024}) async {
  final folder = await Directory.systemTemp.createTemp('share-original-');
  final file = File(p.join(folder.path, name));
  await file.writeAsBytes(List<int>.generate(size, (index) => index % 251));
  return file;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the share window of Windows: $_scenario', (tester) async {
    if (!Platform.isWindows) {
      markTestSkipped('Windows only');
      return;
    }
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.expand())));
    // The window of the app in front, as when a user clicks Share in it
    await windowManager.ensureInitialized();
    await windowManager.show();
    await windowManager.focus();
    await tester.pump(const Duration(milliseconds: 500));
    // ignore: avoid_print
    print('Before the share: ${await _front()}');
    final sheet = WindowsShareSheet();
    final supported = await sheet.supported();
    // ignore: avoid_print
    print('DataTransferManager.IsSupported: $supported');

    switch (_scenario) {
      case 'unsupported':
        expect(supported, isFalse, reason: 'the scenario of Windows Server 2022');
        expect(
          desktopShareWays(platform: TargetPlatform.windows, systemSheet: supported, shareLink: true, quality: true),
          isNot(contains(DesktopShareWay.systemSheet)),
        );
        final file = await _download('IMG_0042.mp4');
        final share = WindowsShareSheet(
          requestTimeout: const Duration(seconds: 8),
        ).share([file.path], title: 'IMG_0042.mp4');
        Object? failure;
        try {
          await share.opened;
        } catch (error) {
          failure = error;
        }
        // ignore: avoid_print
        print('A share where Windows has no share window: $failure');
        expect(failure, isA<SystemShareException>().having((error) => error.step, 'step', 'request'));
        expect(await share.finished, SystemShareEnd.dismissed);

      case 'old':
        expect(supported, isTrue, reason: 'the scenario of Windows Server 2025');
        final file = await _download('IMG_0042.mp4');
        await sheet.observeNextRequest([file.path]);
        final observed = observedShareRequests.stream.first;
        final clock = Stopwatch()..start();
        final answer = await Share.shareXFiles([XFile(file.path)]);
        final answeredMs = clock.elapsedMilliseconds;
        // What build 35 did in whenComplete of that answer (AssetMediaRepository.cleanupTempFiles)
        await file.parent.delete(recursive: true);
        final ({double elapsedMs, int existing}) seen;
        try {
          seen = await observed.timeout(const Duration(seconds: 30));
        } on TimeoutException {
          fail(
            'share_plus answered ${answer.status.name} after $answeredMs ms, then no request in 30 s; ${await _front()}',
          );
        }
        // ignore: avoid_print
        print(
          'share_plus answered ${answer.status.name} ("${answer.raw}") after $answeredMs ms; the window asked for '
          'the files ${seen.elapsedMs.round()} ms after the share was asked, ${seen.existing} of 1 file still there',
        );
        expect(answer.status, ShareResultStatus.unavailable, reason: 'share_plus answers before the window asks');
        expect(seen.elapsedMs, greaterThan(answeredMs), reason: 'the window asks after that answer');
        expect(seen.existing, 0, reason: 'the file build 35 fetched was gone when the window asked for it');

      case 'new':
        expect(supported, isTrue, reason: 'the scenario of Windows Server 2025');
        // A missing file: the window is not shown, the reason of Windows comes back with the file's name only
        final missing = p.join(Directory.systemTemp.path, 'immuch360-gone', 'IMG_0001.mp4');
        final broken = sheet.share([missing], title: 'IMG_0001.mp4');
        Object? failure;
        try {
          await broken.opened;
        } catch (error) {
          failure = error;
        }
        // ignore: avoid_print
        print('A missing file: $failure');
        expect(
          failure,
          isA<SystemShareException>()
              .having((error) => error.step, 'step', 'file')
              .having((error) => error.file, 'file', 'IMG_0001.mp4')
              .having((error) => error.code, 'code', '0x80070002')
              .having((error) => error.reason, 'reason', isNotEmpty),
        );
        expect('$failure', isNot(contains('immuch360-gone')), reason: 'no folder in what is shown or logged');

        // A fetched file: kept in the folder of the copies until the window lets it go
        final root = await Directory.systemTemp.createTemp('immuch360-clipboard-');
        final download = await _download('IMG_0042 été.mp4', size: 36 * 1024 * 1024 ~/ 64);
        final copies = await keepShareCopies([download], root);
        expect(download.existsSync(), isFalse, reason: 'moved out of the folder of the download');
        final kept = File(copies.paths.single);
        expect(kept.existsSync(), isTrue);
        expect(p.basename(kept.path), 'IMG_0042 été.mp4');
        final share = sheet.share(copies.paths, title: p.basename(kept.path));
        final clock = Stopwatch()..start();
        try {
          await share.opened.timeout(const Duration(seconds: 30));
        } on TimeoutException {
          fail('No request of the share window in 30 s; ${await _front()}');
        }
        // ignore: avoid_print
        print('The window asked for the file after ${clock.elapsedMilliseconds} ms and took it');
        // The window is open: the folder stays even once older than the rule's hour
        final later = DateTime.now().add(const Duration(hours: 3));
        await cleanClipboardCopies(root, holds: (_) async => false, systemTokens: true, now: () => later);
        expect(kept.existsSync(), isTrue, reason: 'never deleted while the share window may read it');
        expect(shareCopiesOpen(copies.folder), isTrue);

      default:
        fail('Unknown scenario $_scenario');
    }
  });
}
