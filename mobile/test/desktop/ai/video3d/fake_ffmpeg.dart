// The FFmpeg program played in Dart for the tests of the 3D videos (the engine, the queue, the panel): ffprobe answers a
// probe, the decoder serves synthetic frames at given times with their stats, the encoders keep a digest of what they
// were given, the mux joins the segments; tiny_vda.onnx in double precision as the model.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
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

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(bytes.add);

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
  }

  final _out = StreamController<List<int>>();
  final _exit = Completer<int>();
  final _FakeSink _sink;
  @override
  // ignore: close_sinks, closed by the engine
  late final IOSink stdin;

  @override
  Stream<List<int>> get stdout => _out.stream;

  @override
  Future<String> get errors async => '';

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
  FakeFfmpegRunner({required this.probe, required this.times, this.failMux = false, this.mp4Mux = false});

  final Map<String, Object?> probe;
  final List<double> times;

  /// The mux writes a small real MP4 holding the joined segments as its media data (tiny_mp4.dart), so that the marks
  /// of a 360° video can be written into it and read back
  final bool mp4Mux;

  /// The mux fails, as a full disk or a killed app would make it
  final bool failMux;
  final passing = const {'libsvtav1'};
  final calls = <List<String>>[];
  String? concatList;

  /// -ss counts from the start time of the file, as FFmpeg adds it to an input seek and to its accurate trim
  double get _formatStart => double.parse('${(probe['format']! as Map)['start_time']}');

  @override
  Future<VideoProgram> start(String executable, List<String> arguments) async {
    calls.add(arguments);
    final program = FakeVideoProgram();
    if (executable.endsWith('ffprobe')) {
      program._out.add(utf8.encode(jsonEncode(probe)));
      program.end(0);
    } else if (arguments.contains('lavfi')) {
      program.end(passing.contains(arguments[arguments.indexOf('-c:v') + 1]) ? 0 : 1);
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
