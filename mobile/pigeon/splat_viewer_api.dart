import 'package:pigeon/pigeon.dart';

// The splat viewer of the Android phones and tablets (lot SV6 of the splat viewer): SplatViewerActivity, a WebView that
// shows the page the app serves on its media bridge (http://127.0.0.1:<port>/<token>/<session>/index.html). The page
// talks to the app over HTTP, so this API only opens, closes and tells how the viewer closed. The computers show the
// page through desktop_webview_window and never call it (pigeon-not-on-desktop.json); iOS comes with its own lot.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/splat_viewer_api.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/splatviewer/SplatViewer.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.splatviewer'),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
@HostApi()
abstract class SplatViewerApi {
  /// Shows [pageUrl] full screen, titled [title], as the viewing number [viewing]; only the URLs of its folder load in
  /// it
  void open(String pageUrl, String title, int viewing);

  /// Closes the viewer when it is open
  void close();

  /// The major version of the Android System WebView the app would use, 0 when there is none
  int webViewMajorVersion();
}

@FlutterApi()
abstract class SplatViewerEvents {
  /// The viewer of the viewing number [viewing] closed: "user", "rendererGone", "noWebView" or "error". A late
  /// closing of an earlier viewing never ends the current one.
  void closed(String reason, int viewing);
}
