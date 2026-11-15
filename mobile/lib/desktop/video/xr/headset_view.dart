// "View in headset" of Immuch360 Desktop (store/m2/release-48/pc-vr-v1-plan.md, section 3): a video of any player of
// the window shown in a PC VR headset through the active OpenXR runtime (SteamVR, Meta Horizon Link, Virtual
// Desktop, Pico Connect), by the headset view of media_kit_360 (package:media_kit_video/xr.dart, IMMUCH360-NOTE.md
// patch 15). A 360 or 180 video goes around the head, a flat 2D or 3D film on a screen ahead. Windows only, in a build
// with the plugin's option. Experimental: not yet tried in a headset by the project.
//
// This file holds what the service (headset_view_service.dart), the button, the strip and the setting share:
// - the settings of desktop_xr.json in the support folder: the switch (on by default, the lab rule of 25 October
//   2026), matching the refresh rate, pausing when the headset is taken off, and the crash guard's marker and count;
// - the folder of the headset logs (headset/ of the support folder, one file per view, the 20 newest kept);
// - the calls of the plugin behind an interface the tests replace (HeadsetApi);
// - what a player page gives the service (HeadsetTarget): its player, the layouts it offers, its title for the strip,
//   play or pause and seek through the page's own controls, and what the strip shows of its playback;
// - the label of the log, which says only the kind of video: never a URL, a path, a token or a title;
// - the texts of the stop reasons and notices.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/domain/models/flat_stereo.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit_video/sphere.dart';
import 'package:media_kit_video/xr.dart';
import 'package:native_video_player/native_video_player.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The app's log of the headset view: each start and end with its reason and the name of its log file, so that the
/// export of the Logs page carries them
final headsetViewLog = Logger('HeadsetView');

/// The commit of media_kit_360 that mobile/pubspec.yaml pins, for the first lines of the headset log: the plugin
/// knows its own only when it was built from a git checkout (a test checks both stay the same)
const headsetPluginCommit = '4ce1ebad9e56a814b5f46920957fef624e4d529f';

/// What the crash guard found at the app's start
enum HeadsetCrashCheck {
  /// No view was running when the app last ended
  none,

  /// A view was running when the app last ended: once
  once,

  /// Twice in a row: the switch was turned off
  turnedOff,
}

/// The settings of the headset view, in desktop_xr.json of the support folder, written as the other desktop settings
/// files are (a whole new file renamed over the old one)
class HeadsetViewSettings {
  HeadsetViewSettings({Future<Directory> Function()? folder}) : _folder = folder ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _folder;

  /// The switch of Settings, Asset Viewer, Videos: on by default
  final enabled = ValueNotifier<bool>(true);

  /// Ask the runtime for a refresh rate that is a multiple of the video's frame rate
  final matchRefreshRate = ValueNotifier<bool>(true);

  /// Pause the video when the headset is taken off (never resumed by itself)
  final pauseWhenTakenOff = ValueNotifier<bool>(true);

  /// The crash guard: a view runs (written before its start, cleared at every end), and the views in a row that were
  /// still running when the app ended
  bool _running = false;
  int _crashes = 0;
  Future<void>? _loaded;
  Future<void> _writing = Future.value();

  static const fileName = 'desktop_xr.json';

  /// The folder of the headset logs in the support folder, and how many files it keeps
  static const logFolderName = 'headset';
  static const keptLogs = 20;

  /// The views in a row that took the app down, read for the tests
  @visibleForTesting
  int get crashes => _crashes;
  @visibleForTesting
  bool get runningMarker => _running;

  Future<void> load() => _loaded ??= _read();

  Future<void> _read() async {
    try {
      final file = File(p.join((await _folder()).path, fileName));
      if (!file.existsSync()) {
        return;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return;
      }
      // The probe's file of 14 November 2026 held {"probe": false} only: the feature's own switch starts on
      if (decoded['enabled'] case final bool value) {
        enabled.value = value;
      }
      if (decoded['matchRefreshRate'] case final bool value) {
        matchRefreshRate.value = value;
      }
      if (decoded['pauseWhenTakenOff'] case final bool value) {
        pauseWhenTakenOff.value = value;
      }
      _running = decoded['running'] == true;
      _crashes = decoded['crashes'] is int ? decoded['crashes'] as int : 0;
    } catch (error) {
      headsetViewLog.warning('$fileName could not be read: $error');
    }
  }

