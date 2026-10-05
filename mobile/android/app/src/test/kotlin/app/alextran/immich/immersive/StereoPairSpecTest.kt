package app.alextran.immich.immersive

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The stereoPair JSON Flutter sends for an Apple spatial photo (section 5.6 of the design). */
class StereoPairSpecTest {
  private val sample =
    """{"kind":"heicStereoPair","version":1,"primaryItemId":37,"leftItemId":37,"rightItemId":74,""" +
      """"pitmIdOffset":129,"pitmIdBytes":2,"width":3072,"height":3072,"rotation":0,""" +
      """"disparityAdjustment":-1000,"horizontalFovDeg":59.98}"""

  @Test
  fun `reads the pair of the sample`() {
    assertEquals(
      StereoPairSpec(
        primaryItemId = 37,
        leftItemId = 37,
        rightItemId = 74,
        pitmIdOffset = 129,
        pitmIdBytes = 2,
        width = 3072,
        height = 3072,
        rotation = 0,
        disparityAdjustment = -1000,
        horizontalFovDeg = 59.98f,
      ),
      StereoPairSpec.parse(sample),
    )
  }

  @Test
  fun `the disparity and the field of view are optional`() {
    val spec =
      StereoPairSpec.parse(
        """{"kind":"heicStereoPair","version":1,"primaryItemId":1,"leftItemId":1,"rightItemId":2,""" +
          """"pitmIdOffset":100,"pitmIdBytes":4,"width":10,"height":20,"futureField":true}""",
      )
    assertEquals(0, spec?.disparityAdjustment)
    assertNull(spec?.horizontalFovDeg)
    assertEquals(4, spec?.pitmIdBytes)
    assertEquals(0, spec?.rotation)
  }

  @Test
  fun `an unknown kind or version is no pair`() {
    assertNull(StereoPairSpec.parse(sample.replace("heicStereoPair", "mvHevc")))
    assertNull(StereoPairSpec.parse(sample.replace("\"version\":1", "\"version\":2")))
    assertNull(StereoPairSpec.parse(sample.replace("\"version\":1", "\"version\":\"1\"")))
  }

  @Test
  fun `a damaged or impossible pair is none`() {
    assertNull(StereoPairSpec.parse(null))
    assertNull(StereoPairSpec.parse(""))
    assertNull(StereoPairSpec.parse("not json"))
    assertNull(StereoPairSpec.parse("[1, 2]"))
    assertNull(StereoPairSpec.parse(sample.replace("\"rightItemId\":74,", "")))
    assertNull(StereoPairSpec.parse(sample.replace("\"pitmIdBytes\":2", "\"pitmIdBytes\":3")))
    assertNull(StereoPairSpec.parse(sample.replace("\"width\":3072", "\"width\":0")))
    assertNull(StereoPairSpec.parse(sample.replace("\"rightItemId\":74", "\"rightItemId\":37")))
  }

  @Test
  fun `a disparity out of range is clamped`() {
    assertEquals(10000, StereoPairSpec.parse(sample.replace("-1000", "25000"))?.disparityAdjustment)
  }
}
