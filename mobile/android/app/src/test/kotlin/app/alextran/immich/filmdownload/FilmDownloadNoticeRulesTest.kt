package app.alextran.immich.filmdownload

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FilmDownloadNoticeRulesTest {
  @Test
  fun cleanDropsControlCharactersAndCutsLongTexts() {
    assertEquals("Downloading A film", FilmDownloadNoticeRules.clean("Downloading\nA\u0007film", "x"))
    assertEquals("fallback", FilmDownloadNoticeRules.clean("  \n ", "fallback"))
    assertEquals("fallback", FilmDownloadNoticeRules.clean(null, "fallback"))
    val long = FilmDownloadNoticeRules.clean("a".repeat(500), "x")
    assertEquals(FilmDownloadNoticeRules.MAX_LENGTH, long.length)
    assertEquals('…', long.last())
  }

  @Test
  fun cleanOrNullKeepsNoEmptyText() {
    assertNull(FilmDownloadNoticeRules.cleanOrNull(""))
    assertNull(FilmDownloadNoticeRules.cleanOrNull(null))
    assertEquals("12 MB/s", FilmDownloadNoticeRules.cleanOrNull(" 12 MB/s "))
  }

  @Test
  fun safeLinkOpensOnlyTheDownloadedFilms() {
    assertEquals("immuch360://downloads", FilmDownloadNoticeRules.safeLink("immuch360://downloads"))
    assertEquals(
      "immuch360://downloads?film=0a1b2c&do=retry",
      FilmDownloadNoticeRules.safeLink("immuch360://downloads?film=0a1b2c&do=retry"),
    )
    assertNull(FilmDownloadNoticeRules.safeLink(null))
    assertNull(FilmDownloadNoticeRules.safeLink("https://plex.example/library/parts/1?X-Plex-Token=abc"))
    assertNull(FilmDownloadNoticeRules.safeLink("immuch360://pair?u=http://1.2.3.4"))
    assertNull(FilmDownloadNoticeRules.safeLink("immuch360://downloadsevil"))
    assertNull(FilmDownloadNoticeRules.safeLink("immuch360://downloads/x"))
    assertNull(FilmDownloadNoticeRules.safeLink("immuch360://downloads?u=http://x/y"))
    assertNull(FilmDownloadNoticeRules.safeLink("immuch360://downloads?"))
  }

  @Test
  fun endTagIsOnePerFilmOfTheApp() {
    assertEquals("film_download:0a1b2c3d4e5f6071", FilmDownloadNoticeRules.endTag("0a1b2c3d4e5f6071"))
    assertNull(FilmDownloadNoticeRules.endTag(null))
    assertNull(FilmDownloadNoticeRules.endTag(""))
    assertNull(FilmDownloadNoticeRules.endTag("../x"))
  }
}
