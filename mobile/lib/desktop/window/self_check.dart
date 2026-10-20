// IMMUCH360_SELF_CHECK: what a CI runner checks in the release build of a computer where nobody clicks (the macOS job
// of .github/workflows/immuch360-desktop.yml). Set to the path of a file, it makes the app, after its first frame:
//   - save a secret with the secure storage as the app does, read it back and delete it; on macOS also with the
//     plugin's own default (the data protection keychain), for the record;
//   - once its first page shows, start a session without a server when none is open, as "Use without a server" does
//     but without the folder choice, so that the files and folders of the command line open as a user would see them,
//     and name the pages shown once they had the time to open (a folder: the page of the opened files; one video: the
//     viewer);
//   - say whether libmpv was loaded and, when IMMUCH360_SELF_CHECK_VIDEO names a video, play it for five seconds in a
//     player of its own, with the position, the decoder and the size mpv reports;
// then write what it found to the file, as JSON, and print it. Each result is also saved as soon as it is known, to
// the same path followed by .partial, so that a step that ends the app leaves the results of the steps before it.
// Nothing of it runs without the variable, which no start from the Finder, the Start menu or a desktop entry sets.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/repositories/secure_storage.repository.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:logging/logging.dart';

final _log = Logger('SelfCheck');

/// The two variables of the self check
abstract final class DesktopSelfCheck {
  static const reportVariable = 'IMMUCH360_SELF_CHECK';
  static const videoVariable = 'IMMUCH360_SELF_CHECK_VIDEO';

  /// Where the report goes, null when no self check was asked for
  static String? get reportPath => _nonEmpty(Platform.environment[reportVariable]);

  static String? get videoPath => _nonEmpty(Platform.environment[videoVariable]);

  /// Where the results go while the self check runs (the report file once it is complete)
  static String partialPath(String reportPath) => '$reportPath.partial';

  static String? _nonEmpty(String? value) => value == null || value.trim().isEmpty ? null : value;

  /// [app] as it is, or with the self check around it when the variable is set
  static Widget wrap(Widget app) {
    final report = reportPath;
    return report == null ? app : DesktopSelfCheckHost(reportPath: report, videoPath: videoPath, child: app);
  }
}

/// Runs the self check once, after the first frame of the app
class DesktopSelfCheckHost extends ConsumerStatefulWidget {
  const DesktopSelfCheckHost({
    super.key,
    required this.reportPath,
    this.videoPath,
    this.firstPageTimeout = const Duration(seconds: 60),
    this.openTimeout = const Duration(seconds: 15),
    this.playFor = const Duration(seconds: 5),
    required this.child,
  });

  final String reportPath;
  final String? videoPath;
  final Duration firstPageTimeout;
  final Duration openTimeout;
  final Duration playFor;
  final Widget child;

  @override
  ConsumerState<DesktopSelfCheckHost> createState() => _DesktopSelfCheckHostState();
}

class _DesktopSelfCheckHostState extends ConsumerState<DesktopSelfCheckHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  Future<void> _run() async {
    final report = <String, Object?>{'platform': Platform.operatingSystem, 'started': DateTime.now().toIso8601String()};
    Future<void> step(String name, Future<Object?> Function() run) async {
      report[name] = await run();
      await _save(report, partial: true);
    }

