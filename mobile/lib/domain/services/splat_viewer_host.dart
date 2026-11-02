// The window or the screen that shows the splat viewer's page (plan of 2 November 2026, section 2.3): a window of its
// own over the app's on the computers (DesktopSplatViewerHost, desktop_webview_window), a native activity on Android
// phones and tablets (PigeonSplatViewerHost, SplatViewerActivity). The page talks to the app over HTTP, through the
// media bridge (splat_viewer_session.dart): a host only opens it, closes it and says how it closed.

/// How a viewer closed
enum SplatHostClosed {
  /// The user went back (the page's Back, Esc, the system's back), or the app closed it
  user,

  /// The web view's process died (out of memory most often): the app says so, it is not a white screen
  rendererGone,

  /// No web view that can show the page: the WebView2 Runtime missing on Windows, an Android System WebView too old
  noWebView,

  /// The page could not be loaded
  error,
}

abstract interface class SplatViewerHost {
  /// Shows [pageUrl] (`http://127.0.0.1:<port>/<token>/<session>/index.html`), titled [title]; completes once it is
  /// shown. Only URLs under the session's folder are loaded.
  Future<void> open(Uri pageUrl, {required String title});

  /// Closes the viewer (the page asked to, or the app is closing); nothing when none is open
  Future<void> close();

  /// Once per open, how it closed
  Stream<SplatHostClosed> get closed;
}

/// The folder of the session a page URL is in, which the hosts keep the viewer to:
/// `http://127.0.0.1:<port>/<token>/<s>/`
String splatViewerPrefixOf(Uri pageUrl) {
  final segments = pageUrl.pathSegments;
  return pageUrl
      .replace(pathSegments: [...segments.take(segments.length - 1), ''], query: null, fragment: null)
      .toString();
}

/// Whether [url] may load in the viewer of [prefix]: the session's own files only
bool splatViewerAllows(String prefix, String url) {
  if (!url.startsWith(prefix) || Uri.tryParse(url) == null) {
    return false;
  }
  // No dot segment, written or encoded, which would climb out of the folder
  return !RegExp(r'(^|/)(\.|%2e){1,2}(/|\?|#|$)', caseSensitive: false).hasMatch(url.substring(prefix.length));
}
