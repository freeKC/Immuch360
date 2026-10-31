package app.alextran.immich.documenttree

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Where the folder picker opens for Browse a folder: a folder of the storage of the device, by its document id */
class PickTreeStartTest {
  @Test
  fun `a folder of the storage is a document of the primary volume`() {
    assertEquals("primary:Download", PickTreeStart.documentId("Download"))
    assertEquals("primary:Download", PickTreeStart.documentId("/Download/"))
    assertEquals("primary:Download/Immuch360-splats", PickTreeStart.documentId("Download/Immuch360-splats"))
    assertEquals("primary:DCIM/Camera", PickTreeStart.documentId(" DCIM/Camera "))
  }

  @Test
  fun `no folder asked, or one that is not a plain path, opens the picker where it opens by itself`() {
    assertNull(PickTreeStart.documentId(null))
    assertNull(PickTreeStart.documentId(""))
    assertNull(PickTreeStart.documentId("/"))
    assertNull(PickTreeStart.documentId("../Android/data"))
    assertNull(PickTreeStart.documentId("Download/./x"))
    assertNull(PickTreeStart.documentId("Download//x"))
    assertNull(PickTreeStart.documentId("1A2B-3C4D:DCIM"))
    assertNull(PickTreeStart.documentId("Download\\x"))
    assertNull(PickTreeStart.documentId("Down\nload"))
  }
}
