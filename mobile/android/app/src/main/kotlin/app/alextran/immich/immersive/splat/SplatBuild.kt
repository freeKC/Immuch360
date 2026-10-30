package app.alextran.immich.immersive.splat

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import app.alextran.immich.immersive.TAG
import java.security.MessageDigest

/**
 * Whether this build of the app offers the Gaussian splats: FreeKC's decision of 30 October 2026 on article 1.6 of
 * the licence of the Meta Spatial SDK (licenses/meta-spatial-sdk/README.md, "Decision of 30 October 2026"). The splat
 * API of the SDK is one of its Experimental Features. The GitHub builds of Immuch360, a free hobby app, offer the
 * splats, labelled experimental, with the words that Meta neither supports nor warrants that API and that any defect is
 * Immuch360's own (splat_disclaimer); the build of the Meta Horizon Store hides them.
 *
 * The store build is the quest APK of a GitHub release re-signed with the key the store app is bound to: the same
 * bytes otherwise, so the app tells the two apart by its own signing certificate, read once per process. With the
 * store certificate the viewer never registers the splat module ([SplatGate.registers]), refuses a splat that would
 * reach it anyway ([SplatGate.viewerRefusal]), and the app (ImmersiveApi.splatsInThisBuild) shows no splat tile, no
 * Open a splat file, no Gaussian splats setting, and its licences page does not list the module as active. The module
 * stays in the APK, never started: the store APK is the GitHub one re-signed.
 *
 * The pure part is tested by SplatBuildTest with the certificates of both builds.
 */
internal object SplatBuild {
  /**
   * The one switch of the store build, flipped by FreeKC only: false, the store build hides the Gaussian splats; true,
   * it offers them as the GitHub builds do (once Meta permits the feature in writing, or releases it out of its
   * experimental features). The GitHub builds offer them whatever it says.
   */
  const val SPLATS_IN_STORE_BUILD = false

  /**
   * SHA-256 of the certificate of the key the Meta Horizon Store app is bound to (C=FR, O=aprogsys, OU=FreeKC,
   * CN=ImDoingTheRest), as `apksigner verify --print-certs` prints it for a store APK
   */
  const val STORE_CERTIFICATE_SHA256 = "ecc6b085c727f003cd71ae45927be08800a7fd84b61a5a5634b3d3d70b4adb9b"

  /** SHA-256 of the certificate of the GitHub release builds (C=FR, O=aprogsys, OU=FreeKC, CN=Immuch360) */
  const val GITHUB_CERTIFICATE_SHA256 = "aa7aab33987b1a02d3d2892e60038fb4d8ea8ea6b8aa968a570fcda7558367be"

  /** The SHA-256 of the DER bytes of a certificate, in lower case hexadecimal: the digest apksigner prints */
  fun sha256Hex(der: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(der).joinToString("") { "%02x".format(it.toInt() and 0xff) }

  /** Whether one of the signing [certificates] (SHA-256 digests, any case, colons or not) is the store's */
  fun isStoreBuild(certificates: Collection<String>): Boolean =
    certificates.any { it.replace(":", "").lowercase() == STORE_CERTIFICATE_SHA256 }

  /**
   * Whether a build signed with [certificates] offers the Gaussian splats: always, unless it is the store build, which
   * offers them only with [inStoreBuild]. Certificates that could not be read (null or none) hide them, so that no
   * failure ever shows the splats in the store build.
   */
  fun offersSplats(certificates: Collection<String>?, inStoreBuild: Boolean = SPLATS_IN_STORE_BUILD): Boolean =
    !certificates.isNullOrEmpty() && (inStoreBuild || !isStoreBuild(certificates))

  @Volatile private var offers: Boolean? = null

  /** [offersSplats] for this APK, its certificates read from PackageManager at the first call of the process */
  fun offersSplats(context: Context): Boolean =
    offers
      ?: offersSplats(signingCertificates(context)).also {
        offers = it
        Log.i(TAG, "Gaussian splats ${if (it) "offered" else "hidden"} in this build")
      }

  /** The SHA-256 digests of the certificates this APK is signed with, null when they cannot be read */
  @Suppress("DEPRECATION")
  private fun signingCertificates(context: Context): List<String>? =
    try {
      val manager = context.packageManager
      val name = context.packageName
      val signatures =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
          val info = manager.getPackageInfo(name, PackageManager.GET_SIGNING_CERTIFICATES).signingInfo
          when {
            info == null -> null
            info.hasMultipleSigners() -> info.apkContentsSigners
            else -> info.signingCertificateHistory
          }
        } else {
          manager.getPackageInfo(name, PackageManager.GET_SIGNATURES).signatures
        }
      signatures?.map { sha256Hex(it.toByteArray()) }
    } catch (e: Exception) {
      Log.w(TAG, "signing certificates not read: the Gaussian splats stay hidden", e)
      null
    }
}
