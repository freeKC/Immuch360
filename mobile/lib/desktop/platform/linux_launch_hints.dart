// What a Linux computer needs told or set at launch (parity lot L11 of release 51), next to the dedicated graphics card
// a laptop with two is asked for by the desktop entry (PrefersNonDefaultGPU, .github/desktop/packaging/linux):
//
// - the splat viewer on an NVIDIA card: WebKitGTK's DMABUF renderer leaves the window blank with some NVIDIA drivers
//   (plan section 2.5 of the splat viewer). Where the NVIDIA driver runs (/proc/driver/nvidia/version), the launcher
//   of the app (linux/runner/launch_hints.cc) sets WEBKIT_DISABLE_DMABUF_RENDERER=1 first thing in main, before any
//   thread starts, unless the user set the variable already, behind a setting of "This computer", on by default. A
//   change of the setting counts from the next start;
// - Fedora's FFmpeg: ffmpeg-free, which Fedora's libmpv takes, has no decoder for most camera videos (H.264 Main and
//   High through OpenH264 only, which refuses them, no HEVC). When a film or a camera does not play on Fedora with
//   that FFmpeg, the app says, once a session, to install the FFmpeg of RPM Fusion. The packages are asked of rpm
//   once (libavcodec-free installed, neither RPM Fusion's libavcodec-freeworld nor its ffmpeg-libs).
//
// The setting is kept in desktop_linux.json in the app's support folder, as the network choice (network_choice.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_ui/immich_ui.dart' show scaffoldMessengerKey;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('LinuxLaunchHints');

/// The variable of WebKitGTK that turns its DMABUF renderer off
const webkitDmabufVariable = 'WEBKIT_DISABLE_DMABUF_RENDERER';

/// Whether the NVIDIA driver runs on this computer: its /proc entry is there
bool nvidiaDriverLoaded({String path = '/proc/driver/nvidia/version'}) => File(path).existsSync();

/// The setting "Splats on an NVIDIA card" and its file, read by the launcher at the start too (DmabufOffInSettings of
/// linux/runner/launch_hints.cc: the text {"webkitDmabufOff":false} keeps the renderer on)
abstract final class LinuxWebkitDmabuf {
  static const fileName = 'desktop_linux.json';
  static const _key = 'webkitDmabufOff';

  /// Where the file lives; a temporary folder in the tests
  @visibleForTesting
  static Future<Directory> Function() folder = getApplicationSupportDirectory;

  static Future<bool>? _loaded;

  /// Whether the app turns the DMABUF renderer off on an NVIDIA card: on by default, read from the file once
  static Future<bool> load() => _loaded ??= _read();

  /// Keeps [off] from now on and at the next starts
  static Future<void> save(bool off) async {
    _loaded = Future.value(off);
    try {
      final file = File(p.join((await folder()).path, fileName));
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode({_key: off}), flush: true);
      await temporary.rename(file.path);
    } catch (error) {
      _log.warning('The splat setting of NVIDIA cards is kept for this session only: $error');
    }
  }

  @visibleForTesting
  static void forget() => _loaded = null;

  static Future<bool> _read() async {
    try {
      final file = File(p.join((await folder()).path, fileName));
      if (!file.existsSync()) {
        return true;
      }
      final content = jsonDecode(await file.readAsString());
      final off = content is Map ? content[_key] : null;
      return off is bool ? off : true;
    } catch (error) {
      _log.warning('The splat setting of NVIDIA cards could not be read, on instead: $error');
      return true;
    }
  }
}

var _dmabufDecided = false;

/// Before the first web view of the app (the splat viewer): tells the log, once a session, what the launcher decided.
/// The launcher (linux/runner/launch_hints.cc) sets WEBKIT_DISABLE_DMABUF_RENDERER=1 first thing in main, before GTK
/// and any thread, on a computer with the NVIDIA driver, the setting on and no value of the user's: setenv is not safe
/// once other threads may read the environment, which they do here (the engine, GTK, mpv, Mesa). Returns whether the
/// variable is set. The arguments stand for this computer in the tests.
Future<bool> applyWebkitDmabufHint({
  bool? linux,
  bool Function()? nvidia,
  Map<String, String>? environment,
  Future<bool> Function()? settingOn,
}) async {
  if (_dmabufDecided || !(linux ?? Platform.isLinux)) {
    return false;
  }
  _dmabufDecided = true;
  final value = (environment ?? Platform.environment)[webkitDmabufVariable];
  if (value != null) {
    _log.info('$webkitDmabufVariable=$value for the splat viewer');
    return true;
  }
  if ((nvidia ?? nvidiaDriverLoaded)() && await (settingOn ?? LinuxWebkitDmabuf.load)()) {
    // Turned on in this session: the launcher sets it at the next start
    _log.info('NVIDIA driver: $webkitDmabufVariable=1 from the next start of the app');
  }
  return false;
}

@visibleForTesting
void forgetWebkitDmabufDecision() => _dmabufDecided = false;

