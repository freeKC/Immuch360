package app.alextran.immich.review

import org.junit.Assert.assertEquals
import org.junit.Test

class HorizonStoreLinkTest {
  @Test
  fun `the store page is Meta's deep link of the app's id`() {
    val link = HorizonStoreLink.of()
    assertEquals("com.oculus.vrshell", link.packageName)
    assertEquals("com.oculus.vrshell.MainActivity", link.className)
    assertEquals("systemux://store", link.data)
    assertEquals("/item/1384208401440714", link.uri)
  }

  @Test
  fun `another id gives its page`() {
    assertEquals("/item/42", HorizonStoreLink.of("42").uri)
  }
}
