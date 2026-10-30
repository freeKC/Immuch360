# Meta Spatial SDK

The immersive viewer of the Meta Quest (`mobile/android/app/src/main/kotlin/app/alextran/immich/immersive/`) runs on
the Meta Spatial SDK 0.14.0, from Maven Central (`com.meta.spatial`), under the **Meta Platform Technologies SDK
License Agreement** (effective date 25 October 2022, https://developer.oculus.com/licenses/oculussdk/), the text of
`LICENSE.txt` here, byte for byte the `LICENSE` of each of its AARs.

| Module | In which APK | AAR SHA-256 |
| --- | --- | --- |
| `meta-spatial-sdk` | phone and quest | `1883e12ebc9a3680e4f2b559e1e958b231a2b7090ac9bb71e6255a1a14db4721` |
| `meta-spatial-sdk-toolkit` | phone and quest | `51aba04a07fe4ebf2338fa9650e2303062663ddc80934a5c416a96165f3869a7` |
| `meta-spatial-sdk-vr` | phone and quest | `ae4ed28b9676ccc384029296011876212cff069c477202ca396a39a79f50837a` |
| `meta-spatial-sdk-isdk` (through the toolkit) | phone and quest | `190a6205e00ae3f0a8a23892b00c895517b419e27c22401068abb989fa411445` |
| `meta-spatial-sdk-splat` (Gaussian splats of other tools, lot S5) | quest only (`questImplementation`), never started in the Horizon Store build | `8b09c498e718a0e8532b593c34bfb4e86ff32a3ca33d340ab58b83506926dfdf` |

All five carry the same `LICENSE` (SHA-256 `bb9b12db3b92c024458df625acd6f2d8140ea805cc6814bac74613a466731368`) and the
same `notices.html` (SHA-256 `3c77d854f4771ed619a89f17cf6eb6e5f5d85e2d37f36de471bd3f9f9e40cf95`). The notices list the
third party software of the native libraries of the SDK (Apache 2.0, BSD, MIT, zlib, Boost, ISC, MPL 2.0 and the others
it names, with their texts).

The app shows both on its licence page, under "Meta Spatial SDK" (`mobile/lib/utils/meta_spatial_licenses.dart`):
the licence from `mobile/assets/licenses/meta-spatial-sdk/LICENSE`, the notices from
`mobile/assets/licenses/meta-spatial-sdk/NOTICES.txt`, which `.github/desktop/meta_spatial_notices.py` writes from the
`notices.html` of an AAR (`--check` compares).

## Article 1.6 and the splat module

The text is the one the APK already ships, but one of its clauses applies to the splat module and to nothing else the
app uses: article 1.6, Experimental Features. Meta lists the splats under "Meta Spatial SDK > Experimental features"
(https://developers.meta.com/horizon/documentation/spatial-sdk/spatial-sdk-splats/), and the API of the module needs
the opt in `SpatialSDKExperimentalSplatAPI` (in `immersive/splat/SplatEngines.kt` of the quest flavour, the only
experimental API of the SDK in the app). Article 1.6 says (line 59 of `LICENSE.txt`):

> Experimental Features can only be used for experimental or testing purposes and cannot be incorporated into a
> production build unless (i) the Experimental Feature has been released or included in MPT software production builds
> or (ii) otherwise permitted by MPT in writing.

The quest APK goes out in two published builds: the releases on GitHub, and the Meta Horizon Store build, the same
APK re-signed with the key the store app is bound to. Three ways were open: (a) a written permission of Meta
(1.6 (ii)), (b) the splats kept to a test build installed by hand until Meta takes the API out of the experimental
features, or (c) 1.6 (i) taken as met because the module is published as 0.14.0 on Maven Central.

## Decision of 30 October 2026

FreeKC, the maintainer of Immuch360, decided on 30 October 2026 to ship the Gaussian splats in the GitHub builds of the
quest APK, labelled experimental, and to keep them out of the Meta Horizon Store build. His reasons: Immuch360 is a
free hobby app, with no sale, no advertising and no account to pay for, and he does not hold its GitHub builds for
production in the sense of article 1.6; and nothing in the app may ever put a fault of the splats on Meta. This is his
reading of the clause, not a permission of Meta, which has given none in writing; the clause itself makes no
difference between a free app and a paid one.

What goes with it:

1. **The words wherever the feature is named.** The subtitle of the Gaussian splats setting, the page of a splat, the
   notice of the first splat in the headset and the licence page of the app say: "Gaussian splats use an experimental
   API of the Meta Spatial SDK, which Meta neither supports nor warrants: any defect is Immuch360's own." (key
   `splat_disclaimer` of `i18n/en.json`, in the 88 other languages of the app).
2. **The Horizon Store build without the feature.** The store build is told from the GitHub builds by its signing
   certificates, which the app reads once at start (`immersive/splat/SplatBuild.kt`). Only the certificates it knows
   offer the splats: the GitHub builds, SHA-256 `aa7aab33987b1a02d3d2892e60038fb4d8ea8ea6b8aa968a570fcda7558367be`, and
   the debug key Android tools make on a developer's machine (subject C=US, O=Android, CN=Android Debug, or a debuggable
   build). The store key, SHA-256 `ecc6b085c727f003cd71ae45927be08800a7fd84b61a5a5634b3d3d70b4adb9b`, is looked for
   first: an APK that carries it is the store build, whatever else signs it. A certificate that cannot be read or that
   the app does not know counts as the store's. A new key of a rotation keeps the older certificate in the lineage the
   app reads, so it never moves an APK out of its build. With the store certificate the viewer never registers
   `SplatFeature`, the shares list no splat, the Add menu has no Open a splat file, the Advanced settings have no
   Gaussian splats switch, and the licence page lists the splat module as carried but never started. The bytes of the
   module stay in the store APK, which is the GitHub APK re-signed; nothing calls them. The one switch is the constant
   `SPLATS_IN_STORE_BUILD = false` of `SplatBuild.kt`, for FreeKC to flip once Meta permits the feature in writing or
   releases it out of its experimental features. `SplatBuildTest` checks the gate with both certificates, as their APKs
   carry them, with two debug keys and with keys it does not know.
3. **Large splats off by default.** A splat shows 50,000 gaussians at most; Large splats (150,000) is a setting the
   user turns on.
