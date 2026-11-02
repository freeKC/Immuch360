package app.alextran.immich.splatviewer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The rules of the splat viewer's activity: the URLs it loads, the WebView it needs (lot SV6) */
class SplatViewerRulesTest {
  private val page = "http://127.0.0.1:43123/abcdef0123456789abcdef0123456789/00112233445566778899aabbccddeeff/index.html"

  @Test
  fun `the viewer keeps to the folder of its session`() {
    val prefix = SplatViewerRules.prefixOf(page)
    assertEquals("http://127.0.0.1:43123/abcdef0123456789abcdef0123456789/00112233445566778899aabbccddeeff/", prefix)
    assertEquals(prefix, SplatViewerRules.prefixOf("$page?x=1#y"))
    assertTrue(SplatViewerRules.allows(prefix, page))
    assertTrue(SplatViewerRules.allows(prefix, "${prefix}viewer.js"))
    assertFalse(SplatViewerRules.allows(prefix, "https://example.com/"))
    assertFalse(SplatViewerRules.allows(prefix, "http://127.0.0.1:43123/abcdef0123456789abcdef0123456789/other/index.html"))
    assertFalse(SplatViewerRules.allows(prefix, "${prefix}../other/index.html"))
    assertFalse(SplatViewerRules.allows(prefix, "${prefix}%2e%2e/other/index.html"))
    assertFalse(SplatViewerRules.allows("http://example.com/a/", "http://example.com/a/index.html"))
  }

  @Test
  fun `Android System WebView 91 or later shows the page`() {
    assertEquals(133, SplatViewerRules.majorOf("133.0.6943.137"))
    assertEquals(0, SplatViewerRules.majorOf(null))
    assertEquals(0, SplatViewerRules.majorOf("beta"))
    assertFalse(SplatViewerRules.canShow(90))
    assertTrue(SplatViewerRules.canShow(91))
    assertFalse(SplatViewerRules.canShow(0))
  }
}