  Future<void> _write() {
    final content = jsonEncode({
      'enabled': enabled.value,
      'matchRefreshRate': matchRefreshRate.value,
      'pauseWhenTakenOff': pauseWhenTakenOff.value,
      'running': _running,
      'crashes': _crashes,
    });
    // One write after the other: the last state asked is the one on the disk
    return _writing = _writing.then((_) async {
      try {
        final folder = await _folder();
        await folder.create(recursive: true);
        final file = File(p.join(folder.path, fileName));
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(content, flush: true);
        await temporary.rename(file.path);
      } catch (error) {
        headsetViewLog.warning('$fileName could not be written: $error');
      }
    });
  }

  Future<void> setEnabled(bool value) async {
    await load();
    enabled.value = value;
    if (value) {
      // Turned on again by hand: the guard counts afresh
      _crashes = 0;
    }
    await _write();
  }

  Future<void> setMatchRefreshRate(bool value) async {
    await load();
    matchRefreshRate.value = value;
    await _write();
  }

  Future<void> setPauseWhenTakenOff(bool value) async {
    await load();
    pauseWhenTakenOff.value = value;
    await _write();
  }

  /// At the app's start: a marker left means the last view was running when the app ended, so it took the app down.
  /// Twice in a row turns the switch off.
  Future<HeadsetCrashCheck> checkCrashMarker() async {
    await load();
    if (!_running) {
      return HeadsetCrashCheck.none;
    }
    _running = false;
    _crashes++;
    var check = HeadsetCrashCheck.once;
    if (_crashes >= 2) {
      enabled.value = false;
      _crashes = 0;
      check = HeadsetCrashCheck.turnedOff;
    }
    await _write();
    return check;
  }

  /// Before a start
  Future<void> markRunning() async {
    await load();
    _running = true;
    await _write();
  }

  /// At every end of a view; [good] (the view ran in the headset and ended without taking the app down) resets the
  /// count of the guard
  Future<void> clearRunning({required bool good}) async {
    await load();
    if (!_running && !(good && _crashes > 0)) {
      return;
    }
    _running = false;
    if (good) {
      _crashes = 0;
    }
    await _write();
  }

  /// The folder of the headset logs, made when missing
  Future<Directory> logFolder() async {
    final folder = Directory(p.join((await _folder()).path, logFolderName));
    await folder.create(recursive: true);
    return folder;
  }

  /// The log file of a new view, `headset/headset-YYYYMMDD-HHMMSS.log`; the older files beyond the [keptLogs] newest
  /// are deleted, this one counted
  Future<String> newLogPath({DateTime? now}) async {
    final at = now ?? DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp = '${at.year}${two(at.month)}${two(at.day)}-${two(at.hour)}${two(at.minute)}${two(at.second)}';
    final folder = await logFolder();
    final logs = <File>[
      for (final entity in folder.listSync())
        if (entity is File && _logName.hasMatch(p.basename(entity.path))) entity,
    ]..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    for (final old in logs.take(logs.length - (keptLogs - 1) < 0 ? 0 : logs.length - (keptLogs - 1))) {
      try {
        old.deleteSync();
      } catch (error) {
        headsetViewLog.fine('An old headset log could not be deleted: $error');
      }
    }
    var name = 'headset-$stamp.log';
    for (var n = 2; File(p.join(folder.path, name)).existsSync(); n++) {
      name = 'headset-$stamp-$n.log';
    }
    return p.join(folder.path, name);
  }

  static final _logName = RegExp(r'^headset-\d{8}-\d{6}(-\d+)?\.log$');
}

/// The calls of the plugin's headset view, replaced by the tests
abstract interface class HeadsetApi {
  /// Whether this is Windows, the only system with the headset view for now
  bool get isWindows;
  Future<XrRuntimeInfo> runtimeInfo();
  Future<XrStartResult> start(XrStartRequest request);
  Future<void> setContent(XrContent content);
  Future<void> setContentRate(double fps);
  Future<void> setStrip(Uint8List rgba, int width, int height, {required bool visible});
  Future<void> recenter({bool lyingDown = false});
  Future<XrHeadsetState> poll({int afterSequence = 0});
  Future<bool> stop();
}

