package app.alextran.immich.phoneshare

/**
 * The texts of the notification of the phone share. Flutter sends them translated with every start; a text that did
 * not arrive (a service restarted by the system without its intent) falls back to English rather than an empty
 * notification, and a text too long for a notification line is cut.
 */
data class PhoneShareNotificationTexts(val title: String, val text: String, val stopLabel: String) {
  fun withText(text: String?): PhoneShareNotificationTexts = copy(text = clean(text, DEFAULT.text))

  companion object {
    /** Longest text kept; a notification shows far less, the expanded one a few lines */
    const val MAX_LENGTH = 200

    val DEFAULT =
      PhoneShareNotificationTexts(
        title = "Sharing photos and videos on the network",
        text = "Immuch360",
        stopLabel = "Stop",
      )

    fun of(title: String?, text: String?, stopLabel: String?): PhoneShareNotificationTexts =
      PhoneShareNotificationTexts(
        title = clean(title, DEFAULT.title),
        text = clean(text, DEFAULT.text),
        stopLabel = clean(stopLabel, DEFAULT.stopLabel),
      )

    private fun clean(value: String?, fallback: String): String {
      val trimmed = value?.replace(CONTROL, " ")?.trim()
      if (trimmed.isNullOrEmpty()) {
        return fallback
      }
      return if (trimmed.length > MAX_LENGTH) trimmed.take(MAX_LENGTH - 1).trimEnd() + "…" else trimmed
    }

    private val CONTROL = Regex("[\\u0000-\\u001f\\u007f]+")
  }
}
