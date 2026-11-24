import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// The Linux systems whose package of libmpv the placeholder names: Arch Linux and the systems built on it (the mpv
/// package, through pacman), openSUSE (libmpv2, through zypper), and the others (the text of Debian, Ubuntu and
/// Fedora). The AppImage, from desktop build 32, runs on all of them and takes the system's libmpv
enum LibmpvFamily { arch, suse, other }

/// The family of [osRelease], the text of /etc/os-release, by its ID and ID_LIKE
LibmpvFamily libmpvFamilyOf(String osRelease) {
  final ids = <String>{};
  for (final line in const LineSplitter().convert(osRelease)) {
    final at = line.indexOf('=');
    if (at < 0) {
      continue;
    }
    final key = line.substring(0, at).trim();
    if (key == 'ID' || key == 'ID_LIKE') {
      ids.addAll(line.substring(at + 1).replaceAll('"', '').replaceAll("'", '').toLowerCase().split(' '));
    }
  }
  if (ids.contains('arch')) {
    return LibmpvFamily.arch;
  }
  if (ids.contains('suse') || ids.contains('opensuse') || ids.any((id) => id.startsWith('opensuse-'))) {
    return LibmpvFamily.suse;
  }
  return LibmpvFamily.other;
}

/// The text of /etc/os-release, '' when it cannot be read; replaced by the tests
@visibleForTesting
String Function() readOsRelease = () {
  try {
    return File('/etc/os-release').readAsStringSync();
  } catch (_) {
    return '';
  }
};

LibmpvFamily? _family;

/// The family of this computer, read once
LibmpvFamily get libmpvFamily => _family ??= libmpvFamilyOf(readOsRelease());

@visibleForTesting
void forgetLibmpvFamily() => _family = null;

/// Stands where the native video player of the phones would be when this computer has no libmpv: the poster or the
/// thumbnail stays visible behind it, with a line saying that playback comes later (macOS), or on Linux which package
/// brings the library, named for the system (the .deb and the .rpm depend on it; the AppImage and a bundle copied by
/// hand take the system's)
class DesktopVideoPlaceholder extends StatelessWidget {
  const DesktopVideoPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.all(Radius.circular(12))),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.movie_outlined, color: Colors.white70),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                CurrentPlatform.isLinux ? _linuxText(context) : context.t.desktop_video_later,
                style: context.textTheme.bodyMedium?.copyWith(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _linuxText(BuildContext context) => switch (libmpvFamily) {
    LibmpvFamily.arch => context.t.desktop_video_needs_libmpv_arch,
    LibmpvFamily.suse => context.t.desktop_video_needs_libmpv_suse,
    LibmpvFamily.other => context.t.desktop_video_needs_libmpv,
  };
}
