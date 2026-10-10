// The measured switch of the raw files of two streams on the computers (design 2.5, plan 2.2 step 2d): whether this
// computer stacks the two streams of a raw file in one mpv core (raw_two_streams.dart), and through which decoding
// path. hstack is a filter of FFmpeg that works on frames in memory, so the streams are decoded either in software
// ("no") or by the GPU and copied back to memory (d3d11va-copy on Windows): zero copy decoding is not a choice.
//
// What phase 2b measured on the laptop the desktop app was developed on (spike 5, i9-13980HX, 2026-10-09):
// - an Insta360 X3 pair (two 2880 x 2880 H.264 files at 29.97 fps): 30 fps through the copy back of the RTX 4060
//   Laptop; 7 fps through the copy back of the Intel UHD, whose copy is the bottleneck (under one core busy), and 30
//   fps decoded in software there (3.4 of 24 threads busy);
// - an Insta360 X4 file (two 3840 x 3840 HEVC tracks): 8.7 fps through the copy back of the RTX, 7 fps in software
//   (7.3 threads busy): not usable on that PC, while one track alone plays at 30 fps without copy.
// So an integrated GPU tries software decoding first and a dedicated one the copy back, and two streams above the
// pixel rate of the X3 pair are not stacked until this computer has stacked as much smoothly.
//
// The measures of the build answer until this computer has its own: each stacked playback is measured over 5 s of
// steady play (frames dropped by mpv, and those the video fell behind the clock), kept per GPU, kind of video and
// decoding path in desktop_raw_two_streams.json in the app's support folder (only what describes the video format),
// and given to the decoder measures too (decoder_measure.dart), so that the warning of the viewer before the player
// opens ("two decoders at once") follows what happened here. A path measured too slow is left for 14 days, then tried
// again: the computer may have been busy, a driver may have changed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/platform/desktop_video_decoder_api.dart';
import 'package:immich_mobile/desktop/video/decoder_measure.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/gpu_decoders.dart';
import 'package:immich_mobile/desktop/video/raw_two_streams.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immuch_desktop_video/immuch_desktop_video.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('RawTwoStreams');

/// mpv's decoding paths for two stacked streams, see the top of this file
abstract final class TwoStreamPaths {
  static const software = 'no';

  /// The GPU decodes and copies each frame back to memory: d3d11va-copy, the path spike 5 measured, on Windows; mpv's
  /// safe copy back methods elsewhere (phase 4 measures them)
  static String get copyBack => CurrentPlatform.isWindows ? 'd3d11va-copy' : 'auto-copy-safe';

  /// The order a GPU tries them in: the copy back first on a dedicated GPU, software first on an integrated one or
  /// one not known (software decoding does not depend on the GPU). [copy] is the copy back path of this platform.
  static List<String> orderFor({required bool? integrated, String? copy}) {
    final back = copy ?? copyBack;
    return integrated == false ? [back, software] : [software, back];
  }
}

/// The measures of spike 5 (plan 20, phase 2b, 2026-10-09), see the top of this file: 6 s phases of 180 frames, the
/// frames dropped computed from the frames shown each second
const twoStreamMeasuresOfTheBuild = [
  DecodeMeasure(
    gpu: MeasuredGpu.integrated,
    codec: VideoMime.avc,
    width: 2880,
    height: 2880,
    frameRate: 29.97,
    hwdec: 'd3d11va-copy',
    frames: 180,
    dropped: 137,
    instances: 2,
    source: 'phase 2b, spike 5, Intel UHD: 7.1 fps',
  ),
  DecodeMeasure(
    gpu: MeasuredGpu.integrated,
    codec: VideoMime.avc,
    width: 2880,
    height: 2880,
    frameRate: 29.97,
    hwdec: TwoStreamPaths.software,
    frames: 180,
    dropped: 0,
    instances: 2,
    source: 'phase 2b, spike 5, Intel UHD: 30 fps',
  ),
  DecodeMeasure(
    gpu: MeasuredGpu.dedicated,
    codec: VideoMime.avc,
    width: 2880,
    height: 2880,
    frameRate: 29.97,
    hwdec: 'd3d11va-copy',
    frames: 180,
    dropped: 0,
    instances: 2,
    source: 'phase 2b, spike 5, RTX 4060 Laptop: 30 fps',
  ),
  DecodeMeasure(
    gpu: MeasuredGpu.dedicated,
    codec: VideoMime.hevc,
    width: 3840,
    height: 3840,
    frameRate: 29.97,
    hwdec: 'd3d11va-copy',
    frames: 180,
    dropped: 128,
    instances: 2,
    source: 'phase 2b, spike 5, RTX 4060 Laptop: 8.7 fps',
  ),
  DecodeMeasure(
    gpu: MeasuredGpu.any,
    codec: VideoMime.hevc,
    width: 3840,
    height: 3840,
    frameRate: 29.97,
    hwdec: TwoStreamPaths.software,
    frames: 180,
    dropped: 138,
    instances: 2,
    source: 'phase 2b, spike 5, software on the i9-13980HX: 7 fps',
  ),
];

