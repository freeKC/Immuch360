package app.alextran.immich.core

/**
 * What the crash reports of [AppHealth] leave out of a text before it reaches the Logs page, which users copy into
 * their issues: the URLs (a server address, a token), the folders of the installed app, and what goes beyond a size.
 */
object CrashText {
  // Up to a blank or a quote: the quotes around a thread name stay
  private val URL = Regex("""[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'<>]+""")

  // /data/app/~~<random>==/com.aprogsys.immuch360-<random>==/ before Android 11's random folder too
  private val APP_FOLDER = Regex("""/data/app/(?:~~[^/\s]*/)?[^/\s]+/""")

  /** [text] with each URL in it replaced */
  fun withoutUrls(text: String): String = URL.replace(text, "(a URL)")

  /** [text] with the folders of the installed app removed: its APK is then base.apk, as the stores show it */
  fun withoutAppFolders(text: String): String = APP_FOLDER.replace(text, "")

  /** [text] cut to at most [maxBytes] bytes of UTF-8, never inside a character */
  fun cutUtf8(text: String, maxBytes: Int): String {
    val bytes = text.toByteArray(Charsets.UTF_8)
    if (bytes.size <= maxBytes) {
      return text
    }
    var end = maxBytes.coerceAtLeast(0)
    // A continuation byte (10xxxxxx) belongs to the character before it: the cut goes before that character
    while (end > 0 && (bytes[end].toInt() and 0xC0) == 0x80) {
      end--
    }
    return String(bytes, 0, end, Charsets.UTF_8)
  }
}
