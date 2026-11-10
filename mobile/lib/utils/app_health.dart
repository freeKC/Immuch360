import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/domain/services/rate_app.service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:logging/logging.dart';

/// What Android tells of the app's health (AppHealth.kt): the stalls of the main thread, which also runs Dart, with
/// its stack and the memory at that moment, and why the app ended the last times (not responding, a crash, the low
/// memory killer) with the build that ran, where the app stood and what Android kept of the end (the threads of an
/// ANR, the tombstone of a native crash, the stack of a Java crash), the videos the 360° player could not play, with
/// what it saw of them, and the redirects the HTTP client did not expect. Written to the Logs page at warning level,
/// where a TV user can read them; logcat alone had them before, or nothing. A stall gets the state of the image cache
/// of the moment it is written, the first suspect.
///
/// Android keeps the report of an end in a file until it is in the log: once written and the log flushed to the
/// database, "reportsWritten" gives their ids back, and only then are the files deleted, so that a death in between
/// repeats a report at the next start instead of losing it.
///
/// The app also gives Android its state (the page shown, foreground or background), which Android keeps with the
/// process and returns with its end, the "Last known state" of the report: page names only, never a name of a file,
/// a path nor an address.
class AppHealthReports {
  AppHealthReports._();

  static const channel = MethodChannel('immuch360/app_health');
  static final _log = Logger('AppHealth');

  // Whether AppHealth listens on the other side: the engine of the app UI on Android ([listen])
  static bool _listening = false;
  static String? _page;
  static bool _foreground = true;
  static String? _stateSent;
  static AppLifecycleListener? _lifecycle;

  /// Takes the reports made before the app listened, then each new one: Android only
  static Future<void> listen() async {
    if (!CurrentPlatform.isAndroid) {
      return;
    }
    _listening = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'report') {
        await _writeAll([call.arguments]);
      }
    });
    _lifecycle ??= AppLifecycleListener(onStateChange: _onLifecycleState);
    try {
      final pending = await channel.invokeListMethod<Object?>('takeReports');
      await _writeAll(pending ?? const []);
    } on MissingPluginException {
      // An engine without the activity: a background worker
    } catch (error) {
      _log.fine('No health reports: $error');
    }
  }

  /// Writes [reports] to the logs, then tells Android which of them it can forget, once the logs hold them
  static Future<void> _writeAll(List<Object?> reports) async {
    final ids = <String>[];
    for (final report in reports) {
      final id = report is Map ? report['id'] : null;
      if (write(report) && id is String) {
        ids.add(id);
      }
    }
    if (ids.isEmpty) {
      return;
    }
    try {
      await LogService.I.flush();
    } on LoggerUnInitializedException {
      // No database log in this engine: the reports went to the console only, and stay on the device until an
      // engine with the log takes them
      return;
    }
    await channel.invokeMethod<void>('reportsWritten', ids);
  }

  /// Writes [report], a map of its kind ("stall", "exit", "video" or "network") and its text, to the logs; false when
  /// it is not a report
  @visibleForTesting
  static bool write(Object? report) {
    if (report is! Map) {
      return false;
    }
    final text = report['text'];
    if (text is! String) {
      return false;
    }
    switch (report['kind']) {
      case 'exit':
        RateAppSignals.exitReported(text);
      case 'video':
        RateAppSignals.videoProblem();
    }
    if (report['kind'] != 'stall') {
      _log.warning(text);
      return true;
    }
    final cache = PaintingBinding.instance.imageCache;
    _log.warning(
      '$text\nImage cache: ${cache.currentSize} pictures, ${cache.currentSizeBytes >> 20} MB, '
      '${cache.liveImageCount} shown, ${cache.pendingImageCount} loading',
    );
    return true;
  }

  /// The page now shown, the name of its route (AppNavigationObserver)
  static void setPage(String? name) {
    if (name == null || name.isEmpty) {
      return;
    }
    _page = name;
    unawaited(_sendState());
    RateAppSignals.pageShown();
  }

  static void _onLifecycleState(AppLifecycleState state) =>
      setForeground(state == AppLifecycleState.resumed || state == AppLifecycleState.inactive);

  /// Whether the app is in the foreground
  static void setForeground(bool foreground) {
    _foreground = foreground;
    unawaited(_sendState());
  }

  /// The state Android keeps with the process: "page=TabShellRoute fg"
  @visibleForTesting
  static String stateText({String? page, required bool foreground}) =>
      [if (page != null) 'page=$page', if (foreground) 'fg' else 'bg'].join(' ');

  static Future<void> _sendState() async {
    if (!_listening) {
      return;
    }
    final state = stateText(page: _page, foreground: _foreground);
    if (state == _stateSent) {
      return;
    }
    _stateSent = state;
    try {
      await channel.invokeMethod<void>('setState', state);
    } on MissingPluginException {
      // Not the engine of the app UI
    } catch (error) {
      _log.fine('No state for Android: $error');
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _listening = false;
    _page = null;
    _foreground = true;
    _stateSent = null;
    _lifecycle?.dispose();
    _lifecycle = null;
  }
}
