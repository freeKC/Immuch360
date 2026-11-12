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

## Source (to settle before the Meta Horizon Store build)

The corresponding source of this libmpv is what the build scripts of libmpv-android-video-build `v1.1.7` fetch
(`buildscripts/`, each library at a pinned version or commit). The LGPL lets the source be offered through a third
party's server as long as the app's publisher makes sure it stays available. The computers do better: their libmpv
is built by github.com/immuch360/libmpv-builds, whose release carries the source tarball. The same for Android
(a `libmpv-android-*` release of libmpv-builds, built from the same scripts, with its `-sources.tar.xz`) is the step
to take before the quest build that carries libmpv goes to the Meta Horizon Store; until then the GitHub release of
the Quest APK points to media-kit's release.

## What it adds

About +12.84 MB to the arm64 Quest APK (the two libraries stored uncompressed, minSdk 26, with their alignment, the
classes and the compressed licence texts), +7.67 % on the 167,429,950 bytes of release 45's Quest APK: the one-time
threshold of `.github/desktop/check_apk_sizes.py` (key `v3.4.0-45`). Estimated without a build, from the archive.