/// Whether [osRelease], the text of /etc/os-release, is Fedora's or that of a distribution built on it
bool isFedoraLike(String osRelease) {
  for (final line in const LineSplitter().convert(osRelease)) {
    final at = line.indexOf('=');
    if (at < 0) {
      continue;
    }
    final key = line.substring(0, at).trim();
    final value = line.substring(at + 1).trim().replaceAll('"', '').replaceAll("'", '').toLowerCase();
    if ((key == 'ID' && value == 'fedora') || (key == 'ID_LIKE' && value.split(' ').contains('fedora'))) {
      return true;
    }
  }
  return false;
}

/// The packages rpm asked about: Fedora's FFmpeg libraries, and RPM Fusion's two replacements
const ffmpegPackages = ['libavcodec-free', 'libavcodec-freeworld', 'ffmpeg-libs'];

/// The packages of [ffmpegPackages] that [rpmOutput] (rpm -q --qf '%{NAME}\n' of them) says are installed
Set<String> installedFfmpegPackages(String rpmOutput) =>
    {for (final line in const LineSplitter().convert(rpmOutput)) line.trim()}.intersection(ffmpegPackages.toSet());

/// Whether the FFmpeg libraries of [installed] are Fedora's reduced ones only
bool onlyFfmpegFree(Set<String> installed) =>
    installed.contains('libavcodec-free') &&
    !installed.contains('libavcodec-freeworld') &&
    !installed.contains('ffmpeg-libs');

/// Runs a program and gives what it printed, null when it does not run
typedef RunProgram = Future<String?> Function(String program, List<String> arguments);

Future<String?> _run(String program, List<String> arguments) async {
  try {
    final result = await Process.run(program, arguments).timeout(const Duration(seconds: 10));
    return result.stdout as String;
  } catch (_) {
    return null;
  }
}

/// Whether this computer plays through Fedora's ffmpeg-free (see the top of this file)
Future<bool> usesFedoraFfmpegFree({bool? linux, String osReleasePath = '/etc/os-release', RunProgram? run}) async {
  if (!(linux ?? Platform.isLinux)) {
    return false;
  }
  try {
    if (!isFedoraLike(await File(osReleasePath).readAsString())) {
      return false;
    }
  } on FileSystemException {
    return false;
  }
  final output = await (run ?? _run)('rpm', ['-q', '--qf', r'%{NAME}\n', ...ffmpegPackages]);
  return output != null && onlyFfmpegFree(installedFfmpegPackages(output));
}

/// Tells, once a session, a user of Fedora's ffmpeg-free whose film or camera did not play to install the FFmpeg of
/// RPM Fusion
class FedoraFfmpegHint {
  FedoraFfmpegHint({Future<bool> Function()? detect, void Function(String text)? show})
    : _detect = detect ?? usesFedoraFfmpegFree,
      _show = show ?? _snackBar;

  /// The hint of the app
  static final instance = FedoraFfmpegHint();

  final Future<bool> Function() _detect;
  final void Function(String text) _show;
  Future<bool>? _applies;
  var _told = false;

  static void _snackBar(String text) => scaffoldMessengerKey.currentState?.showSnackBar(
    SnackBar(content: Text(text), duration: const Duration(seconds: 12), showCloseIcon: true),
  );

  /// A film or a camera did not play, or its video did not decode: the hint, once, where it applies
  Future<void> playbackFailed() async {
    if (_told) {
      return;
    }
    final applies = await (_applies ??= _detect().catchError((Object _) => false));
    if (!applies || _told) {
      return;
    }
    _told = true;
    _log.info("A video did not play with Fedora's ffmpeg-free: the FFmpeg of RPM Fusion is suggested");
    _show(StaticTranslations.instance.desktop_video_fedora_ffmpeg);
  }
}

/// The tile of "This computer" on Linux with the NVIDIA driver: the DMABUF renderer of the splat viewer
class LinuxNvidiaSplatTile extends StatefulWidget {
  const LinuxNvidiaSplatTile({super.key, this.shown});

  /// Whether the tile shows: on Linux with the NVIDIA driver; the tests set it
  final bool? shown;

  @override
  State<LinuxNvidiaSplatTile> createState() => _LinuxNvidiaSplatTileState();
}

class _LinuxNvidiaSplatTileState extends State<LinuxNvidiaSplatTile> {
  bool? _off;

  @override
  void initState() {
    super.initState();
    if (_shown) {
      unawaited(
        LinuxWebkitDmabuf.load().then((off) {
          if (mounted) {
            setState(() => _off = off);
          }
        }),
      );
    }
  }

  bool get _shown => widget.shown ?? (Platform.isLinux && nvidiaDriverLoaded());

  @override
  Widget build(BuildContext context) {
    final off = _off;
    if (!_shown || off == null) {
      return const SizedBox.shrink();
    }
    final t = context.t;
    return SwitchListTile(
      key: const Key('desktop_settings_nvidia_splats'),
      secondary: const Icon(Icons.view_in_ar_outlined),
      title: Text(t.desktop_linux_nvidia_splats_title),
      subtitle: Text(t.desktop_linux_nvidia_splats_subtitle),
      value: off,
      onChanged: (value) {
        setState(() => _off = value);
        unawaited(LinuxWebkitDmabuf.save(value));
      },
    );
  }
}
