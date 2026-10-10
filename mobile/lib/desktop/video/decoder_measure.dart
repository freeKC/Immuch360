// The measured correction of the decoder answers (design 2.7), as the phones correct theirs with what was measured on
// the Meta Quest 3: a decoder list says what a GPU can decode, not what the computer keeps up with. A hardware decoder
// may hand its frames back to memory (mpv's copy back modes, which on an integrated GPU halve the frames shown at 8K),
// a size the GPU refuses goes to the processor, and whether the processor keeps up depends on the computer.
//
// So each playback is measured once its video has played steadily for a few seconds: the decoder mpv uses
// (hwdec-current, "no" for software) and the frames it dropped, stored per GPU, codec, size, frame rate and number of
// streams in desktop_decoder_measures.json in the app's support folder (no file name, path or address: only what
// describes the video format). A later question about the same kind of video (DesktopVideoDecoderApi.canDecode)
// answers from the measure: a video that dropped frames there plays the server's transcoded stream next time, with the
// message the phones show.
//
// Beside the measures of this computer, the measures made on the laptop the desktop app was developed on
// (phase 2a and 2b of plan 20: an i9-13980HX with an Intel UHD and an RTX 4060 Laptop) answer until this computer has
// its own: they are the kind of GPU and decoding path, not the machine.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/gpu_decoders.dart';
import 'package:immuch_desktop_video/immuch_desktop_video.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('DecoderMeasure');

/// The GPU of the measures made while the app was built that hold for a kind of GPU rather than one
abstract final class MeasuredGpu {
  static const integrated = 'integrated';
  static const dedicated = 'dedicated';
  static const any = 'any';

  /// Where no probe tells the GPU (Linux and macOS for now)
  static const unknown = 'unknown';
}

/// One measure of a playback: on [gpu] (GpuAdapter.key, or a [MeasuredGpu] kind for the measures of the build), [codec]
/// (a MIME type) at [width] x [height] and [frameRate] frames a second (0 when unknown), [instances] streams at once,
/// decoded through [hwdec] (mpv's hwdec-current: "no" for software, "d3d11va", "d3d11va-copy", ...), [dropped] of the
/// [frames] the video had in the measured time. [mpvVersion] is the libmpv that played it (empty for the measures of
/// the build), [at] when, [source] where a measure of the build comes from.
@immutable
class DecodeMeasure {
  const DecodeMeasure({
    required this.gpu,
    required this.codec,
    required this.width,
    required this.height,
    required this.frameRate,
    required this.hwdec,
    required this.frames,
    required this.dropped,
    this.instances = 1,
    this.mpvVersion = '',
    this.at,
    this.source,
  });

  factory DecodeMeasure.fromJson(Map<String, Object?> json) => DecodeMeasure(
    gpu: json['gpu'] as String? ?? MeasuredGpu.unknown,
    codec: json['codec'] as String? ?? '',
    width: (json['width'] as num?)?.toInt() ?? 0,
    height: (json['height'] as num?)?.toInt() ?? 0,
    frameRate: (json['frameRate'] as num?)?.toDouble() ?? 0,
    hwdec: json['hwdec'] as String? ?? 'no',
    frames: (json['frames'] as num?)?.toInt() ?? 0,
    dropped: (json['dropped'] as num?)?.toInt() ?? 0,
    instances: (json['instances'] as num?)?.toInt() ?? 1,
    mpvVersion: json['mpv'] as String? ?? '',
    at: DateTime.tryParse(json['at'] as String? ?? ''),
  );

  /// A video keeps up when it drops at most one frame in twenty over the measure, and never fewer than this many may
  /// drop: a stall of the share or a busy moment of the computer is not the decoder
  static const smoothShare = 0.05;
  static const smoothFloor = 3;

  final String gpu;
  final String codec;
  final int width;
  final int height;
  final double frameRate;
  final String hwdec;
  final int frames;
  final int dropped;
  final int instances;
  final String mpvVersion;
  final DateTime? at;
  final String? source;

  bool get hardware => hwdec.isNotEmpty && hwdec != 'no';

  /// A hardware decoder whose frames come back to memory before they are shown
  bool get copyBack => hwdec.endsWith('-copy');

  bool get smooth => dropped <= math.max(smoothFloor, (frames * smoothShare).floor());

  /// The pixels decoded each second, the cost the measures are compared by
  double get pixelRate => instances * width * height * (frameRate > 0 ? frameRate : 30);

