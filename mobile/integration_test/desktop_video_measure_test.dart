// The measurement harness of the desktop video (design 2.10, plan 2.5): the figures behind the spikes and decision
// point DP1. It opens a window and plays videos, so it runs on the owner's PC in a slot he gave:
//   flutter test integration_test/desktop_video_measure_test.dart -d windows
// From WSL, through the wrapper of the desktop work (the variables pass by name, their values are never printed):
//   export IMMUCH360_MEASURE_CLIPS='8k-hevc=D:\clips\a.mp4;5k7-h264=D:\clips\b.mp4'
//   win_flutter.sh --env IMMUCH360_MEASURE_CLIPS --log measure-2a \
//     test integration_test/desktop_video_measure_test.dart -d windows
//   grep '^MEASURE ' /tmp/desk-logs/measure-2a.log | cut -c9- > /tmp/desk-measure/2a/measure.jsonl
// flutter test runs it in a debug build. For figures of the app as shipped, build it as an app in profile mode and
// start the executable with the same variables; the records land in IMMUCH360_MEASURE_OUT:
//   win_flutter.sh build windows --profile -t integration_test/desktop_video_measure_test.dart
//
// Without any variable it makes the reference runs only, which need no clip: an uncompressed AVI written to the
// temporary folder (or mpv's lavfi pattern when the libmpv build has that input), played at window size by a bare
// media_kit player, then by the app's own player (DesktopVideoView, the pool, the media bridge) with a frame grab
// of the thumbnail grabber. Both, and nothing else: --plain-name reference.
//
// Variables, all optional:
//   IMMUCH360_MEASURE_CLIPS        label=path entries separated by ";" or new lines; one run per clip
//   IMMUCH360_MEASURE_SECONDS      seconds of each measured phase (default 10)
//   IMMUCH360_MEASURE_HWDEC        mpv's hwdec (default "auto", what media_kit asks when the app gives nothing)
//   IMMUCH360_MEASURE_RENDER       "app" (default): the texture as the app's players size it, the shape of the
//                                  video at most IMMUCH360_MEASURE_MAX_HEIGHT lines high (default 1440, design 2.11,
//                                  DesktopPlayerOptions.maxRenderHeight); "window": the window's physical size,
//                                  capped the same way (the size spikes 1 and 6 of 2026-10-09 were measured at);
//                                  "source": the size of the video, uncapped
//   IMMUCH360_MEASURE_SHADER       a user shader (an mpv hook file) loaded through glsl-shaders; "probe" loads the
//                                  built-in probe hook (MAINPRESUB at OUTPUT size, one float parameter)
//   IMMUCH360_MEASURE_PARAM        name:min:max of the shader parameter changed while measuring (default yaw:-180:180)
//   IMMUCH360_MEASURE_PARAM_RATES  changes a second, one phase each (default "0", or "0,15,30,60" with a shader)
//   IMMUCH360_MEASURE_PARAM_FIXED  other parameters sent with each change ("fov=100,pitch=10"): a change of
//                                  glsl-shader-opts replaces the whole list
//   IMMUCH360_MEASURE_PARAM_PROPERTY  what a change sets (default glsl-shader-opts): another mpv property takes the
//                                  bare value (video-pan-x: the panscan path, which feeds tex_offset to the hooks);
//                                  "glsl-shaders" writes a copy of the shader with @VALUE@ replaced by the value under
//                                  a new name and loads it, the only way to move a view where the libmpv has no
//                                  //!PARAM (mpv added it to vo_gpu on 2026-04-17)
//   IMMUCH360_MEASURE_REDRAW       seconds of a last phase, paused, where the view changes 60 times a second: with
//                                  IMMUCH360_MEASURE_MPV_STATS, the cost of a redraw of a paused frame
//   IMMUCH360_MEASURE_MPV_STATS    "on": mpv's own timing events (dump-stats) per phase: the frames handed to the
//                                  renderer and their intervals, the render calls (frames and redraws), frames
//                                  dropped or late in mpv's output; a stall shows as a long interval
//   IMMUCH360_MEASURE_MPV_SET      mpv properties set before each clip opens, "name=value" entries separated by "|"
//                                  or new lines ("keepaspect=no|lavfi-complex=[vid1] [vid2] hstack [vo]")
//   IMMUCH360_MEASURE_EXTERNAL     label=path entries: the clip of that label opens with this second file as an
//                                  external track (external-files), as the second file of an X3 pair (design 2.5)
//   IMMUCH360_MEASURE_REFERENCE    "off": no reference runs before the clips
//   IMMUCH360_MEASURE_CLIP_RATES   label=rates entries ("p15=0,15;p30=0,30"): the parameter rates of that clip
//   IMMUCH360_MEASURE_CLIP_SCREENS label=screens entries ("p15=primary;e15=secondary"): the screens of that clip
//   IMMUCH360_MEASURE_CLIP_REDRAW  label=seconds entries: the paused redraw phase of that clip (0: none). With the
//                                  same file under several labels, each rate gets a player of its own, and the memory
//                                  a player keeps from one phase does not weigh on the next
//   IMMUCH360_MEASURE_MEMORY_GUARD_MB  growth in MiB of the working set plus the GPU memory of the process, from the
//                                  start of a clip's first phase, that ends a phase early and skips the clip's other
//                                  phases: each change of glsl-shader-opts kept about 40 MB until the player closed
//                                  on 2026-10-09, and the PC ran out of memory (the owner's desktop crashed)
//   IMMUCH360_MEASURE_RENDERER     "c": renderer C of the vendored media_kit_video draws an equirectangular view
//                                  (render/plugin_renderer.dart, DP1); the view changes of each phase go through the
//                                  plugin (yaw from IMMUCH360_MEASURE_PARAM, pitch and fov from _PARAM_FIXED), and each
//                                  phase records the plugin's draws (with a new frame of mpv, or the view alone) and
//                                  their times; with IMMUCH360_MEASURE_REDRAW, the paused phase shows whether a view
//                                  change reaches mpv at all. Five pixels of the output are read back once
//   IMMUCH360_MEASURE_C_TIER       full, w4096 or w2880 (default: the start tier of the GPU, PluginTier.startFor)
//   IMMUCH360_MEASURE_SOAK         number of players opened, played and closed one after the other (spike 2: 200)
//   IMMUCH360_MEASURE_SOAK_CLIP    label of a clip of IMMUCH360_MEASURE_CLIPS for the soak (default the reference)
//   IMMUCH360_MEASURE_SOAK_MODE    "bare" (default): a media_kit player made and disposed each time, what #1449
//                                  is about; "pool": the app's views and pool, three views a round (two on screen,
//                                  a third that takes the player of the first), so that each round hands a player
//                                  over, parks one and disposes one, as swiping through the viewer does
//   IMMUCH360_MEASURE_TICKER       "off": no 4 x 4 point redrawn every frame in the corner (see _Ticker)
//   IMMUCH360_MEASURE_OPTIONS      "mediakit" (default): media_kit's own mpv options; "app": the app's players'
//                                  (DesktopPlayerOptions: the caches, cache-on-disk off, the protocols)
//   IMMUCH360_MEASURE_SCREENS      screens the window is moved to while the clip plays, one set of phases each
//                                  ("primary,secondary,primary"; "primary" is the screen of the taskbar, "secondary"
//                                  the first other one, or a monitor number from 0); spike 6
//   IMMUCH360_MEASURE_WINDOW_SIZE  the window's size in physical pixels on each screen (default 1600x900)
//   IMMUCH360_MEASURE_MEMORY       label of a clip of IMMUCH360_MEASURE_CLIPS for the memory case (plan 2.7, the 8K
//                                  risk): two views of the app play it, first one after the other as a swipe does,
//                                  then both at once, the most the pool allows, while the thumbnail grabber takes
//                                  frames of it; the working set and the GPU memory (dedicated and shared) are sampled
//                                  at each step
//   IMMUCH360_MEASURE_MEMORY_THROUGH  "bridge": the memory case reads the clip through the media bridge, with the
//                                  cache of a share video; "file" (default): as a video of the folders
//   IMMUCH360_MEASURE_BRIDGE       label=kind:path entries, played through the app's media bridge (spike 1):
//                                    local:<file>            a file of this computer, the bridge's own cost
//                                    smb:<path in share>     IMMUCH360_MEASURE_SMB_HOST, _SHARE, _USER, _PASSWORD
//                                    webdav:<path>           IMMUCH360_MEASURE_WEBDAV_URL, _USER, _PASSWORD
//                                    server:<asset id>       IMMUCH360_MEASURE_SERVER_URL, IMMUCH360_MEASURE_API_KEY;
//                                    server:<asset id>/playback for the transcoded stream
//   IMMUCH360_MEASURE_OUT          folder of the JSON files (default <temp>/immuch360-measure/<phase>)
//   IMMUCH360_MEASURE_PHASE        tag of the runs (default 2a)
//   IMMUCH360_MEASURE_GPU, IMMUCH360_MEASURE_SCREEN  what the owner set ("rtx4060, external 1080p"), as given
//
// What a run records (one JSON object per run, also printed on one line after "MEASURE "): the GPU and OpenGL ES
// version mpv reports, the screen and window, the render size, hwdec-current, the codec and size, per phase the
// counters frame-drop-count, decoder-frame-drop-count, vo-delayed-frame-count and mistimed-frame-count, Flutter's
// frame times (build, raster, total), the time paused for the cache, the process memory (the working set, and on
// Windows the GPU memory the driver holds for the process: test/desktop/video/gpu_memory_support.dart), the size of
// the texture media_kit draws into, the "dumb mode" and
// "Disabling" lines of mpv while a hook is loaded, and the redacted lines of mpv's log about the renderer and the
// decoder. Clip paths, URLs, the bridge token, the share's host and user and every password never reach a record or
// the output: labels name the clips, and every log line is filtered (test/desktop/video/mpv_measure_support.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/desktop_video_view.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:immich_mobile/desktop/video/video_thumbnail_grabber.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/network/http_range_reader.dart';
import 'package:immich_mobile/infrastructure/network/smb_file_system.dart';
import 'package:immich_mobile/infrastructure/network/webdav_file_system.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_video_player/native_video_player.dart' show VideoSource, VideoSourceType;
import 'package:path/path.dart' as p;

import '../test/desktop/video/gpu_memory_support.dart';
import '../test/desktop/video/mpv_measure_support.dart';

/// mpv's counters, read before and after each phase
const _counters = ['frame-drop-count', 'decoder-frame-drop-count', 'vo-delayed-frame-count', 'mistimed-frame-count'];

/// mpv's properties read once a clip plays
const _properties = [
  'hwdec',
  'hwdec-current',
  'video-codec',
  'video-format',
  'width',
  'height',
  'container-fps',
  'estimated-vf-fps',
  'display-fps',
  'video-params/pixelformat',
  'video-params/hw-pixelformat',
  'video-params/colormatrix',
  'video-params/gamma',
  'video-bitrate',
  'file-size',
  'duration',
  'current-demuxer',
  'demuxer-cache-duration',
  'cache-speed',
  'vo-passes',
  'mpv-version',
  'lavfi-complex',
  'keepaspect',
];

