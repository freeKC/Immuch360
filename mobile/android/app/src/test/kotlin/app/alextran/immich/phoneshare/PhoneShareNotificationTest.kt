package app.alextran.immich.phoneshare

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneShareNotificationTest {
  @Test
  fun keepsTheTextsFlutterSends() {
    val texts =
      PhoneShareNotificationTexts.of(
        "Partage des photos et vidéos sur le réseau",
        "http://192.168.1.20:8360, utilisateur phone4821",
        "Arrêter",
      )

    assertEquals("Partage des photos et vidéos sur le réseau", texts.title)
    assertEquals("http://192.168.1.20:8360, utilisateur phone4821", texts.text)
    assertEquals("Arrêter", texts.stopLabel)
  }

  @Test
  fun fallsBackToEnglishForAMissingOrBlankText() {
    val texts = PhoneShareNotificationTexts.of(null, "  ", "")

    assertEquals(PhoneShareNotificationTexts.DEFAULT, texts)
  }

  @Test
  fun dropsControlCharactersAndSpacesAround() {
    val texts = PhoneShareNotificationTexts.of(" Title\n", "a\tb\u0000c ", "Stop")

    assertEquals("Title", texts.title)
    assertEquals("a b c", texts.text)
  }

  @Test
  fun cutsATextTooLongForTheNotification() {
    val texts = PhoneShareNotificationTexts.of("Title", "x".repeat(500), "Stop")

    assertEquals(PhoneShareNotificationTexts.MAX_LENGTH, texts.text.length)
    assertTrue(texts.text.endsWith("…"))
  }

  @Test
  fun replacesTheTextOnly() {
    val texts = PhoneShareNotificationTexts.of("Title", "http://192.168.1.20:8360, user phone4821", "Stop")

    val updated = texts.withText("http://10.0.0.5:8360, user phone4821")

    assertEquals("Title", updated.title)
    assertEquals("http://10.0.0.5:8360, user phone4821", updated.text)
    assertEquals("Stop", updated.stopLabel)
    assertEquals("Immuch360", texts.withText(null).text)
  }
}