  /// The frames shown each second
  double get shownRate => frames <= 0 ? 0 : (frameRate > 0 ? frameRate : 30) * (frames - dropped) / frames;

  bool sameClass(DecodeMeasure other) =>
      other.gpu == gpu &&
      other.codec == codec &&
      other.width == width &&
      other.height == height &&
      other.instances == instances &&
      (other.frameRate - frameRate).abs() < 0.5;

  Map<String, Object?> toJson() => {
    'gpu': gpu,
    'codec': codec,
    'width': width,
    'height': height,
    'frameRate': frameRate,
    'hwdec': hwdec,
    'frames': frames,
    'dropped': dropped,
    'instances': instances,
    'mpv': mpvVersion,
    if (at != null) 'at': at!.toUtc().toIso8601String(),
  };

  /// For the logs and the reasons of the answers: not translated
  String describe() =>
      '${videoCodecLabel(codec)} ${instances > 1 ? '$instances x ' : ''}${width}x$height'
      '${frameRate > 0 ? ' at ${_rate(frameRate)} fps' : ''} through $hwdec, $dropped of $frames frames dropped';

  @override
  bool operator ==(Object other) =>
      other is DecodeMeasure &&
      sameClass(other) &&
      other.hwdec == hwdec &&
      other.frames == frames &&
      other.dropped == dropped &&
      other.mpvVersion == mpvVersion &&
      other.at == at;

  @override
  int get hashCode => Object.hash(gpu, codec, width, height, instances, hwdec, frames, dropped, mpvVersion, at);

  @override
  String toString() => 'DecodeMeasure(${describe()} on $gpu)';
}

String _rate(double rate) {
  final rounded = (rate * 100).round() / 100;
  return rounded == rounded.roundToDouble() ? rounded.round().toString() : rounded.toString();
}

/// "H.264", "HEVC", ... for a MIME type, the MIME type itself for the others
String videoCodecLabel(String codec) => switch (codec) {
  VideoMime.avc => 'H.264',
  VideoMime.hevc => 'HEVC',
  VideoMime.av1 => 'AV1',
  VideoMime.vp9 => 'VP9',
  VideoMime.vp8 => 'VP8',
  VideoMime.mpeg2 => 'MPEG-2',
  VideoMime.mpeg4 => 'MPEG-4',
  VideoMime.vc1 => 'VC-1',
  _ => codec,
};

/// The measures made on the laptop the app was developed on (reports of plan 20, phases 2a and 2b; synthetic
/// clips at the bit rates of the cameras, 300 frames a run): what a kind of GPU does through a decoding path. Each
/// holds until this computer measured the same path itself.
const decodeMeasuresOfTheBuild = [
  // 8K HEVC at 215 Mbit/s through mpv's copy back (the libmpv of 2024 bundled so far has no zero copy with ANGLE):
  // 152 to 163 of 300 frames dropped on the Intel UHD on both screens, about 14 fps shown, the whole app slowed
  DecodeMeasure(
    gpu: MeasuredGpu.integrated,
    codec: VideoMime.hevc,
    width: 7680,
    height: 3840,
    frameRate: 30,
    hwdec: 'd3d11va-copy',
    frames: 300,
    dropped: 157,
    source: 'phase 2a, spike 6, Intel UHD',
  ),
  // The same file on the RTX 4060 Laptop, same path: none dropped
  DecodeMeasure(
    gpu: MeasuredGpu.dedicated,
    codec: VideoMime.hevc,
    width: 7680,
    height: 3840,
    frameRate: 30,
    hwdec: 'd3d11va-copy',
    frames: 300,
    dropped: 0,
    source: 'phase 2a, spike 6, RTX 4060 Laptop',
  ),
  // With zero copy (the libmpv of 2026 that the fork's build follows): 30 fps on both GPUs
  DecodeMeasure(
    gpu: MeasuredGpu.any,
    codec: VideoMime.hevc,
    width: 7680,
    height: 3840,
    frameRate: 30,
    hwdec: 'd3d11va',
    frames: 300,
    dropped: 0,
    source: 'phase 2b, spike 3 and renderer C, both GPUs',
  ),
  // 5.7K H.264 at 132 Mbit/s, the export of the 360 cameras, in software since no Direct3D, DXVA2 or NVDEC decoder of
  // either GPU takes H.264 above 4096: none dropped, 2.2 to 2.9 of 24 processor threads busy
  DecodeMeasure(
    gpu: MeasuredGpu.any,
    codec: VideoMime.avc,
    width: 5760,
    height: 2880,
    frameRate: 30,
    hwdec: 'no',
    frames: 300,
    dropped: 0,
    source: 'phase 2a, spike 6, both GPUs',
  ),
  // 8K HEVC in software: 50 to 80 of 300 dropped with 9 threads busy
  DecodeMeasure(
    gpu: MeasuredGpu.any,
    codec: VideoMime.hevc,
    width: 7680,
    height: 3840,
    frameRate: 30,
    hwdec: 'no',
    frames: 300,
    dropped: 65,
    source: 'phase 2a, spike 6, software on the Intel UHD',
  ),
];