class PluginHeadsetApi implements HeadsetApi {
  const PluginHeadsetApi();

  @override
  bool get isWindows => Platform.isWindows;

  @override
  Future<XrRuntimeInfo> runtimeInfo() => XrHeadset.runtimeInfo();

  @override
  Future<XrStartResult> start(XrStartRequest request) => XrHeadset.start(request);

  @override
  Future<void> setContent(XrContent content) => XrHeadset.setContent(content);

  @override
  Future<void> setContentRate(double fps) => XrHeadset.setContentRate(fps);

  @override
  Future<void> setStrip(Uint8List rgba, int width, int height, {required bool visible}) =>
      XrHeadset.setStrip(rgba, width, height, visible: visible);

  @override
  Future<void> recenter({bool lyingDown = false}) => XrHeadset.recenter(lyingDown: lyingDown);

  @override
  Future<XrHeadsetState> poll({int afterSequence = 0}) => XrHeadset.poll(afterSequence: afterSequence);

  @override
  Future<bool> stop() => XrHeadset.stop();
}

/// How the headset shows a page's video, as the menu offers it
enum HeadsetChoice {
  /// Around the head (a 360 or 180 video)
  around,

  /// On a flat screen, as the frame is (2D; a 360 page's frame as the player lays it out)
  screen2d,

  /// On a flat screen, the two eyes side by side in the frame
  screenSideBySide,

  /// On a flat screen, the left eye above the right one
  screenOverUnder,
}

/// Where a page's video comes from, for the label of the log only
enum HeadsetSourceKind { immich, nas, plex, camera, local, player360 }

/// What a 360 page plays, for the label of the log only
enum HeadsetVideoKind { flat, video360, video180, raw360 }

/// How the headset lays out a choice
typedef HeadsetLayout = ({XrHeadsetMode mode, XrStereo stereo, XrEyeSqueeze squeeze});

/// The playback state the strip shows
enum HeadsetPlaybackStatus { playing, paused, buffering, ended, failed }

@immutable
class HeadsetPlayback {
  const HeadsetPlayback({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.status = HeadsetPlaybackStatus.paused,
  });

  final Duration position;
  final Duration duration;
  final HeadsetPlaybackStatus status;

  @override
  bool operator ==(Object other) =>
      other is HeadsetPlayback && other.position == position && other.duration == duration && other.status == status;

  @override
  int get hashCode => Object.hash(position, duration, status);

  @override
  String toString() => 'HeadsetPlayback(${status.name}, $position / $duration)';
}

/// What a player page gives the headset view (see the top of this file). The page registers it with the service
/// while its video is the one on screen; the values are read when they are needed, since the page's video, layout
/// and view change while it is open.
class HeadsetTarget {
  HeadsetTarget({
    required this.source,
    required this.video,
    required this.title,
    required this.choices,
    required this.preselected,
    required this.layoutOf,
    required this.handle,
    required this.playPause,
    required this.seekBy,
    required this.pause,
    required this.playback,
    ValueListenable<double>? frameRate,
    ValueListenable<String>? subtitle,
    this.yaw,
    this.prepare,
    this.release,
    this.hideSubtitles,
    this.videoChanged,
    this.notAvailable,
  }) : frameRate = frameRate ?? ValueNotifier(0),
       subtitle = subtitle ?? ValueNotifier('');

  final HeadsetSourceKind Function() source;
  final HeadsetVideoKind Function() video;

  /// The title for the strip, never written to any log
  final String Function() title;

  /// What the menu offers, in its order
  final List<HeadsetChoice> choices;

  /// The choice H starts and the menu marks: around for a 360 page, the 3D layout the file name tells for a flat one
  final HeadsetChoice Function() preselected;
  final HeadsetLayout Function(HeadsetChoice choice) layoutOf;

  /// The player drawn through renderer C (Player.handle), null when it has none yet
  final Future<int?> Function() handle;

