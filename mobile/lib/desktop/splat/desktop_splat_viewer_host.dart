// The splat viewer of the computers (lot SV2 of the splat viewer): the page in a window of its own over the app's,
// at its place and size (maximized when the app's is), through the patched copy of desktop_webview_window
// (packages/desktop_webview_window/IMMUCH360-NOTE.md): WebView2 on Windows, WebKitGTK on Linux, WKWebView on macOS.
// The keys go straight to the page; the page's Back or Esc closes the window; a page whose process died or stopped
// answering closes it and the app says why. One viewer at a time: a second splat closes the first window. On Windows the WebView2 data stays
// in the app's support folder (an isolated copy keeps its own), one folder per set of browser arguments, since one
// browser process takes one set: with the high performance graphics card (--force_high_performance_gpu) or not.

import 'dart:async';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/domain/services/splat_viewer_host.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

final _log = Logger('SplatViewerWindow');

/// The argument WebView2 takes to draw with the high performance graphics card of a laptop with two
const splatHighPerformanceGpuArgument = '--force_high_performance_gpu';

/// Where the window goes: over the app's, at its place and size in physical pixels, maximized when the app's is
typedef SplatWindowPlace = ({int x, int y, int width, int height, bool maximized});

/// The window of a viewing, as the host uses it: desktop_webview_window's Webview, or a fake in the tests
abstract interface class SplatWindow {
  Future<void> get onClose;
  void setOnUrlRequestCallback(bool Function(String url) allow);
  void setOnProcessFailedCallback(void Function(String kind) failed);
  void launch(String url);
  void close();
}

/// Makes a window titled [title] at [place], its WebView2 data in [userDataFolder] with [browserArguments]
typedef SplatWindowFactory =
    Future<SplatWindow> Function({
      required String title,
      required SplatWindowPlace place,
      required String userDataFolder,
      required String browserArguments,
    });

/// See the top of this file
class DesktopSplatViewerHost implements SplatViewerHost {
  DesktopSplatViewerHost({
    SplatWindowFactory? createWindow,
    Future<bool> Function()? isAvailable,
    Future<SplatWindowPlace> Function()? place,
    Future<Directory> Function()? supportFolder,
    bool Function()? highPerformanceGpu,
  }) : _createWindow = createWindow ?? _createPluginWindow,
       _isAvailable = isAvailable ?? WebviewWindow.isWebviewAvailable,
       _place = place ?? appWindowPlace,
       _supportFolder = supportFolder ?? getApplicationSupportDirectory,
       _highPerformanceGpu = highPerformanceGpu ?? (() => true);

  final SplatWindowFactory _createWindow;
  final Future<bool> Function() _isAvailable;
  final Future<SplatWindowPlace> Function() _place;
  final Future<Directory> Function() _supportFolder;
  final bool Function() _highPerformanceGpu;

  final _closed = StreamController<SplatHostClosed>.broadcast();
  SplatWindow? _window;

  /// How the window being closed ended, told once it is gone
  SplatHostClosed? _ending;

  @override
  Stream<SplatHostClosed> get closed => _closed.stream;

  /// Whether a viewer window is open
  bool get isOpen => _window != null;

  /// The folder of the WebView2 data: one per set of browser arguments, in the app's support folder
  Future<String> userDataFolder(String browserArguments) async {
    final support = (await _supportFolder()).path;
    return p.join(support, browserArguments.isEmpty ? 'WebView2' : 'WebView2-high-performance');
  }

  @override
  Future<void> open(Uri pageUrl, {required String title}) async {
    await close();
    if (!await _isAvailable()) {
      _log.warning('No web view on this computer: the splat viewer cannot open');
      _closed.add(SplatHostClosed.noWebView);
      return;
    }
    final arguments = Platform.isWindows && _highPerformanceGpu() ? splatHighPerformanceGpuArgument : '';
    final SplatWindow window;
    try {
      window = await _createWindow(
        title: title,
        place: await _place(),
        userDataFolder: await userDataFolder(arguments),
        browserArguments: arguments,
      );
    } catch (error, stackTrace) {
      _log.warning('The splat viewer window could not be made', error, stackTrace);
      _closed.add(SplatHostClosed.noWebView);
      return;
    }
    _window = window;
    _ending = null;
    final prefix = splatViewerPrefixOf(pageUrl);
    window.setOnUrlRequestCallback((url) {
      final allowed = splatViewerAllows(prefix, url);
      if (!allowed) {
        _log.warning('The splat viewer was kept from leaving its page');
      }
      return allowed;
    });
    window.setOnProcessFailedCallback((kind) {
      _log.warning('The process of the splat viewer stopped: $kind');
      _ending ??= splatHostClosedOf(kind);
      window.close();
    });
    unawaited(
      window.onClose.then((_) {
        if (identical(_window, window)) {
          _window = null;
        }
        _closed.add(_ending ?? SplatHostClosed.user);
      }),
    );
    window.launch(pageUrl.toString());
  }

  @override
  Future<void> close() async {
    final window = _window;
    if (window == null) {
      return;
    }
    _window = null;
    window.close();
    await window.onClose.timeout(const Duration(milliseconds: 500), onTimeout: () {});
  }
}

/// How a viewer whose web view process failed with [kind] (desktop_webview_window's names) ended: a renderer that
/// died is most often out of memory; one that stopped answering, or a graphics process that ended, stalled the page
SplatHostClosed splatHostClosedOf(String kind) => switch (kind) {
  'rendererExited' || 'rendererOutOfMemory' => SplatHostClosed.rendererGone,
  'rendererUnresponsive' || 'gpuExited' => SplatHostClosed.stalled,
  _ => SplatHostClosed.error,
};

/// The place of the app's window, in the physical pixels CreateWindow takes on Windows
Future<SplatWindowPlace> appWindowPlace() async {
  final bounds = await windowManager.getBounds();
  final maximized = await windowManager.isMaximized() || await windowManager.isFullScreen();
  final ratio = WidgetsBinding.instance.platformDispatcher.views.firstOrNull?.devicePixelRatio ?? 1;
  final scale = Platform.isWindows ? ratio : 1.0;
  return (
    x: (bounds.left * scale).round(),
    y: (bounds.top * scale).round(),
    width: (bounds.width * scale).round(),
    height: (bounds.height * scale).round(),
    maximized: maximized,
  );
}

Future<SplatWindow> _createPluginWindow({
  required String title,
  required SplatWindowPlace place,
  required String userDataFolder,
  required String browserArguments,
}) async {
  final webview = await WebviewWindow.create(
    configuration: CreateConfiguration(
      title: title,
      titleBarHeight: 0,
      windowPosX: place.x,
      windowPosY: place.y,
      windowWidth: place.width,
      windowHeight: place.height,
      useWindowPositionAndSize: true,
      openMaximized: place.maximized,
      userDataFolderWindows: userDataFolder,
      additionalBrowserArguments: browserArguments,
    ),
  );
  return _PluginWindow(webview);
}

class _PluginWindow implements SplatWindow {
  _PluginWindow(this._webview);

  final Webview _webview;

  @override
  Future<void> get onClose => _webview.onClose;

  @override
  void setOnUrlRequestCallback(bool Function(String url) allow) => _webview.setOnUrlRequestCallback(allow);

  @override
  void setOnProcessFailedCallback(void Function(String kind) failed) => _webview.setOnProcessFailedCallback(failed);

  @override
  void launch(String url) => _webview.launch(url);

  @override
  void close() => _webview.close();
}
