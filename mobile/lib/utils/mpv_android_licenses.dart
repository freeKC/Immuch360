import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/utils/debug_print.dart';

/// The licence texts of libmpv on the Meta Quest (release 46: the films the headset cannot decode), an asset of the
/// quest flavour only (pubspec.yaml), see licenses/libmpv-android/README.md of the repository
const mpvAndroidLicenseFolder = 'assets/licenses/libmpv-android';

/// The files of [mpvAndroidLicenseFolder], each under its own heading, in this order
const mpvAndroidLicenseFiles = [
  ('LGPL-3.0.txt', 'GNU Lesser General Public License, version 3'),
  ('GPL-3.0.txt', 'GNU General Public License, version 3'),
  ('mpv-Copyright.txt', 'mpv'),
  ('mpv-LICENSE.LGPL.txt', 'mpv: LGPL'),
  ('ffmpeg-LICENSE.md.txt', 'FFmpeg'),
  ('dav1d-COPYING.txt', 'dav1d'),
  ('libass-COPYING.txt', 'libass'),
  ('freetype-FTL.txt', 'FreeType'),
  ('fribidi-COPYING.txt', 'FriBidi'),
  ('harfbuzz-COPYING.txt', 'HarfBuzz'),
  ('libxml2-Copyright.txt', 'libxml2'),
  ('mbedtls-LICENSE.txt', 'Mbed TLS'),
  ('Apache-2.0.txt', 'Apache License 2.0'),
  ('media_kit-LICENSE.txt', 'media_kit (media_kit_video and media_kit_libs_android_video)'),
];

/// What the licence page says before the texts
const mpvAndroidLicenseHeader =
    'libmpv, which plays on Meta Quest the films the headset cannot decode: mpv 0.36 (git 78d43740f5) and FFmpeg 6.0 '
    '(libavcodec 60.3.100), with dav1d, libass, FreeType, FriBidi, HarfBuzz, libxml2 and Mbed TLS built in, as built '
    'by https://github.com/media-kit/libmpv-android-video-build release v1.1.7 (default-arm64-v8a.jar), a dynamic '
    'library (libmpv.so) under the GNU Lesser General Public License version 3 or later as a whole (mpv built with '
    '-Dgpl=false, FFmpeg with --disable-gpl --enable-version3). Source: the build scripts of that release name the '
    'source of each library. With the Java and Dart '
    'code of media_kit (MIT).';

/// The entry of the licence page for libmpv, under "libmpv". Only the APK of the quest flavour ships it
/// (android/app/build.gradle), so the other builds list nothing; a build without the assets lists nothing rather than
/// failing the page
Stream<LicenseEntry> mpvAndroidLicenses({String? flavor = appFlavor, AssetBundle? bundle}) async* {
  if (flavor != kQuestFlavor) {
    return;
  }
  try {
    final assets = bundle ?? rootBundle;
    final parts = <String>[mpvAndroidLicenseHeader];
    for (final (file, title) in mpvAndroidLicenseFiles) {
      final text = await assets.loadString('$mpvAndroidLicenseFolder/$file');
      parts.add('$title\n\n${text.replaceAll('\r\n', '\n')}');
    }
    yield LicenseEntryWithLineBreaks(const ['libmpv'], parts.join('\n\n'));
  } catch (error) {
    dPrint(() => 'libmpv licence texts: $error');
  }
}