  /// Through the page's own controls, so that the watch history, the wake lock and the window's controls follow
  final void Function() playPause;
  final void Function(Duration delta) seekBy;
  final void Function() pause;

  final ValueListenable<HeadsetPlayback> playback;

  /// The video's frame rate once the player knows it, 0 before
  final ValueListenable<double> frameRate;

  /// The text subtitle line shown now, '' for none
  final ValueListenable<String> subtitle;

  /// The window's yaw in degrees, ahead in the headset
  final double Function()? yaw;

  /// Before the headset shows [choice] of this page (renderer C with the flat pass for a flat player, the frame's
  /// subtitles hidden where the strip shows them); false when the page cannot be shown
  final Future<bool> Function(HeadsetChoice choice)? prepare;

  /// Once the headset no longer shows this page
  final Future<void> Function()? release;

  /// The frame's subtitles hidden (true) for the time the strip shows them, or back as they were (false)
  final Future<void> Function(bool hidden)? hideSubtitles;

  /// Fires when the page shows another video in the same player
  final Listenable? videoChanged;

  /// Why this page's video cannot go to the headset yet, for the log (never a title or a path), null when it can: a
  /// raw 360 file drawn by two players, whose second lens the headset would not get. The menu then says so and
  /// offers no layout, H starts nothing, and a view running shows the dark room. The page fires [videoChanged] when
  /// it changes.
  final String? Function()? notAvailable;

  /// The label of the log for [choice]: the kind of video only
  String labelOf(HeadsetChoice choice) {
    final layout = layoutOf(choice);
    return headsetLabel(
      source: source(),
      video: video(),
      mode: layout.mode,
      stereo: layout.stereo,
      squeeze: layout.squeeze,
    );
  }
}

/// The label of a view in the headset log: where the video comes from, its kind and how the headset shows it, made of
/// fixed words only, so that no URL, path, token or title can reach the log
String headsetLabel({
  required HeadsetSourceKind source,
  required HeadsetVideoKind video,
  required XrHeadsetMode mode,
  XrStereo stereo = XrStereo.mono,
  XrEyeSqueeze squeeze = XrEyeSqueeze.full,
}) {
  final from = switch (source) {
    HeadsetSourceKind.immich => 'Immich',
    HeadsetSourceKind.nas => 'network share',
    HeadsetSourceKind.plex => 'Plex',
    HeadsetSourceKind.camera => 'camera',
    HeadsetSourceKind.local => 'local file',
    HeadsetSourceKind.player360 => '360 player',
  };
  final kind = switch (video) {
    HeadsetVideoKind.flat => 'flat film',
    HeadsetVideoKind.video360 => '360 video',
    HeadsetVideoKind.video180 => '180 video',
    HeadsetVideoKind.raw360 => 'raw 360 video',
  };
  final stereoWords = switch (stereo) {
    XrStereo.mono => '2D',
    XrStereo.leftRight =>
      mode == XrHeadsetMode.screen && squeeze == XrEyeSqueeze.half ? '3D half side by side' : '3D side by side',
    XrStereo.topBottom =>
      mode == XrHeadsetMode.screen && squeeze == XrEyeSqueeze.half ? '3D half over under' : '3D over under',
  };
  return '$from, $kind, ${mode.name}, $stereoWords';
}

/// How a flat film's eyes are laid out for [choice], the squeeze told by the file name's [guess] or, when the name
/// says nothing of it, by the frame's shape ([width] x [height]) as guessFlatStereoFormat reads it
HeadsetLayout flatHeadsetLayout(HeadsetChoice choice, {FlatStereoFormat? guess, int? width, int? height}) {
  final known = width != null && height != null && width > 0 && height > 0;
  switch (choice) {
    case HeadsetChoice.screenSideBySide:
      final half = switch (guess) {
        FlatStereoFormat.halfSbs => true,
        FlatStereoFormat.sbs => false,
        _ => known && width / 2 / height < 1.0,
      };
      return (
        mode: XrHeadsetMode.screen,
        stereo: XrStereo.leftRight,
        squeeze: half ? XrEyeSqueeze.half : XrEyeSqueeze.full,
      );
    case HeadsetChoice.screenOverUnder:
      final half = switch (guess) {
        FlatStereoFormat.halfTb => true,
        FlatStereoFormat.tb => false,
        _ => known && width / (height / 2) > 2.5,
      };
      return (
        mode: XrHeadsetMode.screen,
        stereo: XrStereo.topBottom,
        squeeze: half ? XrEyeSqueeze.half : XrEyeSqueeze.full,
      );
    case HeadsetChoice.screen2d:
    case HeadsetChoice.around:
      return (mode: XrHeadsetMode.screen, stereo: XrStereo.mono, squeeze: XrEyeSqueeze.full);
  }
}

