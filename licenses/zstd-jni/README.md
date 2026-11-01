# zstd-jni

The Gaussian splats saved in SPZ version 4 hold their arrays in ZSTD streams. The version for Meta Quest reads them
with zstd-jni and writes the splat again as SPZ version 2, the only version the splat module of the Meta Spatial SDK
reads (`mobile/android/app/src/quest/kotlin/app/alextran/immich/immersive/splat/SplatZstds.kt`, behind
`SplatZstd` of `src/main`, FreeKC's report of 1 November 2026).

| Artefact (Maven Central) | In which build | SHA-1 | SHA-256 |
| --- | --- | --- | --- |
| `com.github.luben:zstd-jni:1.5.7-3@aar` | the quest APK only (`questImplementation`) | `e9b4897daedecb85c713afa842a24ef4fcc6cfa8` | `85c13f90649746aaa622ee2bd67ec142bfbb61cae296c584a98c787834eb26cf` |
| `com.github.luben:zstd-jni:1.5.7-3` (jar) | the unit tests on the JVM only (`testImplementation`) | `dc55c256583fb810f9fe3ede271843b68132fb7c` | `a38a4a97f1b43b878c91e0dd7f1e3d17f0e70beec71d95bacaf56a2f207624a3` |

## Licences

* zstd-jni, Copyright (c) 2015-present Luben Karavelov: **BSD 2-Clause** (`LICENSE` of
  https://github.com/luben/zstd-jni at tag `v1.5.7-3`, and the `<licenses>` of its POM).
* zstd 1.5.7, built into the native library of zstd-jni, Copyright (c) Meta Platforms, Inc. and affiliates: dual
  licensed under **BSD** or GPLv2 (https://github.com/facebook/zstd, `LICENSE` and `COPYING`). Immuch360 takes it
  under its BSD licence; nothing of the GPLv2 applies.

Both texts ship in the quest APK as `mobile/assets/licenses/zstd-jni/LICENSE` (an asset of the quest flavour only,
`pubspec.yaml`), and the licence page of the app shows them under "zstd-jni" there
(`mobile/lib/utils/zstd_licenses.dart`, registered in `main.dart`, tested by `test/utils/zstd_licenses_test.dart`).
The other builds do not ship zstd-jni and list nothing.

## What it adds

The arm64 native library, `libzstd-jni-1.5.7-3.so`, 603,960 bytes, stored uncompressed in the arm64 only quest APK
(minSdk 26), and about 58 KB of classes, kept whole by R8 (`proguard-quest.pro`: the native code reads the fields of
its streams by name). Build 39's quest APK is 159,135,347 bytes: about +0.38 %, under the 1 % of
`check_apk_sizes.py`. The phone APKs do not change.

## Why this library

The pure Java decoders of aircompressor (0.27, 2.0.3, and the copy of Vespa), Apache 2.0, decode the files on the JVM
but stop on Android at their first stream: they read `sun.misc.Unsafe.ARRAY_BYTE_BASE_OFFSET`, which the `Unsafe` of
Android does not have (exploration of 1 November 2026, on the Android 16 emulator). zstd-jni decoded the same files
there, with the digests of the Python module zstandard.