/// The built-in probe hook: the shape of the projection hook (MAINPRESUB, drawn at the output size while sampling
/// the full frame) with one float parameter, so that the cost of changing glsl-shader-opts can be measured before the
/// real projection exists (spike 3)
const _probeHook = '''//!PARAM yaw
//!DESC turn of the probe, in degrees
//!TYPE float
//!MINIMUM -180.0
//!MAXIMUM 180.0
0.0

//!HOOK MAINPRESUB
//!BIND HOOKED
//!WIDTH OUTPUT.w
//!HEIGHT OUTPUT.h
//!DESC immuch360 probe hook

vec4 hook() {
    vec2 pos = HOOKED_pos;
    pos.x = fract(pos.x + yaw / 360.0);
    return HOOKED_tex(pos);
}
''';

String _safeLabel(String label) {
  final safe = label.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
  return safe.isEmpty ? 'unnamed' : (safe.length > 40 ? safe.substring(0, 40) : safe);
}

List<(String, String)> _entries(String? value) {
  if (value == null || value.trim().isEmpty) {
    return const [];
  }
  final entries = <(String, String)>[];
  for (final part in value.split(RegExp(r'[;\n]'))) {
    final separator = part.indexOf('=');
    if (separator <= 0) {
      continue;
    }
    entries.add((_safeLabel(part.substring(0, separator)), part.substring(separator + 1).trim()));
  }
  return entries;
}

class _Config {
  _Config(this.env)
    : clips = _entries(env['IMMUCH360_MEASURE_CLIPS']),
      bridge = _entries(env['IMMUCH360_MEASURE_BRIDGE']),
      seconds = int.tryParse(env['IMMUCH360_MEASURE_SECONDS'] ?? '') ?? 10,
      hwdec = (env['IMMUCH360_MEASURE_HWDEC'] ?? '').isEmpty ? 'auto' : env['IMMUCH360_MEASURE_HWDEC']!,
      renderMode = switch (env['IMMUCH360_MEASURE_RENDER']) {
        'window' => 'window',
        'source' => 'source',
        _ => 'app',
      },
      maxRenderHeight = int.tryParse(env['IMMUCH360_MEASURE_MAX_HEIGHT'] ?? '') ?? 1440,
      shader = (env['IMMUCH360_MEASURE_SHADER'] ?? '').isEmpty ? null : env['IMMUCH360_MEASURE_SHADER'],
      soakPlayers = int.tryParse(env['IMMUCH360_MEASURE_SOAK'] ?? '') ?? 0,
      soakClip = env['IMMUCH360_MEASURE_SOAK_CLIP'],
      soakThroughPool = env['IMMUCH360_MEASURE_SOAK_MODE'] == 'pool',
      memoryClip = env['IMMUCH360_MEASURE_MEMORY'],
      memoryThroughBridge = env['IMMUCH360_MEASURE_MEMORY_THROUGH'] == 'bridge',
      appOptions = env['IMMUCH360_MEASURE_OPTIONS'] == 'app',
      ticker = env['IMMUCH360_MEASURE_TICKER'] != 'off',
      screens = [
        for (final screen in (env['IMMUCH360_MEASURE_SCREENS'] ?? '').split(','))
          if (screen.trim().isNotEmpty) screen.trim(),
      ],
      phase = _safeLabel(env['IMMUCH360_MEASURE_PHASE'] ?? '2a'),
      gpuLabel = env['IMMUCH360_MEASURE_GPU'],
      screenLabel = env['IMMUCH360_MEASURE_SCREEN'],
      paramFixed = env['IMMUCH360_MEASURE_PARAM_FIXED'] ?? '',
      paramProperty = (env['IMMUCH360_MEASURE_PARAM_PROPERTY'] ?? '').isEmpty
          ? 'glsl-shader-opts'
          : env['IMMUCH360_MEASURE_PARAM_PROPERTY']!,
      redrawChanges = int.tryParse(env['IMMUCH360_MEASURE_REDRAW'] ?? '') ?? 0,
      pluginRenderer = env['IMMUCH360_MEASURE_RENDERER'] == 'c',
      pluginTier = PluginTier.values.where((tier) => tier.name == env['IMMUCH360_MEASURE_C_TIER']).firstOrNull,
      mpvStats = env['IMMUCH360_MEASURE_MPV_STATS'] == 'on',
      mpvSet = [
        for (final entry in (env['IMMUCH360_MEASURE_MPV_SET'] ?? '').split(RegExp(r'[|\n]')))
          if (entry.indexOf('=') > 0)
            (entry.substring(0, entry.indexOf('=')).trim(), entry.substring(entry.indexOf('=') + 1)),
      ],
      external = _entries(env['IMMUCH360_MEASURE_EXTERNAL']),
      reference = env['IMMUCH360_MEASURE_REFERENCE'] != 'off',
      memoryGuardMB = int.tryParse(env['IMMUCH360_MEASURE_MEMORY_GUARD_MB'] ?? '') ?? 0,
      clipRates = {
        for (final (label, rates) in _entries(env['IMMUCH360_MEASURE_CLIP_RATES']))
          label: [for (final rate in rates.split(',')) ?int.tryParse(rate.trim())],
      },
      clipScreens = {
        for (final (label, screens) in _entries(env['IMMUCH360_MEASURE_CLIP_SCREENS']))
          label: [
            for (final screen in screens.split(','))
              if (screen.trim().isNotEmpty) screen.trim(),
          ],
      },
      clipRedraw = {
        for (final (label, seconds) in _entries(env['IMMUCH360_MEASURE_CLIP_REDRAW']))
          label: int.tryParse(seconds) ?? 0,
      } {
    final param = (env['IMMUCH360_MEASURE_PARAM'] ?? 'yaw:-180:180').split(':');
    paramName = param.first;
    paramMin = param.length > 1 ? double.tryParse(param[1]) ?? -180 : -180;
    paramMax = param.length > 2 ? double.tryParse(param[2]) ?? 180 : 180;
    final rates = env['IMMUCH360_MEASURE_PARAM_RATES'] ?? (shader == null && !pluginRenderer ? '0' : '0,15,30,60');
    paramRates = [for (final rate in rates.split(',')) ?int.tryParse(rate.trim())];
    final size = RegExp(r'^(\d+)x(\d+)$').firstMatch(env['IMMUCH360_MEASURE_WINDOW_SIZE'] ?? '');
    windowSize = size == null ? (1600, 900) : (int.parse(size.group(1)!), int.parse(size.group(2)!));
    outDir = (env['IMMUCH360_MEASURE_OUT'] ?? '').isNotEmpty
        ? env['IMMUCH360_MEASURE_OUT']!
        : p.join(Directory.systemTemp.path, 'immuch360-measure', phase);
  }

  final Map<String, String> env;
  final List<(String, String)> clips;
  final List<(String, String)> bridge;
  final int seconds;
  final String hwdec;

  /// "app", "window" or "source" (see IMMUCH360_MEASURE_RENDER)
  final String renderMode;
  final int maxRenderHeight;
  final String? shader;
  final int soakPlayers;
  final String? soakClip;
  final bool soakThroughPool;
  final String? memoryClip;
  final bool memoryThroughBridge;
  final bool appOptions;
  final bool ticker;
  final List<String> screens;
  late final (int, int) windowSize;
  final String phase;
  final String? gpuLabel;
  final String? screenLabel;
  late final String paramName;
  late final double paramMin;
  late final double paramMax;
  late final List<int> paramRates;
  late final String outDir;
  final String paramFixed;
  final String paramProperty;
  final int redrawChanges;
  final bool pluginRenderer;
  final PluginTier? pluginTier;
  final bool mpvStats;
  final List<(String, String)> mpvSet;
  final List<(String, String)> external;
  final bool reference;
  final int memoryGuardMB;
  final Map<String, List<int>> clipRates;
  final Map<String, List<String>> clipScreens;
  final Map<String, int> clipRedraw;

  List<int> ratesOf(String label) => clipRates[label] ?? paramRates;
  List<String> screensOf(String label) => clipScreens[label] ?? screens;
  int redrawOf(String label) => clipRedraw[label] ?? redrawChanges;

  /// The view of renderer C for a value of the parameter that changes, the others from [paramFixed]
  PluginView pluginView(double value) {
    final fixed = {
      for (final entry in paramFixed.split(','))
        if (entry.contains('=')) entry.split('=').first.trim(): double.tryParse(entry.split('=').last.trim()),
    };
    double of(String name, double fallback) => name == paramName ? value : fixed[name] ?? fallback;
    return PluginView(yaw: of('yaw', 0), pitch: of('pitch', 0), fov: of('fov', 90));
  }

  /// The external file of the clip [label], null when it has none
  String? externalOf(String label) => external.where((entry) => entry.$1 == label).firstOrNull?.$2;

  /// The values a record must never show: the clip paths, and the share and server settings
  List<String> get secrets => [
    for (final (_, path) in clips) path,
    for (final (_, path) in external) path,
    for (final (_, entry) in bridge) entry.substring(entry.indexOf(':') + 1),
    for (final name in [
      'IMMUCH360_MEASURE_SMB_HOST',
      'IMMUCH360_MEASURE_SMB_SHARE',
      'IMMUCH360_MEASURE_SMB_USER',
      'IMMUCH360_MEASURE_SMB_PASSWORD',
      'IMMUCH360_MEASURE_WEBDAV_URL',
      'IMMUCH360_MEASURE_WEBDAV_USER',
      'IMMUCH360_MEASURE_WEBDAV_PASSWORD',
      'IMMUCH360_MEASURE_SERVER_URL',
      'IMMUCH360_MEASURE_API_KEY',
    ])
      ?env[name],
  ].where((value) => value.length >= 3).toList();

  /// The values of [secrets] replaced in [text], then its URLs and paths
  String scrub(Object? text) => MpvLogFilter.scrub('$text', secrets: secrets);
}

/// Flutter's frame times while a phase runs
class _FrameTimes {
  final _timings = <FrameTiming>[];
  bool _listening = false;
  bool _recording = false;

  void _add(List<FrameTiming> timings) {
    if (_recording) {
      _timings.addAll(timings);
    }
  }

  // The callback stays registered from the first phase to the end of the run: taking it off between phases turns
  // the engine's timing reports off, and the phases after the first then got no frame at all
  void start() {
    _timings.clear();
    _recording = true;
    if (!_listening) {
      SchedulerBinding.instance.addTimingsCallback(_add);
      _listening = true;
    }
  }

  /// End of a phase: the timings that come later belong to no phase
  void pause() => _recording = false;

  // Called when the run ends, whatever happened: the binding asserts on a callback it does not hold
  void stop() {
    _recording = false;
    if (_listening) {
      SchedulerBinding.instance.removeTimingsCallback(_add);
      _listening = false;
    }
  }

  static Map<String, Object?> _stats(List<double> values) {
    if (values.isEmpty) {
      return const {};
    }
    values.sort();
    double at(double q) => values[min(values.length - 1, (q * values.length).floor())];
    return {'p50': _round(at(0.5)), 'p90': _round(at(0.9)), 'p99': _round(at(0.99)), 'max': _round(values.last)};
  }

  /// Frames that took longer than [ms] from the start of their build to the end of their raster
  int slowFrames(int ms) => _timings.where((timing) => timing.totalSpan.inMilliseconds > ms).length;