/// The choice a flat film starts with: the 3D layout its file name tells, else 2D
HeadsetChoice flatHeadsetChoiceOf(FlatStereoFormat? guess) => switch (guess) {
  FlatStereoFormat.sbs || FlatStereoFormat.halfSbs => HeadsetChoice.screenSideBySide,
  FlatStereoFormat.tb || FlatStereoFormat.halfTb => HeadsetChoice.screenOverUnder,
  null => HeadsetChoice.screen2d,
};

/// Whether the strip shows the subtitles in [layout], the frame's being hidden then: around the head (they sit at
/// the nadir or split between the eyes) and on a 3D screen; a flat 2D screen keeps the frame's own
bool headsetStripShowsSubtitles(HeadsetLayout layout) =>
    layout.mode == XrHeadsetMode.sphere || (layout.mode == XrHeadsetMode.screen && layout.stereo != XrStereo.mono);

/// The names of the controllers' actions in the app's language, for the runtime's binding screen
Map<String, String> headsetActionNames(Translations t) => {
  'player': t.headset_action_set,
  'play_pause': t.headset_action_play_pause,
  'seek': t.headset_action_seek,
  'seek_press': t.headset_action_seek,
  'recenter': t.headset_action_recenter,
  'exit': t.headset_action_exit,
};

/// The text of why a view ended or did not start, null where the window says nothing (the window stopped it)
String? headsetStopText(Translations t, XrStopReason reason) => switch (reason) {
  XrStopReason.none || XrStopReason.stoppedByApp => null,
  XrStopReason.endedFromHeadset => t.headset_view_ended_from_headset,
  XrStopReason.noRuntime => t.headset_view_error_no_runtime,
  XrStopReason.loaderMissing => t.headset_view_error_loader_missing,
  XrStopReason.noHeadset => t.headset_view_error_no_headset,
  XrStopReason.otherGpu => t.headset_view_error_other_gpu,
  XrStopReason.gpuTooWeak => t.headset_view_error_gpu_too_weak,
  XrStopReason.runtimeLost => t.headset_view_error_runtime_lost,
  XrStopReason.runtimeNotAnswering => t.headset_view_error_not_answering,
  XrStopReason.notWindows => t.headset_view_setting_windows_only,
  XrStopReason.alreadyRunning || XrStopReason.notInBuild || XrStopReason.failed => t.headset_view_error_failed,
};

/// What the window tells of the headset view
enum HeadsetNoticeKind {
  /// At each start: experimental, not yet tried in a headset by the project (fades)
  experimental,

  /// The view ended without the window asking, or could not start: [HeadsetNotice.reason]
  stopped,

  /// The headset was taken off and the video paused (fades)
  takenOff,

  /// The last view was running when the app ended (fades)
  crashOnce,

  /// Twice in a row: the switch was turned off
  crashGuard,
}

@immutable
class HeadsetNotice {
  const HeadsetNotice(this.kind, {this.reason = XrStopReason.none});

  final HeadsetNoticeKind kind;
  final XrStopReason reason;

  /// A notice that fades after a few seconds; the others stay longer, they say what to do
  bool get transient =>
      kind == HeadsetNoticeKind.experimental ||
      kind == HeadsetNoticeKind.takenOff ||
      kind == HeadsetNoticeKind.crashOnce;

  @override
  bool operator ==(Object other) => other is HeadsetNotice && other.kind == kind && other.reason == reason;

  @override
  int get hashCode => Object.hash(kind, reason);

  @override
  String toString() => 'HeadsetNotice(${kind.name}${reason == XrStopReason.none ? '' : ', ${reason.name}'})';
}