    try {
      // The keychain first: it waits for no page, and nothing the files of the command line open can stop it
      await step('secureStorage', _secureStorage);
      await step('firstPage', _firstPage);
      await step('session', _session);
      await step('pages', _pagesAfterOpen);
      await step('video', _video);
    } catch (error, stackTrace) {
      _log.severe('Self check stopped', error, stackTrace);
      report['error'] = '$error';
    }
    report['ended'] = DateTime.now().toIso8601String();
    // Printed for the log of the run, written for its checks
    debugPrint('Immuch360 self check: ${const JsonEncoder.withIndent('  ').convert(report)}');
    await _save(report, partial: false);
  }

  /// [report] to the report file, or to the same path followed by .partial while steps are left; the partial file goes
  /// once the report is complete
  Future<void> _save(Map<String, Object?> report, {required bool partial}) async {
    final partialFile = File(DesktopSelfCheck.partialPath(widget.reportPath));
    try {
      final text = const JsonEncoder.withIndent('  ').convert(report);
      await (partial ? partialFile : File(widget.reportPath)).writeAsString(text);
      if (!partial && partialFile.existsSync()) {
        await partialFile.delete();
      }
    } catch (error) {
      _log.severe('Could not write the self check to ${widget.reportPath}: $error');
    }
  }

  Future<Map<String, Object?>> _secureStorage() async => {
    'app': await secretRoundTrip(const SecureStorageRepository(SecureStorageRepository.storage)),
    // What flutter_secure_storage does by default on macOS, to see whether the data protection keychain would work
    if (CurrentPlatform.isMacOS)
      'dataProtectionKeychain': await secretRoundTrip(const SecureStorageRepository(FlutterSecureStorage())),
  };

  @override
  Widget build(BuildContext context) => widget.child;

  /// The name of the first page once the splash page has gone: welcome, login or timeline
  Future<String> _firstPage() async {
    final router = ref.read(appRouterProvider);
    final pages = {WelcomeRoute.name: 'welcome', LoginRoute.name: 'login', TabShellRoute.name: 'timeline'};
    final deadline = DateTime.now().add(widget.firstPageTimeout);
    while (DateTime.now().isBefore(deadline)) {
      for (final route in router.stackData.reversed) {
        final page = pages[route.name];
        if (page != null) {
          return page;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return 'none within ${widget.firstPageTimeout.inSeconds} s';
  }

  /// Starts a session without a server unless one is open, then shows the tabs, as the welcome page's first choice
  Future<String> _session() async {
    if (ref.read(authProvider).isAuthenticated) {
      return 'server';
    }
    if (ref.read(localSessionProvider)) {
      return 'without a server, already open';
    }
    await ref.read(localSessionProvider.notifier).enter();
    await ref.read(appRouterProvider).replaceAll([const TabShellRoute()]);
    return 'without a server, started';
  }

  /// The pages of the app, bottom first, once something was shown over the tabs or after [openTimeout]: what the files
  /// of the command line opened, if any
  Future<List<String>> _pagesAfterOpen() async {
    final router = ref.read(appRouterProvider);
    final deadline = DateTime.now().add(widget.openTimeout);
    while (DateTime.now().isBefore(deadline) && router.stackData.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    // The page that opened has its first frames meanwhile
    await Future<void>.delayed(const Duration(seconds: 2));
    return [for (final route in router.stackData) route.name];
  }

  Future<Map<String, Object?>> _video() async {
    final result = <String, Object?>{'bundled': desktopVideoBundled, 'loaded': desktopVideoAvailable};
    final path = widget.videoPath;
    if (!desktopVideoAvailable || path == null) {
      return result;
    }
    result.addAll(await playForAWhile(path, widget.playFor));
    return result;
  }
}

/// Saves a random secret under a key of its own through [secrets], reads it back and deletes it. ok: the value read
/// was the one written, and nothing was left. The error of the plugin otherwise (on macOS the keychain's OSStatus).
@visibleForTesting
Future<Map<String, Object?>> secretRoundTrip(SecureStorageRepository secrets, {Random? random}) async {
  final generator = random ?? Random.secure();
  final key = 'immuch360_self_check_${generator.nextInt(1 << 32).toRadixString(16)}';
  final value = base64Url.encode(List.generate(24, (_) => generator.nextInt(256)));
  final step = <String>['write'];
  try {
    await secrets.write(key, value);
    step.add('read');
    final read = await secrets.read(key);
    step.add('delete');
    await secrets.delete(key);
    step.add('read after delete');
    final left = await secrets.read(key);
    return {'ok': read == value && left == null, 'readBack': read == value, 'deleted': left == null};
  } catch (error) {
    return {'ok': false, 'failedAt': step.last, 'error': '$error'};
  }
}

/// Plays [path] in a player of its own, without a window, for [duration] from its first frame: how far it went and
/// what mpv decoded it with
Future<Map<String, Object?>> playForAWhile(String path, Duration duration) async {
  final result = <String, Object?>{'file': path};
  DesktopPlayer? player;
  try {
    final created = await DesktopPlayer.create(PlayerKind.playback);
    player = created;
    result['mpvVersion'] = await created.mpvProperty('mpv-version');
    result['ffmpegVersion'] = await created.mpvProperty('ffmpeg-version');
    final opened = Stopwatch()..start();
    final firstFrame = created.events.firstWhere((event) => event.kind != PlayerEventKind.loaded);
    // Its error, if the open fails first, is the one of the await below or none
    firstFrame.ignore();
    await created.setVolume(0);
    await created.open(path);
    await created.play();
    final event = await firstFrame.timeout(const Duration(seconds: 30));
    result['firstFrameMs'] = opened.elapsedMilliseconds;
    if (event.kind != PlayerEventKind.restarted) {
      result['error'] = event.toString();
      return result;
    }
    final from = created.position.value;
    await Future<void>.delayed(duration);
    final to = created.position.value;
    result['playedSeconds'] = (to - from).inMilliseconds / 1000;
    result['position'] = to.inMilliseconds / 1000;
    final size = created.videoSize.value;
    result['size'] = size == null ? null : '${size.width}x${size.height}';
    for (final name in ['hwdec-current', 'video-codec', 'frame-drop-count', 'decoder-frame-drop-count']) {
      result[name] = await created.mpvProperty(name);
    }
  } catch (error) {
    result['error'] = '$error';
  } finally {
    await player?.dispose();
  }
  return result;
}
