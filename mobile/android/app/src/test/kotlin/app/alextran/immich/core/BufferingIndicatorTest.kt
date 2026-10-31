package app.alextran.immich.core

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BufferingIndicatorTest {
  private val labels =
    mapOf(
      BufferingIndicator.LABEL_LOADING_RATE to "Chargement : {got} sur les {need} que demande cette vidéo",
      BufferingIndicator.LABEL_DEAD_SERVER to "Le serveur n'envoie plus cette vidéo",
      BufferingIndicator.LABEL_DEAD_SHARE to "Le partage n'envoie plus cette vidéo",
      BufferingIndicator.LABEL_MBPS to "{value} Mbit/s",
      BufferingIndicator.LABEL_KBPS to "{value} kbit/s",
    )

  @Test
  fun `the rate against the need, in the units of the details of a video`() {
    assertEquals(
      "Chargement : 1,2 Mbit/s sur les 3 Mbit/s que demande cette vidéo",
      BufferingIndicator.describe(labels, 150_000L, 375_000L, 1_000L, share = false, locale = Locale.FRANCE),
    )
    assertEquals("600 kbit/s", BufferingIndicator.formatRate(75_000L, labels, Locale.FRANCE))
    assertEquals("30 Mbit/s", BufferingIndicator.formatRate(3_750_000L, labels, Locale.FRANCE))
    assertEquals("1,2 Mbit/s", BufferingIndicator.formatRate(150_000L, labels, Locale.FRANCE))
  }

  @Test
  fun `thirty seconds without progress say that the server or the share stopped sending`() {
    assertEquals(
      "Le serveur n'envoie plus cette vidéo",
      BufferingIndicator.describe(labels, 0L, 375_000L, 30_000L, share = false),
    )
    assertEquals("Le partage n'envoie plus cette vidéo", BufferingIndicator.describe(labels, null, null, 31_000L, share = true))
  }

  @Test
  fun `nothing measured yet leaves the percentage`() {
    assertNull(BufferingIndicator.describe(labels, null, 375_000L, 1_000L, share = false))
    assertNull(BufferingIndicator.describe(labels, 150_000L, null, 1_000L, share = false))
  }

  @Test
  fun `a share is a video of the media bridge`() {
    assertEquals(true, BufferingIndicator.isShare("http://127.0.0.1:41234/token/src/film.mkv"))
    assertEquals(false, BufferingIndicator.isShare("https://immich.example.org/api/assets/1/video/playback"))
    assertEquals(false, BufferingIndicator.isShare(null))
  }
}