/// The text of [notice], null for none
String? headsetNoticeText(Translations t, HeadsetNotice notice) => switch (notice.kind) {
  HeadsetNoticeKind.experimental => t.headset_view_experimental_notice,
  HeadsetNoticeKind.stopped => headsetStopText(t, notice.reason),
  HeadsetNoticeKind.takenOff => t.headset_view_paused_taken_off,
  HeadsetNoticeKind.crashOnce => t.headset_view_crash_once,
  HeadsetNoticeKind.crashGuard => t.headset_view_crash_guard,
};

/// The name of the runtime as the setting row shows it
String headsetRuntimeName(Translations t, XrRuntimeInfo info) =>
    info.runtime.isEmpty ? t.headset_view_runtime_other : info.runtime;

/// A signal a page fires for the headset view
class HeadsetSignal extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// What the strip shows of a desktop player ([MediaKitVideoPlayerController]): the 360 player's own state, and its
/// subtitle line
class HeadsetControllerPlayback {
  HeadsetControllerPlayback(this.controller) {
    controller.onPlaybackStatusChanged.addListener(_update);
    controller.onPlaybackPositionChanged.addListener(_update);
    controller.onPlaybackEnded.addListener(_onEnded);
    controller.onError.addListener(_update);
    controller.buffering.addListener(_update);
    controller.videoController.addListener(_onPlayer);
    controller.onPlaybackReady.addListener(_onReady);
    _onPlayer();
    _update();
  }

  final MediaKitVideoPlayerController controller;
  final _playback = ValueNotifier(const HeadsetPlayback());
  final _subtitle = ValueNotifier('');
  final _rate = ValueNotifier(0.0);
  final _ready = HeadsetSignal();
  bool _ended = false;
  StreamSubscription<List<String>>? _lines;
  Player? _player;

  ValueListenable<HeadsetPlayback> get playback => _playback;
  ValueListenable<String> get subtitle => _subtitle;

  /// Set by the page once the player knows the frame rate
  ValueNotifier<double> get frameRate => _rate;

  /// A new video became ready in the player
  Listenable get videoChanged => _ready;

  void _onReady() {
    _ended = false;
    _update();
    _ready.fire();
  }

  void _onEnded() {
    _ended = true;
    _update();
  }

  void _onPlayer() {
    final player = controller.videoController.value?.player;
    if (identical(player, _player)) {
      return;
    }
    final before = _player;
    _player = player;
    if (before != null) {
      // Another player of the pool: the headset takes it
      _ready.fire();
    }
    unawaited(_lines?.cancel());
    _lines = player?.stream.subtitle.listen((lines) => _subtitle.value = headsetSubtitleLine(lines));
  }

  void _update() {
    final status = controller.onPlaybackStatusChanged.value;
    if (status == PlaybackStatus.playing) {
      _ended = false;
    }
    _playback.value = HeadsetPlayback(
      position: Duration(milliseconds: controller.onPlaybackPositionChanged.value),
      duration: Duration(milliseconds: controller.videoInfo?.duration ?? 0),
      status: controller.onError.value != null
          ? HeadsetPlaybackStatus.failed
          : _ended
          ? HeadsetPlaybackStatus.ended
          : controller.buffering.value
          ? HeadsetPlaybackStatus.buffering
          : status == PlaybackStatus.playing
          ? HeadsetPlaybackStatus.playing
          : HeadsetPlaybackStatus.paused,
    );
  }

  void dispose() {
    controller.onPlaybackStatusChanged.removeListener(_update);
    controller.onPlaybackPositionChanged.removeListener(_update);
    controller.onPlaybackEnded.removeListener(_onEnded);
    controller.onError.removeListener(_update);
    controller.buffering.removeListener(_update);
    controller.videoController.removeListener(_onPlayer);
    controller.onPlaybackReady.removeListener(_onReady);
    unawaited(_lines?.cancel());
    _playback.dispose();
    _subtitle.dispose();
    _rate.dispose();
    _ready.dispose();
  }
}

/// The subtitle lines media_kit gives (the text of mpv's sub-text, which mpv fills whether the frame shows the
/// subtitles or not) as one line of the strip
String headsetSubtitleLine(List<String> lines) =>
    lines.expand((line) => line.split('\n')).map((line) => line.trim()).where((line) => line.isNotEmpty).join(' ');

