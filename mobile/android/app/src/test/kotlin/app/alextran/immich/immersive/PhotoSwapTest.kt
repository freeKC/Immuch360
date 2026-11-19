package app.alextran.immich.immersive

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The photo shown stays until the next one is ready, between two photos of a flat screen only (issue 19). */
class PhotoSwapTest {
  @Test
  fun `the next photo of a flat screen replaces the one shown without a gap`() {
    assertTrue(PhotoSwap.keepsShown(true, shownIsScreenPhoto = true, nextIsScreenPhoto = true, shownIn25d = false))
  }

  @Test
  fun `a photo opened from the app, a sphere on either side or a relief in 2_5D hides the photo first`() {
    assertFalse(PhotoSwap.keepsShown(false, shownIsScreenPhoto = true, nextIsScreenPhoto = true, shownIn25d = false))
    assertFalse(PhotoSwap.keepsShown(true, shownIsScreenPhoto = false, nextIsScreenPhoto = true, shownIn25d = false))
    assertFalse(PhotoSwap.keepsShown(true, shownIsScreenPhoto = true, nextIsScreenPhoto = false, shownIn25d = false))
    assertFalse(PhotoSwap.keepsShown(true, shownIsScreenPhoto = true, nextIsScreenPhoto = true, shownIn25d = true))
  }
}
