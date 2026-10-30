package app.alextran.immich.immersive.splat

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import app.alextran.immich.immersive.TAG
import java.io.ByteArrayInputStream
import java.security.MessageDigest
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.security.auth.x500.X500Principal

/**
 * Whether this build of the app offers the Gaussian splats: FreeKC's decision of 30 October 2026 on article 1.6 of
 * the licence of the Meta Spatial SDK (licenses/meta-spatial-sdk/README.md, "Decision of 30 October 2026"). The splat
 * API of the SDK is one of its Experimental Features. The GitHub builds of Immuch360, a free hobby app, offer the
 * splats, labelled experimental, with the words that Meta neither supports nor warrants that API and that any defect is
 * Immuch360's own (splat_disclaimer); the build of the Meta Horizon Store hides them.
 *
 * The store build is the quest APK of a GitHub release re-signed with the key the store app is bound to: the same
 * bytes otherwise, so the app tells the builds apart by its own signing certificates, read once per process. The gate
 * is a list of the certificates that offer the splats ([kindOf]): the GitHub one, and the debug key Android tools make
 * on a developer's machine; the store certificate follows [SPLATS_IN_STORE_BUILD], and so does any certificate the app
 * does not know or cannot read. Without the splats the viewer never registers the splat module ([SplatGate.registers]),
 * refuses a splat that would reach it anyway ([SplatGate.viewerRefusal]), and the app (ImmersiveApi.splatsInThisBuild)
 * shows no splat tile, no Open a splat file, no Gaussian splats setting, and its licences page does not list the module
 * as active. The module stays in the APK, never started: the store APK is the GitHub one re-signed.
 *
 * The pure part is tested by SplatBuildTest with the certificates of both builds and of two debug keys.
 */
internal object SplatBuild {
  /**
   * The one switch of the store build, flipped by FreeKC only: false, the store build hides the Gaussian splats; true,
   * it offers them as the GitHub builds do (once Meta permits the feature in writing, or releases it out of its
   * experimental features). The GitHub builds offer them whatever it says. A certificate the app does not know, or none
   * that could be read, follows it too.
   */
  const val SPLATS_IN_STORE_BUILD = false

  /**
   * SHA-256 of the certificate of the key the Meta Horizon Store app is bound to (C=FR, O=aprogsys, OU=FreeKC,
   * CN=ImDoingTheRest), as `apksigner verify --print-certs` prints it for a store APK
   */
  const val STORE_CERTIFICATE_SHA256 = "ecc6b085c727f003cd71ae45927be08800a7fd84b61a5a5634b3d3d70b4adb9b"

  /** SHA-256 of the certificate of the GitHub release builds (C=FR, O=aprogsys, OU=FreeKC, CN=Immuch360) */
  const val GITHUB_CERTIFICATE_SHA256 = "aa7aab33987b1a02d3d2892e60038fb4d8ea8ea6b8aa968a570fcda7558367be"

  /**
   * The subject of the debug key Android tools make for each machine (Android Studio, the Android Gradle plugin for
   * `flutter run`, and for a release build that build.gradle signs with the debug key when key.jks is missing), in both
   * orders of its names: the plugin writes C=US, O=Android, CN=Android Debug; keytool given the usual order writes the
   * other one.
   */
  private val ANDROID_DEBUG_SUBJECTS =
    setOf(X500Principal("C=US, O=Android, CN=Android Debug"), X500Principal("CN=Android Debug, O=Android, C=US"))

  /** Which build the signing certificates of an APK tell */
  enum class Kind {
    /** The store certificate is among them: [SPLATS_IN_STORE_BUILD] decides */
    STORE,
    /** The GitHub certificate is among them, the store one is not: offered */
    GITHUB,
    /** Neither, but an Android debug certificate is among them or the build is debuggable: offered */
    DEBUG,
    /** None the app knows, or none could be read: as the store build, [SPLATS_IN_STORE_BUILD] decides */
    UNKNOWN,
  }

  /** One certificate an APK is signed with, as the gate reads it: its SHA-256, and whether an Android debug key's */
  data class Signer(val sha256: String, val androidDebug: Boolean = false)

  /** The SHA-256 of the DER bytes of a certificate, in lower case hexadecimal: the digest apksigner prints */
  fun sha256Hex(der: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(der).joinToString("") { "%02x".format(it.toInt() and 0xff) }

  /** The [Signer] of a certificate in DER, as PackageManager hands it */
  fun signer(der: ByteArray): Signer = Signer(sha256Hex(der), isAndroidDebug(der))

  /** Whether the certificate [der] is an Android debug key's, by its subject; false for bytes of no certificate */
  fun isAndroidDebug(der: ByteArray): Boolean =
    try {
      val certificate = CertificateFactory.getInstance("X.509").generateCertificate(ByteArrayInputStream(der))
      (certificate as? X509Certificate)?.subjectX500Principal in ANDROID_DEBUG_SUBJECTS
    } catch (e: Exception) {
      false
    }

  /**
   * The build [signers] tell, checked in this order: the store certificate among them, then the GitHub one (a rotation
   * of either key keeps the older certificate in the lineage PackageManager hands, so a newer key alone never moves an
   * APK out of its build), then an Android debug certificate or a [debuggable] build. Digests in any case, with colons
   * or not, as keytool and apksigner write them.
   */
  fun kindOf(signers: Collection<Signer>?, debuggable: Boolean = false): Kind {
    if (signers.isNullOrEmpty()) return Kind.UNKNOWN
    val digests = signers.map { it.sha256.replace(":", "").lowercase() }
    return when {
      STORE_CERTIFICATE_SHA256 in digests -> Kind.STORE
      GITHUB_CERTIFICATE_SHA256 in digests -> Kind.GITHUB
      debuggable || signers.any { it.androidDebug } -> Kind.DEBUG
      else -> Kind.UNKNOWN
    }
  }

  /** Whether a build of [kind] offers the Gaussian splats: GitHub and debug builds do, the others by [inStoreBuild] */
  fun offersSplats(kind: Kind, inStoreBuild: Boolean = SPLATS_IN_STORE_BUILD): Boolean =
    when (kind) {
      Kind.GITHUB,
      Kind.DEBUG -> true
      Kind.STORE,
      Kind.UNKNOWN -> inStoreBuild
    }

  @Volatile private var offers: Boolean? = null

  /** [offersSplats] for this APK, its certificates read from PackageManager at the first call of the process */
  fun offersSplats(context: Context): Boolean =
    offers
      ?: run {
        val kind = kindOf(signingCertificates(context), isDebuggable(context))
        offersSplats(kind).also {
          offers = it
          val shown = if (it) "offered" else "hidden"
          Log.i(TAG, "Gaussian splats $shown in this build (${kind.name.lowercase()} certificate)")
        }
      }

  private fun isDebuggable(context: Context): Boolean =
    (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

  /** The certificates this APK is signed with, null when they cannot be read */
  @Suppress("DEPRECATION")
  private fun signingCertificates(context: Context): List<Signer>? =
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
      signatures?.map { signer(it.toByteArray()) }
    } catch (e: Exception) {
      Log.w(TAG, "signing certificates not read: the Gaussian splats follow the rule of the store build", e)
      null
    }
}
