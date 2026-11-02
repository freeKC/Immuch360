package app.alextran.immich.splatviewer

/**
 * The rules of the splat viewer's activity, pure so that they are tested on the JVM (SplatViewerRulesTest):
 * which URLs load in it, and which Android System WebView can show the page.
 */
object SplatViewerRules {
  /**
   * The oldest Android System WebView that shows the page: WebAssembly SIMD came with Chromium 91, and Spark needs it.
   * The page checks again (WebGL 2 and SIMD) and says so.
   */
  const val MIN_WEBVIEW_MAJOR = 91

  /** The folder of the session [pageUrl] is in: the page and everything it loads are under it */
  fun prefixOf(pageUrl: String): String {
    val query = pageUrl.indexOfAny(charArrayOf('?', '#')).let { if (it < 0) pageUrl.length else it }
    val path = pageUrl.substring(0, query)
    return path.substring(0, path.lastIndexOf('/') + 1)
  }

  /** Whether [url] may load in the viewer of [prefix]: the session's own files, no dot segment climbing out */
  fun allows(prefix: String, url: String): Boolean {
    if (!url.startsWith(prefix) || !prefix.startsWith("http://127.0.0.1:")) return false
    val rest = url.substring(prefix.length)
    return !Regex("(^|/)(\\.|%2e){1,2}(/|\\?|#|$)", RegexOption.IGNORE_CASE).containsMatchIn(rest)
  }

  /** The major version of a WebView version name ("133.0.6943.137"), 0 when it cannot be read */
  fun majorOf(versionName: String?): Int = versionName?.substringBefore('.')?.trim()?.toIntOrNull() ?: 0

  /** Whether a WebView of [major] can show the page */
  fun canShow(major: Int): Boolean = major >= MIN_WEBVIEW_MAJOR
}
