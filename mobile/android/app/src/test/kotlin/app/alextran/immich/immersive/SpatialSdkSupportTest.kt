package app.alextran.immich.immersive

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Android versions whose libc has every symbol of libMetaSpatialSDK.so, and the openers of the Spatial SDK
 * activities that ask it first. On a Quest 2 left on Horizon OS v74 (Android 12L, API 32) the immersive viewer of
 * release 45 ended the app at its first opening: "dlopen failed: cannot locate symbol "backtrace" referenced by
 * libMetaSpatialSDK.so" in VrActivity.loadLibrary (Meta signature 934bfc, 4 crashes of one user, build 3030043).
 */
class SpatialSdkSupportTest {
  @Test
  fun `the Spatial SDK loads from Android 13 on, where bionic has backtrace`() {
    assertFalse(SpatialSdkSupport.loads(29))
    assertFalse(SpatialSdkSupport.loads(32))
    assertTrue(SpatialSdkSupport.loads(33))
    assertTrue(SpatialSdkSupport.loads(34))
    assertTrue(SpatialSdkSupport.loads(36))
  }

  @Test
  fun `the bound was read on the library of the SDK version the app ships`() {
    // backtrace@LIBC_T is the newest libc symbol of libMetaSpatialSDK.so 0.14.0 (readelf --dyn-syms of the APK of
    // release 50). Another version of the SDK may need another Android: read its library again, then move both.
    val catalogue = findFile("gradle/libs.versions.toml").readText()
    assertEquals(
      SpatialSdkSupport.SDK_VERSION_CHECKED,
      Regex("""(?m)^spatial-sdk\s*=\s*"([^"]+)"""").find(catalogue)?.groupValues?.get(1),
    )
  }

  @Test
  fun `the immersive viewer and the flight view are opened only where the SDK loads`() {
    val api = findFile("app/src/main/kotlin/app/alextran/immich/immersive/ImmersiveApiImpl.kt").readText()
    val openBody = api.substringAfter("override fun open(").substringBefore("ImmersiveViewerActivity.intent(")
    assertTrue("open() must refuse before the activity starts", openBody.contains("SpatialSdkSupport.here"))

    val dji = findFile("app/src/main/kotlin/app/alextran/immich/djilink/DjiLinkController.kt").readText()
    val flightBody = dji.substringAfter("fun openFlightView(").substringBefore("DjiFlightViewActivity.intent(")
    assertTrue("openFlightView() must refuse before the activity starts", flightBody.contains("SpatialSdkSupport.here"))
  }

  private fun findFile(path: String): File {
    var dir: File? = File(requireNotNull(System.getProperty("user.dir"))).absoluteFile
    while (dir != null) {
      for (prefix in listOf("", "../", "android/", "mobile/android/")) {
        val candidate = File(dir, prefix + path)
        if (candidate.isFile) return candidate
      }
      dir = dir.parentFile
    }
    error("$path not found")
  }
}
