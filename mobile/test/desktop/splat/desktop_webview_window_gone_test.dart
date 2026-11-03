// The copy of desktop_webview_window (packages/desktop_webview_window/IMMUCH360-NOTE.md, patch 9): a window the user
// closed while it opened is gone before the plugin answers its launch, and the answer "can not find webview window for
// id" of a method that returns nothing reached no caller but the zone's catch-all (the review's replay of 2 November
// 2026, the 637k room closed 300 ms after its window showed). Such a call to a window that is gone ends quietly; any
// other error still reaches the zone.
import 'dart:async';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('webview_window');
  late List<String> calls;
  late String launchError;

  setUp(() {
    calls = [];
    launchError = 'can not find webview window for id';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'create':
          return 7;
        case 'launch':
          throw PlatformException(code: '0', message: launchError);
        case 'close':
          throw PlatformException(code: '0', message: 'can not find webview window for id');
      }
      return null;
    });
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  test('launch and close of a window that is gone end quietly', () async {
    final webview = await WebviewWindow.create(configuration: const CreateConfiguration(titleBarHeight: 0));
    webview.launch('http://127.0.0.1:41000/token/session/index.html');
    webview.close();
    await pumpEventQueue();
    expect(calls, ['create', 'launch', 'close']);
  });

  test('a window whose close came before the answer to create still ends (patch 12)', () async {
    // The fix round's replay of 3 November 2026: a window closed about 300 ms after it showed, right as its controller
    // was made; Flutter's merged platform and UI threads hand onWindowClose to Dart before the answer to create, the
    // close found no web view of that id and was dropped, and the viewing never ended
    const codec = StandardMethodCodec();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'create') {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
          'webview_window',
          codec.encodeMethodCall(const MethodCall('onWindowClose', {'id': 8})),
          (_) {},
        );
        return 8;
      }
      return null;
    });
    final webview = await WebviewWindow.create(configuration: const CreateConfiguration(titleBarHeight: 0));
    var closed = false;
    unawaited(webview.onClose.then((_) => closed = true));
    await pumpEventQueue();
    expect(closed, isTrue);
  });

  test('another error of a launch still reaches the zone', () async {
    launchError = 'the web view failed';
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final webview = await WebviewWindow.create(configuration: const CreateConfiguration(titleBarHeight: 0));
      webview.launch('http://127.0.0.1:41000/token/session/index.html');
      await pumpEventQueue();
    }, (error, stack) => errors.add(error));
    expect(errors.single, isA<PlatformException>().having((error) => error.message, 'message', 'the web view failed'));
  });
}