  Map<String, Object?> summary(double refreshRate) {
    final budget = 1000 / (refreshRate > 0 ? refreshRate : 60);
    double ms(Duration duration) => duration.inMicroseconds / 1000;
    return {
      'frames': _timings.length,
      'buildMs': _stats([for (final timing in _timings) ms(timing.buildDuration)]),
      'rasterMs': _stats([for (final timing in _timings) ms(timing.rasterDuration)]),
      'totalMs': _stats([for (final timing in _timings) ms(timing.totalSpan)]),
      'overBudget': _timings.where((timing) => ms(timing.totalSpan) > budget).length,
      'budgetMs': _round(budget),
    };
  }
}

double _round(double value) => (value * 100).round() / 100;

/// What renderer C drew over a phase: its draws with a new frame of mpv and of the view alone, their times on the
/// plugin's render thread (and the part Flutter's raster thread could wait for), the sizes
Map<String, Object?>? _pluginSummary(ProjectionStats? stats) {
  if (stats == null) {
    return null;
  }
  Map<String, Object?>? times(List<double> values) {
    if (values.isEmpty) {
      return null;
    }
    final sorted = [...values]..sort();
    double at(double q) => sorted[min(sorted.length - 1, (sorted.length * q).floor())];
    return {'count': sorted.length, 'p50': _round(at(0.5)), 'p99': _round(at(0.99)), 'max': _round(sorted.last)};
  }

  return {
    'frames': stats.frames,
    'redraws': stats.redraws,
    'failed': stats.failed,
    'frameMs': ?times(stats.frameMs),
    'redrawMs': ?times(stats.redrawMs),
    'lockedMs': ?times(stats.lockedMs),
    'sizeMs': ?times(stats.sizeMs),
    'mpvMs': ?times(stats.mpvMs),
    'viewMs': ?times(stats.viewMs),
    'frame': [stats.frameWidth, stats.frameHeight],
    'output': [stats.outputWidth, stats.outputHeight],
    'error': ?stats.error,
  };
}

/// mpv's timing events of one phase (its dump-stats file: one line each, the time in nanoseconds then the event).
/// Flutter's frame times do not show the video: the texture is drawn by mpv on its own thread and Flutter only
/// composes the last one.
/// The frames mpv hands to the renderer do: "video-flip" ends when media_kit's render thread takes the frame
/// (vo_libmpv's flip_page waits for it), so a render that stalls, for example while mpv rebuilds its passes after an
/// option change, lengthens the interval between two ends. "glcb-render" is each render call, frames and redraws
/// alike (a parameter change while paused or between two frames is a redraw); "drop-vo" a frame dropped because it
/// came too late; "vo-delayed" a frame shown late.
class _MpvStats {
  static Map<String, Object?> summarize(String text) {
    final flipStarts = <String, int>{};
    final frames = <int>[];
    final flips = <double>[];
    final renders = <int>[];
    var dropped = 0;
    var delayed = 0;
    var lines = 0;
    final events = <String, int>{};
    for (final line in const LineSplitter().convert(text)) {
      final space = line.indexOf(' ');
      final time = space > 0 ? int.tryParse(line.substring(0, space)) : null;
      if (time == null) {
        continue;
      }
      lines++;
      final event = line.substring(space + 1).trim();
      // "value" lines carry a number before their name
      final name = event.startsWith('value ') ? 'value ${event.split(' ').last}' : event;
      events[name] = (events[name] ?? 0) + 1;
      switch (event) {
        case 'start video-flip':
          flipStarts['flip'] = time;
        case 'end video-flip':
          frames.add(time);
          final start = flipStarts.remove('flip');
          if (start != null) {
            flips.add((time - start) / 1e6);
          }
        case 'glcb-render':
          renders.add(time);
        case 'drop-vo':
          dropped++;
        case 'vo-delayed':
          delayed++;
      }
    }
    List<double> intervals(List<int> times) => [for (var i = 1; i < times.length; i++) (times[i] - times[i - 1]) / 1e6];
    final frameIntervals = intervals(frames);
    final renderIntervals = intervals(renders);
    final seconds = frames.length > 1 ? (frames.last - frames.first) / 1e9 : 0.0;
    return {
      'lines': lines,
      'frames': frames.length,
      'framesPerSecond': seconds > 0 ? _round((frames.length - 1) / seconds) : null,
      'frameIntervalMs': _FrameTimes._stats([...frameIntervals]),
      'frameIntervalsOver50': frameIntervals.where((ms) => ms > 50).length,
      'frameIntervalsOver100': frameIntervals.where((ms) => ms > 100).length,
      'flipWaitMs': _FrameTimes._stats(flips),
      'renders': renders.length,
      'redraws': max(0, renders.length - frames.length),
      'renderIntervalMs': _FrameTimes._stats([...renderIntervals]),
      'renderGapsOver50': renderIntervals.where((ms) => ms > 50).length,
      'dropVo': dropped,
      'voDelayed': delayed,
      'events': Map.fromEntries((events.entries.toList()..sort((a, b) => b.value - a.value)).take(12)),
    };
  }
}

/// Ends a measured wait early when the process grows past [_Config.memoryGuardMB] over its level at [arm]: the larger of
/// its private bytes and of its working set plus the GPU memory the driver holds for it (on the Intel UHD that is
/// system memory too)
class _MemoryGuard {
  _MemoryGuard(this.limitMB);

  final int limitMB;
  int? _baseMB;
  Map<String, Object?>? tripped;

  static int? _totalMB() {
    final gpu = GpuProcessMemory.sample();
    final shared = gpu?['sharedMB'];
    final dedicated = gpu?['dedicatedMB'];
    if (shared is! int || dedicated is! int) {
      return null;
    }
    return max(ProcessInfo.currentRss ~/ (1 << 20) + shared + dedicated, _WindowsProcess.privateMB() ?? 0);
  }

  void arm() {
    if (limitMB > 0 && _baseMB == null) {
      _baseMB = _totalMB();
    }
  }

  /// Waits [duration], or less when the guard trips; [onTrip] stops what grows
  Future<void> wait(Duration duration, Stopwatch watch, int Function() changes, void Function() onTrip) async {
    final base = _baseMB;
    if (limitMB <= 0 || base == null || tripped != null) {
      await Future<void>.delayed(duration);
      return;
    }
    final done = Completer<void>();
    final end = Timer(duration, () {
      if (!done.isCompleted) {
        done.complete();
      }
    });
    final check = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final total = _totalMB();
      if (done.isCompleted || total == null || total - base <= limitMB) {
        return;
      }
      onTrip();
      tripped = {
        'atSeconds': _round(watch.elapsedMilliseconds / 1000),
        'changes': changes(),
        'baseMB': base,
        'totalMB': total,
        'rssMB': ProcessInfo.currentRss ~/ (1 << 20),
        'privateMB': _WindowsProcess.privateMB(),
        'gpuMemory': GpuProcessMemory.sample(),
      };
      done.complete();
    });
    await done.future;
    end.cancel();
    check.cancel();
  }
}

/// Frames the framework built since the run started, to tell "no frame" from "no timing reported"
int _frameworkFrames = 0;

/// Handles, GDI and USER objects of the process, and whether COM is still set up on the window's thread (media_kit
/// #1449: each Player.dispose() on Windows left COM uninitialised, and drag and drop died after four)
class _WindowsProcess {
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _user32 = DynamicLibrary.open('user32.dll');
  static final _ole32 = DynamicLibrary.open('ole32.dll');

  static final _currentProcess = _kernel32.lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
  static final _currentProcessId = _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
  static final _currentThreadId = _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentThreadId');
  static final _handleCount = _kernel32
      .lookupFunction<Int32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
        'GetProcessHandleCount',
      );
  static final _guiResources = _user32.lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>(
    'GetGuiResources',
  );
  static final _memoryInfo = _kernel32
      .lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>, Uint32), int Function(int, Pointer<Uint8>, int)>(
        'K32GetProcessMemoryInfo',
      );

  /// The private bytes of this process in MiB (its commit charge), null off Windows. The graphics driver commits
  /// memory for the textures of a discrete GPU too, so this grows where the working set does not, and the commit
  /// limit of the PC is what ran out on 2026-10-09.
  static int? privateMB() {
    if (!Platform.isWindows) {
      return null;
    }
    // PROCESS_MEMORY_COUNTERS_EX on 64 bit Windows: 80 bytes, PrivateUsage last
    final counters = calloc<Uint8>(80);
    try {
      counters.cast<Uint32>().value = 80;
      if (_memoryInfo(_currentProcess(), counters, 80) == 0) {
        return null;
      }
      return (counters + 72).cast<Uint64>().value ~/ (1 << 20);
    } finally {
      calloc.free(counters);
    }
  }

  static final _findWindowEx = _user32
      .lookupFunction<
        IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
        int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
      >('FindWindowExW');
  static final _windowThreadProcessId = _user32
      .lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
        'GetWindowThreadProcessId',
      );
  static final _coInitializeEx = _ole32
      .lookupFunction<Int32 Function(Pointer<Void>, Uint32), int Function(Pointer<Void>, int)>('CoInitializeEx');
  static final _coUninitialize = _ole32.lookupFunction<Void Function(), void Function()>('CoUninitialize');
  static final _processTimes = _kernel32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
        int Function(int, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)
      >('GetProcessTimes');

  static final _setThreadExecutionState = _kernel32.lookupFunction<Uint32 Function(Uint32), int Function(int)>(
    'SetThreadExecutionState',
  );

  /// Keeps the screen and the computer awake while the runs go, as a video player does: on 2026-10-09 the owner's PC
  /// went into modern standby after its idle time in the middle of a run, which clamped the processor to 18 % of its
  /// speed and turned the screen off, and every figure after that was wrong
  static void keepDisplayOn(bool on) {
    if (Platform.isWindows) {
      // ES_CONTINUOUS, plus ES_SYSTEM_REQUIRED and ES_DISPLAY_REQUIRED while on
      _setThreadExecutionState(on ? 0x80000003 : 0x80000000);
    }
  }

  /// Whether the owner's session shows the lock screen (LogonUI runs): the app still draws and the timings hold, but
  /// what the screen shows is the lock screen, so the pixel reads say nothing then; null off Windows
  static bool? sessionLocked() {
    if (!Platform.isWindows) {
      return null;
    }
    final result = Process.runSync('tasklist', ['/FI', 'IMAGENAME eq LogonUI.exe', '/NH']);
    return '${result.stdout}'.toLowerCase().contains('logonui.exe');
  }

  /// Kernel and user processor time of this process so far, in milliseconds, null off Windows
  static int? cpuMs() {
    if (!Platform.isWindows) {
      return null;
    }
    final times = calloc<Uint64>(4);
    try {
      if (_processTimes(_currentProcess(), times, times + 1, times + 2, times + 3) == 0) {
        return null;
      }
      // FILETIME counts 100 ns steps
      return (times[2] + times[3]) ~/ 10000;
    } finally {
      calloc.free(times);
    }
  }

  static Map<String, Object?> sample() {
    if (!Platform.isWindows) {
      return const {};
    }
    final process = _currentProcess();
    final count = calloc<Uint32>();
    try {
      return {
        'handles': _handleCount(process, count) != 0 ? count.value : null,
        'gdiObjects': _guiResources(process, 0),
        'userObjects': _guiResources(process, 1),
        'ole': _ole(),
      };
    } finally {
      calloc.free(count);
    }
  }

  /// This process's top level Flutter window and its thread, null when none is found
  static (int, int)? window() {
    final pid = calloc<Uint32>();
    try {
      for (final name in [
        'IMMUCH360_DESKTOP_DEBUG_WINDOW',
        'IMMUCH360_DESKTOP_WINDOW',
        'FLUTTER_RUNNER_WIN32_WINDOW',
      ]) {
        final className = name.toNativeUtf16();
        try {
          var window = 0;
          while ((window = _findWindowEx(0, window, className, nullptr)) != 0) {
            final thread = _windowThreadProcessId(window, pid);
            if (pid.value == _currentProcessId()) {
              return (window, thread);
            }
          }
        } finally {
          calloc.free(className);
        }
      }
      return null;
    } finally {
      calloc.free(pid);
    }
  }

  static int? _windowThread() => window()?.$2;

  static String _ole() {
    final thread = _windowThread();
    if (thread == null) {
      return 'no window found';
    }
    if (thread != _currentThreadId()) {
      // Dart runs on another thread than the window here: OLE of the window's thread cannot be looked at from Dart
      return 'not on the window thread';
    }
    // COM, not OLE itself: the app registers no drop target yet (nothing calls OleInitialize, which answers S_OK the
    // first time whatever COM's state), while the runner sets COM up on this thread (CoInitializeEx in main.cpp), as
    // drag and drop and the file dialogs need it. S_FALSE: still set up; S_OK: the references were all taken off,
    // what #1449 does. Every call that succeeds is balanced.
    final result = _coInitializeEx(nullptr, 0x2);
    if (result == 0 || result == 1) {
      _coUninitialize();
    }
    return switch (result) {
      1 => 'set up',
      0 => 'was torn down',
      _ => 'error 0x${(result & 0xffffffff).toRadixString(16)}',
    };
  }
}

