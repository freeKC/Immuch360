// The FFmpeg program played in Dart for the tests of the 3D videos (the engine, the queue, the panel): ffprobe answers a
// probe, the decoder serves synthetic frames at given times with their stats, the encoders keep a digest of what they
// were given, the mux joins the segments; tiny_vda.onnx in double precision as the model.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:immich_mobile/desktop/ai/video3d/ffmpeg_commands.dart';
import 'package:immich_mobile/desktop/ai/video3d/vda_window_loop.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_engine.dart';
import 'package:path/path.dart' as p;

import 'tiny_mp4.dart';

/// tiny_vda.onnx in double precision
Float32List tinyVdaInDart(Float32List input, int width, int height) {
  final plane = width * height;
  var total = 0.0;
  for (final value in input) {
    total += value;
  }
  final g = total / input.length;
  final out = Float32List(vdaWindowLength * plane);
  for (var slot = 0; slot < vdaWindowLength; slot++) {
    final base = slot * 3 * plane;
    for (var i = 0; i < plane; i++) {
      final m = (input[base + i] + input[base + plane + i] + input[base + 2 * plane + i]) / 3;
      out[slot * plane + i] = (m * 0.5 + 2) * (1 + g / 8) + g / 4;
    }
  }
  return out;
}

const fakeVideoSide = 28;

/// The synthetic frame [index], [width] x [height] (the decoder's scale; fakeVideoSide square by default)
Uint8List fakeVideoFrame(int index, {int width = fakeVideoSide, int height = fakeVideoSide}) {
  final rgb = Uint8List(width * height * 3);
  var at = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      rgb[at++] = (8 * x + 3 * index) % 200;
      rgb[at++] = (5 * y + index) % 90 + 20;
      rgb[at++] = (x * y + 2 * index) % 120;
    }
  }
  return rgb;
}

class _FakeSink implements StreamConsumer<List<int>> {
  final bytes = BytesBuilder(copy: false);
  final done = Completer<void>();

  /// The program closes its input once it holds this many bytes, as an encoder that dies does (null: never)
  int? closesAfter;
  void Function()? onClosed;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      final limit = closesAfter;
      if (limit != null && bytes.length + chunk.length > limit) {
        onClosed?.call();
        throw const SocketException('Write failed', osError: OSError('The pipe is being closed', 232));
      }
      bytes.add(chunk);
    }
  }

  @override
  Future<void> close() async {
    if (!done.isCompleted) {
      done.complete();
    }
  }
}

class FakeVideoProgram implements VideoProgram {
  FakeVideoProgram() : _sink = _FakeSink() {
    stdin = IOSink(_sink);
    // As the real programs: a closed input is told by the writes, not as an error of its own
    unawaited(stdin.done.then<void>((_) {}, onError: (Object _) {}));
  }

  final _out = StreamController<List<int>>();
  final _exit = Completer<int>();
  final _FakeSink _sink;
  @override
  // ignore: close_sinks, closed by the engine
  late final IOSink stdin;

  @override
  Stream<List<int>> get stdout => _out.stream;

  /// What the program writes on its error output
  var errorText = '';

  @override
  Future<String> get errors async => errorText;

  @override
  Future<int> get exitCode => _exit.future;

  void end(int code) {
    if (!_out.isClosed) {
      unawaited(_out.close());
    }
    if (!_exit.isCompleted) {
      _exit.complete(code);
    }
  }

  @override
  void kill() => end(-9);
}

/// The FFmpeg program played in Dart: ffprobe answers [probe], the decoder serves [frames] frames at [times], the
/// encoders keep a digest of what they were given, the mux joins the segments
class FakeFfmpegRunner implements VideoProgramRunner {
  FakeFfmpegRunner({
    required this.probe,
    required this.times,
    this.failMux = false,
    this.mp4Mux = false,
    this.passing = const {VideoEncoder.svtAv1},
    Map<VideoEncoder, int>? diesAfter,
    this.dieAtSegment = 1,
    this.remakeFails = false,
    this.testFramesLost = 0,
  }) : diesAfter = diesAfter ?? {};

  final Map<String, Object?> probe;
  final List<double> times;