/// The kind of video a choice is about: two streams of [codec] (a MIME type) at [width] x [height] and [frameRate]
/// (0 when unknown) on [gpu] (GpuAdapter.key, or MeasuredGpu.unknown), [integrated] when that GPU is one
typedef TwoStreamQuestion = ({String gpu, bool? integrated, String? codec, int? width, int? height, double frameRate});

/// The decoding path to stack the two streams of [question] with, null when they are not to be stacked (see the top
/// of this file), from [own], the measures of this computer, and [build], those of the build. [failed] are paths
/// measured too slow during this playback, [copyBack] the copy back path of this platform (TwoStreamPaths.copyBack).
/// In this order, for each path of [TwoStreamPaths.orderFor]:
/// 1. a measure of this computer of the same kind of video through that path: it is what happened;
/// 2. a measure through that path, of this computer then of the build for this kind of GPU, that kept up at a higher
///    pixel rate (taken) or did not at a lower one (left);
/// 3. none: the path is tried.
/// Two streams above the pixel rate of the X3 pair (DesktopVideoDecoderApi.twoStreamPixelRate) are not stacked at
/// all, unless this computer stacked as much smoothly through some path.
TwoStreamChoice chooseTwoStreamPath(
  TwoStreamQuestion question, {
  required List<DecodeMeasure> own,
  List<DecodeMeasure> build = twoStreamMeasuresOfTheBuild,
  Set<String> failed = const {},
  String? copyBack,
}) {
  final order = TwoStreamPaths.orderFor(integrated: question.integrated, copy: copyBack);
  final codec = question.codec;
  final width = question.width;
  final height = question.height;
  if (codec == null || width == null || height == null || width <= 0 || height <= 0) {
    // As the phones: the decoders are not checked without a size or a codec, the stack is tried
    final path = order.where((path) => !failed.contains(path)).firstOrNull;
    return (hwdec: path, reason: path == null ? 'every path too slow' : 'size or codec unknown: $path tried');
  }
  final asked = DecodeMeasure(
    gpu: question.gpu,
    codec: codec,
    width: width,
    height: height,
    frameRate: question.frameRate,
    hwdec: '',
    frames: 0,
    dropped: 0,
    instances: 2,
  );
  final rate = asked.pixelRate;
  // 29.97 and 30 fps, or a rate not known yet (counted as 30), are the same kind of video
  bool atLeast(DecodeMeasure m) => m.pixelRate >= rate * (1 - _rateTolerance);
  bool atMost(DecodeMeasure m) => m.pixelRate <= rate * (1 + _rateTolerance);
  bool sameKind(DecodeMeasure m) =>
      m.gpu == asked.gpu &&
      m.codec == codec &&
      m.width == width &&
      m.height == height &&
      m.instances == 2 &&
      (question.frameRate <= 0 || (m.frameRate - question.frameRate).abs() < 0.5);
  final mine = [
    for (final measure in own.reversed)
      if (measure.instances == 2 && measure.gpu == question.gpu) measure,
  ];
  const ceiling = DesktopVideoDecoderApi.twoStreamPixelRate;
  if (rate > ceiling * (1 + _rateTolerance) && !mine.any((m) => m.codec == codec && m.smooth && atLeast(m))) {
    return (
      hwdec: null,
      reason:
          '${(rate / 1e6).round()} Mpx/s, above the ${(ceiling / 1e6).round()} Mpx/s measured smooth for two streams',
    );
  }
  final kinds = {
    MeasuredGpu.any,
    if (question.integrated == true) MeasuredGpu.integrated,
    if (question.integrated == false) MeasuredGpu.dedicated,
  };
  final fromBuild = [
    for (final measure in build)
      if (kinds.contains(measure.gpu)) measure,
  ];
  final reasons = <String>[];
  for (final path in order) {
    if (failed.contains(path)) {
      reasons.add('$path too slow now');
      continue;
    }
    final same = mine.where((m) => m.hwdec == path && sameKind(m)).firstOrNull;
    if (same != null) {
      if (same.smooth) {
        return (hwdec: path, reason: 'measured on this computer: ${same.describe()}');
      }
      reasons.add('measured on this computer: ${same.describe()}');
      continue;
    }
    DecodeMeasure? covering(Iterable<DecodeMeasure> measures) => measures
        .where((m) => m.hwdec == path && m.codec == codec && m.instances == 2 && (m.smooth ? atLeast(m) : atMost(m)))
        .firstOrNull;
    final known = covering(mine) ?? covering(fromBuild);
    if (known == null) {
      return (hwdec: path, reason: 'not measured yet: $path tried');
    }
    final where = known.source ?? 'this computer';
    if (known.smooth) {
      return (hwdec: path, reason: '$where: ${known.describe()}');
    }
    reasons.add('$where: ${known.describe()}');
  }
  return (hwdec: null, reason: reasons.join('; '));
}

