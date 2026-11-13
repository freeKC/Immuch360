package app.alextran.immich.filmdownload

/**
 * The rules of the notifications of the film downloads that need no Android: the texts cut to what a notification
 * shows, the links a tap may open, the tag of the notification of the end of a copy. Kept apart from the service so
 * that the unit tests pin them.
 */
object FilmDownloadNoticeRules {
  const val MAX_LENGTH = 200

  /** The page of the downloaded films in the app, with its optional query (`?film=<id>&do=resume`) */
  const val LINK = "immuch360://downloads"

  private val CONTROL = Regex("[\\u0000-\\u001f\\u007f]+")
  private val LINK_QUERY = Regex("[A-Za-z0-9=&_.-]{1,200}")
  private val FILM_ID = Regex("[0-9a-f]{1,64}")
  private const val TAG_PREFIX = "film_download:"

  /** [value] without control characters, cut to [MAX_LENGTH]; [fallback] when nothing is left */
  fun clean(value: String?, fallback: String): String = cleanOrNull(value) ?: fallback

  /** [value] without control characters, cut to [MAX_LENGTH]; null when nothing is left */
  fun cleanOrNull(value: String?): String? {
    val trimmed = value?.replace(CONTROL, " ")?.trim()
    if (trimmed.isNullOrEmpty()) {
      return null
    }
    return if (trimmed.length > MAX_LENGTH) trimmed.take(MAX_LENGTH - 1).trimEnd() + "…" else trimmed
  }

  /**
   * [link] when it opens the downloaded films of this app, null for any other link: a notification never carries an
   * address of a server nor another app's link
   */
  fun safeLink(link: String?): String? {
    if (link == null || !link.startsWith(LINK)) {
      return null
    }
    val rest = link.substring(LINK.length)
    if (rest.isEmpty()) {
      return link
    }
    if (rest[0] != '?' || !LINK_QUERY.matches(rest.substring(1))) {
      return null
    }
    return link
  }

  /** The tag of the end notification of [filmId], one per film; null for an id the app does not make */
  fun endTag(filmId: String?): String? =
    if (filmId != null && FILM_ID.matches(filmId)) TAG_PREFIX + filmId else null
}