typedef _MonitorEnumNative = Int32 Function(IntPtr monitor, IntPtr dc, Pointer<Int32> rect, IntPtr data);

/// The screens of the PC and the window moved between them (spike 6, design 2.11): the panel of a hybrid laptop is
/// driven by one GPU and an external screen often by the other, and media_kit's texture may then cross adapters.
/// Also a look at the pixels of the window, as the screen shows them, to tell a black or frozen video from a playing
/// one. Windows only; the runner is per monitor DPI aware, so every figure is in physical pixels.
class _Screens {
  static final _user32 = DynamicLibrary.open('user32.dll');
  static final _gdi32 = DynamicLibrary.open('gdi32.dll');

  static final _enumDisplayMonitors = _user32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Void>, Pointer<NativeFunction<_MonitorEnumNative>>, IntPtr),
        int Function(int, Pointer<Void>, Pointer<NativeFunction<_MonitorEnumNative>>, int)
      >('EnumDisplayMonitors');
  static final _getMonitorInfo = _user32
      .lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>('GetMonitorInfoW');
  static final _monitorFromWindow = _user32.lookupFunction<IntPtr Function(IntPtr, Uint32), int Function(int, int)>(
    'MonitorFromWindow',
  );
  static final _setWindowPos = _user32
      .lookupFunction<
        Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int, int)
      >('SetWindowPos');
  static final _showWindow = _user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
    'ShowWindow',
  );
  static final _getClientRect = _user32
      .lookupFunction<Int32 Function(IntPtr, Pointer<Int32>), int Function(int, Pointer<Int32>)>('GetClientRect');
  static final _clientToScreen = _user32
      .lookupFunction<Int32 Function(IntPtr, Pointer<Int32>), int Function(int, Pointer<Int32>)>('ClientToScreen');
  static final _getDC = _user32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GetDC');
  static final _releaseDC = _user32.lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>('ReleaseDC');
  static final _getPixel = _gdi32.lookupFunction<Uint32 Function(IntPtr, Int32, Int32), int Function(int, int, int)>(
    'GetPixel',
  );

  /// The monitors: handle, whole rectangle, work area, primary, as GetMonitorInfoW gives them
  static List<({int handle, List<int> bounds, List<int> work, bool primary})> monitors() {
    final handles = <int>[];
    final callback = NativeCallable<_MonitorEnumNative>.isolateLocal((
      int monitor,
      int dc,
      Pointer<Int32> rect,
      int data,
    ) {
      handles.add(monitor);
      return 1;
    }, exceptionalReturn: 0);
    try {
      _enumDisplayMonitors(0, nullptr, callback.nativeFunction, 0);
    } finally {
      callback.close();
    }
    return [for (final handle in handles) ?_info(handle)];
  }

  static ({int handle, List<int> bounds, List<int> work, bool primary})? _info(int handle) {
    // MONITORINFOEXW: cbSize, rcMonitor, rcWork, dwFlags, szDevice[32]
    final info = calloc<Uint8>(104);
    try {
      info.cast<Uint32>().value = 104;
      if (_getMonitorInfo(handle, info) == 0) {
        return null;
      }
      final values = info.cast<Int32>();
      return (
        handle: handle,
        bounds: [values[1], values[2], values[3], values[4]],
        work: [values[5], values[6], values[7], values[8]],
        primary: (values[9] & 1) != 0,
      );
    } finally {
      calloc.free(info);
    }
  }

  /// The monitor named by [name]: "primary", "secondary" (the first other one) or a number in [monitors]' order
  static ({int handle, List<int> bounds, List<int> work, bool primary})? find(String name) {
    final all = monitors();
    final index = int.tryParse(name);
    if (index != null) {
      return index >= 0 && index < all.length ? all[index] : null;
    }
    return switch (name) {
      'primary' => all.where((monitor) => monitor.primary).firstOrNull,
      'secondary' => all.where((monitor) => !monitor.primary).firstOrNull,
      _ => null,
    };
  }

  /// Index in [monitors] of the monitor that holds most of the window
  static int? windowMonitor() {
    final window = _WindowsProcess.window();
    if (window == null) {
      return null;
    }
    final handle = _monitorFromWindow(window.$1, 2);
    final index = monitors().indexWhere((monitor) => monitor.handle == handle);
    return index < 0 ? null : index;
  }

  /// Puts the window in the middle of the work area of [name] at [size], in physical pixels. Twice: the first move
  /// to a screen of another scale makes the runner resize the window to keep its logical size (WM_DPICHANGED), the
  /// second gives it back the size asked, so that both screens draw the same number of pixels.
  static Future<String?> moveTo(String name, (int, int) size) async {
    final window = _WindowsProcess.window();
    final monitor = find(name);
    if (window == null || monitor == null) {
      return window == null ? 'no window found' : 'no screen "$name"';
    }
    final work = monitor.work;
    final width = min(size.$1, work[2] - work[0]);
    final height = min(size.$2, work[3] - work[1]);
    final x = work[0] + (work[2] - work[0] - width) ~/ 2;
    final y = work[1] + (work[3] - work[1] - height) ~/ 2;
    // SW_RESTORE first: a maximised window does not move; then HWND_TOPMOST with SWP_NOACTIVATE: on a screen where
    // other windows are open the test window could sit behind them, and the pixels read would be theirs
    _showWindow(window.$1, 9);
    for (var pass = 0; pass < 2; pass++) {
      _setWindowPos(window.$1, -1, x, y, width, height, 0x0010);
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    return null;
  }

  /// A grid of 7 x 7 points of the window's client area, read from the screen three times 300 ms apart: their mean
  /// brightness, how many are black, and how many changed between the first and the last read (a playing video
  /// changes, a frozen or black one does not). The points are sampled out of the measured phases: reading the
  /// screen waits for the compositor.
  static Future<Map<String, Object?>> pixels() async {
    final window = _WindowsProcess.window();
    if (window == null) {
      return const {'error': 'no window found'};
    }
    final rect = calloc<Int32>(4);
    final point = calloc<Int32>(2);
    try {
      if (_getClientRect(window.$1, rect) == 0 || _clientToScreen(window.$1, point) == 0) {
        return const {'error': 'no client area'};
      }
      final left = point[0];
      final top = point[1];
      final width = rect[2] - rect[0];
      final height = rect[3] - rect[1];
      final reads = <List<int>>[];
      for (var pass = 0; pass < 3; pass++) {
        if (pass > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        final dc = _getDC(0);
        try {
          reads.add([
            for (var row = 0; row < 7; row++)
              for (var column = 0; column < 7; column++)
                _getPixel(dc, left + width * (column + 1) ~/ 8, top + height * (row + 1) ~/ 8),
          ]);
        } finally {
          _releaseDC(0, dc);
        }
      }
      double luma(int colour) =>
          0.2126 * (colour & 0xff) + 0.7152 * ((colour >> 8) & 0xff) + 0.0722 * ((colour >> 16) & 0xff);
      final valid = [
        for (final colour in reads.first)
          if (colour != 0xffffffff) colour,
      ];
      var changed = 0;
      for (var i = 0; i < reads.first.length; i++) {
        if ((luma(reads.first[i]) - luma(reads.last[i])).abs() > 8) {
          changed++;
        }
      }
      return {
        'points': reads.first.length,
        'unreadable': reads.first.length - valid.length,
        'meanLuma': valid.isEmpty ? null : _round(valid.map(luma).reduce((a, b) => a + b) / valid.length),
        'blackPoints': valid.where((colour) => luma(colour) < 16).length,
        'changedPoints': changed,
      };
    } finally {
      calloc.free(rect);
      calloc.free(point);
    }
  }

  /// What a record says of the screen the window is on now
  static Map<String, Object?> describe(WidgetTester tester, String? asked) {
    final index = windowMonitor();
    final all = monitors();
    final monitor = index == null ? null : all[index];
    return {
      'asked': asked,
      'monitor': index,
      'primary': monitor?.primary,
      'monitorSize': monitor == null
          ? null
          : [monitor.bounds[2] - monitor.bounds[0], monitor.bounds[3] - monitor.bounds[1]],
      'devicePixelRatio': tester.view.devicePixelRatio,
      'refreshRate': tester.view.display.refreshRate,
      'windowPhysicalSize': [tester.view.physicalSize.width, tester.view.physicalSize.height],
    };
  }
}

/// A file of this computer as a share, so that the bridge's own cost is measured without a network
class _LocalFileSystem implements NetworkFileSystem {
  _LocalFileSystem(this._file);

  final File _file;

  @override
  final NetworkSource source = const NetworkSource(
    id: 'measure-local',
    type: NetworkSourceType.smb,
    name: 'local',
    host: 'localhost',
  );

  @override
  Future<List<NetworkEntry>> list(String path) async => const [];

  @override
  Future<NetworkEntry> stat(String path) async =>
      NetworkEntry(sourceId: source.id, path: path, isDirectory: false, size: await _file.length());

  // A file opened per read: the bridge and the players read several parts at once, and a shared position would mix
  // them up
  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    final file = await _file.open();
    try {
      await file.setPosition(offset);
      return await file.read(length);
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> close() async {}
}

/// An asset of an Immich server read by ranges with an API key, until the app's own ImmichServerFileSystem exists
/// (plan 2.2, V-FLAT); the key stays in Dart, libmpv only sees the bridge URL
class _ServerFileSystem implements NetworkFileSystem {
  _ServerFileSystem(this._base, this._apiKey);

  final Uri _base;
  final String _apiKey;
  final _client = http.Client();
  late final _ranges = HttpRangeReader(send: _send, fail: _fail);

  @override
  final NetworkSource source = const NetworkSource(
    id: 'measure-server',
    type: NetworkSourceType.webdav,
    name: 'server',
    host: 'server',
  );

  Uri _uriOf(String path) {
    final (id, playback) = path.endsWith('/playback')
        ? (path.substring(0, path.length - '/playback'.length), true)
        : (path, false);
    return _base.resolve('api/assets/${id.replaceAll('/', '')}/${playback ? 'video/playback' : 'original'}');
  }

  Future<(http.StreamedResponse, Uri)> _send(String method, Uri uri, {Map<String, String> headers = const {}}) async {
    final request = http.Request(method, uri)
      ..headers.addAll(headers)
      ..headers['x-api-key'] = _apiKey;
    return (await _client.send(request), uri);
  }

  Future<Never> _fail(http.StreamedResponse response, String key) async {
    await response.stream.drain<void>();
    throw NetworkFileSystemException('The server answered ${response.statusCode}');
  }

  @override
  Future<List<NetworkEntry>> list(String path) async => const [];

  @override
  Future<NetworkEntry> stat(String path) async {
    final (response, _) = await _send('GET', _uriOf(path), headers: {'range': 'bytes=0-0'});
    await response.stream.drain<void>();
    final total = RegExp(r'/(\d+)$').firstMatch(response.headers['content-range'] ?? '')?.group(1);
    if (response.statusCode != 206 || total == null) {
      throw NetworkFileSystemException('No range answer from the server (${response.statusCode})');
    }
    return NetworkEntry(sourceId: source.id, path: path, isDirectory: false, size: int.parse(total));
  }

  @override
  Future<Uint8List> readRange(String path, int offset, int length) => _ranges.read(_uriOf(path), path, offset, length);

  @override
  Future<void> close() async => _client.close();
}

Future<NetworkFileSystem> _openBridgeSource(_Config config, String kind, String path) async {
  final env = config.env;
  switch (kind) {
    case 'local':
      return _LocalFileSystem(File(path));
    case 'smb':
      return SmbFileSystem.open(
        NetworkSource(
          id: 'measure-smb',
          type: NetworkSourceType.smb,
          name: 'measure',
          host: env['IMMUCH360_MEASURE_SMB_HOST'] ?? '',
          share: env['IMMUCH360_MEASURE_SMB_SHARE'] ?? '',
          username: env['IMMUCH360_MEASURE_SMB_USER'] ?? '',
        ),
        env['IMMUCH360_MEASURE_SMB_PASSWORD'],
      );
    case 'webdav':
      final url = Uri.parse(env['IMMUCH360_MEASURE_WEBDAV_URL'] ?? '');
      return WebDavFileSystem.open(
        NetworkSource(
          id: 'measure-webdav',
          type: NetworkSourceType.webdav,
          name: 'measure',
          host: url.host,
          port: url.hasPort ? url.port : null,
          share: url.path,
          username: env['IMMUCH360_MEASURE_WEBDAV_USER'] ?? '',
          useTls: url.scheme == 'https',
        ),
        env['IMMUCH360_MEASURE_WEBDAV_PASSWORD'],
      );
    case 'server':
      final base = Uri.parse(env['IMMUCH360_MEASURE_SERVER_URL'] ?? '');
      final key = env['IMMUCH360_MEASURE_API_KEY'] ?? '';
      if (!base.hasScheme || key.isEmpty) {
        throw const NetworkFileSystemException('IMMUCH360_MEASURE_SERVER_URL and IMMUCH360_MEASURE_API_KEY are needed');
      }
      return _ServerFileSystem(base.path.endsWith('/') ? base : base.replace(path: '${base.path}/'), key);
  }
  throw NetworkFileSystemException('Unknown bridge source kind "$kind"');
}

/// What the run plays, a widget that fills the window with it
class _VideoPage extends StatelessWidget {
  const _VideoPage(this.controller, {this.ticker = true});

  final VideoController? controller;
  final bool ticker;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: ColoredBox(
      color: Colors.black,
      child: controller == null
          ? const SizedBox.expand()
          : Stack(
              children: [
                SizedBox.expand(
                  child: Video(controller: controller!, controls: NoVideoControls, wakelock: false),
                ),
                if (ticker) const Positioned(left: 0, top: 0, width: 4, height: 4, child: _Ticker()),
              ],
            ),
    ),
  );
}

/// A 4 x 4 point that changes colour every frame. A new video frame alone makes the engine compose the last layer
/// tree again, and such frames report no FrameTiming: without a widget that redraws, the frame times only count the
/// frames something else asked for. The app redraws every frame too while the controls fade or a 360 view is
/// dragged, so the times measured with it are the ones that matter.
class _Ticker extends StatefulWidget {
  const _Ticker();

  @override
  State<_Ticker> createState() => _TickerState();
}

class _TickerState extends State<_Ticker> with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(vsync: this, duration: const Duration(seconds: 1))
    ..repeat();

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _animation,
    builder: (context, _) => ColoredBox(color: Color.lerp(Colors.black, Colors.white, _animation.value)!),
  );
}

