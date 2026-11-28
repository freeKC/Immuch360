// The share window of the system as the Share menu of a computer reaches it (lib/desktop/share/system_share_sheet.dart):
// on Windows through the channel of the runner, whose failures come back with their step, HRESULT, text and the name
// of the file (never its folder), and whose events tell when the window took the files and when it let them go (a
// program chosen or not); a window that never asks for the files fails as such. On macOS through share_plus, whose
// picker answers with the service chosen, or nothing for a picker closed.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/share/system_share_sheet.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();
  late List<MethodCall> calls;
  late Object? Function(MethodCall call) answer;

  setUp(() {
    resetWindowsShares();
    calls = [];
    answer = (call) => null;
    messenger.setMockMethodCallHandler(desktopShareChannel, (call) async {
      calls.add(call);
      return answer(call);
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(desktopShareChannel, null));

  /// The runner calls Dart, as it does for an event of the window
  Future<void> fromRunner(String method, Map<String, Object?> arguments) async {
    await messenger.handlePlatformMessage(
      desktopShareChannel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
  }

  group('Windows', () {
    test('asks the runner whether the system has a share window', () async {
      answer = (call) => call.method == 'isSupported' ? true : null;
      expect(await WindowsShareSheet().supported(), isTrue);
      answer = (call) => false;
      expect(await WindowsShareSheet().supported(), isFalse);
      answer = (call) => throw PlatformException(code: 'activation');
      expect(await WindowsShareSheet().supported(), isFalse);
    });

    test('hands the paths and the title, then the window takes the files and a program is chosen', () async {
      answer = (call) => 7;
      final share = WindowsShareSheet().share([r'C:\cache\copies\1\IMG.mp4'], title: 'IMG.mp4');
      await pumpEventQueue();
      expect(calls.single.method, 'shareFiles');
      expect(calls.single.arguments, {
        'paths': [r'C:\cache\copies\1\IMG.mp4'],
        'title': 'IMG.mp4',
      });

      var opened = false;
      share.opened.then((_) => opened = true).ignore();
      await fromRunner('event', {'share': 7, 'event': 'requested', 'detail': '1'});
      await pumpEventQueue();
      expect(opened, isTrue);

      await fromRunner('event', {'share': 7, 'event': 'target', 'detail': 'Mail'});
      await fromRunner('event', {'share': 7, 'event': 'destroyed', 'detail': ''});
      expect(await share.finished, SystemShareEnd.shared);
      expect(share.target, 'Mail');
    });

    test('a window closed without a choice ends dismissed; events of another share are not its own', () async {
      answer = (call) => 8;
      final share = WindowsShareSheet().share([r'C:\a.jpg'], title: 'a.jpg');
      await pumpEventQueue();
      await fromRunner('event', {'share': 9, 'event': 'target', 'detail': 'Teams'});
      await fromRunner('event', {'share': 8, 'event': 'requested', 'detail': '1'});
      await fromRunner('event', {'share': 8, 'event': 'destroyed', 'detail': ''});
      await share.opened;
      expect(await share.finished, SystemShareEnd.dismissed);
      expect(share.target, isNull);
    });

    test('a failure of the runner: its step, HRESULT and text, and the name of the file only', () async {
      answer = (call) => throw PlatformException(
        code: 'file',
        message: '0x80070002 The system cannot find the file specified.',
        details: {'hresult': '0x80070002', 'index': 1},
      );
      final share = WindowsShareSheet().share([
        r'C:\Users\fr\AppData\Local\Temp\a\one.jpg',
        r'C:\Users\fr\AppData\Local\Temp\b\IMG_0042.mp4',
      ], title: '2 files');
      await expectLater(
        share.opened,
        throwsA(
          isA<SystemShareException>()
              .having((error) => error.step, 'step', 'file')
              .having((error) => error.code, 'code', '0x80070002')
              .having((error) => error.file, 'file', 'IMG_0042.mp4')
              .having((error) => error.reason, 'reason', contains('cannot find the file'))
              .having((error) => '$error', 'text', isNot(contains('AppData'))),
        ),
      );
      expect(await share.finished, SystemShareEnd.dismissed);
    });

    test('a window that never asks for the files fails as not opened', () async {
      answer = (call) => 3;
      final share = WindowsShareSheet(
        requestTimeout: const Duration(milliseconds: 30),
      ).share([r'C:\a.jpg'], title: 'a.jpg');
      await expectLater(
        share.opened,
        throwsA(isA<SystemShareException>().having((error) => error.step, 'step', 'request')),
      );
      expect(await share.finished, SystemShareEnd.dismissed);
    });

    test('the requests the runner watched for the tests of the workflow come on their stream', () async {
      final seen = observedShareRequests.stream.first;
      await WindowsShareSheet().observeNextRequest([r'C:\a.jpg']);
      expect(calls.single.method, 'observeNextRequest');
      await fromRunner('observed', {'elapsedMs': 240.5, 'existing': 0});
      expect(await seen, (elapsedMs: 240.5, existing: 0));
    });
  });

  group('macOS', () {
    test('the service chosen, a picker closed, a failure', () async {
      final asked = <(List<String>, Rect?)>[];
      var result = const ShareResult('Mail', ShareResultStatus.success);
      final sheet = MacShareSheet(
        share: (files, origin) async {
          asked.add(([for (final file in files) file.path], origin));
          return result;
        },
      );
      expect(await sheet.supported(), isTrue);

      var share = sheet.share(
        ['/Users/fr/Library/Caches/IMG.HEIC'],
        title: 'IMG.HEIC',
        origin: const Rect.fromLTWH(10, 20, 1, 1),
      );
      await share.opened;
      expect(await share.finished, SystemShareEnd.shared);
      expect(share.target, 'Mail');
      expect(asked.single.$1, ['/Users/fr/Library/Caches/IMG.HEIC']);
      expect(asked.single.$2, const Rect.fromLTWH(10, 20, 1, 1));

      result = const ShareResult('', ShareResultStatus.dismissed);
      share = sheet.share(['/a.jpg'], title: 'a.jpg');
      await share.opened;
      expect(await share.finished, SystemShareEnd.dismissed);

      final failing = MacShareSheet(
        share: (files, origin) async => throw PlatformException(code: 'x', message: 'no view'),
      );
      share = failing.share(['/a.jpg'], title: 'a.jpg');
      await expectLater(
        share.opened,
        throwsA(isA<SystemShareException>().having((error) => error.reason, 'reason', 'no view')),
      );
    });
  });
}
