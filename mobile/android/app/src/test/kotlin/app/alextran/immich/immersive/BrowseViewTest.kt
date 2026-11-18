package app.alextran.immich.immersive

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The view kept from one photo of the flat screen to the next (issue 19, point 5). */
class BrowseViewTest {
  @Test
  fun `a photo opened from the app starts from its request`() {
    val fresh = BrowseView.startView(null, StereoView.THREE_D, holdsTwoEyes = true, relief = false)
    assertEquals(StereoView.THREE_D, fresh)
    val relief = BrowseView.startView(null, StereoView.MESH_25D, holdsTwoEyes = true, relief = true)
    assertEquals(StereoView.MESH_25D, relief)
  }

  @Test
  fun `2D kept goes to every photo of two eyes, a relief included`() {
    for (relief in listOf(false, true)) {
      val view = BrowseView.startView(StereoView.TWO_D, StereoView.THREE_D, holdsTwoEyes = true, relief = relief)
      assertEquals(StereoView.TWO_D, view)
    }
    // A relief whose request asks for 2.5D still stays 2D while browsing in 2D
    assertEquals(
      StereoView.TWO_D,
      BrowseView.startView(StereoView.TWO_D, StereoView.MESH_25D, holdsTwoEyes = true, relief = true),
    )
  }

  @Test
  fun `2_5D kept goes to a relief only, another photo of two eyes shows in 3D`() {
    assertEquals(
      StereoView.MESH_25D,
      BrowseView.startView(StereoView.MESH_25D, StereoView.THREE_D, holdsTwoEyes = true, relief = true),
    )
    assertEquals(
      StereoView.THREE_D,
      BrowseView.startView(StereoView.MESH_25D, StereoView.THREE_D, holdsTwoEyes = true, relief = false),
    )
  }

  @Test
  fun `3D kept wins over the 2_5D of a relief request, and one picture shows as it is`() {
    assertEquals(
      StereoView.THREE_D,
      BrowseView.startView(StereoView.THREE_D, StereoView.MESH_25D, holdsTwoEyes = true, relief = true),
    )
    assertEquals(
      StereoView.THREE_D,
      BrowseView.startView(StereoView.TWO_D, StereoView.THREE_D, holdsTwoEyes = false, relief = false),
    )
  }

  @Test
  fun `a relief reached in 2D is not computed, in 3D or 2_5D it is`() {
    assertFalse(BrowseView.computesRelief(StereoView.TWO_D))
    assertTrue(BrowseView.computesRelief(StereoView.THREE_D))
    assertTrue(BrowseView.computesRelief(StereoView.MESH_25D))
  }

  @Test
  fun `a relief left without a press keeps the setting`() {
    assertNull(ReliefFirstView().take())
  }

  @Test
  fun `2_5D passed through on the way to 2D is never kept`() {
    val first = ReliefFirstView()
    // 3D at the opening, then the button: 2.5D, then 2D
    first.pressed(StereoView.MESH_25D)
    first.pressed(StereoView.TWO_D)
    assertNull(first.take())
  }

  @Test
  fun `the view a relief is left in after a press is kept, once`() {
    val first = ReliefFirstView()
    first.pressed(StereoView.MESH_25D)
    assertEquals(StereoView.MESH_25D, first.take())
    assertNull(first.take())
    // 2.5D, 2D, then 3D again: 3D is the choice
    first.pressed(StereoView.MESH_25D)
    first.pressed(StereoView.TWO_D)
    first.pressed(StereoView.THREE_D)
    assertEquals(StereoView.THREE_D, first.take())
  }
}
