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
  _FakeRunner({required this.probe, required this.times, this.failMux = false});

  final Map<String, Object?> probe;
  final List<double> times;

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
    final program = _FakeProgram();
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
      program._out.add(_frame(i));
      n++;
      // The pace of a pipe
      await Future<void>.delayed(Duration.zero);
    }
    await stats.close();
    program.end(0);
  }
}

Map<String, Object?> _probe(
  int frames,
  double duration, {
  String rate = '25/1',
  double start = 0,
  String audio = 'vorbis',
}) => {
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
      'start_time': start.toStringAsFixed(6),
      'disposition': {'attached_pic': 0},
    },
    {'index': 1, 'codec_type': 'audio', 'codec_name': audio, 'channels': 2},
  ],
  'format': {'duration': '$duration', 'start_time': start.toStringAsFixed(6)},
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
    expect(logs.where((line) => line.startsWith('segment ')), [startsWith('segment 1: frames 0 to 45')]);
    // Each segment with its exact length in the concat list: 46 and 14 slots at 25 fps
    expect(
      runner.concatList,
      "ffconcat version 1.0\nfile 'seg-0001.seg'\nduration 1.840000000\nfile 'seg-0002.seg'\n"
      'duration 0.560000000',
    );
    // The work folder goes once the MP4 is in place: segments, states, times
    expect(Directory(p.join(temp.path, '${videoWorkPrefix}clip_3D_LRF_Full_SBS.mp4')).existsSync(), isFalse);
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

  /// Runs a job to the log line [line], pauses it there, and gives its work folder
  Future<Directory> pausedAt(String name, String line, _FakeRunner runner) async {
    late VideoConversion first;
    first = conversion(
      runner,
      name,
      onLog: (logged) {
        if (logged.startsWith(line)) {
          first.pause();
        }
      },
    );
    await expectLater(first.run(), throwsA(isA<VideoJobStopped>()));
    return Directory(p.join(temp.path, '$videoWorkPrefix$name'));
  }

  List<String> statesIn(Directory folder) => [
    for (final entity in folder.listSync())
      if (p.basename(entity.path).startsWith('state-')) p.basename(entity.path),
  ];

  test('a source whose times start at 1.44 s (MPEG-TS) resumes at the right frame', () async {
    // -copyts keeps the times absolute, -ss counts from the file's start time: the seek takes it off
    final times = [for (var i = 0; i < 100; i++) 1.44 + i / 25];
    final whole = await conversion(_FakeRunner(probe: _probe(100, 4, start: 1.44), times: times), 'ts-whole.mp4').run();
    expect(whole.frames, 100);

    final folder = await pausedAt('ts.mp4', 'segment 1', _FakeRunner(probe: _probe(100, 4, start: 1.44), times: times));
    expect((await VideoJobFile.read(folder))!.segments.length, 1);
    final runner = _FakeRunner(probe: _probe(100, 4, start: 1.44), times: times);
    final logs = <String>[];
    final resumed = await conversion(runner, 'ts.mp4', onLog: logs.add).run();
    expect(logs.where((line) => line.contains('started again')), isEmpty);
    final decoder = runner.calls.firstWhere((call) => call.contains('-stats_enc_pre'));
    expect(double.parse(decoder[decoder.indexOf('-ss') + 1]), closeTo(times[46] - 1.44 - 0.5 / 25, 1e-6));
    expect(resumed.frames, 100);
    expect(
      File(p.join(temp.path, 'ts.mp4')).readAsStringSync(),
      File(p.join(temp.path, 'ts-whole.mp4')).readAsStringSync(),
    );
  });

  test('frames that are not where the work folder says start the job again instead of failing each Resume', () async {
    final times = [for (var i = 0; i < 100; i++) i / 25];
    final whole = await conversion(_FakeRunner(probe: _probe(100, 4), times: times), 'drift-whole.mp4').run();
    final folder = await pausedAt('drift.mp4', 'segment 1', _FakeRunner(probe: _probe(100, 4), times: times));
    // The times written then are not those the decoder gives now
    final pts = File(p.join(folder.path, 'pts.txt'));
    pts.writeAsStringSync([for (final line in pts.readAsLinesSync()) '${double.parse(line) + 0.01}'].join('\n'));
    final logs = <String>[];
    final again = await conversion(
      _FakeRunner(probe: _probe(100, 4), times: times),
      'drift.mp4',
      onLog: logs.add,
    ).run();
    expect(logs, contains(allOf(startsWith('frame 46 is at 1.84'), endsWith(': started again'))));
    expect(again.frames, whole.frames);
    expect(
      File(p.join(temp.path, 'drift.mp4')).readAsStringSync(),
      File(p.join(temp.path, 'drift-whole.mp4')).readAsStringSync(),
    );
  });

  test('only the state of the last segment stays in the work folder', () async {
    final times = [for (var i = 0; i < 100; i++) i / 25];
    final folder = await pausedAt('states.mp4', 'segment 2', _FakeRunner(probe: _probe(100, 4), times: times));
    expect((await VideoJobFile.read(folder))!.segments.length, 2);
    expect(statesIn(folder), [VideoSegment.stateNameOf(2)]);
  });

  test('a mux that fails goes back to the mux, not to the frames', () async {
    final times = [for (var i = 0; i < 100; i++) i / 25];
    final whole = await conversion(_FakeRunner(probe: _probe(100, 4), times: times), 'mux-whole.mp4').run();
    await expectLater(
      conversion(_FakeRunner(probe: _probe(100, 4), times: times, failMux: true), 'mux.mp4').run(),
      throwsA(isA<VideoJobException>().having((e) => e.message, 'message', startsWith('The mux stopped with 1'))),
    );
    final folder = Directory(p.join(temp.path, '${videoWorkPrefix}mux.mp4'));
    final job = (await VideoJobFile.read(folder))!;
    expect((job.encoded!.frames, job.encoded!.windows, job.finished), (100, whole.windows, false));
    expect(job.segments.length, whole.segments);
    // The states, the times and the stats went with the last segment
    expect(statesIn(folder), isEmpty);
    expect(File(p.join(folder.path, 'pts.txt')).existsSync(), isFalse);

    final runner = _FakeRunner(probe: _probe(100, 4), times: times);
    final logs = <String>[];
    final result = await conversion(runner, 'mux.mp4', onLog: logs.add).run();
    expect(logs, contains('every frame is in a segment already: the final mux'));
    expect(runner.calls.where((call) => call.contains('-stats_enc_pre')), isEmpty);
    expect(
      (result.frames, result.windows, result.segments, result.holesMean),
      (100, whole.windows, 3, whole.holesMean),
    );
    expect(
      File(p.join(temp.path, 'mux.mp4')).readAsStringSync(),
      File(p.join(temp.path, 'mux-whole.mp4')).readAsStringSync(),
    );
    expect(folder.existsSync(), isFalse);
  });

  test('a WMA track the program cannot decode is not mapped into the mux', () async {
    final runner = _FakeRunner(
      probe: _probe(60, 2.4, audio: 'wmav2'),
      times: [for (var i = 0; i < 60; i++) i / 25],
    );
    final logs = <String>[];
    await conversion(runner, 'wma.mp4', onLog: logs.add).run();
    final mux = runner.calls.firstWhere((call) => call.contains('concat'));
    expect(mux, isNot(contains('1:1')));
    expect(mux, isNot(contains('-c:a:0')));
    expect(logs, contains('audio track 1 (wmav2): the program cannot read it, not kept'));
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