/// What the correction says about a question: [measure], the measure it follows, and [own] when it was made on this
/// computer
typedef DecodeCorrection = ({DecodeMeasure measure, bool own});

/// The measures of this computer, kept in [fileName] in the app's support folder
class DecoderMeasureStore {
  DecoderMeasureStore({Future<Directory> Function()? folder, this._ofTheBuild = decodeMeasuresOfTheBuild})
    : _folder = folder ?? getApplicationSupportDirectory;

  static const fileName = 'desktop_decoder_measures.json';

  /// Measures kept, the oldest dropped beyond
  static const maxMeasures = 100;

  /// A measure that dropped frames stops answering after this long, so that the original of a video is tried again
  /// (the computer may have been busy, the driver updated): a measure that kept up has nothing to be tried again for
  static const failureLasts = Duration(days: 14);

  /// The store of the app
  static DecoderMeasureStore shared = DecoderMeasureStore();

  final Future<Directory> Function() _folder;
  final List<DecodeMeasure> _ofTheBuild;
  List<DecodeMeasure>? _measures;
  Future<List<DecodeMeasure>>? _loading;
  Future<void> _writing = Future.value();

  /// The measures of this computer, read from the file once
  Future<List<DecodeMeasure>> measures() async => _measures ?? await (_loading ??= _read());

  Future<File> _file() async => File(p.join((await _folder()).path, fileName));

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
      _log.warning('The decoder measures could not be read: $error');
      return _measures = [];
    }
  }

  /// Keeps [measure], in place of an earlier one of the same kind of video. Measures of another libmpv are dropped
  /// first: a new build of mpv decodes differently (zero copy or not), so its predecessor's measures say nothing.
  Future<void> record(DecodeMeasure measure) async {
    final current = await measures();
    final kept = [
      for (final earlier in current)
        if (earlier.mpvVersion == measure.mpvVersion && !earlier.sameClass(measure)) earlier,
      measure,
    ];
    _measures = kept.length > maxMeasures ? kept.sublist(kept.length - maxMeasures) : kept;
    _log.info('Measured: $measure, ${measure.smooth ? 'keeps up' : 'does not keep up'}');
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
      _log.warning('The decoder measures are kept for this session only: $error');
    }
  }

  /// The measures of this computer on [gpu] (a GpuAdapter key, or MeasuredGpu.unknown), failures past
  /// [failureLasts] left out
  Future<List<DecodeMeasure>> ownOn(String gpu, {DateTime? now}) async {
    final today = now ?? DateTime.now();
    return [
      for (final measure in await measures())
        if (measure.gpu == gpu &&
            (measure.smooth || measure.at == null || today.difference(measure.at!) < failureLasts))
          measure,
    ];
  }

  /// What the measures say about [instances] streams of [codec] at [width] x [height] and [frameRate] on [gpu]
  /// ([integrated] tells which measures of the build apply; null when the kind of GPU is not known), when it decodes
  /// in hardware or not as [hardware] expects; null when nothing measured applies. The measures of the build are
  /// taken only with [buildMeasures]: where no probe tells whether the GPU decodes (Linux and macOS for now), a path
  /// measured on Windows says nothing. In this order:
  /// 1. a measure of this computer of the same kind of video, whatever its decoding path: it is what happened;
  /// 2. a measure of this computer on the same decoding path that kept up at a higher pixel rate (the video keeps
  ///    up), or that did not keep up at a lower one (it does not), the latest first;
  /// 3. the same with the measures of the build for this kind of GPU.
  /// The decoding path of a hardware decoder (zero copy or copy back) is the one this computer's last hardware
  /// playback took: until one happened, no measure of the build is taken for a hardware path.
  Future<DecodeCorrection?> correction({
    required String gpu,
    required bool? integrated,
    required String codec,
    required int width,
    required int height,
    required double frameRate,
    required bool hardware,
    int instances = 1,
    bool buildMeasures = true,
    DateTime? now,
  }) async {
    final own = await ownOn(gpu, now: now);
    final question = DecodeMeasure(
      gpu: gpu,
      codec: codec,
      width: width,
      height: height,
      frameRate: frameRate,
      hwdec: '',
      frames: 0,
      dropped: 0,
      instances: instances,
    );
    final latestFirst = own.reversed.toList();
    for (final measure in latestFirst) {
      if (measure.sameClass(question)) {
        return (measure: measure, own: true);
      }
    }
    final String? path;
    if (!hardware) {
      path = 'no';
    } else {
      path = latestFirst.where((measure) => measure.hardware).firstOrNull?.hwdec;
    }
    if (path == null) {
      return null;
    }
    final rate = question.pixelRate;
    DecodeMeasure? covering(Iterable<DecodeMeasure> measures) {
      for (final measure in measures) {
        if (measure.codec != codec || measure.instances != instances || measure.hwdec != path) {
          continue;
        }
        if (measure.smooth ? measure.pixelRate >= rate : measure.pixelRate <= rate) {
          return measure;
        }
      }
      return null;
    }

    final fromOwn = covering(latestFirst);
    if (fromOwn != null) {
      return (measure: fromOwn, own: true);
    }
    if (!buildMeasures) {
      return null;
    }
    final kinds = {
      MeasuredGpu.any,
      if (integrated == true) MeasuredGpu.integrated,
      if (integrated == false) MeasuredGpu.dedicated,
    };
    final fromBuild = covering(_ofTheBuild.where((measure) => kinds.contains(measure.gpu)));
    return fromBuild == null ? null : (measure: fromBuild, own: false);
  }

  /// Forgets what was read, for the tests
  @visibleForTesting
  void forget() {
    _measures = null;
    _loading = null;
  }
}

