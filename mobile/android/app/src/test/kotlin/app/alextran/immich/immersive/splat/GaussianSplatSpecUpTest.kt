package app.alextran.immich.immersive.splat

import app.alextran.immich.relief.ReliefFixtures
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The optional up of the gaussianSplat request (plan of 3 November 2026, lot L4): the scene of a splat photo opens
 * in the orientation chosen before it was saved, the requests of version 1 without it read as before, and an
 * orientation the headset does not know is no orientation.
 */
class GaussianSplatSpecUpTest {
  private val contract = ReliefFixtures.json("gaussian_splat_contract_v1.json")

  private fun spec(name: String): GaussianSplatSpec? = GaussianSplatSpec.fromJson(contract.getValue(name).jsonObject)

  @Test
  fun `the scene of a splat photo carries its up`() {
    val photo = spec("splatPhoto")
    assertNotNull(photo)
    assertEquals(SplatUpright.Y_UP, photo!!.up)
    assertEquals("mipnerf360-room-brush-150k.spz", photo.name)
    assertEquals(3612448L, photo.fileBytes)
  }

  @Test
  fun `a request of version 1 without up reads as before`() {
    assertEquals(
      GaussianSplatSpec(SplatFormat.SPZ, 3, 452451, 0, 6824362, 50000, null, "gsplat-cactus.spz"),
      spec("gaussianSplat"),
    )
    assertNull(spec("ply")!!.up)
  }

  @Test
  fun `an up the headset does not know is no up, the request still read`() {
    val photo = contract.getValue("splatPhoto").jsonObject
    for (value in listOf(JsonPrimitive("sideways"), JsonPrimitive(1), kotlinx.serialization.json.JsonNull)) {
      val read = GaussianSplatSpec.fromJson(JsonObject(photo + ("up" to value)))
      assertNotNull(value.toString(), read)
      assertNull(value.toString(), read!!.up)
    }
  }
}
