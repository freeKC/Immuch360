import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/video3d/ffmpeg_commands.dart';
import 'package:immich_mobile/desktop/ai/video3d/vda_window_loop.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_engine.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_frame_ops.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_job_file.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';
import 'package:path/path.dart' as p;

/// tiny_vda.onnx in double precision
Float32List _tinyVda(Float32List input, int width, int height) {
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

const _side = 28;

Uint8List _frame(int index) {
  final rgb = Uint8List(_side * _side * 3);
  var at = 0;
  for (var y = 0; y < _side; y++) {
    for (var x = 0; x < _side; x++) {
      rgb[at++] = (8 * x + 3 * index) % 200;
      rgb[at++] = (5 * y + index) % 90 + 20;
      rgb[at++] = (x * y + 2 * index) % 120;
    }
  }
  return rgb;
}

class _Sink implements StreamConsumer<List<int>> {
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

class _FakeProgram implements VideoProgram {
  _FakeProgram() : _sink = _Sink() {
    stdin = IOSink(_sink);
  }

  final _out = StreamController<List<int>>();
  final _exit = Completer<int>();
  final _Sink _sink;
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
class _FakeRunner implements VideoProgramRunner {
  _FakeRunner({required this.probe, required this.times});

  final Map<String, Object?> probe;
  final List<double> times;
  final passing = const {'libsvtav1'};
  final calls = <List<String>>[];

  @override
  Future<VideoProgram> start(String executable, List<String> arguments) async {
    calls.add(arguments);
    final program = _FakeProgram();
    if (executable.endsWith('ffprobe')) {
      program._out.add(utf8.encode(jsonEncode(probe)));
      program.end(0);
    } else if (arguments.contains('lavfi')) {
      program.end(passing.contains(arguments[arguments.indexOf('-c:v') + 1]) ? 0 : 1);
    } else if (arguments.contains('-stats_enc_pre')) {
      unawaited(_decode(program, arguments));
    } else if (arguments.contains('concat')) {
      final list = File(arguments[arguments.indexOf('concat') + 4]).readAsLinesSync();
      final out = BytesBuilder();
      for (final line in list.skip(1)) {
        out.add(
          File(p.join(p.dirname(arguments[arguments.indexOf('concat') + 4]), line.split("'")[1])).readAsBytesSync(),
        );
      }
      File(arguments.last).writeAsBytesSync(out.takeBytes());
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

  Future<void> _decode(_FakeProgram program, List<String> arguments) async {
    final stats = File(arguments[arguments.indexOf('-stats_enc_pre') + 1]).openWrite();
    final seekAt = arguments.indexOf('-ss');
    final seek = seekAt < 0 ? null : double.parse(arguments[seekAt + 1]);
    var n = 0;
    for (var i = 0; i < times.length; i++) {
      if (seek != null && times[i] < seek) {
        continue;
      }
      stats.write('$n ${(times[i] * 1000).round()} 1/1000\n');
      await stats.flush();
      program._out.add(_frame(i));
      n++;
      // The pace of a pipe
      await Future<void>.delayed(Duration.zero);
    }
    await stats.close();
    program.end(0);
  }
}

Map<String, Object?> _probe(int frames, double duration, {String rate = '25/1'}) => {
  'streams': [
    {
      'index': 0,
      'codec_type': 'video',
      'codec_name': 'h264',
      'width': _side,
      'height': _side,
      'pix_fmt': 'yuv420p',
      'r_frame_rate': rate,
      'avg_frame_rate': rate,
      'nb_frames': '$frames',
      'duration': '$duration',
      'start_time': '0.000000',
      'disposition': {'attached_pic': 0},
    },
    {'index': 1, 'codec_type': 'audio', 'codec_name': 'vorbis', 'channels': 2},
  ],
  'format': {'duration': '$duration', 'start_time': '0.000000'},
};

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('video3d-engine-'));
  tearDown(() => temp.deleteSync(recursive: true));

  VideoConversion conversion(_FakeRunner runner, String name, {void Function(String)? onLog}) => VideoConversion(
    request: VideoJobRequest(
      sourcePath: p.join(temp.path, 'clip.mp4'),
      outputPath: p.join(temp.path, name),
      workFolder: Directory(p.join(temp.path, '$videoWorkPrefix$name')),
      ffmpeg: 'ffmpeg',
      ffprobe: 'ffprobe',
      quality: VideoDepthQuality.fast,
      relief: const VideoReliefSettings(parallax: 0.015),
      encoders: const [VideoEncoder.h264VaapiFull, VideoEncoder.svtAv1],
      segmentSeconds: 1,
    ),
    runner: runner,
    workerFactory: ({required eyeWidth, required eyeHeight, required modelWidth, required modelHeight}) async =>
        LocalVideoFrameWorker(
          ops: const DartVideoFrameOps(),
          model: _tinyVda,
          eyeWidth: eyeWidth,
          eyeHeight: eyeHeight,
          modelWidth: modelWidth,
          modelHeight: modelHeight,
          relief: const VideoReliefSettings(parallax: 0.015),
        ),
    onLog: onLog,
  );

  setUp(() => File(p.join(temp.path, 'clip.mp4')).writeAsBytesSync(List.generate(1000, (i) => i % 251)));

  test('a job: encoder test, decoder, segments at window ends, mux with the audio made AAC', () async {
    final runner = _FakeRunner(probe: _probe(60, 2.4), times: [for (var i = 0; i < 60; i++) i / 25]);
    final logs = <String>[];
    final result = await conversion(runner, 'clip_3D_LRF_Full_SBS.mp4', onLog: logs.add).run();
    expect(result.frames, 60);
    expect(result.slots, 60);
    expect(result.encoder, VideoEncoder.svtAv1);
    expect(result.segments, 2);
    expect(result.windows, 3);
    expect(logs.where((line) => line.startsWith('encoder test')), [
      startsWith('encoder test h264VaapiFull: failed'),
      'encoder test svtAv1: passed',
    ]);
    final decoder = runner.calls.firstWhere((call) => call.contains('-stats_enc_pre'));
    expect(decoder, containsAllInOrder(['-fps_mode', 'passthrough', '-vf']));
    expect(decoder[decoder.indexOf('-vf') + 1], 'scale=28:28:flags=area,format=rgb24');
    final mux = runner.calls.firstWhere((call) => call.contains('concat'));
    expect(mux, containsAllInOrder(['-map', '1:1', '-map_metadata', '1', '-c:a:0', 'aac']));
    expect(mux, containsAllInOrder(['-strict', 'unofficial', '-movflags', '+faststart+use_metadata_tags']));
    final job = (await VideoJobFile.read(Directory(p.join(temp.path, '${videoWorkPrefix}clip_3D_LRF_Full_SBS.mp4'))))!;
    expect(job.finished, isTrue);
    expect(job.segments.map((s) => (s.firstFrame, s.endFrame)), [(0, 46), (46, 60)]);
    expect(File(p.join(temp.path, 'clip_3D_LRF_Full_SBS.mp4')).existsSync(), isTrue);
    expect(File(p.join(temp.path, 'clip_3D_LRF_Full_SBS.mp4.part')).existsSync(), isFalse);
  });

  test('paused after its first segment, a job resumed gives the bytes of an uninterrupted one', () async {
    final times = [for (var i = 0; i < 100; i++) i / 25];
    final whole = await conversion(_FakeRunner(probe: _probe(100, 4), times: times), 'whole.mp4').run();
    expect(whole.segments, 3);

    late VideoConversion first;
    first = conversion(
      _FakeRunner(probe: _probe(100, 4), times: times),
      'resumed.mp4',
      onLog: (line) {
        if (line.startsWith('segment 1')) {
          first.pause();
        }
      },
    );
    await expectLater(first.run(), throwsA(isA<VideoJobStopped>()));
    final folder = Directory(p.join(temp.path, '${videoWorkPrefix}resumed.mp4'));
    final paused = (await VideoJobFile.read(folder))!;
    expect(paused.segments.length, 1);
    expect(paused.finished, isFalse);
    expect(File(p.join(folder.path, VideoSegment.stateNameOf(1))).existsSync(), isTrue);

    final runner = _FakeRunner(probe: _probe(100, 4), times: times);
    final logs = <String>[];
    final resumed = await conversion(runner, 'resumed.mp4', onLog: logs.add).run();
    expect(logs.where((line) => line.startsWith('encoder test')), isEmpty);
    final decoder = runner.calls.firstWhere((call) => call.contains('-stats_enc_pre'));
    expect(decoder, contains('-ss'));
    expect(double.parse(decoder[decoder.indexOf('-ss') + 1]), closeTo(46 / 25 - 0.5 / 25, 1e-6));
    expect(resumed.frames, 100);
    expect(
      File(p.join(temp.path, 'resumed.mp4')).readAsStringSync(),
      File(p.join(temp.path, 'whole.mp4')).readAsStringSync(),
    );
  });

  test('a variable rate source keeps its timing on the grid, with no extra frame of depth', () async {
    // One frame in 7 dropped, the times kept: 30 fps grid
    final times = [
      for (var i = 0; i < 70; i++)
        if (i % 7 != 6) i / 30,
    ];
    final runner = _FakeRunner(
      probe: _probe(times.length, 70 / 30, rate: '30/1'),
      times: times,
    );
    final result = await conversion(runner, 'vfr.mp4').run();
    expect(result.frames, times.length);
    expect(result.slots, 69);
    expect(videoGridRepeats(times, const VideoRate(30, 1)).fold<int>(0, (a, b) => a + b), result.slots);
  });

  test('a source that changed since cannot resume: the job starts again', () async {
    final times = [for (var i = 0; i < 60; i++) i / 25];
    late VideoConversion first;
    first = conversion(
      _FakeRunner(probe: _probe(60, 2.4), times: times),
      'changed.mp4',
      onLog: (line) {
        if (line.startsWith('segment 1')) {
          first.pause();
        }
      },
    );
    await expectLater(first.run(), throwsA(isA<VideoJobStopped>()));
    File(p.join(temp.path, 'clip.mp4')).writeAsBytesSync(List.generate(1000, (i) => i % 13));
    final logs = <String>[];
    await conversion(
      _FakeRunner(probe: _probe(60, 2.4), times: times),
      'changed.mp4',
      onLog: logs.add,
    ).run();
    expect(logs, contains('the work folder holds another job: started again'));
  });

  test('the state of the loop survives its bytes', () {
    final state = VdaLoopState(
      nextIndex: 54,
      sceneStart: 0,
      sceneFrames: 54,
      windows: 2,
      held: [
        for (var i = 0; i < 8; i++) Float64List.fromList([i.toDouble(), 0.5]),
      ],
      ref: [
        Float64List.fromList([1, 2]),
        Float64List.fromList([3, 4]),
      ],
      keyInputs: [
        for (var i = 0; i < 10; i++) Float32List.fromList([i / 4, 1]),
      ],
      lo: 0.25,
      hi: null,
      previousHistogram: Float64List.fromList([0.5, 0.5]),
      distances: const [0.01, 0.02],
      firstHeld: 46,
      resets: const {50},
    );
    final back = decodeVdaLoopState(encodeVdaLoopState(state))!;
    expect(back.held.map((m) => m.toList()), state.held.map((m) => m.toList()));
    expect(back.ref.map((m) => m.toList()), state.ref.map((m) => m.toList()));
    expect(back.keyInputs.map((m) => m.toList()), state.keyInputs.map((m) => m.toList()));
    expect((back.lo, back.hi, back.firstHeld, back.nextIndex, back.windows), (0.25, null, 46, 54, 2));
    expect(back.resets, {50});
    expect(back.distances, [0.01, 0.02]);
    expect(back.previousHistogram, state.previousHistogram);
    expect(decodeVdaLoopState(Uint8List(8)), isNull);
    final bytes = encodeVdaLoopState(state);
    expect(decodeVdaLoopState(bytes.sublist(0, bytes.length - 1)), isNull);
  });
}