/// The playback of a flat player as the window's controls show it (VideoPlayerNotifier)
class HeadsetNotifierPlayback {
  HeadsetNotifierPlayback(VideoPlayerNotifier notifier) {
    try {
      _remove = notifier.addListener(
        (state) => _playback.value = HeadsetPlayback(
          position: state.position,
          duration: state.duration,
          status: switch (state.status) {
            VideoPlaybackStatus.playing => HeadsetPlaybackStatus.playing,
            VideoPlaybackStatus.paused => HeadsetPlaybackStatus.paused,
            VideoPlaybackStatus.buffering => HeadsetPlaybackStatus.buffering,
            VideoPlaybackStatus.completed => HeadsetPlaybackStatus.ended,
            VideoPlaybackStatus.failed => HeadsetPlaybackStatus.failed,
          },
        ),
      );
    } catch (_) {
      // A notifier already disposed: the strip shows paused
    }
  }

  final _playback = ValueNotifier(const HeadsetPlayback());
  void Function()? _remove;

  ValueListenable<HeadsetPlayback> get playback => _playback;

  void dispose() {
    try {
      _remove?.call();
    } catch (_) {
      // The notifier went first
    }
    _remove = null;
    _playback.dispose();
  }
}

/// For the time a flat player's film is in the headset: renderer C draws the player with the flat pass (kind 4), so
/// that the headset view reads the player's frame while the window keeps its normal picture; detached after. The
/// frame's subtitles are hidden while the strip shows them, and restored after.
class HeadsetFlatPlayer {
  HeadsetFlatPlayer(this.controller);

  final MediaKitVideoPlayerController controller;
  PluginRenderer? _renderer;
  VideoController? _rendererOf;

  NativePlayer? get _native {
    final native = controller.videoController.value?.player.platform;
    return native is NativePlayer ? native : null;
  }

  Future<int?> handle() async {
    return controller.videoController.value?.player.handle;
  }

  /// Renderer C with the flat pass, at the frame's own size so the window's picture keeps its shape
  Future<bool> attach() async {
    final videoController = controller.videoController.value;
    if (videoController == null) {
      return false;
    }
    if (_renderer != null && identical(_rendererOf, videoController)) {
      return true;
    }
    // Another player of the pool: renderer C off on the one before
    await detach();
    final renderer = _renderer = PluginRenderer.forController(videoController);
    _rendererOf = videoController;
    final size = controller.decoding.value.size;
    final attached = await renderer.attach(
      projection: PluginProjection.flat(),
      outputSize: size == null || size.width <= 0 || size.height <= 0
          ? const ui.Size(1920, 1080)
          : ui.Size(size.width.toDouble(), size.height.toDouble()),
    );
    if (!attached.ok) {
      headsetViewLog.warning('renderer C refused the flat pass: ${attached.reason}');
      _renderer = null;
      _rendererOf = null;
      await renderer.dispose();
    }
    return attached.ok;
  }

  Future<void> detach() async {
    final renderer = _renderer;
    _renderer = null;
    _rendererOf = null;
    await renderer?.dispose();
  }

  /// The frame's subtitles off ([hidden]) or back as they were
  Future<void> hideSubtitles(bool hidden) => headsetHideSubtitles(hidden, native: _native, state: this);
}

/// mpv's sub-visibility off for the time the strip shows the subtitles, then back as it was; [state] keeps the value
Future<void> headsetHideSubtitles(bool hidden, {required NativePlayer? native, required Object state}) async {
  final kept = _keptSubVisibility[state];
  try {
    if (hidden) {
      if (native == null || kept != null) {
        return;
      }
      final before = await native.getProperty('sub-visibility');
      _keptSubVisibility[state] = (native, before.isEmpty ? 'yes' : before);
      await native.setProperty('sub-visibility', 'no');
    } else if (kept != null) {
      _keptSubVisibility[state] = null;
      await kept.$1.setProperty('sub-visibility', kept.$2);
    }
  } catch (error) {
    headsetViewLog.fine('sub-visibility not changed: $error');
  }
}