/// The MIME type of a codec as mpv names it (current-tracks/video/codec: FFmpeg's decoder names), null for the others
String? mimeOfMpvCodec(String codec) => switch (codec.trim().toLowerCase()) {
  'h264' => VideoMime.avc,
  'hevc' => VideoMime.hevc,
  'av1' => VideoMime.av1,
  'vp9' => VideoMime.vp9,
  'vp8' => VideoMime.vp8,
  'mpeg2video' => VideoMime.mpeg2,
  'mpeg4' => VideoMime.mpeg4,
  'vc1' => VideoMime.vc1,
  _ => null,
};

/// Reads an mpv property of a player as text, empty when mpv has none
typedef MpvPropertyReader = Future<String> Function(String name);

/// Measures the playbacks of [engine] (see the top of this file): once a file has played steadily for [settle] after
/// its first frame, mpv's drop counters are read, and again [window] later; the class of the video and what happened
/// go to [record], the frames dropped and those the video fell behind the clock counted together. One measure per
/// file opened; a pause, a seek, a stall or a change of speed in the middle cancels that try, and the next steady
/// playback of the same file tries again.
class PlaybackDecodeSampler {
  PlaybackDecodeSampler(
    this._engine,
    this._read, {
    required this.record,
    required this.gpu,
    this.settle = const Duration(seconds: 1),
    this.window = const Duration(seconds: 5),
    bool Function()? appShown,
    DateTime Function()? now,
  }) : _appShown = appShown ?? _resumed,
       _now = now ?? DateTime.now {
    _subscription = _engine.events.listen(_onEvent, onDone: dispose);
    _engine.playing.addListener(_onState);
    _engine.buffering.addListener(_onState);
  }

  final PlaybackEngine _engine;
  final MpvPropertyReader _read;
  final Future<void> Function(DecodeMeasure measure) record;

  /// The GPU the measures hold for (GpuAdapter.key), MeasuredGpu.unknown where it is not known
  final Future<String> Function() gpu;
  final Duration settle;
  final Duration window;
  final bool Function() _appShown;
  final DateTime Function() _now;

  StreamSubscription<PlayerEvent>? _subscription;
  Timer? _timer;
  bool _measured = false;
  bool _disposed = false;

  // The try under way: a number that a cancelled try's reads no longer match
  int _try = 0;

