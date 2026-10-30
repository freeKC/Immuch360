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
| `meta-spatial-sdk-splat` (Gaussian splats of other tools, lot S5) | quest only (`questImplementation`) | `8b09c498e718a0e8532b593c34bfb4e86ff32a3ca33d340ab58b83506926dfdf` |

All five carry the same `LICENSE` (SHA-256 `bb9b12db3b92c024458df625acd6f2d8140ea805cc6814bac74613a466731368`) and the
same `notices.html` (SHA-256 `3c77d854f4771ed619a89f17cf6eb6e5f5d85e2d37f36de471bd3f9f9e40cf95`): the splat module
brings no new terms. The notices list the third party software of the native libraries of the SDK (Apache 2.0, BSD,
MIT, zlib, Boost, ISC, MPL 2.0 and the others it names, with their texts).

The app shows both on its licence page, under "Meta Spatial SDK" (`mobile/lib/utils/meta_spatial_licenses.dart`):
the licence from `mobile/assets/licenses/meta-spatial-sdk/LICENSE`, the notices from
`mobile/assets/licenses/meta-spatial-sdk/NOTICES.txt`, which `.github/desktop/meta_spatial_notices.py` writes from the
`notices.html` of an AAR (`--check` compares).
