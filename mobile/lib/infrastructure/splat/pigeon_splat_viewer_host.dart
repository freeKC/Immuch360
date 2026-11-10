// The splat viewer of the Android phones and tablets (lot SV6 of the splat viewer): SplatViewerActivity, a WebView
// full screen, opened through pigeon (pigeon/splat_viewer_api.dart). The page talks to the app over HTTP through the
// media bridge; the activity only says how it closed.

import 'dart:async';

import 'package:immich_mobile/domain/models/rate_app.dart';
import 'package:immich_mobile/domain/services/rate_app.service.dart';
import 'package:immich_mobile/domain/services/splat_viewer_host.dart';
import 'package:immich_mobile/platform/splat_viewer_api.g.dart';
import 'package:logging/logging.dart';

final _log = Logger('SplatViewerActivity');

/// See the top of this file
class PigeonSplatViewerHost implements SplatViewerHost {
  /// [listen] false leaves the events of the activity to the tests, which call [onActivityClosed]
  PigeonSplatViewerHost({SplatViewerApi? api, bool listen = true}) : _api = api ?? SplatViewerApi() {
    if (listen) {
      SplatViewerEvents.setUp(_ActivityEvents(this));
    }
  }

  final SplatViewerApi _api;

  /// The number of the last viewing opened, and its end
  int _viewing = 0;
  Completer<SplatHostClosed>? _ended;

  /// The major version of Android System WebView, 0 when there is none or the question failed
  Future<int> webViewMajorVersion() async {
    try {
      return await _api.webViewMajorVersion();
    } catch (error) {
      _log.warning('Could not read the version of Android System WebView: $error');
      return 0;
    }
  }

  /// The bytes free for the app on the drive of [folder], null when Android cannot say
  Future<int?> freeBytes(String folder) async {
    try {
      final free = await _api.freeBytes(folder);
      return free < 0 ? null : free;
    } catch (error) {
      _log.fine('Could not read the free space of $folder: $error');
      return null;
    }
  }

  @override
  Future<SplatHostClosed> open(Uri pageUrl, {required String title}) async {
    // A viewing still open ends now, as the user's: the activity shows the new page instead
    _end(SplatHostClosed.user);
    final viewing = ++_viewing;
    final ended = Completer<SplatHostClosed>();
    _ended = ended;
    RateAppSignals.viewingOpened(RateAppViewing.splat);
    try {
      await _api.open(pageUrl.toString(), title, viewing);
    } catch (error) {
      _log.warning('The splat viewer did not open: $error');
      _end(SplatHostClosed.error);
    }
    return ended.future;
  }

  @override
  Future<void> close() async {
    try {
      await _api.close();
    } catch (error) {
      _log.fine('The splat viewer did not close: $error');
    }
  }

  /// The activity of the viewing [viewing] closed for [reason]: 'user', 'rendererGone', 'noWebView' or 'error'. The
  /// closing of an earlier viewing, told late, is only logged.
  void onActivityClosed(String reason, int viewing) {
    _log.info('The splat viewer closed: $reason');
    if (viewing != _viewing) {
      _log.fine('That was the viewing $viewing; the viewing $_viewing goes on');
      return;
    }
    RateAppSignals.viewingClosed(RateAppViewing.splat, normal: reason == 'user');
    _end(switch (reason) {
      'rendererGone' => SplatHostClosed.rendererGone,
      'noWebView' => SplatHostClosed.noWebView,
      'error' => SplatHostClosed.error,
      _ => SplatHostClosed.user,
    });
  }

  void _end(SplatHostClosed how) {
    final ended = _ended;
    _ended = null;
    if (ended != null && !ended.isCompleted) {
      ended.complete(how);
    }
  }
}

class _ActivityEvents implements SplatViewerEvents {
  const _ActivityEvents(this._host);

  final PigeonSplatViewerHost _host;

  @override
  void closed(String reason, int viewing) => _host.onActivityClosed(reason, viewing);
}