  /// The mux writes a small real MP4 holding the joined segments as its media data (tiny_mp4.dart), so that the marks
  /// of a 360° video can be written into it and read back
  final bool mp4Mux;

  /// The mux fails, as a full disk or a killed app would make it
  final bool failMux;

  /// The encoders whose test passes
  final Set<VideoEncoder> passing;

  /// The encoders that die in a job after this many frames of their segments (their test passes), as the Intel
  /// Quick Sync H.264 MFT did on FreeKC's PC under Matroska: an entry is taken off once it fired
  final Map<VideoEncoder, int> diesAfter;

  /// The segment of that encoder (1 for its first) where it dies
  final int dieAtSegment;
  final _segmentsBy = <VideoEncoder?, int>{};

  /// The making again of a segment by another encoder fails
  final bool remakeFails;

  /// The file of an encoder test holds this many frames fewer than it was given (an encoder that drops its last ones)
  final int testFramesLost;
  final calls = <List<String>>[];
  String? concatList;

  /// The frames each encoder test wrote, by its file
  final _testFrames = <String, int>{};

  /// What a dying encoder writes, as FFmpeg 9 wrote it on FreeKC's PC
  static const dyingWords =
      '[out#0/matroska @ 000001c1cb674b40] Could not write header (incorrect codec parameters ?): Invalid data found '
      'when processing input\n'
      '[vf#0:0 @ 000001c1cb675440] Error sending frames to consumers: Invalid data found when processing input\n';

  /// The encoder of a command of a segment, a test or a making again
  static VideoEncoder? encoderOf(List<String> arguments) {
    final at = arguments.indexOf('-c:v');
    if (at < 0) {
      return null;
    }
    return switch (arguments[at + 1]) {
      'h264_mf' => arguments.contains('-hw_encoding') ? VideoEncoder.h264MfHardware : VideoEncoder.h264Mf,
      'h264_vaapi' =>
        arguments[arguments.indexOf('-low_power') + 1] == '1'
            ? VideoEncoder.h264VaapiLowPower
            : VideoEncoder.h264VaapiFull,
      'h264_videotoolbox' => VideoEncoder.h264VideoToolbox,
      'libsvtav1' => VideoEncoder.svtAv1,
      _ => null,
    };
  }

  /// -ss counts from the start time of the file, as FFmpeg adds it to an input seek and to its accurate trim
  double get _formatStart => double.parse('${(probe['format']! as Map)['start_time']}');

