// The window of the splat viewer on the computers (lot SV2): made at the app's place with its WebView2 folder, kept to
// the folder of its session, closed by the user, by the app or by a process that died, one at a time.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/desktop_start.dart';
import 'package:immich_mobile/desktop/splat/desktop_splat_viewer_host.dart';
import 'package:immich_mobile/domain/services/splat_viewer_host.dart';

class _Window implements SplatWindow {
  final _closed = Completer<void>();
  bool Function(String url)? allow;
  void Function(String kind)? failed;
  String? launched;
  int closes = 0;

  /// The user closes the window, or Windows destroys it after a close asked by the app
  void closeByUser() {
    if (!_closed.isCompleted) {
      _closed.complete();
    }
  }

  @override
  Future<void> get onClose => _closed.future;

  @override
  void setOnUrlRequestCallback(bool Function(String url) allow) => this.allow = allow;

  @override
  void setOnProcessFailedCallback(void Function(String kind) failed) => this.failed = failed;

  @override
  void launch(String url) => launched = url;

  @override
  void close() {
    closes++;
    closeByUser();
  }
}

void main() {
  final page = Uri.parse('http://127.0.0.1:41000/token/0123456789abcdef0123456789abcdef/index.html');
  late List<_Window> windows;
  late List<Map<String, Object>> made;
  late Directory support;

  setUp(() {
    windows = [];
    made = [];
    support = Directory.systemTemp.createTempSync('splat_window_test');
  });

  tearDown(() => support.deleteSync(recursive: true));

  DesktopSplatViewerHost host({bool available = true, bool fails = false, Exception? error}) => DesktopSplatViewerHost(
    isAvailable: () async => available,
    place: () async => (x: 10, y: 20, width: 1600, height: 900, maximized: true),
    supportFolder: () async => support,
    createWindow:
        ({
          required String title,
          required SplatWindowPlace place,
          required String userDataFolder,
          required String browserArguments,
        }) async {
          if (fails) {
            if (error != null) {
              throw error;
            }
            throw StateError('no window');
          }
          made.add({'title': title, 'place': place, 'folder': userDataFolder, 'arguments': browserArguments});
          final window = _Window();
          windows.add(window);
          return window;
        },
  );

  test('the window takes the place of the app, the title of the file and its WebView2 folder, then the page', () async {
    final viewer = host();
    unawaited(viewer.open(page, title: 'cactus.spz'));
    await pumpEventQueue();

    expect(made.single['title'], 'cactus.spz');
    expect(made.single['place'], (x: 10, y: 20, width: 1600, height: 900, maximized: true));
    // The test runs on Linux, where WebView2 takes no arguments
    expect(made.single['arguments'], Platform.isWindows ? splatHighPerformanceGpuArgument : '');
    expect(made.single['folder'], startsWith(support.path));
    expect(windows.single.launched, page.toString());
    expect(viewer.isOpen, isTrue);
  });

  test('one WebView2 folder per set of browser arguments, in the support folder of the app', () async {
    final viewer = host();
    expect(await viewer.userDataFolder(''), '${support.path}${Platform.pathSeparator}WebView2');
    expect(
      await viewer.userDataFolder(splatHighPerformanceGpuArgument),
      '${support.path}${Platform.pathSeparator}WebView2-high-performance',
    );
  });

  test('the page is kept to the folder of its session', () async {
    final viewer = host();
    unawaited(viewer.open(page, title: 'a.spz'));
    await pumpEventQueue();
    final allow = windows.single.allow!;

    expect(allow(page.toString()), isTrue);
    expect(allow(page.resolve('viewer.js').toString()), isTrue);
    expect(allow('https://example.com/'), isFalse);
    expect(allow('http://127.0.0.1:41000/token/other/index.html'), isFalse);
    expect(allow(page.resolve('x').toString().replaceFirst('/x', '/../other/index.html')), isFalse);
  });

  test('the user closes the window: the viewer says so', () async {
    final viewer = host();
    final closed = viewer.open(page, title: 'a.spz');
    await pumpEventQueue();
    windows.single.closeByUser();

    expect(await closed, SplatHostClosed.user);
    expect(viewer.isOpen, isFalse);
  });

  test('a process of the page that died closes the window and says why', () async {
    final viewer = host();
    final closed = viewer.open(page, title: 'a.spz');
    await pumpEventQueue();
    windows.single.failed!('rendererExited');

    expect(await closed, SplatHostClosed.rendererGone);
    expect(windows.single.closes, 1);
  });

  test('a page that stopped answering closes the window too, as stalled; a process that ended for another reason', () {
    expect(splatHostClosedOf('rendererExited'), SplatHostClosed.rendererGone);
    expect(splatHostClosedOf('rendererOutOfMemory'), SplatHostClosed.rendererGone);
    expect(splatHostClosedOf('rendererUnresponsive'), SplatHostClosed.stalled);
    expect(splatHostClosedOf('gpuExited'), SplatHostClosed.stalled);
    expect(splatHostClosedOf('browserExited'), SplatHostClosed.error);
  });

  test('the replay of 2 November 2026: an unresponsive page ends as stalled, not out of memory', () async {
    final viewer = host();
    final closed = viewer.open(page, title: 'a.spz');
    await pumpEventQueue();
    windows.single.failed!('rendererUnresponsive');

    expect(await closed, SplatHostClosed.stalled);
  });

  test('no web view on this computer, or a window that cannot be made: the viewer says so', () async {
    expect(await host(available: false).open(page, title: 'a.spz'), SplatHostClosed.noWebView);
    expect(made, isEmpty);
    expect(await host(fails: true).open(page, title: 'a.spz'), SplatHostClosed.noWebView);
  });

  test('a window closed while WebView2 still made its page ends as the user closed it, not as no web view', () async {
    // The replay of 3 November 2026: the window closed 300 ms after it showed, before its controller existed; the
    // plugin's copy now answers create with this error at the window's close (patch 11) instead of ending the app
    final closedWhileOpening = PlatformException(code: '0', message: splatWindowClosedWhileOpening);
    expect(await host(fails: true, error: closedWhileOpening).open(page, title: 'a.spz'), SplatHostClosed.user);
    final failed = PlatformException(code: '0', message: 'failed to show window');
    expect(await host(fails: true, error: failed).open(page, title: 'a.spz'), SplatHostClosed.noWebView);
  });

  test('a second splat closes the first window, whose end never ends the second viewing', () async {
    // The replay of 2 November 2026: a second splat opened while the first window was open showed "Not Found", the
    // close of the first window having ended the second viewing at once
    final viewer = host();
    final first = viewer.open(page, title: 'a.spz');
    await pumpEventQueue();
    var secondEnded = false;
    final second = viewer.open(page, title: 'b.spz');
    unawaited(second.then((_) => secondEnded = true));
    await pumpEventQueue();

    expect(await first, SplatHostClosed.user);
    expect(windows, hasLength(2));
    expect(windows.first.closes, 1);
    expect(windows.last.closes, 0);
    expect(secondEnded, isFalse);
    expect(viewer.isOpen, isTrue);

    await viewer.close();
    expect(await second, SplatHostClosed.user);
    expect(windows.last.closes, 1);
    expect(viewer.isOpen, isFalse);
    // Nothing left to close
    await viewer.close();
  });

  test('the engine of a title bar runs nothing of the app', () {
    expect(isWebViewTitleBarEngine(['web_view_title_bar', '1']), isTrue);
    expect(isWebViewTitleBarEngine([]), isFalse);
    expect(isWebViewTitleBarEngine([r'C:\Users\me\cactus.spz']), isFalse);
  });
}