final _keptSubVisibility = Expando<(NativePlayer, String)>('sub-visibility');

/// What a flat player page tells the headset view of its video (the Immich viewer, the network page): the player's
/// key of videoPlayerProvider, where the video comes from, its title for the strip and its file name for the 3D
/// layout (guessFlatStereoFormat)
@immutable
class HeadsetFlatPage {
  const HeadsetFlatPage({required this.playerKey, required this.source, required this.title, this.fileName});

  final String playerKey;
  final HeadsetSourceKind Function() source;
  final String Function() title;

  /// The file name, for the 3D words only; the title when null
  final String? Function()? fileName;
}

/// The frame rate mpv reads from the file, 0 when it tells none
Future<double> headsetFrameRateOf(MediaKitVideoPlayerController controller) async {
  final native = controller.videoController.value?.player.platform;
  if (native is! NativePlayer) {
    return 0;
  }
  for (final name in const ['container-fps', 'estimated-vf-fps']) {
    try {
      final value = double.tryParse(await native.getProperty(name));
      if (value != null && value > 0) {
        return value;
      }
    } catch (_) {
      // The next one
    }
  }
  return 0;
}

/// The target of a flat player (DesktopVideoView), made while its page shows it: play or pause and seek through the
/// page's VideoPlayerNotifier, the strip from its state, renderer C's flat pass for the time it is in the headset
class HeadsetFlatBinding {
  HeadsetFlatBinding({
    required this.controller,
    required this.page,
    required this.notifier,
    Future<double> Function(MediaKitVideoPlayerController controller)? frameRateOf,
  }) : _frameRateOf = frameRateOf ?? headsetFrameRateOf {
    _player = HeadsetFlatPlayer(controller);
    _controllerPlayback = HeadsetControllerPlayback(controller);
    _notifierPlayback = HeadsetNotifierPlayback(notifier());
    _controllerPlayback.videoChanged.addListener(_onVideo);
    target = HeadsetTarget(
      source: page.source,
      video: () => HeadsetVideoKind.flat,
      title: page.title,
      choices: const [HeadsetChoice.screen2d, HeadsetChoice.screenSideBySide, HeadsetChoice.screenOverUnder],
      preselected: () => flatHeadsetChoiceOf(_guess()),
      layoutOf: (choice) {
        final size = controller.decoding.value.size;
        return flatHeadsetLayout(choice, guess: _guess(), width: size?.width, height: size?.height);
      },
      handle: _player.handle,
      playPause: () => notifier().toggle(),
      seekBy: (delta) => notifier().seekBy(delta),
      pause: () => unawaited(notifier().pause()),
      playback: _notifierPlayback.playback,
      frameRate: _controllerPlayback.frameRate,
      subtitle: _controllerPlayback.subtitle,
      prepare: (_) => _player.attach(),
      release: _player.detach,
      hideSubtitles: _player.hideSubtitles,
      videoChanged: _controllerPlayback.videoChanged,
    );
    unawaited(_readRate());
  }

  final MediaKitVideoPlayerController controller;
  final HeadsetFlatPage page;
  final VideoPlayerNotifier Function() notifier;
  final Future<double> Function(MediaKitVideoPlayerController controller) _frameRateOf;
  late final HeadsetFlatPlayer _player;
  late final HeadsetControllerPlayback _controllerPlayback;
  late final HeadsetNotifierPlayback _notifierPlayback;
  late final HeadsetTarget target;
  bool _disposed = false;

  FlatStereoFormat? _guess() {
    final size = controller.decoding.value.size;
    return guessFlatStereoFormat(
      fileName: page.fileName?.call() ?? page.title(),
      width: size?.width,
      height: size?.height,
      isVideo: true,
    );
  }

  void _onVideo() => unawaited(_readRate());

  Future<void> _readRate() async {
    final rate = await _frameRateOf(controller);
    if (!_disposed && rate > 0) {
      _controllerPlayback.frameRate.value = rate;
    }
  }

  void dispose() {
    _disposed = true;
    _controllerPlayback.videoChanged.removeListener(_onVideo);
    unawaited(_player.detach());
    _controllerPlayback.dispose();
    _notifierPlayback.dispose();
  }
}
