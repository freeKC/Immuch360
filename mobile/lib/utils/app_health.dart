import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:logging/logging.dart';

/// What Android tells of the app's health (AppHealth.kt): the stalls of the main thread, which also runs Dart, with
/// its stack and the memory at that moment, and why the app ended the last times (not responding, a crash, the low
/// memory killer). Written to the Logs page at warning level, where a TV user can read them; logcat alone had them
/// before, or nothing. A stall gets the state of the image cache of the moment it is written, the first suspect.
class AppHealthReports {
  AppHealthReports._();

  static const channel = MethodChannel('immuch360/app_health');
  static final _log = Logger('AppHealth');

  /// Takes the reports made before the app listened, then each new one: Android only
  static Future<void> listen() async {
    if (!CurrentPlatform.isAndroid) {
      return;
    }
    channel.setMethodCallHandler((call) async {
      if (call.method == 'report') {
        write(call.arguments);
      }
    });
    try {
      final pending = await channel.invokeListMethod<Object?>('takeReports');
      pending?.forEach(write);
    } on MissingPluginException {
      // An engine without the activity: a background worker
    } catch (error) {
      _log.fine('No health reports: $error');
    }
  }

  /// Writes [report], a map of its kind ("stall" or "exit") and its text, to the logs
  @visibleForTesting
  static void write(Object? report) {
    if (report is! Map) {
      return;
    }
    final text = report['text'];
    if (text is! String) {
      return;
    }
    if (report['kind'] != 'stall') {
      _log.warning(text);
      return;
    }
    final cache = PaintingBinding.instance.imageCache;
    _log.warning(
      '$text\nImage cache: ${cache.currentSize} pictures, ${cache.currentSizeBytes >> 20} MB, '
      '${cache.liveImageCount} shown, ${cache.pendingImageCount} loading',
    );
  }
}