// Pixel rates within one percent are the same: 29.97 fps against 30
const _rateTolerance = 0.01;

/// The measures of stacked playbacks on this computer, kept in [fileName] in the app's support folder: one per GPU,
/// kind of video and decoding path
class TwoStreamMeasureStore {
  TwoStreamMeasureStore({Future<Directory> Function()? folder}) : _folder = folder ?? getApplicationSupportDirectory;

  static const fileName = 'desktop_raw_two_streams.json';
  static const maxMeasures = 60;

  /// A path measured too slow is tried again after this long (see the top of this file)
  static const failureLasts = DecoderMeasureStore.failureLasts;

  /// The store of the app
  static TwoStreamMeasureStore shared = TwoStreamMeasureStore();

  final Future<Directory> Function() _folder;
  List<DecodeMeasure>? _measures;
  Future<List<DecodeMeasure>>? _loading;
  Future<void> _writing = Future.value();

  Future<File> _file() async => File(p.join((await _folder()).path, fileName));

  /// The measures kept, oldest first, failures past [failureLasts] left out
  Future<List<DecodeMeasure>> measures({DateTime? now}) async {
    final all = _measures ?? await (_loading ??= _read());
    final today = now ?? DateTime.now();
    return [
      for (final measure in all)
        if (measure.smooth || measure.at == null || today.difference(measure.at!) < failureLasts) measure,
    ];
  }

  Future<List<DecodeMeasure>> _read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return _measures = [];
      }
      final content = jsonDecode(await file.readAsString());
      final list = content is Map ? content['measures'] : null;
      return _measures = [
        for (final entry in list is List ? list : const [])
          if (entry is Map<String, Object?>) DecodeMeasure.fromJson(entry),
      ];
    } catch (error) {
      // A damaged file costs the measures, which the next playbacks make again
      _log.warning('The measures of two streams could not be read: $error');
      return _measures = [];
    }
  }

  /// Keeps [measure] in place of an earlier one of the same kind of video and path
  Future<void> record(DecodeMeasure measure) async {
    await measures();
    final kept = [
      for (final earlier in _measures!)
        if (!(earlier.sameClass(measure) && earlier.hwdec == measure.hwdec)) earlier,
      measure,
    ];
    _measures = kept.length > maxMeasures ? kept.sublist(kept.length - maxMeasures) : kept;
    final snapshot = List.of(_measures!);
    _writing = _writing.then((_) => _write(snapshot));
    await _writing;
  }

  Future<void> _write(List<DecodeMeasure> measures) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      // Written beside, then renamed over: a crash in the middle leaves the previous measures, not half a file
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'measures': [for (final m in measures) m.toJson()],
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    } catch (error) {
      _log.warning('The measures of two streams are kept for this session only: $error');
    }
  }

  /// Forgets what was read, for the tests
  @visibleForTesting
  void forget() {
    _measures = null;
    _loading = null;
  }
}

