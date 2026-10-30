package app.alextran.immich.immersive.splat

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The gate of the build of the Gaussian splats (FreeKC's decision of 30 October 2026): the GitHub builds offer them,
 * the build of the Meta Horizon Store, the same APK re-signed with the key its store app is bound to, hides them unless
 * [SplatBuild.SPLATS_IN_STORE_BUILD] is flipped. The two certificates are those of the quest APK of release 35 (GitHub)
 * and of the quest APK of release 32 re-signed for the store (builds/meta_sign_upload.sh), as their APK signature
 * blocks carry them: what PackageManager hands the app.
 */
class SplatBuildTest {
  private val github = Base64.getDecoder().decode(GITHUB_CERTIFICATE)
  private val store = Base64.getDecoder().decode(STORE_CERTIFICATE)

  @Test
  fun `the SHA-256 of each certificate is the digest apksigner prints for its APK`() {
    assertEquals(SplatBuild.GITHUB_CERTIFICATE_SHA256, SplatBuild.sha256Hex(github))
    assertEquals(SplatBuild.STORE_CERTIFICATE_SHA256, SplatBuild.sha256Hex(store))
    assertTrue(SplatBuild.GITHUB_CERTIFICATE_SHA256.startsWith("aa7aab33987b1a02"))
    assertTrue(SplatBuild.STORE_CERTIFICATE_SHA256.startsWith("ecc6b085c727f003"))
  }

  @Test
  fun `the GitHub build offers the splats`() {
    val certificates = listOf(SplatBuild.sha256Hex(github))
    assertFalse(SplatBuild.isStoreBuild(certificates))
    assertTrue(SplatBuild.offersSplats(certificates, inStoreBuild = false))
    assertTrue(SplatBuild.offersSplats(certificates, inStoreBuild = true))
  }

  @Test
  fun `the store build hides the splats while SPLATS_IN_STORE_BUILD is false`() {
    val certificates = listOf(SplatBuild.sha256Hex(store))
    assertTrue(SplatBuild.isStoreBuild(certificates))
    assertFalse(SplatBuild.offersSplats(certificates, inStoreBuild = false))
    // Flipped (Meta's written permission, or the API out of its experimental features), the store build offers them
    assertTrue(SplatBuild.offersSplats(certificates, inStoreBuild = true))
  }

  @Test
  fun `the switch is off in this source, and it is the default of the gate`() {
    assertFalse(SplatBuild.SPLATS_IN_STORE_BUILD)
    assertFalse(SplatBuild.offersSplats(listOf(SplatBuild.STORE_CERTIFICATE_SHA256)))
    assertTrue(SplatBuild.offersSplats(listOf(SplatBuild.GITHUB_CERTIFICATE_SHA256)))
  }

  @Test
  fun `a debug key or any other key offers the splats, a store certificate among several hides them`() {
    assertTrue(SplatBuild.offersSplats(listOf("0".repeat(64)), inStoreBuild = false))
    assertFalse(
      SplatBuild.offersSplats(
        listOf(SplatBuild.GITHUB_CERTIFICATE_SHA256, SplatBuild.STORE_CERTIFICATE_SHA256),
        inStoreBuild = false,
      )
    )
  }

  @Test
  fun `the digest is compared whatever its case and its colons, as keytool and apksigner write it`() {
    val keytool = SplatBuild.STORE_CERTIFICATE_SHA256.uppercase().chunked(2).joinToString(":")
    assertTrue(SplatBuild.isStoreBuild(listOf(keytool)))
  }

  @Test
  fun `certificates that could not be read hide the splats`() {
    assertFalse(SplatBuild.offersSplats(null, inStoreBuild = false))
    assertFalse(SplatBuild.offersSplats(emptyList(), inStoreBuild = false))
  }

  private companion object {
    /** The certificate of the GitHub release builds (C=FR, O=aprogsys, OU=FreeKC, CN=Immuch360), DER in Base64 */
    const val GITHUB_CERTIFICATE =
        "MIIFLzCCAxegAwIBAgIIQgZs8y4eND8wDQYJKoZIhvcNAQEMBQAwRTELMAkGA1UEBhMCRlIxETAPBgNVBAoTCGFwcm9nc3lzMQ8w" +
        "DQYDVQQLEwZGcmVlS0MxEjAQBgNVBAMTCUltbXVjaDM2MDAgFw0yNjA5MzAwNjM1MzZaGA8yMDU0MDIxNTA2MzUzNlowRTELMAkG" +
        "A1UEBhMCRlIxETAPBgNVBAoTCGFwcm9nc3lzMQ8wDQYDVQQLEwZGcmVlS0MxEjAQBgNVBAMTCUltbXVjaDM2MDCCAiIwDQYJKoZI" +
        "hvcNAQEBBQADggIPADCCAgoCggIBAKLEXl2kcJloVgx9uj9U0GeqWMpYeSj++DvnXqbkelP8Vt23374owM5fGRF+epxxkLwgOSyK" +
        "N9sVsQ+6X4y2lpnP+RaR7TAkiQiKKv2Fb//DWGpRK6cVSAWUmfb6Yx+9c0hE5jeczNh2Rs/wzhTT9r6HFk94wKNkyZj/fTB6DENz" +
        "qNSLdRnfwPkh+ytoKUNOiPgnAxLOyZZPLq2APMw10RQP8wh17pUKefuYxHZHO+Eci3N+aGWdRbLKG+S+v70jzeAbu5YiGCB1gyzS" +
        "GHBllMvpzh/tRoWZpQXeZmyBhTKD74plJZur2voGdmBQ5HosVqpMCbhUEaIaodCIJVW3CuFABHu+/40DYSO5ce2c/u4ZPsbDAxz/" +
        "JbhnxN3x2jivTc/qslYwP2GQo7xSs9OlzwXCDeLdoFgh+YnyOQ4aRZhzGixYaCuEJaVEq0Da32NLF5BdC472SyyGZnh5hNGMMoSy" +
        "r6Q7o+zybbTMH90QQrNK8YIVA1JybXN69QYlIgJpGXIbYPScHX/ib4GYHq8a/2/cAJVM682TjDTEYp7uVlPknUlHzGIgmDCUl13L" +
        "lCgWZz4h+Z3/YCNCTix3HF9E4TEo8fbIGXy/GYN1PUSQbdTVgg1Wqq7362Omgg5YeC9K485U/PWUsshfDLDZ6/Jgr4WfJwqeoeXG" +
        "o39mJRKYKia3AgMBAAGjITAfMB0GA1UdDgQWBBTlfplQF10jM30E6wvtPMVc3ZRURzANBgkqhkiG9w0BAQwFAAOCAgEAPIgR1DJm" +
        "P6IKflHWqgSo35CrVWPvqe0MovsY0gpXclS0QLB0JjbSmKJtfJgzUT07Fp1fQ+VcItTzp4nF9EJlLVCY7z5bKyo5ANXv7hzhQ6Is" +
        "il9AvTmSlhOc1gDEOr9sKdAplXQ1Y1idWZCcib9AfUD6p5wk+GvNG4ay7sySBsHs4+zofpZ62lx/rHUbV6xI9NZKdkDlTa6nHl2G" +
        "f6L9/02rdpWMeD0Tk12gNtSS3CxqcSfVtW71IpzLS0puYx2HHIcLH4oxvLJbvberbI8kL07dV1WXvbYZLUjwVMlOwPVUfzOiV/+4" +
        "9xHS9fgByPI6yPKYp5dVuVbJsTgeBpUVgUsJAckDBCv8ufKHfEy46RvsV2/U2OVtQqWZcRnRdBHc5fJLw3t5BxyjqP7UqQF/9uC7" +
        "ZdkrM+j9LEhSFXHOkSThFmW2qfZNHPpXyolGoam/0TSTdDO4QI+DbmeiSytNCArvq0EwODTpTK3467AJV+1Yb1nXVr1ivPekuKk+" +
        "OjV1qGZk8oqjzYiEAMIgUT7fnrbSReLfq4i+xm0Ge4rBLclE1sGvob42AkdiyjQLx0CVnRjLrzhECDJLvP8+ijh4PdP457OngHrw" +
        "sgdRhDIXaN1uRzPCVRXqgLJVF/dlYFKFKChp/B6Gv6Ya7AIkv0AnLMScsPG8QhtthlDL8ebDpEI="

    /** The certificate of the store build (C=FR, O=aprogsys, OU=FreeKC, CN=ImDoingTheRest), DER in Base64 */
    const val STORE_CERTIFICATE =
        "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"
  }
}
