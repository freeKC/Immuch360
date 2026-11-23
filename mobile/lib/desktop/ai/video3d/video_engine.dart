// A 2D video made 3D side by side on a computer (store/m2/release-49/lots/video3d-plan.md, sections 2 and 4): the
// FFmpeg program decodes the source to eye frames on a pipe, the window loop of Video Depth Anything gives each frame
// its depth, relief-v1 draws its right eye (Rust), and the program encodes the side by side frames, one Matroska
// segment of about 30 s at a time, then joins them with the source's audio, tags and chapters into
// <name>_3D_LRF_Full_SBS.mp4 (or Half), with FFmpeg's st3d box "left right".
//
// The heavy part (the loop, the model, the right eye) goes through [VideoFrameWorker]: in the app an isolate of its
// own, in the tests and the command line tool the same code run in place ([LocalVideoFrameWorker]). The programs go
// through [VideoProgramRunner]: in the app the runner of the AI features (job object, immuch360-run, low priority),
// elsewhere a plain process. The engine is asynchronous Dart without Flutter.
//
// Each segment ends right after a window of the loop, so that its state (state-NNNN.bin) and job.json are enough to
// go on from there: Pause, a crash, a restart of the computer lose at most one segment. A resumed job seeks the
// decoder to the first frame the state holds back (relative to the file's start time, as -ss counts) and checks its
// time against pts.txt; when they differ, the job starts again rather than failing on every Resume. Once every frame is
// in a segment, job.json says so: a stop or a failure during the final mux goes back to the mux only. One state file
// is kept at a time, and the work folder goes once the MP4 is in place.
//
// A 360° video (lot ai-360-3d-51, VideoJobRequest.sphereEyeWidth) runs the same way with its own worker
// (sphere_video_worker.dart): eyes of 2:1, the frame top and bottom (the left eye on top), segments not marked, and the
// MP4 of the mux written once more with the marks of a 360° 3D video (spherical_mp4_writer.dart) before its rename.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/video3d/ffmpeg_commands.dart';
import 'package:immich_mobile/desktop/ai/video3d/sphere_depth.dart' show sphereShiftDegreesOf;
import 'package:immich_mobile/desktop/ai/video3d/spherical_mp4_writer.dart';
import 'package:immich_mobile/desktop/ai/video3d/vda_window_loop.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_frame_ops.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_job_file.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:path/path.dart' as p;

/// A program of the FFmpeg archive, running: its standard output as bytes
abstract interface class VideoProgram {
  Stream<List<int>> get stdout;
  IOSink get stdin;

  /// The end of its error output, for the message of a failure
  Future<String> get errors;
  Future<int> get exitCode;
  void kill();
}

/// Starts the programs of the FFmpeg archive
abstract interface class VideoProgramRunner {
  Future<VideoProgram> start(String executable, List<String> arguments);
}

/// Programs started as they are (the command line tool, the tests)
class DirectVideoProgramRunner implements VideoProgramRunner {
  const DirectVideoProgramRunner();

  @override
  Future<VideoProgram> start(String executable, List<String> arguments) async =>
      _DirectProgram(await Process.start(executable, arguments));
}

class _DirectProgram implements VideoProgram {
  _DirectProgram(this._process) {
    final tail = StringBuffer();
    _errors = _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach((text) {
          tail.write(text);
          if (tail.length > 8192) {
            final kept = tail.toString().substring(tail.length - 4096);
            tail
              ..clear()
              ..write(kept);
          }
        })
        .then((_) => tail.toString());
    unawaited(_process.stdin.done.then<void>((_) {}, onError: (Object _) {}));
  }

  final Process _process;
  late final Future<String> _errors;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  IOSink get stdin => _process.stdin;

  @override
  Future<String> get errors => _errors;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void kill() => _process.kill(ProcessSignal.sigkill);
}

/// A failure of a 3D video job, with what the program said
class VideoJobException implements Exception {
  const VideoJobException(this.message, {this.refusal});

  final String message;

  /// The refusal of the source, when that is why
  final VideoRefusal? refusal;

  @override
  String toString() => 'VideoJobException: $message';
}

/// The encoder of a segment stopped during a job (it closed its input, or ended with an error): [said] is the end of
/// what FFmpeg wrote. The job falls back to the next encoder once (VideoConversion.run); this reaches the queue only
/// through the error of a dead end.
class VideoEncoderStopped extends VideoJobException {
  const VideoEncoderStopped(super.message, {required this.encoder, required this.said});

  final VideoEncoder encoder;
  final String said;
}

/// The job was stopped by Pause or Cancel
class VideoJobStopped implements Exception {
  const VideoJobStopped(this.cancelled);

  final bool cancelled;

  @override
  String toString() => cancelled ? 'VideoJobStopped: cancelled' : 'VideoJobStopped: paused';
}

/// A side by side frame ready for the encoder
class VideoSbsFrame {
  const VideoSbsFrame({required this.index, required this.bytes, required this.holes});

  final int index;
  final Uint8List bytes;

  /// Pixels of the right eye filled from the background
  final int holes;
}

/// The heavy work of a job: the window loop, the model and the right eye
abstract interface class VideoFrameWorker {
  /// Takes the next eye frame; gives the side by side frames that became final
  Future<List<VideoSbsFrame>> add(Uint8List rgb);

  /// The end of the video: every frame left
  Future<List<VideoSbsFrame>> finish();

  /// The loop's state right after a window, null at any other point
  Future<VdaLoopState?> stateAfterWindow();

  /// Takes back a state and the eye frames of its held maps
  Future<void> restore(VdaLoopState state, List<Uint8List> heldFrames);

  /// Windows run and cuts found so far
  Future<({int windows, List<int> cuts})> counts();

  Future<void> close();
}

/// How a frame is drawn
class VideoReliefSettings {
  const VideoReliefSettings({
    required this.parallax,
    this.convergence = 0.5,
    this.packing = VideoSbsPacking.full,
    this.edgeFade = true,
    this.sphere = false,
  });

  final double parallax;
  final double convergence;
  final VideoSbsPacking packing;

  /// The soft floating window (plan 4.6), on by default
  final bool edgeFade;

  /// A 360° video: the right eye drawn around the sphere (relief-360), the frame top and bottom; packing, convergence
  /// and the floating window do not apply
  final bool sphere;

  /// The shift of the nearest point at the equator of a 360° video, from the strength (sphereShiftDegreesOf)
  double get sphereShiftDegrees => sphereShiftDegreesOf(parallax);
}

/// The worker in the caller's isolate: [VdaWindowLoop] and [VideoFrameOps] called in place
class LocalVideoFrameWorker implements VideoFrameWorker {
  LocalVideoFrameWorker({
    required this.ops,
    required VdaModel model,
    required this.eyeWidth,
    required this.eyeHeight,
    required int modelWidth,
    required int modelHeight,
    required this.relief,
    VideoDepthAlignment alignment = VideoDepthAlignment.upstream,
    this.onMap,
  }) : _loop = VdaWindowLoop(
         ops: ops,
         model: model,
         eyeWidth: eyeWidth,
         eyeHeight: eyeHeight,
         modelWidth: modelWidth,
         modelHeight: modelHeight,
         alignment: alignment,
       ),
       _modelWidth = modelWidth,
       _modelHeight = modelHeight,
       _band = relief.edgeFade ? videoEdgeBand(relief.parallax, eyeWidth, relief.convergence) : 0;

