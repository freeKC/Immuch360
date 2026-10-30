package app.alextran.immich.immersive.splat

import app.alextran.immich.immersive.splat.SplatBuild.Kind
import app.alextran.immich.immersive.splat.SplatBuild.Signer
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The gate of the build of the Gaussian splats (FreeKC's decision of 30 October 2026): a list of the certificates that
 * offer them. The GitHub builds and the debug builds of a developer's machine offer them; the build of the Meta Horizon
 * Store, the same APK re-signed with the key its store app is bound to, follows [SplatBuild.SPLATS_IN_STORE_BUILD]
 * (true: offered, false: hidden), and so does a certificate the app does not know or cannot read. The
 * two release certificates are those of the quest APK of release 35 (GitHub) and of the quest APK of release 32
 * re-signed for the store (builds/meta_sign_upload.sh), as their APK signature blocks carry them: what PackageManager
 * hands the app. The debug and lookalike certificates were made by keytool for these tests.
 */
class SplatBuildTest {
  private val github = decode(GITHUB_CERTIFICATE)
  private val store = decode(STORE_CERTIFICATE)
  private val debug = decode(DEBUG_CERTIFICATE)
  private val debugKeytool = decode(DEBUG_CERTIFICATE_KEYTOOL)
  private val lookalike = decode(LOOKALIKE_CERTIFICATE)

  /** A release key the app does not know, a newer key of a rotation for one */
  private val newKey = Signer("0".repeat(64))

  @Test
  fun `the SHA-256 of each certificate is the digest apksigner prints for its APK`() {
    assertEquals(SplatBuild.GITHUB_CERTIFICATE_SHA256, SplatBuild.sha256Hex(github))
    assertEquals(SplatBuild.STORE_CERTIFICATE_SHA256, SplatBuild.sha256Hex(store))
    assertTrue(SplatBuild.GITHUB_CERTIFICATE_SHA256.startsWith("aa7aab33987b1a02"))
    assertTrue(SplatBuild.STORE_CERTIFICATE_SHA256.startsWith("ecc6b085c727f003"))
  }

  @Test
  fun `the GitHub build offers the splats, whatever the switch`() {
    val kind = SplatBuild.kindOf(listOf(SplatBuild.signer(github)))
    assertEquals(Kind.GITHUB, kind)
    assertTrue(SplatBuild.offersSplats(kind, inStoreBuild = false))
    assertTrue(SplatBuild.offersSplats(kind, inStoreBuild = true))
  }

  @Test
  fun `the store build hides the splats while SPLATS_IN_STORE_BUILD is false`() {
    val kind = SplatBuild.kindOf(listOf(SplatBuild.signer(store)))
    assertEquals(Kind.STORE, kind)
    assertFalse(SplatBuild.offersSplats(kind, inStoreBuild = false))
    // Flipped (Meta's written permission, or the API out of its experimental features), the store build offers them
    assertTrue(SplatBuild.offersSplats(kind, inStoreBuild = true))
  }

  @Test
  fun `the switch is on in this source, and it is the default of the gate`() {
    // Turned off, the same change rewrites what says the store build offers the splats: point 2 and the table row of
    // licenses/meta-spatial-sdk/README.md, SPLAT_MODULE of publish_ai_components.py then MODEL-LICENSES.md, and the
    // comments of SplatBuild, SplatEngines (quest), immersive_api.dart, immersive.provider.dart and splat_gate.dart
    assertTrue(
      "SPLATS_IN_STORE_BUILD turned off: rewrite the licence note and the comments saying the store build offers them",
      SplatBuild.SPLATS_IN_STORE_BUILD,
    )
    assertTrue(SplatBuild.offersSplats(Kind.STORE))
    assertTrue(SplatBuild.offersSplats(Kind.UNKNOWN))
    assertTrue(SplatBuild.offersSplats(Kind.GITHUB))
    assertTrue(SplatBuild.offersSplats(Kind.DEBUG))
  }

  @Test
  fun `a release key the app does not know hides the splats, as the store build does`() {
    for (signers in listOf(listOf(newKey), listOf(SplatBuild.signer(lookalike)))) {
      val kind = SplatBuild.kindOf(signers)
      assertEquals(Kind.UNKNOWN, kind)
      assertFalse(SplatBuild.offersSplats(kind, inStoreBuild = false))
      assertTrue(SplatBuild.offersSplats(kind, inStoreBuild = true))
    }
  }

  @Test
  fun `a build signed with an Android debug key offers the splats, its subject in either order`() {
    assertTrue(SplatBuild.isAndroidDebug(debug))
    assertTrue(SplatBuild.isAndroidDebug(debugKeytool))
    assertFalse(SplatBuild.isAndroidDebug(github))
    assertFalse(SplatBuild.isAndroidDebug(store))
    assertFalse(SplatBuild.isAndroidDebug(lookalike))
    assertFalse(SplatBuild.isAndroidDebug(byteArrayOf(0x30, 0x03, 0x02, 0x01)))
    assertFalse(SplatBuild.isAndroidDebug(ByteArray(0)))
    for (der in listOf(debug, debugKeytool)) {
      val kind = SplatBuild.kindOf(listOf(SplatBuild.signer(der)))
      assertEquals(Kind.DEBUG, kind)
      assertTrue(SplatBuild.offersSplats(kind, inStoreBuild = false))
    }
  }

  @Test
  fun `a debuggable build offers the splats whatever its key, unless it carries the store certificate`() {
    assertEquals(Kind.DEBUG, SplatBuild.kindOf(listOf(newKey), debuggable = true))
    assertTrue(SplatBuild.offersSplats(SplatBuild.kindOf(listOf(newKey), debuggable = true), inStoreBuild = false))
    assertEquals(Kind.STORE, SplatBuild.kindOf(listOf(SplatBuild.signer(store)), debuggable = true))
    assertEquals(Kind.GITHUB, SplatBuild.kindOf(listOf(SplatBuild.signer(github)), debuggable = true))
  }

  @Test
  fun `in a lineage or among several signers the store certificate wins, then the GitHub one`() {
    // A rotation of the GitHub key: the older certificate stays in signingCertificateHistory, the build stays GitHub's
    assertEquals(Kind.GITHUB, SplatBuild.kindOf(listOf(SplatBuild.signer(github), newKey)))
    assertEquals(Kind.GITHUB, SplatBuild.kindOf(listOf(newKey, SplatBuild.signer(github))))
    // A rotation of the store key, or the store certificate beside any other: the store build
    assertEquals(Kind.STORE, SplatBuild.kindOf(listOf(SplatBuild.signer(store), newKey)))
    assertEquals(Kind.STORE, SplatBuild.kindOf(listOf(SplatBuild.signer(github), SplatBuild.signer(store))))
    assertEquals(Kind.STORE, SplatBuild.kindOf(listOf(SplatBuild.signer(debug), SplatBuild.signer(store))))
    // A debug key beside the GitHub one is the GitHub build, and beside an unknown key a debug build
    assertEquals(Kind.GITHUB, SplatBuild.kindOf(listOf(SplatBuild.signer(debug), SplatBuild.signer(github))))
    assertEquals(Kind.DEBUG, SplatBuild.kindOf(listOf(newKey, SplatBuild.signer(debug))))
    assertFalse(
      SplatBuild.offersSplats(
        SplatBuild.kindOf(listOf(SplatBuild.signer(github), SplatBuild.signer(store))),
        inStoreBuild = false,
      )
    )
  }

  @Test
  fun `the digest is compared whatever its case and its colons, as keytool and apksigner write it`() {
    val keytool = SplatBuild.STORE_CERTIFICATE_SHA256.uppercase().chunked(2).joinToString(":")
    assertEquals(Kind.STORE, SplatBuild.kindOf(listOf(Signer(keytool))))
    val githubKeytool = SplatBuild.GITHUB_CERTIFICATE_SHA256.uppercase().chunked(2).joinToString(":")
    assertEquals(Kind.GITHUB, SplatBuild.kindOf(listOf(Signer(githubKeytool))))
  }

  @Test
  fun `certificates that could not be read count as the store's`() {
    assertEquals(Kind.UNKNOWN, SplatBuild.kindOf(null))
    assertEquals(Kind.UNKNOWN, SplatBuild.kindOf(emptyList(), debuggable = true))
    assertFalse(SplatBuild.offersSplats(SplatBuild.kindOf(null), inStoreBuild = false))
    assertFalse(SplatBuild.offersSplats(SplatBuild.kindOf(emptyList()), inStoreBuild = false))
  }

  private companion object {
    fun decode(base64: String): ByteArray = Base64.getDecoder().decode(base64)

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

    /** A debug key as the Android Gradle plugin makes it (C=US, O=Android, CN=Android Debug), DER in Base64 */
    const val DEBUG_CERTIFICATE =
        "MIIBhzCCAS2gAwIBAgIIE9v2FYk5wZMwCgYIKoZIzj0EAwIwNzEWMBQGA1UEAxMNQW5kcm9pZCBEZWJ1ZzEQMA4GA1UEChMHQW5k" +
        "cm9pZDELMAkGA1UEBhMCVVMwIBcNMjYxMDMwMjAyMzM5WhgPMjA1NjEwMjIyMDIzMzlaMDcxFjAUBgNVBAMTDUFuZHJvaWQgRGVi" +
        "dWcxEDAOBgNVBAoTB0FuZHJvaWQxCzAJBgNVBAYTAlVTMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEaLKRMcoms1PnLrlZqRBM" +
        "EUXZozVCvlqh4ofqxKpsYsyg0Oh23EUyNFlkQnniQwxiojB5pkNp/8NmfvwBRTNTjKMhMB8wHQYDVR0OBBYEFIKtPWXMmoVN+tqz" +
        "4DTAjvbYLi/0MAoGCCqGSM49BAMCA0gAMEUCIHYNZQrfdXbr+0moHBhYljBA/h7EA2KKuMOrpuuMU37LAiEA0hpOR3I1fCORFWOu" +
        "jSQLmwLj36Pcj20HBVGt5aWlaLg="

    /** A debug key made by keytool with the names the other way round (CN=Android Debug, O=Android, C=US) */
    const val DEBUG_CERTIFICATE_KEYTOOL =
        "MIIBiDCCAS2gAwIBAgIIFuw2FsRTdxYwCgYIKoZIzj0EAwIwNzELMAkGA1UEBhMCVVMxEDAOBgNVBAoTB0FuZHJvaWQxFjAUBgNV" +
        "BAMTDUFuZHJvaWQgRGVidWcwIBcNMjYxMDMwMjAyMzQwWhgPMjA1NjEwMjIyMDIzNDBaMDcxCzAJBgNVBAYTAlVTMRAwDgYDVQQK" +
        "EwdBbmRyb2lkMRYwFAYDVQQDEw1BbmRyb2lkIERlYnVnMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEJ/hBXvR9rg41l8J8BaDD" +
        "Azc+VuQbs1o6iVZQkG7djm1uirgrhXUn3pkN4VUTKc5kiKHLkb+WhKXwdxa3GcXPRKMhMB8wHQYDVR0OBBYEFNGPNDJAu9S2rUdI" +
        "pZqSgqya2UfhMAoGCCqGSM49BAMCA0kAMEYCIQCRDsiSwuCswHrrRPtK6yA3KCZvgj5P/rbZ27T6WdlMvwIhALEZr5cZ72VZzXB/" +
        "GI+haBfYmSOm8LZkEiiHzP7czdO3"

    /** A release key of someone else whose common name says Android Debug (C=US, O=Example, CN=Android Debug) */
    const val LOOKALIKE_CERTIFICATE =
        "MIIBhzCCAS2gAwIBAgIINVsyZ+tibPswCgYIKoZIzj0EAwIwNzEWMBQGA1UEAxMNQW5kcm9pZCBEZWJ1ZzEQMA4GA1UEChMHRXhh" +
        "bXBsZTELMAkGA1UEBhMCVVMwIBcNMjYxMDMwMjAyNDU0WhgPMjA1NjEwMjIyMDI0NTRaMDcxFjAUBgNVBAMTDUFuZHJvaWQgRGVi" +
        "dWcxEDAOBgNVBAoTB0V4YW1wbGUxCzAJBgNVBAYTAlVTMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEVCkmfiJqlQpLhIRXK4kp" +
        "ox2RwqKLZgxZNhqn0eK9QhoEk+CGhxnBrpadcrZhS7sl8D1YoAU6HBFTrTGIV8yp06MhMB8wHQYDVR0OBBYEFN88rN4mxacWLg9r" +
        "UNd6n3uJJzcFMAoGCCqGSM49BAMCA0gAMEUCIQCLRYjYQSMuL9UMyRHy1bq/6AqSqgl5IhoGkLtj4hpb3QIgQqX1twDJDWBrrE57" +
        "lywdhyFYMFHURqfdjT9q/4yqYnE="
  }
}
