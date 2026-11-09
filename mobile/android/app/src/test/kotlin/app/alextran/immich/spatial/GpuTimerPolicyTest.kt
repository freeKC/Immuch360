package app.alextran.immich.spatial

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which drivers may run the GPU timer queries of the Spatial 2.5D renderer. Build 25 crashed in libGLES_mali.so under
 * glGetQueryObjectuiv on a Redmi Note 11S, whose GPU is a Mali-G57 MC2 (Play cluster 7b656f).
 */
class GpuTimerPolicyTest {
  private fun decide(
    vendor: String?,
    renderer: String?,
    extensions: String? = WITH_TIMER,
    crashedBefore: Boolean = false,
    wanted: Boolean = true,
  ): GpuTimerVerdict = GpuTimerPolicy.decide(vendor, renderer, extensions, crashedBefore, wanted)

  @Test
  fun `the Mali-G57 of the P6 crash gives ARM_MALI`() {
    assertEquals(GpuTimerVerdict.ARM_MALI, decide("ARM", "Mali-G57 MC2"))
    // The renderer alone is enough, whatever the vendor string says
    assertEquals(GpuTimerVerdict.ARM_MALI, decide("Unknown", "Mali-G57 MC2"))
    assertEquals(GpuTimerVerdict.ARM_MALI, decide(null, "mali-g57 mc2"))
  }

  @Test
  fun `Immortalis names and the ARM vendor give ARM_MALI`() {
    assertEquals(GpuTimerVerdict.ARM_MALI, decide("ARM", "Mali-G715-Immortalis MC11"))
    assertEquals(GpuTimerVerdict.ARM_MALI, decide("ARM", "Immortalis-G720 MC12"))
    assertEquals(GpuTimerVerdict.ARM_MALI, decide(null, "IMMORTALIS-G925"))
    // A future ARM GPU with another name is caught by the vendor
    assertEquals(GpuTimerVerdict.ARM_MALI, decide("ARM", "Some later GPU"))
    assertEquals(GpuTimerVerdict.ARM_MALI, decide("arm", "Some later GPU"))
  }

  @Test
  fun `the vendor check takes ARM as a word only`() {
    assertEquals(GpuTimerVerdict.ALLOWED, decide("Charm Graphics", "Some GPU"))
    assertEquals(GpuTimerVerdict.ALLOWED, decide("Qualcomm", "Adreno (TM) 740"))
  }

  @Test
  fun `Adreno is allowed with the extension and not without it`() {
    assertEquals(GpuTimerVerdict.ALLOWED, decide("Qualcomm", "Adreno (TM) 619"))
    assertEquals(GpuTimerVerdict.NO_EXTENSION, decide("Qualcomm", "Adreno (TM) 619", WITHOUT_TIMER))
  }

  @Test
  fun `null strings give NO_EXTENSION`() {
    assertEquals(GpuTimerVerdict.NO_EXTENSION, decide(null, null, null))
    assertEquals(GpuTimerVerdict.NO_EXTENSION, decide("Qualcomm", "Adreno (TM) 619", null))
    assertEquals(GpuTimerVerdict.NO_EXTENSION, decide("Qualcomm", "Adreno (TM) 619", ""))
  }

  @Test
  fun `a longer token that only starts with the extension name is not the extension`() {
    val lookalikes = "GL_OES_EGL_image_external GL_EXT_disjoint_timer_query_webgl2 GL_EXT_disjoint_timer_query2"
    assertEquals(GpuTimerVerdict.NO_EXTENSION, decide("Qualcomm", "Adreno (TM) 619", lookalikes))
    assertFalse(GpuTimerPolicy.hasExtension(lookalikes, GpuTimerPolicy.TIMER_EXTENSION))
    assertFalse(GpuTimerPolicy.hasExtension("XGL_EXT_disjoint_timer_query", GpuTimerPolicy.TIMER_EXTENSION))
    assertTrue(GpuTimerPolicy.hasExtension(" GL_EXT_disjoint_timer_query ", GpuTimerPolicy.TIMER_EXTENSION))
    assertTrue(GpuTimerPolicy.hasExtension(WITH_TIMER, GpuTimerPolicy.TIMER_EXTENSION))
    assertFalse(GpuTimerPolicy.hasExtension(WITH_TIMER, ""))
  }

  @Test
  fun `virtual GPUs give VIRTUAL_GPU`() {
    assertEquals(GpuTimerVerdict.VIRTUAL_GPU, decide("Mesa", "virgl"))
    assertEquals(GpuTimerVerdict.VIRTUAL_GPU, decide("Mesa", "Virtio-GPU"))
  }

  @Test
  fun `a crash before wins over ALLOWED`() {
    assertEquals(GpuTimerVerdict.CRASHED_BEFORE, decide("Qualcomm", "Adreno (TM) 619", crashedBefore = true))
  }

  @Test
  fun `timers not wanted give TURNED_OFF before anything else`() {
    assertEquals(GpuTimerVerdict.TURNED_OFF, decide("Qualcomm", "Adreno (TM) 619", wanted = false))
    assertEquals(GpuTimerVerdict.TURNED_OFF, decide("ARM", "Mali-G57 MC2", crashedBefore = true, wanted = false))
  }

  @Test
  fun `only ALLOWED lets the queries run`() {
    assertEquals(listOf(GpuTimerVerdict.ALLOWED), GpuTimerVerdict.entries.filter { it.allowed })
  }

  @Test
  fun `the driver key changes with GL_VERSION`() {
    val before = GpuTimerPolicy.driverKey("Mali-G57 MC2", "OpenGL ES 3.2 v1.r26p0-01eac0")
    val after = GpuTimerPolicy.driverKey("Mali-G57 MC2", "OpenGL ES 3.2 v1.r32p1-00pxl1")
    assertNotEquals(before, after)
    assertEquals(before, GpuTimerPolicy.driverKey(" Mali-G57 MC2", "OpenGL ES 3.2 v1.r26p0-01eac0 "))
    assertNotEquals(before, GpuTimerPolicy.driverKey("Mali-G68 MC4", "OpenGL ES 3.2 v1.r26p0-01eac0"))
  }

  @Test
  fun `the driver key is bounded, on one line, and takes null strings`() {
    val long = GpuTimerPolicy.driverKey("R".repeat(500), "V".repeat(500))
    assertEquals(GpuTimerPolicy.MAX_DRIVER_KEY_LENGTH, long.length)
    assertFalse(GpuTimerPolicy.driverKey("Adreno\n(TM)", "OpenGL ES\r\n3.2").contains('\n'))
    assertEquals(" | ", GpuTimerPolicy.driverKey(null, null))
  }

  private companion object {
    const val WITH_TIMER = "GL_OES_EGL_image_external GL_EXT_disjoint_timer_query GL_EXT_color_buffer_half_float"
    const val WITHOUT_TIMER = "GL_OES_EGL_image_external GL_EXT_color_buffer_half_float"
  }
}
