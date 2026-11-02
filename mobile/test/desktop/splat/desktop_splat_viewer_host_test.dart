// The window of the splat viewer on the computers (lot SV2): made at the app's place with its WebView2 folder, kept to
// the folder of its session, closed by the user, by the app or by a process that died, one at a time.
import 'dart:async';
import 'dart:io';

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

  DesktopSplatViewerHost host({bool available = true, bool fails = false}) => DesktopSplatViewerHost(
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
    await viewer.open(page, title: 'cactus.spz');

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
    await viewer.open(page, title: 'a.spz');
    final allow = windows.single.allow!;

    expect(allow(page.toString()), isTrue);
    expect(allow(page.resolve('viewer.js').toString()), isTrue);
    expect(allow('https://example.com/'), isFalse);
    expect(allow('http://127.0.0.1:41000/token/other/index.html'), isFalse);
    expect(allow(page.resolve('x').toString().replaceFirst('/x', '/../other/index.html')), isFalse);
  });

  test('the user closes the window: the viewer says so', () async {
    final viewer = host();
    final closed = viewer.closed.first;
    await viewer.open(page, title: 'a.spz');
    windows.single.closeByUser();

    expect(await closed, SplatHostClosed.user);
    expect(viewer.isOpen, isFalse);
  });

  test('a process of the page that died closes the window and says why', () async {
    final viewer = host();
    final closed = viewer.closed.first;
    await viewer.open(page, title: 'a.spz');
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
    final closed = viewer.closed.first;
    await viewer.open(page, title: 'a.spz');
    windows.single.failed!('rendererUnresponsive');

    expect(await closed, SplatHostClosed.stalled);
  });

  test('no web view on this computer, or a window that cannot be made: the viewer says so', () async {
    final none = host(available: false);
    final closedNone = none.closed.first;
    await none.open(page, title: 'a.spz');
    expect(await closedNone, SplatHostClosed.noWebView);
    expect(made, isEmpty);

    final failing = host(fails: true);
    final closedFailing = failing.closed.first;
    await failing.open(page, title: 'a.spz');
    expect(await closedFailing, SplatHostClosed.noWebView);
  });

  test('a second splat closes the first window; close closes the open one', () async {
    final viewer = host();
    await viewer.open(page, title: 'a.spz');
    await viewer.open(page, title: 'b.spz');

    expect(windows.first.closes, 1);
    expect(windows.last.closes, 0);
    await viewer.close();
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