  final VideoFrameOps ops;
  final int eyeWidth;
  final int eyeHeight;
  final VideoReliefSettings relief;

  /// Hears each final map with its percentiles (the measures of the command line tool)
  final void Function(VdaFinalFrame frame)? onMap;
  final VdaWindowLoop _loop;
  final int _modelWidth;
  final int _modelHeight;
  final int _band;

  List<VideoSbsFrame> _draw(List<VdaFinalFrame> frames) => [for (final frame in frames) _drawOne(frame)];

  VideoSbsFrame _drawOne(VdaFinalFrame frame) {
    onMap?.call(frame);
    final sbs = Uint8List(eyeWidth * eyeHeight * 6);
    for (var y = 0; y < eyeHeight; y++) {
      sbs.setRange(y * eyeWidth * 6, y * eyeWidth * 6 + eyeWidth * 3, frame.rgb, y * eyeWidth * 3);
    }
    final holes = ops.reliefEye(
      sbs,
      eyeWidth,
      eyeHeight,
      frame.map,
      _modelWidth,
      _modelHeight,
      p2: frame.p2,
      p98: frame.p98,
      parallax: relief.parallax,
      convergence: relief.convergence,
    );
    if (_band > 0) {
      ops.edgeFade(sbs, eyeWidth, eyeHeight, _band);
    }
    if (relief.packing == VideoSbsPacking.half) {
      final half = Uint8List(eyeWidth * eyeHeight * 3);
      ops.halfSbs(sbs, eyeWidth, eyeHeight, half);
      return VideoSbsFrame(index: frame.index, bytes: half, holes: holes);
    }
    return VideoSbsFrame(index: frame.index, bytes: sbs, holes: holes);
  }

  @override
  Future<List<VideoSbsFrame>> add(Uint8List rgb) async => _draw(_loop.add(rgb));

  @override
  Future<List<VideoSbsFrame>> finish() async => _draw(_loop.finish());

  @override
  Future<VdaLoopState?> stateAfterWindow() async => _loop.stateAfterWindow();

  @override
  Future<void> restore(VdaLoopState state, List<Uint8List> heldFrames) async => _loop.restore(state, heldFrames);

  @override
  Future<({int windows, List<int> cuts})> counts() async => (windows: _loop.windowsRun, cuts: [..._loop.cuts]);

  @override
  Future<void> close() async => ops.dispose();
}

/// Where a job is
class VideoJobProgress {
  const VideoJobProgress({
    required this.framesDone,
    required this.framesTotal,
    this.framesPerSecond,
    this.timeLeft,
    this.windows = 0,
    this.segmentsDone = 0,
    this.muxing = false,
    this.encoderSwitch,
  });

  /// Frames final and encoded, of about [framesTotal]
  final int framesDone;
  final int framesTotal;

  /// From this job's own windows: null until two windows ran
  final double? framesPerSecond;
  final Duration? timeLeft;
  final int windows;

  /// The segments closed in the work folder: what a stop keeps
  final int segmentsDone;

  /// Every frame is in a segment: the final mux runs
  final bool muxing;

  /// The encoder of the job stopped and the job went on with the next one: said in its row
  final ({VideoEncoder from, VideoEncoder to})? encoderSwitch;

  VideoJobProgress withSwitch(({VideoEncoder from, VideoEncoder to})? value) => VideoJobProgress(
    framesDone: framesDone,
    framesTotal: framesTotal,
    framesPerSecond: framesPerSecond,
    timeLeft: timeLeft,
    windows: windows,
    segmentsDone: segmentsDone,
    muxing: muxing,
    encoderSwitch: value,
  );

  double get fraction => framesTotal <= 0 ? 0 : math.min(1, framesDone / framesTotal);
}

/// What a job was asked
class VideoJobRequest {
  const VideoJobRequest({
    required this.sourcePath,
    required this.outputPath,
    required this.workFolder,
    required this.ffmpeg,
    required this.ffprobe,
    required this.quality,
    required this.relief,
    this.alignment = VideoDepthAlignment.upstream,
    this.encoders,
    this.segmentSeconds = 30,
    this.keys = const {},
    this.sphereEyeWidth,
  });

  final String sourcePath;

  /// The MP4 to write (through a .part file beside it)
  final String outputPath;

  /// The work folder of the job: segments, states, job.json
  final Directory workFolder;
  final String ffmpeg;
  final String ffprobe;
  final VideoDepthQuality quality;
  final VideoReliefSettings relief;
  final VideoDepthAlignment alignment;

  /// The encoders to try, in order; those of this computer when null
  final List<VideoEncoder>? encoders;

  /// About how long each segment is
  final int segmentSeconds;

  /// Our keys in the MP4 (com.immuch360.*)
  final Map<String, String> keys;

  /// A 360° video made 360° 3D: the width of each eye (its height half of it), the frame top and bottom; null for a
  /// flat video
  final int? sphereEyeWidth;

  bool get sphere => sphereEyeWidth != null;
}

/// What a finished job made
class VideoJobResult {
  const VideoJobResult({
    required this.outputPath,
    required this.frames,
    required this.slots,
    required this.encoder,
    required this.windows,
    required this.cuts,
    required this.holesMean,
    required this.segments,
  });

  final String outputPath;

  /// Frames decoded and given a depth, and frames of the output's grid
  final int frames;
  final int slots;
  final VideoEncoder encoder;
  final int windows;
  final List<int> cuts;

  /// The mean share of the right eye filled from the background
  final double holesMean;
  final int segments;
}

/// Makes the worker of a job once its sizes are known
typedef VideoWorkerFactory =
    Future<VideoFrameWorker> Function({
      required int eyeWidth,
      required int eyeHeight,
      required int modelWidth,
      required int modelHeight,
    });

/// Runs ffprobe on [path]
Future<Map<String, Object?>> probeVideo(VideoProgramRunner runner, String ffprobe, String path) async {
  final program = await runner.start(ffprobe, videoProbeArguments(path));
  unawaited(program.stdin.close());
  final text = await program.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
  final code = await program.exitCode.timeout(const Duration(minutes: 10));
  if (code != 0) {
    throw VideoJobException(
      'ffprobe stopped with $code: ${videoProgramTail(await program.errors)}',
      refusal: VideoRefusal.unreadable,
    );
  }
  try {
    return (jsonDecode(text) as Map).cast<String, Object?>();
  } on FormatException {
    throw const VideoJobException('ffprobe gave no JSON', refusal: VideoRefusal.unreadable);
  }
}