class _Harness {
  _Harness(this.config);

  final _Config config;
  late final Directory work;

  Future<void> setUp() async {
    work = await Directory.systemTemp.createTemp('immuch360_measure_');
    await Directory(config.outDir).create(recursive: true);
  }

  Future<void> tearDown() => work.delete(recursive: true);

  Future<void> report(Map<String, Object?> record) async {
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final name = '$stamp-${record['kind']}-${record['label']}.json';
    final text = jsonEncode(record);
    await File(p.join(config.outDir, name)).writeAsString(text);
    // ignore: avoid_print
    print('MEASURE $text');
  }

  Map<String, Object?> screen(WidgetTester tester) {
    final view = tester.view;
    final display = view.display;
    return {
      'given': config.gpuLabel == null && config.screenLabel == null
          ? null
          : {'gpu': config.gpuLabel, 'screen': config.screenLabel},
      'displaySize': [display.size.width, display.size.height],
      'devicePixelRatio': view.devicePixelRatio,
      'refreshRate': display.refreshRate,
      'windowPhysicalSize': [view.physicalSize.width, view.physicalSize.height],
    };
  }

  /// The fixed texture size of the "window" mode: the window's physical size with its height capped (design 2.11);
  /// null in the other modes, where the texture follows the video
  (int, int)? renderSize(WidgetTester tester) {
    if (config.renderMode != 'window') {
      return null;
    }
    final size = tester.view.physicalSize;
    final scale = size.height > config.maxRenderHeight ? config.maxRenderHeight / size.height : 1.0;
    return ((size.width * scale).round(), (size.height * scale).round());
  }

  /// The cap media_kit_video applies to every texture it sizes after the video (its IMMUCH360-NOTE.md, patch 3):
  /// the app's in "app" mode, none in "source" mode (0: DesktopPlayer.create only sets it when it is null). Returns
  /// the value before, to be given back when the run ends.
  int? applyRenderCap() {
    final before = VideoController.maxOutputHeight;
    VideoController.maxOutputHeight = switch (config.renderMode) {
      'app' => config.maxRenderHeight,
      'source' => 0,
      _ => before,
    };
    return before;
  }

  static List<double>? textureOf(VideoController? controller) {
    final rect = controller?.rect.value;
    return rect == null ? null : [rect.width, rect.height];
  }

  Future<String?> shaderFile() async {
    final given = config.shader;
    if (given == null) {
      return null;
    }
    if (given != 'probe') {
      return given;
    }
    final file = File(p.join(work.path, 'probe_hook.glsl'));
    await file.writeAsString(_probeHook);
    return file.path;
  }

  Future<Map<String, String>> read(NativePlayer native, List<String> names) async => {
    for (final name in names) name: config.scrub(await native.getProperty(name, waitForInitialization: false)),
  };