/// The switch of one playback: [choose] asks [chooseTwoStreamPath] about the streams of a raw file on the GPU in use,
/// [record] keeps what a stacked playback measured
class TwoStreamSwitch {
  TwoStreamSwitch({
    TwoStreamMeasureStore? store,
    DecoderMeasureStore? decoderMeasures,
    Future<GpuAdapter?> Function()? adapter,
  }) : _store = store ?? TwoStreamMeasureStore.shared,
       _decoderMeasures = decoderMeasures ?? DecoderMeasureStore.shared,
       _adapter = adapter ?? DesktopGpuDecoders.adapter;

  final TwoStreamMeasureStore _store;
  final DecoderMeasureStore _decoderMeasures;
  final Future<GpuAdapter?> Function() _adapter;

  /// The paths measured too slow during this playback
  final failed = <String>{};

  Future<({String gpu, bool? integrated})> _gpu() async {
    GpuAdapter? adapter;
    try {
      adapter = await _adapter();
    } catch (error) {
      _log.info('No GPU known for two streams: $error');
    }
    return (gpu: adapter?.key ?? MeasuredGpu.unknown, integrated: adapter?.integrated);
  }

  /// The question about [raw]'s largest stream at [frameRate] (0 when unknown)
  Future<TwoStreamQuestion> question(RawStreams raw, {double frameRate = 0}) async {
    final (:gpu, :integrated) = await _gpu();
    final track = raw.largest;
    return (
      gpu: gpu,
      integrated: integrated,
      codec: _mimeOf(track),
      width: track.width,
      height: track.height,
      frameRate: frameRate,
    );
  }

  /// The decoding path to stack [raw] with, or why not
  Future<TwoStreamChoice> choose(RawStreams raw, {double frameRate = 0}) async {
    final asked = await question(raw, frameRate: frameRate);
    final choice = chooseTwoStreamPath(asked, own: await _store.measures(), failed: failed);
    _log.info('Two streams of ${asked.width}x${asked.height}: ${choice.hwdec ?? 'not stacked'} (${choice.reason})');
    return choice;
  }

  /// The first path of the GPU in use, for streams of unknown size (the server's transcoded streams of a pair)
  Future<String> startPath() async => TwoStreamPaths.orderFor(
    integrated: (await _gpu()).integrated,
  ).firstWhere((path) => !failed.contains(path), orElse: () => TwoStreamPaths.software);

  /// Keeps [measure], a stacked playback of this computer; a path too slow is left for the rest of this playback
  Future<void> record(DecodeMeasure measure) async {
    if (!measure.smooth) {
      failed.add(measure.hwdec);
    }
    _log.info('Measured: $measure, ${measure.smooth ? 'keeps up' : 'does not keep up'}');
    await _store.record(measure);
    // The viewer's warning before the player opens asks the decoder measures about two streams of this kind
    await _decoderMeasures.record(measure);
  }

  static String? _mimeOf(RawStreamTrack track) {
    for (final name in [track.codecs, track.codec]) {
      final mime = name == null ? null : desktopMimeFor(name);
      if (mime != null) {
        return mime;
      }
    }
    return null;
  }
}