/// The test of [encoder] at [width] x [height] and [rate], as a job runs it: the command of a segment, fed
/// [videoEncoderTestFrames] RGB frames on its standard input, written into a Matroska file in [folder], that file read
/// back by ffprobe (decoded, every frame there), then deleted. Null when it passed, else why it failed (the end of what
/// FFmpeg said).
Future<String?> testVideoEncoder(
  VideoProgramRunner runner,
  String ffmpeg,
  String ffprobe,
  VideoEncoder encoder,
  int width,
  int height,
  VideoRate rate, {
  required Directory folder,
  bool markLeftRight = true,
  Duration timeout = const Duration(seconds: 90),
}) async {
  await folder.create(recursive: true);
  final output = File(p.join(folder.path, 'encoder-test-${encoder.name}-${width}x$height.mkv'));
  final program = await runner.start(
    ffmpeg,
    videoEncoderTestArguments(encoder, width, height, rate, outputPath: output.path, markLeftRight: markLeftRight),
  );
  unawaited(program.stdout.drain<void>().then<void>((_) {}, onError: (Object _) {}));
  try {
    int code;
    try {
      code = await () async {
        await _feedTestFrames(program, width, height);
        return program.exitCode;
      }().timeout(timeout);
    } on TimeoutException {
      program.kill();
      return 'no answer in ${timeout.inSeconds} s';
    }
    if (code != 0) {
      final said = videoProgramTail(await program.errors.timeout(const Duration(seconds: 5), onTimeout: () => ''));
      return 'stopped with $code${said.isEmpty ? '' : ': $said'}';
    }
    // Decodable, with every frame: the file the job's mux would read
    final check = await runner.start(ffprobe, videoTestCheckArguments(output.path));
    unawaited(check.stdin.close().then<void>((_) {}, onError: (Object _) {}));
    String text;
    int checkCode;
    try {
      text = await check.stdout.transform(const Utf8Decoder(allowMalformed: true)).join().timeout(timeout);
      checkCode = await check.exitCode.timeout(timeout);
    } on TimeoutException {
      check.kill();
      return 'its file was not read in ${timeout.inSeconds} s';
    }
    if (checkCode != 0) {
      return 'its file cannot be read: ${videoProgramTail(await check.errors)}';
    }
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      json = null;
    }
    final frames = videoTestFrameCount(json);
    if (frames != videoEncoderTestFrames) {
      return 'its file holds ${frames ?? 'no'} frames of $videoEncoderTestFrames';
    }
    return null;
  } finally {
    await _deleteQuietly(output);
  }
}

/// [work] on the input of [program], or the end of [program] if it comes first: a write to a program that died
/// between two flushes fails the done future of its input, and a later flush would wait for ever
Future<void> _whileRunning(VideoProgram program, Future<void> work) => Future.any([
  work,
  program.exitCode.then<void>((code) => throw StateError('the program ended with $code while it was written to')),
]);

/// The frames of an encoder test: a gradient that moves, two pictures in turn (a plain grey is no work for an encoder)
Future<void> _feedTestFrames(VideoProgram program, int width, int height) async {
  final stdin = program.stdin;
  Uint8List picture(int shift) {
    final rgb = Uint8List(width * height * 3);
    var at = 0;
    for (var y = 0; y < height; y++) {
      final g = (y * 255 ~/ math.max(1, height - 1)) & 0xFF;
      for (var x = 0; x < width; x++) {
        rgb[at++] = ((x + shift) * 255 ~/ math.max(1, width - 1)) & 0xFF;
        rgb[at++] = g;
        rgb[at++] = (x ^ y) & 0xFF;
      }
    }
    return rgb;
  }

  final pictures = [picture(0), picture(math.max(1, width ~/ 64))];
  try {
    for (var i = 0; i < videoEncoderTestFrames; i++) {
      stdin.add(pictures[i % 2]);
      await _whileRunning(program, stdin.flush());
    }
    await Future.any([stdin.close(), program.exitCode]);
  } on Object {
    // The encoder closed its input: its exit code and its words say why (its input is left as it is: a flush given up
    // keeps it bound)
  }
}

/// The first encoder of [order] whose test ([testVideoEncoder]) at [width] x [height] passes, null for none; those of
/// [skip] are not tried (they stopped during a job at this size on this computer)
Future<VideoEncoder?> chooseVideoEncoder(
  VideoProgramRunner runner,
  String ffmpeg,
  String ffprobe,
  List<VideoEncoder> order,
  int width,
  int height,
  VideoRate rate, {
  required Directory folder,
  bool markLeftRight = true,
  Set<VideoEncoder> skip = const {},
  Duration timeout = const Duration(seconds: 90),
  void Function(VideoEncoder encoder, bool passed, String reason)? onTest,
}) async {
  for (final encoder in order) {
    if (skip.contains(encoder)) {
      continue;
    }
    final failure = await testVideoEncoder(
      runner,
      ffmpeg,
      ffprobe,
      encoder,
      width,
      height,
      rate,
      folder: folder,
      markLeftRight: markLeftRight,
      timeout: timeout,
    );
    onTest?.call(encoder, failure == null, failure ?? '');
    if (failure == null) {
      return encoder;
    }
  }
  return null;
}

/// The eye width of the 360° 3D videos below [eye] that the dialog offers, null for a flat video or the smallest size
int? videoSmallerSphereEye(int? eye) => eye == null ? null : sphereEyeWidths.where((width) => width < eye).lastOrNull;

/// What a computer remembers of its encoders: those that stopped during a job at a frame size although their test
/// passed, so that the next jobs and the dialog skip them there (video_encoder_memory.dart keeps it in a file)
abstract interface class VideoEncoderMemory {
  /// The encoders that stopped at [width] x [height]
  Future<Set<VideoEncoder>> stoppedAt(int width, int height);

  Future<void> remember(VideoEncoder encoder, int width, int height, String said);
}

/// Reads frames of exactly [frameBytes] bytes from a byte stream
class _FrameReader {
  _FrameReader(Stream<List<int>> stream, this.frameBytes, this._errors) : _iterator = StreamIterator(stream);

  final int frameBytes;
  final Future<String> Function() _errors;
  final StreamIterator<List<int>> _iterator;
  Uint8List? _pending;
  var _pendingAt = 0;

  /// The next frame, null at the end of the stream (a partial frame at the end is an error)
  Future<Uint8List?> next() async {
    final frame = Uint8List(frameBytes);
    var filled = 0;
    while (filled < frameBytes) {
      var pending = _pending;
      if (pending == null || _pendingAt >= pending.length) {
        if (!await _iterator.moveNext()) {
          if (filled == 0) {
            return null;
          }
          final said = videoProgramTail(await _errors().timeout(const Duration(seconds: 5), onTimeout: () => ''));
          throw VideoJobException('The decoder stopped inside a frame ($filled of $frameBytes bytes): $said');
        }
        final chunk = _iterator.current;
        pending = _pending = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        _pendingAt = 0;
      }
      final take = math.min(frameBytes - filled, pending.length - _pendingAt);
      frame.setRange(filled, filled + take, pending, _pendingAt);
      filled += take;
      _pendingAt += take;
    }
    return frame;
  }