  /// Plays what [open] opens in a window sized player, then measures each phase of [Config.paramRates]
  Future<Map<String, Object?>> playAndMeasure(
    WidgetTester tester, {
    required String kind,
    required String label,
    required Future<String?> Function(Player player) open,
    List<String> secrets = const [],
    bool streamed = false,
  }) async {
    final screens = Platform.isWindows ? config.screensOf(label) : const <String>[];
    if (screens.isNotEmpty) {
      // On the first screen before the texture is made: the render size follows the window there
      await _Screens.moveTo(screens.first, config.windowSize);
      await tester.pump();
    }
    final logs = MpvLogFilter(secrets: [...config.secrets, ...secrets]);
    final player = Player(configuration: const PlayerConfiguration(logLevel: MPVLogLevel.v));
    final native = player.platform! as NativePlayer;
    final logSubscription = player.stream.log.listen(logs.add);
    final errors = <String>[];
    final errorSubscription = player.stream.error.listen((error) => errors.add(config.scrub(error)));
    var buffering = Duration.zero;
    var bufferingCount = 0;
    Stopwatch? bufferingSince;
    final bufferingSubscription = player.stream.buffering.listen((isBuffering) {
      if (isBuffering && bufferingSince == null) {
        bufferingSince = Stopwatch()..start();
        bufferingCount++;
      } else if (!isBuffering && bufferingSince != null) {
        buffering += bufferingSince!.elapsed;
        bufferingSince = null;
      }
    });
    final size = renderSize(tester);
    final capBefore = applyRenderCap();
    final controller = VideoController(
      player,
      configuration: VideoControllerConfiguration(hwdec: config.hwdec, width: size?.$1, height: size?.$2),
    );
    final record = <String, Object?>{
      'phase': config.phase,
      'kind': kind,
      'label': label,
      'buildMode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
      'screen': screen(tester),
      'renderMode': config.renderMode,
      'renderSize': size == null
          ? (config.renderMode == 'app' ? 'video, at most ${config.maxRenderHeight} lines' : 'video')
          : [size.$1, size.$2],
      'hwdecOption': config.hwdec,
      'options': config.appOptions ? 'app' : 'mediakit',
      'ticker': config.ticker,
      'sessionLocked': _WindowsProcess.sessionLocked(),
    };
    final frameTimes = _FrameTimes();
    PluginRenderer? plugin;
    try {
      await tester.pumpWidget(_VideoPage(controller, ticker: config.ticker));
      // media_kit turns cache-on-disk on, and mpv has no cache folder without a config folder
      await native.setProperty('demuxer-cache-dir', work.path);
      if (config.appOptions) {
        // The app's players set these after media_kit's own, as DesktopPlayer does
        for (final MapEntry(:key, :value) in {
          ...DesktopPlayerOptions.common(PlayerKind.playback),
          ...DesktopPlayerOptions.forOpen(PlayerKind.playback, streamed: streamed),
        }.entries) {
          await native.setProperty(key, value);
        }
      }
      for (final (name, value) in config.mpvSet) {
        await native.setProperty(name, value);
      }
      if (config.mpvSet.isNotEmpty) {
        record['mpvSet'] = [for (final (name, value) in config.mpvSet) config.scrub('$name=$value')];
      }
      final shader = await shaderFile();
      if (shader != null) {
        await native.setProperty('glsl-shaders', shader);
        record['shader'] = config.shader == 'probe' ? 'probe' : p.basename(shader);
        record['paramProperty'] = config.paramProperty;
      }
      if (config.pluginRenderer) {
        // Attached before the file opens, as the 360 page does, so that the first texture already is the view
        plugin = PluginRenderer.forController(controller, maxOutputHeight: config.maxRenderHeight);
        final attached = await plugin.attach(
          projection: PluginProjection.equirect(),
          outputSize: tester.view.physicalSize,
          tier: config.pluginTier,
          view: config.pluginView((config.paramMin + config.paramMax) / 2),
        );
        record['plugin'] = {
          'ok': attached.ok,
          'reason': attached.reason,
          'tier': attached.tier?.name,
          'glRenderer': attached.glRenderer,
          'output': attached.outputSize == null ? null : [attached.outputSize!.width, attached.outputSize!.height],
        };
        if (!attached.ok) {
          throw StateError('renderer C refused: ${attached.reason}');
        }
      }
      // The template of the "glsl-shaders" channel: the shader text, written again for each value
      final template = shader != null && config.paramProperty == 'glsl-shaders'
          ? await File(shader).readAsString()
          : null;
      var reloads = 0;
      // One change of the view, through the channel the run measures
      void change(double value) {
        final text = value.toStringAsFixed(3);
        if (plugin != null) {
          // A uniform of the plugin's pass: nothing of mpv changes
          plugin.setView(config.pluginView(value));
        } else if (template != null) {
          final file = File(p.join(work.path, 'reload-${reloads++}.glsl'));
          file.writeAsStringSync(template.replaceAll('@VALUE@', text));
          unawaited(native.setProperty('glsl-shaders', file.path, waitForInitialization: false));
        } else if (config.paramProperty == 'glsl-shader-opts') {
          final opts = config.paramFixed.isEmpty
              ? '${config.paramName}=$text'
              : '${config.paramName}=$text,${config.paramFixed}';
          unawaited(native.setProperty('glsl-shader-opts', opts, waitForInitialization: false));
        } else {
          unawaited(native.setProperty(config.paramProperty, text, waitForInitialization: false));
        }
      }

      var statsFiles = 0;
      // mpv's timing events go to a new file for each phase; an empty name closes the file, which flushes it
      Future<File?> startStats() async {
        if (!config.mpvStats) {
          return null;
        }
        final file = File(p.join(work.path, 'mpv-stats-${statsFiles++}.txt'));
        await native.setProperty('dump-stats', file.path);
        return file;
      }

      Future<Map<String, Object?>?> endStats(File? file) async {
        if (file == null) {
          return null;
        }
        await native.setProperty('dump-stats', '');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!file.existsSync()) {
          return {'error': 'no stats file'};
        }
        final summary = _MpvStats.summarize(await file.readAsString());
        await file.delete();
        return summary;
      }

      // The phases of a run with several screens outlast a 30 s clip: it plays again from the start
      await native.setProperty('loop-file', 'inf');
      final rssBefore = ProcessInfo.currentRss;
      final gpuBefore = GpuProcessMemory.sample();
      final opened = Stopwatch()..start();
      record['source'] = await open(player);
      await controller.waitUntilFirstFrameRendered.timeout(const Duration(seconds: 30));
      record['firstFrameMs'] = opened.elapsedMilliseconds;
      record['texture'] = textureOf(controller);
      await player.play();
      // Lets the decoder settle (and hwdec-current tell what it got) before the first phase
      await Future<void>.delayed(const Duration(seconds: 3));
      record['mpv'] = await read(native, _properties);
      final refreshRate = tester.view.display.refreshRate;
      final phases = <Map<String, Object?>>[];
      final guard = _MemoryGuard(config.memoryGuardMB)..arm();
      for (final (index, screenName) in (screens.isEmpty ? const <String?>[null] : screens).indexed) {
        if (index > 0) {
          // Moved while the video plays, as a user drags the window from one screen to the other
          await _Screens.moveTo(screenName!, config.windowSize);
          await tester.pump();
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        for (final rate in config.ratesOf(label)) {
          if (rate > 0 && shader == null && plugin == null || guard.tripped != null) {
            continue;
          }
          final before = await read(native, _counters);
          final markersBefore = Map.of(logs.markers);
          final bufferingBefore = buffering;
          var changes = 0;
          final watch = Stopwatch()..start();
          final statsFile = await startStats();
          Timer? timer;
          timer = rate <= 0
              ? null
              : Timer.periodic(Duration(microseconds: 1000000 ~/ rate), (_) {
                  // A sweep over the parameter's range every four seconds, as a drag would do
                  final t = (watch.elapsedMilliseconds % 4000) / 4000;
                  final value = config.paramMin + (config.paramMax - config.paramMin) * (0.5 - 0.5 * cos(2 * pi * t));
                  changes++;
                  change(value);
                });
          await plugin?.stats();
          final frameworkBefore = _frameworkFrames;
          // How late a 10 ms timer of this isolate fires: the bridge and the HTTP reads run on it, as the widgets do,
          // so a late timer tells a busy UI isolate from a slow raster thread
          final lateness = <int>[];
          final tick = Stopwatch()..start();
          final isolateTimer = Timer.periodic(const Duration(milliseconds: 10), (_) {
            lateness.add(tick.elapsedMilliseconds - 10);
            tick.reset();
          });
          frameTimes.start();
          final cpuBefore = _WindowsProcess.cpuMs();
          await guard.wait(Duration(seconds: config.seconds), watch, () => changes, () => timer?.cancel());
          final cpuAfter = _WindowsProcess.cpuMs();
          frameTimes.pause();
          isolateTimer.cancel();
          lateness.sort();
          timer?.cancel();
          final after = await read(native, _counters);
          final pluginStats = await plugin?.stats();
          final mpvStats = await endStats(statsFile);
          phases.add({
            'changesPerSecond': rate,
            'changes': changes,
            'memoryGuard': ?guard.tripped,
            'mpvStats': ?mpvStats,
            'plugin': ?_pluginSummary(pluginStats),
            'seconds': _round(watch.elapsedMilliseconds / 1000),
            for (final name in _counters)
              name: (int.tryParse(after[name] ?? '') ?? 0) - (int.tryParse(before[name] ?? '') ?? 0),
            'flutter': frameTimes.summary(refreshRate),
            'frameworkFrames': _frameworkFrames - frameworkBefore,
            'slowFrames': frameTimes.slowFrames(100),
            'isolateLateMs': lateness.isEmpty
                ? null
                : {
                    'p99': lateness[min(lateness.length - 1, (lateness.length * 0.99).floor())],
                    'max': lateness.last,
                    'over50': lateness.where((late) => late > 50).length,
                  },
            'bufferingMs': (buffering - bufferingBefore).inMilliseconds,
            'dumbModeLines': logs.markers['dumb mode']! - markersBefore['dumb mode']!,
            'disablingLines': logs.markers['Disabling']! - markersBefore['Disabling']!,
            'hwdecCurrent': config.scrub(await native.getProperty('hwdec-current', waitForInitialization: false)),
            'voPasses': (await native.getProperty('vo-passes', waitForInitialization: false)).length,
            'rssMB': ProcessInfo.currentRss ~/ (1 << 20),
            'privateMB': _WindowsProcess.privateMB(),
            'gpuMemory': GpuProcessMemory.sample(),
            'texture': textureOf(controller),
            // Processor time of the whole process over the phase, in logical processors busy (24 on the owner's PC):
            // a software decoder shows here and nowhere else
            'cpuCores': cpuBefore == null || cpuAfter == null
                ? null
                : _round((cpuAfter - cpuBefore) / max(1, watch.elapsedMilliseconds)),
            if (Platform.isWindows) ...{
              'screen': _Screens.describe(tester, screenName),
              'pixels': await _Screens.pixels(),
            },
          });
        }
      }
      record['phases'] = phases;
      if (plugin != null) {
        // Five pixels of the plugin's output, read back after its next draw: the frame reached the texture
        // Flutter shows (the screen's own pixels are in each phase)
        await plugin.stats(probe: true);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final probed = await plugin.stats();
        record['pluginProbe'] = probed?.probe == null
            ? null
            : {
                for (final (index, name) in const ['centre', 'top', 'bottom', 'left', 'right'].indexed)
                  name: '#${(probed!.probe![index] & 0xffffff).toRadixString(16).padLeft(6, '0')}',
              };
      }
      if (config.redrawOf(label) > 0 &&
          (shader != null || plugin != null) &&
          Platform.isWindows &&
          guard.tripped == null) {
        record['redraw'] = await pausedRedraw(
          tester,
          player,
          config.redrawOf(label),
          change,
          startStats,
          endStats,
          guard,
          plugin,
        );
      }
      record['buffering'] = {'count': bufferingCount, 'ms': buffering.inMilliseconds};
      record['memory'] = {
        'rssBeforeMB': rssBefore ~/ (1 << 20),
        'rssAfterMB': ProcessInfo.currentRss ~/ (1 << 20),
        'maxRssMB': ProcessInfo.maxRss ~/ (1 << 20),
        'gpuBefore': gpuBefore,
        'gpuAfter': GpuProcessMemory.sample(),
      };
      record['process'] = _WindowsProcess.sample();
    } catch (error, stack) {
      record['failure'] = config.scrub(error);
      // Where it failed, without paths (scrubbed): the first frames of the harness and the app
      record['failureAt'] = [for (final line in '$stack'.split('\n').take(6)) config.scrub(line)];
    } finally {
      frameTimes.stop();
      record['errors'] = errors;
      record['logMarkers'] = logs.markers;
      record['log'] = logs.lines;
      record['logLinesDropped'] = logs.dropped;
      await plugin?.dispose();
      await tester.pumpWidget(const _VideoPage(null));
      await bufferingSubscription.cancel();
      await errorSubscription.cancel();
      await logSubscription.cancel();
      await player.dispose();
      VideoController.maxOutputHeight = capBefore;
      if (config.memoryGuardMB > 0) {
        // A closed player's textures go back to the driver a moment later; the next clip opens once they have, so
        // that two players' memory never adds up
        await Future<void>.delayed(const Duration(seconds: 5));
        record['privateAfterCloseMB'] = _WindowsProcess.privateMB();
      }
    }
    return record;
  }

  /// Spike 3: a paused frame redrawn after changes of the view (design 2.10). While paused every render is a redraw
  /// that a change asked for, and changes come faster (60 a second) than a redraw that rebuilds mpv's passes can
  /// follow, so the render calls in mpv's timing events give the cost of one redraw: the interval between two of them
  /// is the time media_kit's render thread spent on the previous one. The screen itself is not read: the owner's
  /// session may be locked while the harness runs, and the screen then shows the lock screen.
  Future<Map<String, Object?>> pausedRedraw(
    WidgetTester tester,
    Player player,
    int redrawSeconds,
    void Function(double value) change,
    Future<File?> Function() startStats,
    Future<Map<String, Object?>?> Function(File? file) endStats,
    _MemoryGuard guard,
    PluginRenderer? plugin,
  ) async {
    await player.pause();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await plugin?.stats();
    final frameTimes = _FrameTimes()..start();
    final statsFile = await startStats();
    var changes = 0;
    final watch = Stopwatch()..start();
    final timer = Timer.periodic(const Duration(microseconds: 1000000 ~/ 60), (_) {
      changes++;
      change(changes.isEven ? config.paramMin : config.paramMax);
    });
    await guard.wait(Duration(seconds: redrawSeconds), watch, () => changes, timer.cancel);
    timer.cancel();
    frameTimes.pause();
    final pluginStats = await plugin?.stats();
    final stats = await endStats(statsFile);
    final seconds = watch.elapsedMilliseconds / 1000;
    final flutter = frameTimes.summary(tester.view.display.refreshRate);
    frameTimes.stop();
    final renders = (stats?['renders'] as int?) ?? 0;
    return {
      'changes': changes,
      'seconds': _round(seconds),
      'rendersPerSecond': _round(renders / max(0.001, seconds)),
      'memoryGuard': ?guard.tripped,
      'mpvStats': stats,
      'plugin': ?_pluginSummary(pluginStats),
      'flutter': flutter,
    };
  }