/// Measures a stacked playback of [engine] once: after [settle] of steady play from the first frame, mpv's drop
/// counters and the position are read, and again [window] later; the frames dropped and those the video fell behind
/// the clock count together, as in PlaybackDecodeSampler (decoder_measure.dart), which leaves stacked playbacks to
/// this one. A pause, a seek or a stall in the middle cancels that try, and the next steady play tries again.
/// [onMeasure] gets a DecodeMeasure of two streams of [track] (codec as a MIME type, the size of one stream) through
/// [hwdec].
class TwoStreamSampler {
  TwoStreamSampler(
    this._engine,
    this._read, {
    required this.gpu,
    required this.codec,
    required this.width,
    required this.height,
    required this.hwdec,
    required this.onMeasure,
    this.settle = const Duration(seconds: 1),
    this.window = const Duration(seconds: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _subscription = _engine.events.listen(_onEvent);
    _engine.playing.addListener(_onState);
    _engine.buffering.addListener(_onState);
    _onState();
  }

  final PlaybackEngine _engine;
  final MpvPropertyReader _read;
  final String gpu;
  final String codec;
  final int width;
  final int height;
  final String hwdec;
  final void Function(DecodeMeasure measure) onMeasure;
  final Duration settle;
  final Duration window;
  final DateTime Function() _now;

  StreamSubscription<PlayerEvent>? _subscription;
  Timer? _timer;
  bool _done = false;
  bool _disposed = false;
  int _try = 0;

  bool get done => _done;

  void _onEvent(PlayerEvent event) {
    switch (event.kind) {
      case PlayerEventKind.restarted:
        _cancel();
        _start();
      case PlayerEventKind.loaded || PlayerEventKind.failed:
        _cancel();
    }
  }

  void _onState() {
    if (!_engine.playing.value || _engine.buffering.value) {
      _cancel();
    } else if (_timer == null) {
      _start();
    }
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    _try++;
  }

  void _start() {
    if (_disposed || _done || _timer != null || !_engine.playing.value || _engine.buffering.value) {
      return;
    }
    final attempt = ++_try;
    _timer = Timer(settle, () => unawaited(_measure(attempt)));
  }

  Future<int> _int(String name) async => int.tryParse((await _read(name)).trim()) ?? 0;

  Future<double> _double(String name) async => double.tryParse((await _read(name)).trim()) ?? 0;

  Future<void> _measure(int attempt) async {
    try {
      final positionBefore = _engine.position.value;
      final dropsBefore = await _int('frame-drop-count') + await _int('decoder-frame-drop-count');
      final started = _now();
      await Future<void>.delayed(window);
      if (attempt != _try || _disposed) {
        return;
      }
      final elapsed = _now().difference(started).inMicroseconds / Duration.microsecondsPerSecond;
      final dropsAfter = await _int('frame-drop-count') + await _int('decoder-frame-drop-count');
      final played = (_engine.position.value - positionBefore).inMicroseconds / Duration.microsecondsPerSecond;
      // A seek inside the window (the position jumped, either way): not a measure
      if (attempt != _try || elapsed <= 0 || played < 0 || played > elapsed * 1.1) {
        return;
      }
      var frameRate = await _double('container-fps');
      if (frameRate <= 0) {
        // Under lavfi-complex mpv may know the rate of the graph's output only
        frameRate = await _double('estimated-vf-fps');
      }
      if (frameRate <= 0) {
        frameRate = 30;
      }
      final frames = (frameRate * elapsed).round();
      // A video that plays slower than the clock lost those frames as surely as dropped ones (decoder_measure.dart)
      final behind = ((elapsed - played - 0.1) * frameRate).round();
      final measure = DecodeMeasure(
        gpu: gpu,
        codec: codec,
        width: width,
        height: height,
        frameRate: (frameRate * 1000).round() / 1000,
        hwdec: hwdec,
        frames: frames,
        dropped: math.max(0, math.min(frames, dropsAfter - dropsBefore + math.max(0, behind))),
        instances: 2,
        mpvVersion: (await _read('mpv-version')).trim(),
        at: _now(),
      );
      if (attempt != _try || _disposed) {
        return;
      }
      _done = true;
      onMeasure(measure);
    } catch (error) {
      // A player given back in the middle: nothing to measure
      _log.fine('No measure of two streams: $error');
    } finally {
      if (attempt == _try) {
        _timer = null;
      }
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _cancel();
    unawaited(_subscription?.cancel());
    _engine.playing.removeListener(_onState);
    _engine.buffering.removeListener(_onState);
  }
}
