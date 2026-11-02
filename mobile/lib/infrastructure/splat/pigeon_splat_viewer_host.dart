// The splat viewer of the Android phones and tablets (lot SV6 of the splat viewer): SplatViewerActivity, a WebView
// full screen, opened through pigeon (pigeon/splat_viewer_api.dart). The page talks to the app over HTTP through the
// media bridge; the activity only says how it closed.

import 'dart:async';

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
  final _closed = StreamController<SplatHostClosed>.broadcast();

  @override
  Stream<SplatHostClosed> get closed => _closed.stream;

  /// The major version of Android System WebView, 0 when there is none or the question failed
  Future<int> webViewMajorVersion() async {
    try {
      return await _api.webViewMajorVersion();
    } catch (error) {
      _log.warning('Could not read the version of Android System WebView: $error');
      return 0;
    }
  }

  @override
  Future<void> open(Uri pageUrl, {required String title}) async {
    try {
      await _api.open(pageUrl.toString(), title);
    } catch (error) {
      _log.warning('The splat viewer did not open: $error');
      _closed.add(SplatHostClosed.error);
    }
  }

  @override
  Future<void> close() async {
    try {
      await _api.close();
    } catch (error) {
      _log.fine('The splat viewer did not close: $error');
    }
  }

  /// The activity closed for [reason]: 'user', 'rendererGone', 'noWebView' or 'error'
  void onActivityClosed(String reason) {
    _log.info('The splat viewer closed: $reason');
    _closed.add(switch (reason) {
      'rendererGone' => SplatHostClosed.rendererGone,
      'noWebView' => SplatHostClosed.noWebView,
      'error' => SplatHostClosed.error,
      _ => SplatHostClosed.user,
    });
  }
}

class _ActivityEvents implements SplatViewerEvents {
  const _ActivityEvents(this._host);

  final PigeonSplatViewerHost _host;

  @override
  void closed(String reason) => _host.onActivityClosed(reason);
}