  /// Spike 1: the raw throughput of the bridge for one file, then the same file played through it
  Future<Map<String, Object?>> bridge(WidgetTester tester, String label, String entry) async {
    final separator = entry.indexOf(':');
    final kind = separator > 0 ? entry.substring(0, separator) : entry;
    final path = separator > 0 ? entry.substring(separator + 1) : '';
    final record = <String, Object?>{'phase': config.phase, 'kind': 'bridge', 'label': label, 'source': kind};
    final bridge = LocalMediaBridge();
    NetworkFileSystem? fileSystem;
    try {
      fileSystem = await _openBridgeSource(config, kind, path);
      await bridge.start();
      bridge.register(fileSystem);
      // The bridge serves paths from the root of the source; a local file is served under its name
      final served = kind == 'local' ? p.basename(path) : path;
      final size = (await fileSystem.stat(kind == 'local' ? served : path)).size ?? 0;
      final url = bridge.urlFor(fileSystem.source.id, served);
      record['fileMB'] = _round(size / (1 << 20));

      // Raw read through the bridge: up to 512 MiB or 30 seconds, whichever comes first
      final client = HttpClient();
      final watch = Stopwatch()..start();
      var bytes = 0;
      int? firstByteMs;
      try {
        final request = await client.getUrl(url);
        final response = await request.close();
        await for (final chunk in response) {
          firstByteMs ??= watch.elapsedMilliseconds;
          bytes += chunk.length;
          if (bytes >= 512 << 20 || watch.elapsed > const Duration(seconds: 30)) {
            break;
          }
        }
      } finally {
        client.close(force: true);
      }
      final seconds = watch.elapsedMicroseconds / 1e6;
      record['read'] = {
        'MB': _round(bytes / (1 << 20)),
        'seconds': _round(seconds),
        'MBps': _round(bytes / (1 << 20) / seconds),
        'Mbitps': _round(bytes * 8 / 1e6 / seconds),
        'firstByteMs': firstByteMs,
      };
      final played = await playAndMeasure(
        tester,
        kind: 'bridge',
        label: label,
        secrets: [url.toString(), ...url.pathSegments.take(1)],
        streamed: true,
        open: (player) async {
          await player.open(Media(url.toString()));
          return kind;
        },
      );
      final mpv = played['mpv'] as Map<String, String>?;
      final duration = double.tryParse(mpv?['duration'] ?? '') ?? 0;
      record['fileMbitps'] = duration > 0 ? _round(size * 8 / 1e6 / duration) : null;
      record['playback'] = played;
    } catch (error) {
      record['failure'] = config.scrub(error);
    } finally {
      await bridge.stop();
      await fileSystem?.close();
    }
    return record;
  }