  static bool _resumed() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _onEvent(PlayerEvent event) {
    switch (event.kind) {
      case PlayerEventKind.loaded:
        _measured = false;
        _cancel();
      case PlayerEventKind.restarted:
        _cancel();
        _start();
      case PlayerEventKind.failed:
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
    if (_disposed || _measured || _timer != null || !_engine.playing.value || _engine.buffering.value) {
      return;
    }
    final attempt = ++_try;
    _timer = Timer(settle, () => unawaited(_measure(attempt)));
  }

  Future<int> _int(String name) async => int.tryParse((await _read(name)).trim()) ?? 0;

  Future<double> _double(String name) async => double.tryParse((await _read(name)).trim()) ?? 0;

  Future<void> _measure(int attempt) async {
    try {
      final measure = await _take(attempt);
      if (measure != null) {
        _measured = true;
        await record(measure);
      }
    } catch (error) {
      // A player disposed in the middle: nothing to measure
      _log.fine('No decoder measure: $error');
    } finally {
      // Still this try: the next steady playback may try again (a cancelled try was reset by its cancel)
      if (attempt == _try) {
        _timer = null;
      }
    }
  }

  /// The measure of the try [attempt], null when the playback was not steady enough to say anything
  Future<DecodeMeasure?> _take(int attempt) async {
    final positionBefore = _engine.position.value;
    final dropsBefore = await _int('frame-drop-count') + await _int('decoder-frame-drop-count');
    final started = _now();
    await Future<void>.delayed(window);
    if (attempt != _try || _disposed) {
      return null;
    }
    final elapsed = _now().difference(started).inMicroseconds / Duration.microsecondsPerSecond;
    final dropsAfter = await _int('frame-drop-count') + await _int('decoder-frame-drop-count');
    final played = (_engine.position.value - positionBefore).inMicroseconds / Duration.microsecondsPerSecond;
    // A seek inside the window (the position jumped, either way) or the window hidden: not a measure
    if (attempt != _try || elapsed <= 0 || played < 0 || played > elapsed * 1.1 || !_appShown()) {
      return null;
    }
    // Another speed than normal, or two streams stacked by a filter (raw two lens files, whose player measures
    // them itself): not the kind of video a question is about
    if ((await _double('speed')) != 1 || (await _read('lavfi-complex')).trim().isNotEmpty) {
      return null;
    }
    final codec = mimeOfMpvCodec(await _read('current-tracks/video/codec'));
    final width = await _int('width');
    final height = await _int('height');
    var frameRate = await _double('container-fps');
    if (frameRate <= 0) {
      frameRate = await _double('estimated-vf-fps');
    }
    if (codec == null || width <= 0 || height <= 0 || frameRate <= 0) {
      return null;
    }
    final hwdec = (await _read('hwdec-current')).trim();
    final frames = (frameRate * elapsed).round();
    // A video that plays slower than the clock lost those frames as surely as dropped ones: mpv slows down rather
    // than drops when nothing else (sound, the display) holds the time, as a decoder that hands its frames late does
    // without sound (measured: 8K HEVC copied back on the Intel UHD, 0.6 s of video a second, no frame counted as
    // dropped). A tenth of a second is left for the position's own updates.
    final behind = ((elapsed - played - 0.1) * frameRate).round();
    return DecodeMeasure(
      gpu: await gpu(),
      codec: codec,
      width: width,
      height: height,
      frameRate: (frameRate * 1000).round() / 1000,
      hwdec: hwdec.isEmpty ? 'no' : hwdec,
      frames: frames,
      dropped: math.max(0, math.min(frames, dropsAfter - dropsBefore + math.max(0, behind))),
      mpvVersion: (await _read('mpv-version')).trim(),
      at: _now(),
    );
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _cancel();
    unawaited(_subscription?.cancel());
    _subscription = null;
    _engine.playing.removeListener(_onState);
    _engine.buffering.removeListener(_onState);
  }
}

/// The GPU of the measures: the GPU in use where the probe knows it, MeasuredGpu.unknown elsewhere
Future<String> measuredGpuKey() async => (await DesktopGpuDecoders.adapter())?.key ?? MeasuredGpu.unknown;

/// Measures the playbacks of [engine] into the app's store (see [PlaybackDecodeSampler]); the returned function stops
void Function() watchDecoding(PlaybackEngine engine, MpvPropertyReader read) {
  final sampler = PlaybackDecodeSampler(engine, read, record: DecoderMeasureStore.shared.record, gpu: measuredGpuKey);
  return sampler.dispose;
}