  @override
  Future<VideoProgram> start(String executable, List<String> arguments) async {
    calls.add(arguments);
    final program = FakeVideoProgram();
    final encoder = encoderOf(arguments);
    if (executable.endsWith('ffprobe') && arguments.contains('-count_frames')) {
      final frames = _testFrames[arguments.last];
      program._out.add(
        utf8.encode(
          jsonEncode({
            'streams': [
              if (frames != null) {'codec_name': 'h264', 'nb_read_frames': '$frames'},
            ],
          }),
        ),
      );
      program.end(0);
    } else if (executable.endsWith('ffprobe')) {
      program._out.add(utf8.encode(jsonEncode(probe)));
      program.end(0);
    } else if (p.basename(arguments.last).startsWith('encoder-test-')) {
      final path = arguments.last;
      final size = arguments[arguments.indexOf('-s') + 1].split('x').map(int.parse).toList();
      if (!passing.contains(encoder)) {
        // Dies at its header, as the hardware MFT under Matroska
        program
          ..errorText = dyingWords
          .._sink.closesAfter = 0
          .._sink.onClosed = () => program.end(-1094995529);
        return program;
      }
      unawaited(
        program._sink.done.future.then((_) {
          final bytes = program._sink.bytes.takeBytes();
          _testFrames[path] = bytes.length ~/ (size[0] * size[1] * 3) - testFramesLost;
          File(path).writeAsBytesSync([1, 2, 3]);
          program.end(0);
        }),
      );
    } else if (arguments.last.endsWith('.remade')) {
      if (remakeFails) {
        program
          ..errorText = dyingWords
          ..end(1);
        return program;
      }
      final input = arguments[arguments.indexOf('-i') + 1];
      File(arguments.last).writeAsStringSync('remade by ${encoder?.name}: ${File(input).readAsStringSync()}');
      program.end(0);
    } else if (arguments.contains('-stats_enc_pre')) {
      unawaited(_decode(program, arguments));
    } else if (arguments.contains('concat')) {
      if (failMux) {
        program.end(1);
        return program;
      }
      concatList = File(arguments[arguments.indexOf('concat') + 4]).readAsStringSync();
      final list = File(arguments[arguments.indexOf('concat') + 4]).readAsLinesSync();
      final out = BytesBuilder();
      for (final line in list.where((line) => line.startsWith('file '))) {
        out.add(
          File(p.join(p.dirname(arguments[arguments.indexOf('concat') + 4]), line.split("'")[1])).readAsBytesSync(),
        );
      }
      final joined = out.takeBytes();
      File(arguments.last).writeAsBytesSync(mp4Mux ? tinyMp4(mediaData: joined) : joined);
      program.end(0);
    } else {
      final path = arguments.last;
      final ordinal = _segmentsBy[encoder] = (_segmentsBy[encoder] ?? 0) + 1;
      if (ordinal >= dieAtSegment && diesAfter.containsKey(encoder)) {
        final frames = diesAfter.remove(encoder)!;
        final size = arguments[arguments.indexOf('-s') + 1].split('x').map(int.parse).toList();
        program
          ..errorText = dyingWords
          .._sink.closesAfter = frames * size[0] * size[1] * 3
          .._sink.onClosed = () => program.end(-1094995529);
        return program;
      }
      unawaited(
        program._sink.done.future.then((_) {
          final bytes = program._sink.bytes.takeBytes();
          File(path).writeAsStringSync('${bytes.length} ${crypto.sha256.convert(bytes)}\n');
          program.end(0);
        }),
      );
    }
    return program;
  }

  Future<void> _decode(FakeVideoProgram program, List<String> arguments) async {
    final stats = File(arguments[arguments.indexOf('-stats_enc_pre') + 1]).openWrite();
    // The size the decoder scales to: scale=W:H of its filter
    final scale = RegExp(r'scale=(\d+):(\d+)').firstMatch(arguments[arguments.indexOf('-vf') + 1]);
    final width = scale == null ? fakeVideoSide : int.parse(scale.group(1)!);
    final height = scale == null ? fakeVideoSide : int.parse(scale.group(2)!);
    final size = (width, height);
    final seekAt = arguments.indexOf('-ss');
    final seek = seekAt < 0 ? null : double.parse(arguments[seekAt + 1]);
    var n = 0;
    for (var i = 0; i < times.length; i++) {
      if (seek != null && times[i] < seek + _formatStart) {
        continue;
      }
      // Killed by a pause: a real decoder ends there too
      if (program._out.isClosed) {
        break;
      }
      stats.write('$n ${(times[i] * 1000).round()} 1/1000\n');
      await stats.flush();
      if (program._out.isClosed) {
        break;
      }
      program._out.add(fakeVideoFrame(i, width: size.$1, height: size.$2));
      n++;
      // The pace of a pipe
      await Future<void>.delayed(Duration.zero);
    }
    await stats.close();
    program.end(0);
  }
}

Map<String, Object?> fakeVideoProbe(
  int frames,
  double duration, {
  String rate = '25/1',
  double start = 0,
  String audio = 'vorbis',
  int width = fakeVideoSide,
  int height = fakeVideoSide,
}) => {
  'streams': [
    {
      'index': 0,
      'codec_type': 'video',
      'codec_name': 'h264',
      'width': width,
      'height': height,
      'pix_fmt': 'yuv420p',
      'r_frame_rate': rate,
      'avg_frame_rate': rate,
      'nb_frames': '$frames',
      'duration': '$duration',
      'start_time': start.toStringAsFixed(6),
      'disposition': {'attached_pic': 0},
    },
    {'index': 1, 'codec_type': 'audio', 'codec_name': audio, 'channels': 2},
  ],
  'format': {'duration': '$duration', 'start_time': start.toStringAsFixed(6)},
};