  /// The app's own path (plan 2.4, V-FLAT): the reference played by DesktopVideoView and its controller from the
  /// player pool, read through the media bridge as every share video is, then a frame of it taken by the thumbnail
  /// grabber, from the bridge and from the file. What the viewer and the network page do, without a server or a share.
  Future<Map<String, Object?>> appPlayer(WidgetTester tester) async {
    final seconds = min(config.seconds, 5);
    final record = <String, Object?>{
      'phase': config.phase,
      'kind': 'app',
      'label': 'reference',
      'buildMode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
      'screen': screen(tester),
    };
    final reference = await aviReference(work, width: 640, height: 360, frames: 90);
    final bridge = LocalMediaBridge();
    final fileSystem = _LocalFileSystem(reference);
    MediaKitVideoPlayerController? video;
    final steps = <String>[];
    record['steps'] = steps;
    final watch = Stopwatch()..start();
    void step(String name) => steps.add('${watch.elapsedMilliseconds} $name');
    // The app's video loggers, redacted, in the output: what the player did when a step does not come
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.FINE;
    final logs = Logger.root.onRecord
        .where(
          (log) =>
              log.loggerName.startsWith('Desktop') ||
              log.loggerName.startsWith('Player') ||
              log.loggerName.startsWith('VideoThumbnail') ||
              log.loggerName == 'MediaBridge',
        )
        .listen((log) => debugPrint('LOG ${log.loggerName} ${log.level.name}: ${config.scrub(log.message)}'));
    try {
      await bridge.start();
      bridge.register(fileSystem);
      final url = bridge.urlFor(fileSystem.source.id, p.basename(reference.path)).toString();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: ColoredBox(
              color: Colors.black,
              child: SizedBox.expand(
                child: DesktopVideoView(
                  pool: desktopPlayerPool,
                  resolve: (source) async => source.path,
                  onViewReady: (controller) => video = controller as MediaKitVideoPlayerController,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      step('view built');
      final player = video!;
      final ready = Completer<void>();
      player.onPlaybackReady.addListener(() {
        if (!ready.isCompleted) {
          ready.complete();
        }
      });
      // Played time, summed over the loops of the three second reference
      var played = 0;
      var last = 0;
      player.onPlaybackPositionChanged.addListener(() {
        final now = player.onPlaybackPositionChanged.value;
        if (now > last) {
          played += now - last;
        }
        last = now;
      });
      await player.setLoop(true);
      await player.setVolume(1);
      await player
          .loadVideoSource(await VideoSource.init(path: url, type: VideoSourceType.network))
          .timeout(const Duration(seconds: 30));
      step('loaded');
      await ready.future.timeout(const Duration(seconds: 30));
      step('ready');
      record['videoInfo'] = player.videoInfo?.toJson();
      await player.play().timeout(const Duration(seconds: 10));
      step('playing');
      await player.videoController.value?.waitUntilFirstFrameRendered.timeout(const Duration(seconds: 10));
      step('first frame');
      final texture = player.videoController.value?.rect.value;
      record['texture'] = texture == null ? null : [texture.width, texture.height];
      played = 0;
      last = player.onPlaybackPositionChanged.value;
      await Future<void>.delayed(Duration(seconds: seconds));
      record['playedMs'] = played;
      record['seconds'] = seconds;
      record['status'] = player.onPlaybackStatusChanged.value.name;
      record['error'] = player.onError.value;
      await player.pause();

      step('played');
      final grabber = VideoThumbnailGrabber.shared;
      final fromBridge = await grabber.grab(
        url,
        time: const Duration(seconds: 1),
        box: (width: 320, height: 320, cover: true),
      );
      final fromFile = await grabber.grab(
        reference.path,
        time: const Duration(seconds: 1),
        box: (width: 400, height: 1600, cover: false),
      );
      bool isJpeg(List<int>? bytes) => bytes != null && bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
      record['grab'] = {
        'bridgeBytes': fromBridge?.length,
        'bridgeJpeg': isJpeg(fromBridge),
        'fileBytes': fromFile?.length,
        'fileJpeg': isJpeg(fromFile),
      };
      step('grabbed');
      record['pool'] = {'created': desktopPlayerPool.created, 'disposed': desktopPlayerPool.disposed};
      record['process'] = _WindowsProcess.sample();
      if (played < seconds * 500 || !isJpeg(fromBridge) || !isJpeg(fromFile) || player.onError.value != null) {
        record['failure'] = 'played ${played}ms in ${seconds}s, frames ${isJpeg(fromBridge)}/${isJpeg(fromFile)}';
      }
    } catch (error) {
      record['failure'] = config.scrub(error);
      final engine = video?.engine;
      record['engineAtFailure'] = engine == null
          ? null
          : {
              'durationMs': engine.duration.value.inMilliseconds,
              'positionMs': engine.position.value.inMilliseconds,
              'videoSize': engine.videoSize.value == null
                  ? null
                  : [engine.videoSize.value!.width, engine.videoSize.value!.height],
              'hasVideo': engine.hasVideo.value,
              'playing': engine.playing.value,
              'buffering': engine.buffering.value,
              'error': video?.onError.value,
            };
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await bridge.stop();
      await fileSystem.close();
      await logs.cancel();
      Logger.root.level = previousLevel;
    }
    return record;
  }

  /// The 8K memory risk of plan 2.7, with two views of the app on [path]: first a swipe (the first view paused, then
  /// the second opened, which takes the first one's player: one decoder), then the most the pool allows, both views
  /// playing (a page opened over a large video that plays on) while the frame grabber takes frames, as a folder
  /// showing its tiles does. Each step samples the working set and the GPU memory: the decoder surfaces sit in the
  /// second, in shared system memory on an integrated GPU, and the working set does not show them.
  Future<Map<String, Object?>> memory(WidgetTester tester, String label, String path) async {
    final record = <String, Object?>{
      'phase': config.phase,
      'kind': 'memory',
      'label': label,
      'buildMode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
      'screen': screen(tester),
      'through': config.memoryThroughBridge ? 'bridge' : 'file',
      'renderSize': 'video, at most ${config.maxRenderHeight} lines',
    };
    final steps = <Map<String, Object?>>[];
    record['steps'] = steps;
    final controllers = <int, MediaKitVideoPlayerController>{};
    final capBefore = VideoController.maxOutputHeight;
    VideoController.maxOutputHeight = config.maxRenderHeight;
    final bridge = config.memoryThroughBridge ? LocalMediaBridge() : null;
    final fileSystem = bridge == null ? null : _LocalFileSystem(File(path));
    Map<String, Object?> sample(String step) => {
      'step': step,
      'rssMB': ProcessInfo.currentRss ~/ (1 << 20),
      'gpuMemory': GpuProcessMemory.sample(),
      'textures': [
        for (final view in controllers.keys.toList()..sort()) textureOf(controllers[view]!.videoController.value),
      ],
      'pool': {
        'active': desktopPlayerPool.activeCount(PlayerKind.playback),
        'idle': desktopPlayerPool.idleCount(PlayerKind.playback),
      },
    };
    try {
      var source = path;
      var type = VideoSourceType.file;
      if (bridge != null) {
        await bridge.start();
        bridge.register(fileSystem!);
        source = bridge.urlFor(fileSystem.source.id, p.basename(path)).toString();
        type = VideoSourceType.network;
      }
      final videoSource = await VideoSource.init(path: source, type: type);
      steps.add(sample('start'));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: ColoredBox(
              color: Colors.black,
              child: Row(
                children: [
                  for (final view in [0, 1])
                    Expanded(
                      child: DesktopVideoView(
                        key: ValueKey('memory-$view'),
                        pool: desktopPlayerPool,
                        resolve: (source) async => source.path,
                        onViewReady: (controller) => controllers[view] = controller as MediaKitVideoPlayerController,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      Future<void> loadAndPlay(int view) async {
        final controller = controllers[view];
        if (controller == null) {
          throw StateError('view $view has no controller');
        }
        final ready = Completer<void>();
        void onReady() {
          if (!ready.isCompleted) {
            ready.complete();
          }
        }

        controller.onPlaybackReady.addListener(onReady);
        try {
          await controller.loadVideoSource(videoSource).timeout(const Duration(seconds: 30));
          await ready.future.timeout(const Duration(seconds: 30));
          await controller.play();
        } finally {
          controller.onPlaybackReady.removeListener(onReady);
        }
      }

      // Long enough for the decoder's surfaces and the demuxer cache to fill
      final settle = Duration(seconds: max(5, config.seconds));
      await loadAndPlay(0);
      await Future<void>.delayed(settle);
      steps.add(sample('first view playing'));
      // A swipe: the page left is paused before the next one opens, which takes its player (one decoder)
      await controllers[0]!.pause();
      await loadAndPlay(1);
      await Future<void>.delayed(settle);
      steps.add(sample('swiped: first paused, then second playing'));
      // The first plays on while the second plays: it gets a player again, a second one, at its position
      await controllers[0]!.play();
      await Future<void>.delayed(settle);
      steps.add(sample('both views playing'));

      // Frames grabbed while both views hold their players; the highest sample is kept
      final during = <Map<String, Object?>>[];
      final sampler = Timer.periodic(const Duration(milliseconds: 500), (_) => during.add(sample('grabbing')));
      final grabs = <int?>[];
      try {
        for (final second in [2, 6, 10]) {
          final bytes = await VideoThumbnailGrabber.shared.grab(
            source,
            time: Duration(seconds: second),
            box: (width: 320, height: 320, cover: true),
          );
          grabs.add(bytes?.length);
        }
      } finally {
        sampler.cancel();
      }
      record['grabBytes'] = grabs;
      int weight(Map<String, Object?> sample) {
        final gpu = sample['gpuMemory'];
        final gpuMB = gpu is Map ? ((gpu['sharedMB'] as int? ?? 0) + (gpu['dedicatedMB'] as int? ?? 0)) : 0;
        return gpuMB + (sample['rssMB']! as int);
      }

      during.sort((a, b) => weight(b) - weight(a));
      steps.add({...during.firstOrNull ?? sample('grabbing'), 'step': 'grabbing, highest of ${during.length} samples'});
      await Future<void>.delayed(settle);
      steps.add(sample('after the grabs, both views playing'));
      if (grabs.any((bytes) => bytes == null)) {
        record['failure'] = 'a frame grab gave nothing: $grabs';
      }
    } catch (error) {
      record['failure'] = config.scrub(error);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      controllers.clear();
      // The views give their players back to the pool, which stops and parks them; media_kit destroys a disposed
      // libmpv five seconds later
      await Future<void>.delayed(const Duration(seconds: 7));
      steps.add(sample('views closed'));
      await bridge?.stop();
      await fileSystem?.close();
      VideoController.maxOutputHeight = capBefore;
    }
    return record;
  }

  /// Spike 2: [Config.soakPlayers] players opened, played and closed one after the other in the window
  Future<Map<String, Object?>> soak(WidgetTester tester) async {
    final path = config.clips.where((clip) => clip.$1 == config.soakClip).map((clip) => clip.$2).firstOrNull;
    final source = path ?? (await aviReference(work, width: 640, height: 360)).path;
    final samples = <Map<String, Object?>>[];
    Map<String, Object?> sample(int players) => {
      'players': players,
      'rssMB': ProcessInfo.currentRss ~/ (1 << 20),
      'gpuMemory': GpuProcessMemory.sample(),
      ..._WindowsProcess.sample(),
    };
    var noFirstFrame = 0;
    final errors = <String>[];
    final watch = Stopwatch()..start();
    samples.add(sample(0));
    if (config.soakThroughPool) {
      await _soakRounds(
        tester,
        source,
        config.soakPlayers,
        (players) {
          if (players % 20 == 0 || players == config.soakPlayers) {
            samples.add(sample(players));
          }
        },
        onNoFirstFrame: () => noFirstFrame++,
        onError: (error) {
          if (errors.length < 20) {
            errors.add(config.scrub(error));
          }
        },
      );
    }
    for (var i = 1; i <= (config.soakThroughPool ? 0 : config.soakPlayers); i++) {
      final player = Player();
      final native = player.platform! as NativePlayer;
      final controller = VideoController(player, configuration: VideoControllerConfiguration(hwdec: config.hwdec));
      try {
        await tester.pumpWidget(_VideoPage(controller));
        await native.setProperty('demuxer-cache-dir', work.path);
        await player.open(Media(source));
        try {
          await controller.waitUntilFirstFrameRendered.timeout(const Duration(seconds: 10));
        } on TimeoutException {
          noFirstFrame++;
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } catch (error) {
        if (errors.length < 20) {
          errors.add(config.scrub(error));
        }
      } finally {
        await tester.pumpWidget(const _VideoPage(null));
        await player.dispose();
      }
      if (i % 20 == 0 || i == config.soakPlayers) {
        samples.add(sample(i));
      }
    }
    // Lets the last disposals end before the final sample: media_kit destroys libmpv five seconds after dispose
    await Future<void>.delayed(const Duration(seconds: 7));
    samples.add(sample(config.soakPlayers));
    int? growth(String key) {
      final first = samples.first[key];
      final last = samples.last[key];
      return first is int && last is int ? last - first : null;
    }

    return {
      'phase': config.phase,
      'kind': 'soak',
      'mode': config.soakThroughPool ? 'pool' : 'bare',
      if (config.soakThroughPool)
        'pool': {
          'created': desktopPlayerPool.created,
          'disposed': desktopPlayerPool.disposed,
          'idle': desktopPlayerPool.idleCount(PlayerKind.playback),
          'active': desktopPlayerPool.activeCount(PlayerKind.playback),
        },
      'label': path == null ? 'reference' : _safeLabel(config.soakClip!),
      'players': config.soakPlayers,
      'seconds': watch.elapsed.inSeconds,
      'noFirstFrame': noFirstFrame,
      'errors': errors,
      'growth': {
        for (final key in ['rssMB', 'handles', 'gdiObjects', 'userObjects']) key: growth(key),
      },
      'oleAtEnd': samples.last['ole'],
      'samples': samples,
    };
  }
}

/// The rounds of the pool soak: two views on screen play, a third comes and takes the player of the first (the
/// pool holds two), then all three close: each round hands a player over, parks one and disposes one. [onRound] gets
/// the number of rounds done.
Future<void> _soakRounds(
  WidgetTester tester,
  String source,
  int rounds,
  void Function(int rounds) onRound, {
  required void Function() onNoFirstFrame,
  required void Function(Object error) onError,
}) async {
  final videoSource = await VideoSource.init(path: source, type: VideoSourceType.file);
  for (var round = 1; round <= rounds; round++) {
    final controllers = <int, MediaKitVideoPlayerController>{};
    Widget views(List<int> shown) => ProviderScope(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ColoredBox(
          color: Colors.black,
          child: Row(
            children: [
              for (final view in shown)
                Expanded(
                  child: DesktopVideoView(
                    key: ValueKey('soak-$round-$view'),
                    pool: desktopPlayerPool,
                    resolve: (source) async => source.path,
                    onViewReady: (controller) => controllers[view] = controller as MediaKitVideoPlayerController,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    Future<void> loadAndPlay(int view) async {
      final controller = controllers[view];
      if (controller == null) {
        throw StateError('view $view has no controller');
      }
      final ready = Completer<void>();
      void onReady() {
        if (!ready.isCompleted) {
          ready.complete();
        }
      }

      controller.onPlaybackReady.addListener(onReady);
      try {
        await controller.loadVideoSource(videoSource).timeout(const Duration(seconds: 10));
        try {
          await ready.future.timeout(const Duration(seconds: 10));
        } on TimeoutException {
          onNoFirstFrame();
        }
        await controller.play();
      } finally {
        controller.onPlaybackReady.removeListener(onReady);
      }
    }

    try {
      await tester.pumpWidget(views([0, 1]));
      await tester.pump();
      await loadAndPlay(0);
      await loadAndPlay(1);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pumpWidget(views([0, 1, 2]));
      await tester.pump();
      await loadAndPlay(2);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } catch (error) {
      onError(error);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      // The views give their leases back as they are disposed; the pool stops and parks the players in turn
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    onRound(round);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Frames as in the app: the engine draws the video textures as they come, not only when the test pumps
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final config = _Config(Platform.environment);
  SchedulerBinding.instance.addPersistentFrameCallback((_) => _frameworkFrames++);
  final harness = _Harness(config);
  final skip = CurrentPlatform.isDesktop ? false : 'the desktop video harness runs on Windows, Linux or macOS';

  setUpAll(() async {
    if (skip != false) {
      return;
    }
    MediaKit.ensureInitialized();
    _WindowsProcess.keepDisplayOn(true);
    // The first read of the GPU counters loads their providers, for seconds: done here, not inside a run
    GpuProcessMemory.sample();
    await harness.setUp();
  });

  tearDownAll(() async {
    if (skip == false) {
      GpuProcessMemory.close();
      _WindowsProcess.keepDisplayOn(false);
      await harness.tearDown();
    }
  });

  final noReference = skip != false || !config.reference;
  testWidgets('reference video at window size', (tester) async {
    final record = await harness.playAndMeasure(
      tester,
      kind: 'reference',
      label: 'reference',
      open: (player) => openReference(player, harness.work, width: 1920, height: 1080),
    );
    await harness.report(record);
    expect(record['failure'], isNull, reason: '${record['failure']}');
  }, skip: noReference);

  testWidgets('app player: the reference through the media bridge, and a frame grab', (tester) async {
    final record = await harness.appPlayer(tester);
    await harness.report(record);
    expect(record['failure'], isNull, reason: '${record['failure']}');
  }, skip: noReference);

  for (final (label, path) in config.clips) {
    testWidgets('clip $label', (tester) async {
      final record = await harness.playAndMeasure(
        tester,
        kind: 'clip',
        label: label,
        open: (player) async {
          final second = config.externalOf(label);
          if (second != null) {
            // Loaded with the next file: the pair's second lens as a second video track (design 2.5)
            await (player.platform! as NativePlayer).setProperty('external-files', second);
          }
          await player.open(Media(path));
          return second == null ? 'file' : 'file and external file';
        },
      );
      await harness.report(record);
      expect(record['failure'], isNull, reason: '${record['failure']}');
    }, skip: skip != false);
  }

  for (final (label, entry) in config.bridge) {
    testWidgets('bridge $label', (tester) async {
      final record = await harness.bridge(tester, label, entry);
      await harness.report(record);
      expect(record['failure'], isNull, reason: '${record['failure']}');
    }, skip: skip != false);
  }

  final memoryClip = config.memoryClip == null
      ? null
      : config.clips.where((clip) => clip.$1 == _safeLabel(config.memoryClip!)).firstOrNull;
  testWidgets(
    'memory: two views and frame grabs of ${memoryClip?.$1}',
    (tester) async {
      final record = await harness.memory(tester, memoryClip!.$1, memoryClip.$2);
      await harness.report(record);
      expect(record['failure'], isNull, reason: '${record['failure']}');
    },
    skip: skip != false || memoryClip == null,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'soak of ${config.soakPlayers} players',
    (tester) async {
      final record = await harness.soak(tester);
      await harness.report(record);
      expect(record['oleAtEnd'], isNot('was torn down'), reason: 'drag and drop dies when OLE is torn down (#1449)');
    },
    skip: skip != false || config.soakPlayers <= 0,
    timeout: const Timeout(Duration(hours: 2)),
  );
}
