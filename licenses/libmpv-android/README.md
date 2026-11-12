# libmpv on Meta Quest (Android, quest flavour)

From release 46 the Meta Quest build plays with libmpv the Plex films the headset cannot decode (DTS, DivX 3, WMA,
WMV, MPEG-4 part 2 beyond its simple profile, 10 bit H.264), hardware video decoding kept (`hwdec=mediacodec-copy`),
FFmpeg in software for what the hardware refuses (`mobile/lib/domain/services/film_player/`, lot feat-plex-mpv-46,
FreeKC's decision of 11 November 2026). The phone, tablet and TV builds carry none of it in 46.

| Artefact | In which build | SHA-256 |
| --- | --- | --- |
| `default-arm64-v8a.jar` of https://github.com/media-kit/libmpv-android-video-build release `v1.1.7` (the archive `media_kit_libs_android_video` 1.3.8 downloads; its MD5 `83df25b61193af8fa815e373143ac9af`) | the quest APK only, downloaded and checked by `mobile/android/app/build.gradle` (`downloadQuestLibmpv`), unpacked as native libraries of the quest flavour | `4363dfa5d3d415b91c1f16f6fb90c3fe59a77dfd3f9b824d2b24b492d6b09df9` |

What the archive holds (read on 11 November 2026):

| File | Size | What |
| --- | --- | --- |
| `lib/arm64-v8a/libmpv.so` | 12,369,680 bytes | mpv 0.36 (git `78d43740f5`, `-Dgpl=false`) with FFmpeg 6.0 (libavcodec 60.3.100, `--disable-gpl --enable-version3`, `--enable-mediacodec --enable-jni`), dav1d, libass, FreeType, FriBidi, HarfBuzz, libxml2, Mbed TLS, zlib, built in; stripped, 16 KiB aligned |
| `lib/arm64-v8a/libmediakitandroidhelper.so` | 386,696 bytes | the JNI helper of media_kit (MIT): the Java VM for FFmpeg's MediaCodec decoders, global references of the output surfaces |

The FFmpeg inside decodes (its configure line, `--disable-decoders` then): H.264, HEVC, AV1 (and dav1d), VP8, VP9,
MPEG-1, MPEG-2, MPEG-4 part 2, MS-MPEG4 v1 to v3 (DivX 3), WMV 1 to 3, H.263, FLV, Theora, MJPEG; AAC, AC-3, E-AC-3,
DTS (dca), MP1 to MP3, FLAC, Opus, Vorbis, ALAC, ALS, APE, WavPack, WMA, PCM, TTA, TAK, RealAudio 1 and 2; the
subtitles SubRip, ASS and SSA, WebVTT, mov_text, DVD and DVB bitmaps. Not: TrueHD and MLP, VC-1, the PGS subtitles of
Blu-ray discs. The app knows this list (`film_decoders.dart`, `mpvFilmDecoders`): a TrueHD film goes to the Plex
server's conversion when it is allowed.

The Java code copied into `mobile/android/app/src/quest/java/com/alexmercerind/` (the texture output of
`media_kit_video` and the helper class of `media_kit_libs_android_video`, unchanged, MIT, media-kit commit
`c533e446755f51cf53c7e57aea873f2aa5355f81`, the commit `media_kit_360` is a fork of) is registered by
`MpvPlayers.kt` of `src/quest`; `src/phone` has an empty `MpvPlayers`.

## Licences

* mpv: LGPL 2.1 or later when built with `-Dgpl=false` (`mpv/Copyright`).
* FFmpeg built with `--enable-version3` and without `--enable-gpl`: LGPL version 3 or later, so libmpv.so is under
  the **LGPL version 3 or later** as a whole, a dynamic library the app loads (`System.loadLibrary`, `dlopen`), as on
  the computers.
* dav1d BSD 2-Clause, libass ISC, FreeType FTL, FriBidi LGPL 2.1 or later, HarfBuzz MIT ("Old MIT"), libxml2 MIT,
  Mbed TLS Apache 2.0, zlib zlib.
* media_kit (the Java copies, the helper library, and the Dart packages the app already takes from media_kit_360):
  MIT.

The texts ship in the quest APK as `mobile/assets/licenses/libmpv-android/` (an asset of the quest flavour only,
`pubspec.yaml`), and the licence page of the app shows them under "libmpv" there (`mobile/lib/utils/
mpv_android_licenses.dart`, registered in `main.dart`). The other builds do not ship libmpv and list nothing.

## Source

The corresponding source of this libmpv is on the release
[libmpv-android-20261112-1](https://github.com/immuch360/libmpv-builds/releases/tag/libmpv-android-20261112-1) of
github.com/immuch360/libmpv-builds (its `android/` folder, 12 November 2026):

* `libmpv-android-20261112-1-sources.tar.xz`: the recipe at `v1.1.7` (commit `fe8c3ac1a9`) with its three patches,
  and each library it builds into `libmpv.so` and the helper at the commit the recipe built (mpv `78d43740f5`, FFmpeg
  `n6.0`, Mbed TLS `v3.4.0`, dav1d `1.2.0`, libxml2 `v2.10.3`, FreeType `VER-2-13-0`, FriBidi `v1.0.12`, HarfBuzz
  `7.2.0`, libass `0.17.1`, media-kit-android-helper `42054e5d47`), with the script that rebuilds the jars from it.
  mpv and FFmpeg are also attached alone, the licence texts in `libmpv-android-20261112-1-licenses.tar.gz`.
* The same release re-hosts media-kit's four `default-<abi>.jar` and their debug symbols, the same bytes (the arm64 one
  has the SHA-256 above), so the binary and its source sit together under one tag. The Gradle task still downloads
  from media-kit's release; both serve the same file, checked by the same SHA-256.
* Checked in the files themselves before publishing: FFmpeg configured `--disable-gpl --disable-nonfree
  --enable-version3`, its six libraries reporting `LGPL version 3 or later`, mpv `-Dgpl=false`, no x264 or x265
  code; the recipe's GPL flavour (`encoders-gpl`, libx264) is not built. So the LGPL offer holds.

The licence page of the Quest build names that release (`mpvAndroidSourceRelease` in
`mobile/lib/utils/mpv_android_licenses.dart`).

## What it adds

About +12.84 MB to the arm64 Quest APK (the two libraries stored uncompressed, minSdk 26, with their alignment, the
classes and the compressed licence texts), +7.67 % on the 167,429,950 bytes of release 45's Quest APK: the one-time
threshold of `.github/desktop/check_apk_sizes.py` (key `v3.4.0-45`). Estimated without a build, from the archive.