  Future<void> cancel() => _iterator.cancel();
}

/// The times of the decoded frames, read from the -stats_enc_pre file as the decoder writes it
class _StatsTail {
  _StatsTail(this.file);

  final File file;
  final _times = <double>[];
  var _read = 0;
  var _partial = '';

  /// The time of the decoder's frame [n], waiting up to [patience] for its line
  Future<double> timeOf(int n, {Duration patience = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(patience);
    while (n >= _times.length) {
      await _poll();
      if (n < _times.length) {
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw VideoJobException('No time for frame $n in ${p.basename(file.path)}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return _times[n];
  }

  Future<void> _poll() async {
    if (!file.existsSync()) {
      return;
    }
    final length = file.lengthSync();
    if (length <= _read) {
      return;
    }
    final reader = await file.open();
    try {
      await reader.setPosition(_read);
      final bytes = await reader.read(length - _read);
      _read += bytes.length;
      final text = _partial + utf8.decode(bytes, allowMalformed: true);
      final lines = text.split('\n');
      _partial = lines.removeLast();
      for (final line in lines) {
        final parsed = parseStatsLine(line);
        if (parsed != null && parsed.frame == _times.length) {
          _times.add(parsed.seconds);
        }
      }
    } finally {
      await reader.close();
    }
  }
}

/// One encoder process writing one segment; an encoder that closes its input or ends with an error is a
/// [VideoEncoderStopped] with the end of what it said
class _SegmentWriter {
  _SegmentWriter(this.index, this.path, this.program, this.firstFrame, this.encoder);

  final int index;
  final String path;
  final VideoProgram program;
  final int firstFrame;
  final VideoEncoder encoder;
  var slots = 0;
  var _unflushed = 0;

  Future<void> write(Uint8List bytes, int repeats) async {
    try {
      for (var r = 0; r < repeats; r++) {
        program.stdin.add(bytes);
        slots++;
        _unflushed += bytes.length;
        // Held back by the encoder rather than kept in memory
        if (_unflushed >= 32 * 1024 * 1024) {
          await _whileRunning(program, program.stdin.flush());
          _unflushed = 0;
        }
      }
    } on Object catch (error) {
      throw await _stopped('$error');
    }
  }

  Future<void> close() async {
    try {
      await _whileRunning(program, program.stdin.flush());
      // Its end may come before the close is told
      await Future.any([program.stdin.close(), program.exitCode]);
    } on Object catch (error) {
      throw await _stopped('$error');
    }
    final code = await program.exitCode.timeout(const Duration(minutes: 10));
    if (code != 0) {
      throw await _stopped(null, code);
    }
  }

  Future<VideoEncoderStopped> _stopped(String? writeError, [int? exit]) async {
    final code =
        exit ??
        await program.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            program.kill();
            return -1;
          },
        );
    final said = videoProgramTail(await program.errors.timeout(const Duration(seconds: 5), onTimeout: () => ''));
    final words = said.isNotEmpty ? said : (writeError ?? 'no word from FFmpeg');
    return VideoEncoderStopped(
      'The encoder ${encoder.name} of ${p.basename(path)} stopped with $code after $slots frames: $words',
      encoder: encoder,
      said: words,
    );
  }
}

/// One 3D video job: [run] makes it, or goes on from where its work folder says it stopped
class VideoConversion {
  VideoConversion({
    required this.request,
    required this.runner,
    required this.workerFactory,
    this.onProgress,
    this.onLog,
    this.betweenWindows,
    this.encoderMemory,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final VideoJobRequest request;
  final VideoProgramRunner runner;
  final VideoWorkerFactory workerFactory;
  final void Function(VideoJobProgress progress)? onProgress;
  final void Function(String line)? onLog;

  /// Awaited after each window of the loop, its segment closed when one ended there: the queue lets the 3D photos
  /// asked meanwhile run then, the session of the model kept (video3d-plan.md, section 2). The time it takes is left
  /// out of the pace of the job.
  final Future<void> Function()? betweenWindows;

  /// The encoders that stopped during a job on this computer: skipped at their size, and told of the one that stops
  final VideoEncoderMemory? encoderMemory;
  final DateTime Function() _now;

  /// The frame of the encoder, once the job read its source
  ({int width, int height, VideoRate rate, bool markLeftRight})? _frame;

  /// The encoder the job went on with after the one it chose stopped; the switch said in its row
  VideoEncoder? _switchedTo;
  ({VideoEncoder from, VideoEncoder to})? _switch;
  VideoJobProgress? _lastProgress;

  var _stop = 0; // 0 run, 1 pause, 2 cancel
  final _running = <VideoProgram>[];

  /// Stops the job at the next frame: the segment in progress is dropped, the work folder kept
  void pause() => _stop = math.max(_stop, 1);

  /// Stops the job at the next frame; the caller deletes the work folder
  void cancel() => _stop = 2;

  void _checkStop() {
    if (_stop > 0) {
      throw VideoJobStopped(_stop == 2);
    }
  }

  void _log(String line) => onLog?.call(line);

  void _emit(VideoJobProgress progress) {
    final told = progress.withSwitch(_switch);
    _lastProgress = told;
    onProgress?.call(told);
  }

  /// Makes the job. An encoder that stops during it (its test passed: a driver, a size it takes only at first) does not
  /// fail the job: it goes on once with the next encoder of the list that passes its test at this size, from the last
  /// segment kept (the segments before made again by the new encoder), and this computer remembers the one that stopped.
  /// A second stop, or no encoder left, is the error of a dead end: the encoder, the size, a smaller size to choose.
  Future<VideoJobResult> run() async {
    while (true) {
      try {
        return await _runResuming();
      } on VideoEncoderStopped catch (stopped) {
        _log(stopped.message);
        if (_stop > 0) {
          throw VideoJobStopped(_stop == 2);
        }
        if (_switch != null) {
          throw _deadEnd(stopped);
        }
        VideoEncoder? next;
        try {
          next = await _fallBack(stopped);
        } on VideoEncoderStopped catch (again) {
          _log(again.message);
          throw _deadEnd(again);
        }
        if (next == null) {
          throw _deadEnd(stopped);
        }
      }
    }
  }

  Future<VideoJobResult> _runResuming() async {
    try {
      return await _run(resume: true);
    } on _ResumeRefused catch (refused) {
      // The work folder does not match the source as the decoder reads it now: every later Resume would fail the
      // same way, so the job starts again rather than throwing
      _log('${refused.reason}: started again');
      return _run(resume: false);
    }
  }

  /// After [stopped]: remembered for this computer, the next encoder of the list tested at the frame of the job, the
  /// segments written so far made again by it, the job file told; null when no encoder is left
  Future<VideoEncoder?> _fallBack(VideoEncoderStopped stopped) async {
    final frame = _frame;
    if (frame == null) {
      return null;
    }
    try {
      await encoderMemory?.remember(stopped.encoder, frame.width, frame.height, stopped.said);
    } on Object catch (error) {
      _log('the stop of the encoder was not remembered: $error');
    }
    final order = request.encoders ?? VideoEncoder.forThisComputer;
    final at = order.indexOf(stopped.encoder);
    final rest = at < 0 ? const <VideoEncoder>[] : order.sublist(at + 1);
    final next = await chooseVideoEncoder(
      runner,
      request.ffmpeg,
      request.ffprobe,
      rest,
      frame.width,
      frame.height,
      frame.rate,
      folder: request.workFolder,
      markLeftRight: frame.markLeftRight,
      onTest: _logTest,
    );
    if (next == null) {
      return null;
    }
    final job = await VideoJobFile.read(request.workFolder);
    if (job != null) {
      if (job.segments.isNotEmpty) {
        await _remakeSegments(job, next, frame);
      }
      job.settings['encoder'] = next.name;
      await job.write(request.workFolder);
    }
    _switchedTo = next;
    _switch = (from: stopped.encoder, to: next);
    _log('the encoder ${stopped.encoder.name} stopped: continuing with ${next.name} from the last segment kept');
    if (_lastProgress case final last?) {
      _emit(last);
    }
    return next;
  }

  /// The segments of [job] made again by [encoder], each into a file of its own first, then all put in place
  Future<void> _remakeSegments(
    VideoJobFile job,
    VideoEncoder encoder,
    ({int width, int height, VideoRate rate, bool markLeftRight}) frame,
  ) async {
    final folder = request.workFolder;
    final remade = <String>[];
    for (final segment in job.segments) {
      _checkStop();
      final input = p.join(folder.path, segment.name);
      final output = '$input.remade';
      final program = await runner.start(
        request.ffmpeg,
        videoSegmentTranscodeArguments(
          encoder: encoder,
          width: frame.width,
          height: frame.height,
          rate: frame.rate,
          inputPath: input,
          segmentPath: output,
          markLeftRight: frame.markLeftRight,
        ),
      );
      _running.add(program);
      unawaited(program.stdin.close().then<void>((_) {}, onError: (Object _) {}));
      unawaited(program.stdout.drain<void>().then<void>((_) {}, onError: (Object _) {}));
      final code = await program.exitCode;
      _running.remove(program);
      if (code != 0) {
        for (final path in [...remade, output]) {
          await _deleteQuietly(File(path));
        }
        final said = videoProgramTail(await program.errors);
        throw VideoEncoderStopped(
          'The encoder ${encoder.name} could not make ${segment.name} again (exit $code): $said',
          encoder: encoder,
          said: said,
        );
      }
      remade.add(output);
      _log('segment ${segment.index} made again by ${encoder.name}');
    }
    final segments = <VideoSegment>[];
    for (final (i, segment) in job.segments.indexed) {
      final file = await File(remade[i]).rename(p.join(folder.path, segment.name));
      segments.add(
        VideoSegment(
          index: segment.index,
          name: segment.name,
          firstFrame: segment.firstFrame,
          endFrame: segment.endFrame,
          slots: segment.slots,
          bytes: file.lengthSync(),
          sha256: await sha256OfFile(file),
        ),
      );
    }
    job.segments
      ..clear()
      ..addAll(segments);
  }

  /// The error of a job no encoder of this computer can finish at its size: the encoder, the size and, for a 360° video
  /// made above 2048, the smaller size to choose
  VideoJobException _deadEnd(VideoEncoderStopped stopped) {
    final frame = _frame;
    final smaller = videoSmallerSphereEye(request.sphereEyeWidth);
    return VideoJobException(
      videoEncoderDeadEndMessage(
        encoder: stopped.encoder,
        width: frame?.width ?? 0,
        height: frame?.height ?? 0,
        smaller: smaller,
        said: stopped.said,
      ),
    );
  }

  void _logTest(VideoEncoder encoder, bool passed, String reason) =>
      _log('encoder test ${encoder.name}: ${passed ? 'passed' : 'failed $reason'}');

  Future<VideoJobResult> _run({required bool resume}) async {
    final folder = request.workFolder;
    await folder.create(recursive: true);
    final source = File(request.sourcePath);
    final json = await probeVideo(runner, request.ffprobe, request.sourcePath);
    final video = VideoSource.fromFfprobe(json);
    final sphereEye = request.sphereEyeWidth;
    // The app's own probe of the boxes as well as ffprobe's, as the dialog reads a file of this computer: a video of
    // the server or of a share is read for the first time here, after its download, and its Spherical Video V1 XML
    // (two eyes, a half sphere) is seen by this probe only
    SphericalProbe? spherical;
    try {
      spherical = await probeSphericalMetadata(videoFileRangeReader(request.sourcePath));
    } on Object catch (error) {
      _log('the boxes of the source were not read: $error');
    }
    final check = checkVideoSource(
      video,
      fileName: p.basename(request.sourcePath),
      spherical: spherical,
      ask: sphereEye != null ? VideoProjectionAsk.sphere : VideoProjectionAsk.flat,
    );
    if (!check.accepted) {
      throw VideoJobException('Refused: ${check.skip!.name}', refusal: check.skip);
    }
    final info = check.source!;
    final grid = check.grid!;
    final side = request.quality.shortSide;
    final eye = sphereEye != null ? (width: sphereEye, height: sphereEye ~/ 2) : videoEyeSize(info);
    final model = sphereEye != null
        ? (width: side, height: side)
        : videoModelSize(eye.width, eye.height, request.quality);
    final outWidth = sphereEye != null || request.relief.packing == VideoSbsPacking.half ? eye.width : eye.width * 2;
    final outHeight = sphereEye != null ? 2 * eye.height : eye.height;
    final identity = await VideoSourceIdentity.of(source);
    for (final track in info.audio) {
      if (!track.isKept) {
        _log('audio track ${track.index} (${track.codec}): the program cannot read it, not kept');
      }
    }

    // A job already in the folder for this source and these settings goes on; anything else starts again
    final settings = <String, Object?>{
      'quality': request.quality.name,
      'parallax': request.relief.parallax,
      'convergence': request.relief.convergence,
      'packing': request.relief.packing.name,
      'edgeFade': request.relief.edgeFade,
      'alignment': request.alignment.name,
      'eye': [eye.width, eye.height],
      'model': [model.width, model.height],
      'grid': grid.rate.ffmpeg,
      'slowMotion': grid.slowMotion,
      // Only for a 360° video: the work folders of the flat ones keep the settings they had
      'sphere': ?sphereEye,
    };
    var job = resume ? await VideoJobFile.read(folder) : null;
    VdaLoopState? state;
    if (job != null &&
        (job.identity != identity ||
            jsonEncode({...job.settings}..remove('encoder')) != jsonEncode(settings) ||
            job.finished)) {
      _log('the work folder holds another job: started again');
      job = null;
    }
    if (job != null && job.segments.isNotEmpty) {
      // Every segment as it was written
      var intact = true;
      for (final segment in job.segments) {
        final file = File(p.join(folder.path, segment.name));
        if (!file.existsSync() || await sha256OfFile(file) != segment.sha256) {
          intact = false;
        }
      }
      if (job.encoded != null) {
        if (!intact) {
          _log('a segment of the work folder changed: started again');
          job = null;
        }
      } else {
        final last = job.segments.last;
        final stateFile = File(p.join(folder.path, VideoSegment.stateNameOf(last.index)));
        state = intact && stateFile.existsSync() ? decodeVdaLoopState(await stateFile.readAsBytes()) : null;
        if (state == null || state.firstHeld != last.endFrame) {
          _log('the state of the work folder cannot be read: started again');
          job = null;
          state = null;
        }
      }
    } else if (job != null && job.encoded != null) {
      _log('the work folder holds no segment: started again');
      job = null;
    }

    _frame = (width: outWidth, height: outHeight, rate: grid.rate, markLeftRight: sphereEye == null);
    final remembered = job != null && job.settings['encoder'] is String
        ? VideoEncoder.values.asNameMap()[job.settings['encoder']! as String]
        : null;
    if (job != null && remembered == null) {
      _log('the work folder names an encoder this version does not know: started again');
      job = null;
      state = null;
    }
    final VideoEncoder? chosen;
    if (_switchedTo case final switched?) {
      chosen = switched;
    } else if (job != null && remembered != null) {
      // A resumed job tests the encoder its file names before the first frame, as a new job tests its own: a driver
      // updated or a card changed since the pause would otherwise stop at the first segment (only the mux needs none)
      chosen = job.encoded != null
          ? remembered
          : await _retestOnResume(job, remembered, outWidth, outHeight, grid.rate, markLeftRight: sphereEye == null);
    } else {
      chosen = await _chooseEncoder(outWidth, outHeight, grid.rate, markLeftRight: sphereEye == null);
    }
    if (chosen == null) {
      throw VideoJobException(
        'No encoder of the FFmpeg program passed its test at ${outWidth}x$outHeight (the log of the job says why)',
      );
    }
    final encoder = chosen;
    if (job == null) {
      for (final entity in folder.listSync()) {
        entity.deleteSync(recursive: true);
      }
      job = VideoJobFile(
        id: p.basename(folder.path),
        sourcePath: request.sourcePath,
        identity: identity,
        outputPath: request.outputPath,
        settings: {...settings, 'encoder': encoder.name},
      );
      await job.write(folder);
    }
    final jobFile = job;
    _log('eye ${eye.width}x${eye.height}, model ${model.width}x${model.height}, grid ${grid.rate}, ${encoder.name}');
    final started = _now();

    // Stopped during the final mux: every frame is in a segment already
    if (jobFile.encoded case final encoded?) {
      _log('every frame is in a segment already: the final mux');
      _emit(
        VideoJobProgress(
          framesDone: encoded.frames,
          framesTotal: encoded.frames,
          timeLeft: Duration.zero,
          segmentsDone: jobFile.segments.length,
          muxing: true,
        ),
      );
      return _mux(jobFile, encoded, json, info, check.audio, grid, encoder, started);
    }

    final worker = await workerFactory(
      eyeWidth: eye.width,
      eyeHeight: eye.height,
      modelWidth: model.width,
      modelHeight: model.height,
    );
    final ptsFile = File(p.join(folder.path, 'pts.txt'));
    final times = <double>[];
    if (state != null && ptsFile.existsSync()) {
      for (final line in await ptsFile.readAsLines()) {
        final value = double.tryParse(line.trim());
        if (value != null) {
          times.add(value);
        }
      }
      if (times.length < state.nextIndex) {
        await worker.close();
        throw const _ResumeRefused('pts.txt holds fewer frames than the state');
      }
      times.removeRange(state.nextIndex, times.length);
    } else if (ptsFile.existsSync()) {
      await ptsFile.delete();
    }
    final ptsSink = ptsFile.openWrite(mode: FileMode.writeOnly)..write(times.map((t) => '$t\n').join());

    final frameBytes = eye.width * eye.height * 3;
    final total = info.frameCount != null && !grid.slowMotion
        ? info.frameCount!
        : ((info.duration ?? 0) * (grid.slowMotion ? 30 : grid.rate.value)).round();
    var segmentIndex = jobFile.segments.isEmpty ? 0 : jobFile.segments.last.index;
    var done = state?.firstHeld ?? 0;
    var holesSum = 0.0;
    var holesCount = 0;
    final segmentFrames = math.max(vdaStep, (request.segmentSeconds * grid.rate.value).round());
    final windowTimes = <DateTime>[];
    _SegmentWriter? writer;
    final pendingFrames = <VideoSbsFrame>[];

    Future<_SegmentWriter> openSegment(int firstFrame) async {
      segmentIndex++;
      final name = VideoSegment.nameOf(segmentIndex);
      final path = p.join(folder.path, name);
      final program = await runner.start(
        request.ffmpeg,
        videoSegmentArguments(
          encoder: encoder,
          width: outWidth,
          height: outHeight,
          rate: grid.rate,
          segmentPath: path,
          markLeftRight: sphereEye == null,
        ),
      );
      _running.add(program);
      unawaited(program.stdout.drain<void>().then<void>((_) {}, onError: (Object _) {}));
      return _SegmentWriter(segmentIndex, path, program, firstFrame, encoder);
    }

    // The decoder, from the start or from the first frame the state holds back
    final statsFile = File(p.join(folder.path, 'stats-${segmentIndex + 1}.txt'));
    if (statsFile.existsSync()) {
      await statsFile.delete();
    }
    final firstDecoded = state?.firstHeld ?? 0;
    double? seek;
    if (state != null) {
      // -ss counts from the start time of the file (its format start_time: 1.4 s in most MPEG-TS), while -copyts
      // keeps the times of pts.txt absolute: without it, a TS or M2TS source would resume 1.4 s too late
      seek = math.max(0.0, times[firstDecoded] - _formatStart(json, info) - 0.5 / grid.rate.value);
    }
    final decoder = await runner.start(
      request.ffmpeg,
      videoDecoderArguments(
        path: request.sourcePath,
        source: info,
        eyeWidth: eye.width,
        eyeHeight: eye.height,
        slowMotion: grid.slowMotion,
        statsPath: statsFile.path,
        seekSeconds: seek,
      ),
    );
    _running.add(decoder);
    unawaited(decoder.stdin.close());
    final reader = _FrameReader(decoder.stdout, frameBytes, () => decoder.errors);
    final stats = _StatsTail(statsFile);
    var decodedHere = 0;

    Future<double> timeOfDecoded(int n) => stats.timeOf(n);

    void report({bool muxing = false}) {
      double? fps;
      Duration? left;
      if (windowTimes.length >= 3) {
        final span = windowTimes.last.difference(windowTimes[windowTimes.length - 3]).inMicroseconds / 1e6;
        if (span > 0) {
          fps = 2 * vdaStep / span;
          left = Duration(seconds: (math.max(0, total - done) / fps).round());
        }
      }
      _emit(
        VideoJobProgress(
          framesDone: done,
          framesTotal: math.max(total, done),
          framesPerSecond: fps,
          timeLeft: muxing ? Duration.zero : left,
          windows: windowTimes.length,
          segmentsDone: jobFile.segments.length,
          muxing: muxing,
        ),
      );
    }

    // Repeats need the next frame's time: a frame waits in pendingFrames until it is known
    Future<void> writeFrames({required bool atEnd}) async {
      while (pendingFrames.isNotEmpty) {
        final frame = pendingFrames.first;
        final hasNext = frame.index + 1 < times.length;
        if (!hasNext && !atEnd) {
          return;
        }
        final repeats = hasNext
            ? math.max(
                0,
                videoGridSlot(times[frame.index + 1], times.first, grid.rate) -
                    videoGridSlot(times[frame.index], times.first, grid.rate),
              )
            : 1;
        writer ??= await openSegment(frame.index);
        await writer!.write(frame.bytes, repeats);
        holesSum += frame.holes / (eye.width * eye.height);
        holesCount++;
        done = frame.index + 1;
        pendingFrames.removeAt(0);
      }
    }

    Future<VideoSegment> addSegment(_SegmentWriter current) async {
      await current.close();
      _running.remove(current.program);
      final file = File(current.path);
      final segment = VideoSegment(
        index: current.index,
        name: p.basename(current.path),
        firstFrame: current.firstFrame,
        endFrame: done,
        slots: current.slots,
        bytes: file.lengthSync(),
        sha256: await sha256OfFile(file),
      );
      jobFile.segments.add(segment);
      return segment;
    }

    Future<void> closeSegment(VdaLoopState loopState) async {
      final current = writer!;
      writer = null;
      final previous = jobFile.segments.isEmpty ? null : jobFile.segments.last;
      await addSegment(current);
      await File(
        p.join(folder.path, VideoSegment.stateNameOf(current.index)),
      ).writeAsBytes(encodeVdaLoopState(loopState), flush: true);
      await ptsSink.flush();
      await jobFile.write(folder);
      // Only the state of the last segment is read again (55 MB at 392): the one before goes once job.json names
      // the new one
      if (previous != null) {
        await _deleteQuietly(File(p.join(folder.path, VideoSegment.stateNameOf(previous.index))));
      }
      _log('segment ${current.index}: frames ${current.firstFrame} to ${done - 1}, ${current.slots} slots');
    }

    final VideoJobEncoded encoded;
    try {
      if (state != null) {
        // The 8 held frames again, checked against the times written before
        final held = <Uint8List>[];
        for (var i = 0; i < vdaBlended; i++) {
          final frame = await reader.next();
          if (frame == null) {
            throw const _ResumeRefused('the source ended before the held frames of the state');
          }
          final time = await timeOfDecoded(decodedHere++);
          if ((time - times[firstDecoded + i]).abs() > 1e-6) {
            throw _ResumeRefused('frame ${firstDecoded + i} is at $time s, it was at ${times[firstDecoded + i]} s');
          }
          held.add(frame);
        }
        await worker.restore(state, held);
        report();
      }
      while (true) {
        _checkStop();
        final frame = await reader.next();
        if (frame == null) {
          break;
        }
        final index = (state?.nextIndex ?? 0) + decodedHere - (state == null ? 0 : vdaBlended);
        final time = await timeOfDecoded(decodedHere++);
        if (index != times.length) {
          throw VideoJobException('Frame $index decoded after ${times.length} times');
        }
        times.add(time);
        ptsSink.write('$time\n');
        final windowsBefore = (await worker.counts()).windows;
        final finals = await worker.add(frame);
        _checkStop();
        pendingFrames.addAll(finals);
        await writeFrames(atEnd: false);
        if ((await worker.counts()).windows > windowsBefore) {
          windowTimes.add(_now());
          if (writer != null && done - writer!.firstFrame >= segmentFrames && pendingFrames.isEmpty) {
            final loopState = await worker.stateAfterWindow();
            if (loopState != null && loopState.firstHeld == done) {
              await closeSegment(loopState);
            }
          }
          report();
          if (betweenWindows case final wait?) {
            final before = _now();
            await wait();
            _checkStop();
            // The time the photos took is not the pace of this job
            final yielded = _now().difference(before);
            if (yielded > Duration.zero) {
              for (var i = 0; i < windowTimes.length; i++) {
                windowTimes[i] = windowTimes[i].add(yielded);
              }
            }
          }
        }
      }
      final code = await decoder.exitCode;
      if (code != 0) {
        throw VideoJobException('The decoder stopped with $code: ${videoProgramTail(await decoder.errors)}');
      }
      _running.remove(decoder);
      pendingFrames.addAll(await worker.finish());
      await writeFrames(atEnd: true);
      if (writer != null) {
        final current = writer!;
        writer = null;
        await addSegment(current);
      }
      await ptsSink.flush();
      await ptsSink.close();
      final counts = await worker.counts();
      encoded = VideoJobEncoded(
        frames: done,
        firstTime: times.isEmpty ? _formatStart(json, info) : times.first,
        windows: counts.windows,
        cuts: counts.cuts,
        holesMean: holesCount == 0 ? 0 : holesSum / holesCount,
      );
      // From here a stop or a failure of the mux goes back to the mux, not to the frames
      jobFile.encoded = encoded;
      await jobFile.write(folder);
      report(muxing: true);
    } finally {
      for (final program in _running) {
        program.kill();
      }
      _running.clear();
      await reader.cancel();
      try {
        await ptsSink.close();
      } on Object {
        // Closed already
      }
      await worker.close();
      // A segment begun and not closed is not part of the job: a resume writes it again
      final current = writer;
      if (current != null) {
        await _deleteQuietly(File(current.path));
      }
    }
    // The states, the times and the stats of the decoder are not needed any more
    for (final entity in folder.listSync()) {
      final name = p.basename(entity.path);
      if (entity is File && (name.startsWith('state-') || name.startsWith('stats-') || name == 'pts.txt')) {
        await _deleteQuietly(entity);
      }
    }
    return _mux(jobFile, encoded, json, info, check.audio, grid, encoder, started);
  }

  /// The encoder of a resumed job: [remembered], the one its file names, when it passes its test again at this frame;
  /// else the first other encoder of the list that passes, the segments kept made again by it (so that the mux joins
  /// one codec), the job file and the row told of the switch. Null when none passes. A failed test is not a stop during
  /// a job: this computer does not remember it.
  Future<VideoEncoder?> _retestOnResume(
    VideoJobFile job,
    VideoEncoder remembered,
    int width,
    int height,
    VideoRate rate, {
    required bool markLeftRight,
  }) async {
    final failure = await testVideoEncoder(
      runner,
      request.ffmpeg,
      request.ffprobe,
      remembered,
      width,
      height,
      rate,
      folder: request.workFolder,
      markLeftRight: markLeftRight,
    );
    _log(
      'encoder test ${remembered.name} (the encoder of the job, on resume): ${failure == null ? 'passed' : 'failed $failure'}',
    );
    if (failure == null) {
      return remembered;
    }
    final order = request.encoders ?? VideoEncoder.forThisComputer;
    final next = await chooseVideoEncoder(
      runner,
      request.ffmpeg,
      request.ffprobe,
      [
        for (final other in order)
          if (other != remembered) other,
      ],
      width,
      height,
      rate,
      folder: request.workFolder,
      markLeftRight: markLeftRight,
      onTest: _logTest,
    );
    if (next == null) {
      return null;
    }
    if (job.segments.isNotEmpty) {
      await _remakeSegments(job, next, _frame!);
    }
    job.settings['encoder'] = next.name;
    await job.write(request.workFolder);
    _switchedTo = next;
    _switch = (from: remembered, to: next);
    _log('the encoder ${remembered.name} of the job failed its test on resume: continuing with ${next.name}');
    return next;
  }

  /// The encoder of a new job: the first of the list that passes its test at this frame, those that stopped during a
  /// job here at this size skipped (tried after all when none other passes)
  Future<VideoEncoder?> _chooseEncoder(int width, int height, VideoRate rate, {required bool markLeftRight}) async {
    final order = request.encoders ?? VideoEncoder.forThisComputer;
    var stopped = const <VideoEncoder>{};
    try {
      stopped = await encoderMemory?.stoppedAt(width, height) ?? const {};
    } on Object catch (error) {
      _log('the encoders that stopped before are not known: $error');
    }
    for (final encoder in order.where(stopped.contains)) {
      _log('encoder test ${encoder.name}: skipped, it stopped during a 3D video at ${width}x$height on this computer');
    }
    Future<VideoEncoder?> among(Set<VideoEncoder> skip) => chooseVideoEncoder(
      runner,
      request.ffmpeg,
      request.ffprobe,
      order,
      width,
      height,
      rate,
      folder: request.workFolder,
      markLeftRight: markLeftRight,
      skip: skip,
      onTest: _logTest,
    );
    return await among(stopped) ?? (order.any(stopped.contains) ? among(const {}) : null);
  }

  /// The final mux of a job whose frames are all in segments, then the work folder removed
  Future<VideoJobResult> _mux(
    VideoJobFile jobFile,
    VideoJobEncoded encoded,
    Map<String, Object?> json,
    VideoSource info,
    List<VideoAudioTrack> audio,
    VideoGrid grid,
    VideoEncoder encoder,
    DateTime started,
  ) async {
    _checkStop();
    final folder = request.workFolder;
    final segmentBytes = jobFile.segments.fold<int>(0, (sum, segment) => sum + segment.bytes);
    final concat = File(p.join(folder.path, 'segments.txt'));
    await concat.writeAsString(
      videoConcatList([for (final segment in jobFile.segments) (name: segment.name, slots: segment.slots)], grid.rate),
    );
    final part = '${request.outputPath}.part';
    final offset = math.max(0.0, encoded.firstTime - _formatStart(json, info));
    final mux = await runner.start(
      request.ffmpeg,
      videoMuxArguments(
        concatPath: concat.path,
        sourcePath: request.sourcePath,
        audio: audio,
        keys: {...request.keys, 'com.immuch360.encoder': encoder.codec},
        outputPath: part,
        videoOffset: offset,
      ),
    );
    _running.add(mux);
    try {
      unawaited(mux.stdin.close());
      unawaited(mux.stdout.drain<void>());
      final muxCode = await mux.exitCode;
      if (muxCode != 0) {
        throw VideoJobException('The mux stopped with $muxCode: ${videoProgramTail(await mux.errors)}');
      }
    } finally {
      _running.remove(mux);
      mux.kill();
    }
    if (request.sphere) {
      await _markSphere(part, info, audio);
    }
    await File(part).rename(request.outputPath);
    jobFile.finished = true;
    await jobFile.write(folder);
    final slots = jobFile.segments.fold<int>(0, (sum, segment) => sum + segment.slots);
    _log(
      'done: ${encoded.frames} frames, $slots slots, ${jobFile.segments.length} segments ($segmentBytes bytes), '
      '${_now().difference(started).inSeconds} s',
    );
    // The segments take about what the output takes: they go with the folder
    if (p.basename(folder.path).startsWith(videoWorkPrefix)) {
      try {
        await folder.delete(recursive: true);
      } on FileSystemException catch (error) {
        _log('the work folder stays: ${error.message}');
      }
    }
    return VideoJobResult(
      outputPath: request.outputPath,
      frames: encoded.frames,
      slots: slots,
      encoder: encoder,
      windows: encoded.windows,
      cuts: encoded.cuts,
      holesMean: encoded.holesMean,
      segments: jobFile.segments.length,
    );
  }
}

extension on VideoConversion {
  /// The MP4 of the mux [part] written again with the marks of a 360° 3D video, top and bottom: st3d and sv3d, the XML
  /// of Spherical Video V1, and the SA3D box of each spatial sound track the mux copied as it is
  Future<void> _markSphere(String part, VideoSource info, List<VideoAudioTrack> audio) async {
    final source = await readAudioSa3d(request.sourcePath);
    final sa3d = <Uint8List?>[];
    for (final track in audio) {
      final rank = info.audio.indexWhere((candidate) => candidate.index == track.index);
      sa3d.add(track.isCopied && rank >= 0 && rank < source.length ? source[rank] : null);
    }
    final marked = '$part.sphere';
    try {
      final result = await writeSphericalMp4(part, marked, audioSa3d: sa3d);
      await File(part).delete();
      await File(marked).rename(part);
      // How many audio tracks end with an SA3D box, the mux's own (FFmpeg may write one from an ambisonic layout) and
      // ours: a Matroska source has none to copy back, this line says whether the player will be told
      final spatial = audioSa3dOf(result.moov).nonNulls.length;
      _log(
        'marked as a 360° video top and bottom: ${result.videoTracks} video track, '
        '${result.sa3dAdded} spatial sound box put back, $spatial audio track(s) with an SA3D box of '
        '${audio.where((track) => track.ambisonic).length} ambisonic',
      );
    } on FormatException catch (error) {
      await _deleteQuietly(File(marked));
      throw VideoJobException('The marks of a 360° video could not be written: ${error.message}');
    }
  }
}

/// The work folder does not match the source as the decoder reads it now: the job starts again
class _ResumeRefused implements Exception {
  const _ResumeRefused(this.reason);

  final String reason;
}

Future<void> _deleteQuietly(File file) async {
  try {
    await file.delete();
  } on FileSystemException {
    // Gone already
  }
}

double _formatStart(Map<String, Object?> json, VideoSource info) {
  final format = (json['format'] as Map?)?.cast<String, Object?>();
  final start = double.tryParse('${format?['start_time']}');
  return start ?? info.startTime;
}

/// The bytes of [path] from [offset], for the app's probe of its boxes (probeSphericalMetadata)
ByteRangeReader videoFileRangeReader(String path) => (offset, length) async {
  final file = await File(path).open();
  try {
    await file.setPosition(offset);
    return Uint8List.fromList(await file.read(length));
  } finally {
    await file.close();
  }
};
