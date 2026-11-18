// A small program that makes 3D videos through the engine of the app (store/m2/release-49/lots/video3d-plan.md,
// section 5: the integration with the real components): the FFmpeg program of immuch360/libmpv-builds, Video Depth
// Anything Small on ONNX Runtime, the frame work in Rust (built by the hook of immuch_sbs_codec), else the pure Dart
// reference. The models of the app it reads (stereo_layout, exif) import dart:ui, so it runs in the test runner of
// Flutter, with no window: video3d_integration_test.dart passes it IMMUCH360_VIDEO3D_ARGS, a JSON list of the arguments
// below. It prints one JSON line per event, with the milliseconds since its start:
//   log       a line of the engine (the encoder tests, the segments)
//   progress  frames done of the total, frames a second and the time left once two windows ran
//   window    the run of one window of the model: its milliseconds
//   done      the 3D video: its file, frames, slots, encoder, windows, cuts, holes, segments, the st3d mode the app's
//             own probe reads back, and the median milliseconds of a window and of a new frame
//   failed    the message
//
//   --ffmpeg DIR --ort LIBRARY --model FILE --out DIR [--quality standard] [--strength normal]
//   [--alignment upstream|tenFrame] [--packing full|half] [--segment 30] [--no-fade]
//   [--frames-npy] [--maps-npy] [--pause-after N] VIDEO...
// DIR holds bin/ffmpeg and bin/ffprobe (an archive of the FFmpeg program unpacked). Each video gives
// <out>/<name>_3D_LRF_Full_SBS.mp4 (or Half), its work folder beside it. --maps-npy writes the aligned maps of the
// model (float32 [frames, height, width]) and --frames-npy the eye frames (uint8 [frames, height, width, 3]) next to
// it, for depth.py and analyse.py of the probe. --pause-after N pauses the job after its segment N and resumes it at
// once: the resume check (not with the .npy files, whose held frames would come twice).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/desktop/ai/video3d/vda_window_loop.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_engine.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_frame_ops.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_job_file.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:path/path.dart' as p;

final _clock = Stopwatch()..start();

void _emit(String event, Map<String, Object?> fields) =>
    stdout.writeln(jsonEncode({'event': event, 'ms': _clock.elapsedMilliseconds, ...fields}));

const _strengths = {'subtle': 0.015, 'normal': 0.02, 'strong': 0.03};

/// An .npy file written as frames come: its header says [shape] with [frames] counted at the end
class _NpyWriter {
  _NpyWriter(this.path, this.descr, this.frameShape) : _sink = File('$path.data').openWrite();

  final String path;
  final String descr;
  final List<int> frameShape;
  final IOSink _sink;
  var frames = 0;

  void add(TypedData data) {
    _sink.add(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    frames++;
  }

  Future<void> close() async {
    await _sink.close();
    final shape = [frames, ...frameShape].join(', ');
    var header = "{'descr': '$descr', 'fortran_order': False, 'shape': ($shape), }";
    final total = 10 + header.length + 1;
    header = header.padRight(header.length + (64 - total % 64) % 64);
    final out = File(path).openWrite()
      ..add([0x93, ...ascii.encode('NUMPY'), 1, 0])
      ..add([(header.length + 1) & 0xff, (header.length + 1) >> 8])
      ..add(ascii.encode('$header\n'));
    await out.addStream(File('$path.data').openRead());
    await out.close();
    await File('$path.data').delete();
  }
}

/// Runs the probe on [args]; the number of videos that failed
Future<int> runVideo3dProbe(List<String> args) async {
  final options = <String, String>{};
  final flags = <String>{};
  final videos = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (const {'--frames-npy', '--maps-npy', '--no-fade'}.contains(arg)) {
      flags.add(arg);
    } else if (arg.startsWith('--')) {
      options[arg] = args[++i];
    } else {
      videos.add(arg);
    }
  }
  final ffmpegDir = options['--ffmpeg'];
  final ortLibrary = options['--ort'];
  final modelPath = options['--model'];
  final outDir = options['--out'];
  if (ffmpegDir == null || ortLibrary == null || modelPath == null || outDir == null || videos.isEmpty) {
    stderr.writeln('video3d_probe --ffmpeg DIR --ort LIBRARY --model FILE --out DIR [options] VIDEO...');
    return 1;
  }
  final quality = VideoDepthQuality.values.byName(options['--quality'] ?? 'standard');
  final parallax = _strengths[options['--strength'] ?? 'normal']!;
  final alignment = VideoDepthAlignment.values.byName(options['--alignment'] ?? 'upstream');
  final packing = VideoSbsPacking.values.byName(options['--packing'] ?? 'full');
  final pauseAfter = int.tryParse(options['--pause-after'] ?? '');
  final relief = VideoReliefSettings(parallax: parallax, packing: packing, edgeFade: !flags.contains('--no-fade'));
  final runtime = OrtRuntime.load(ortLibrary);
  final ffmpeg = p.join(ffmpegDir, 'bin', Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg');
  final ffprobe = p.join(ffmpegDir, 'bin', Platform.isWindows ? 'ffprobe.exe' : 'ffprobe');
  Directory(outDir).createSync(recursive: true);
  var failures = 0;

  for (final video in videos) {
    final name = videoOutputName(video, packing);
    final output = p.join(outDir, name);
    final folder = Directory(p.join(outDir, '$videoWorkPrefix${p.basenameWithoutExtension(name)}'));
    final windowMs = <int>[];
    _NpyWriter? frames;
    _NpyWriter? maps;
    final session = runtime.openSession(modelPath, settings: OrtSessionSettings.forThisComputer());
    var paused = false;
    VideoConversion make() {
      late VideoConversion conversion;
      conversion = VideoConversion(
        request: VideoJobRequest(
          sourcePath: video,
          outputPath: output,
          workFolder: folder,
          ffmpeg: ffmpeg,
          ffprobe: ffprobe,
          quality: quality,
          relief: relief,
          alignment: alignment,
          segmentSeconds: int.parse(options['--segment'] ?? '30'),
          keys: {
            'com.immuch360.kind': 'StereoVideo',
            'com.immuch360.pipeline': 'relief-v1-video',
            'com.immuch360.parallax': '$parallax',
            'com.immuch360.convergence': '${relief.convergence}',
            'com.immuch360.model': 'video-depth-anything-small-onnx',
            'com.immuch360.depth.short_side': '${quality.shortSide}',
            'com.immuch360.original.name': p.basename(video),
          },
        ),
        runner: const DirectVideoProgramRunner(),
        workerFactory: ({required eyeWidth, required eyeHeight, required modelWidth, required modelHeight}) async {
          if (flags.contains('--frames-npy') && frames == null) {
            frames = _NpyWriter(p.join(outDir, '${p.basenameWithoutExtension(video)}_frames.npy'), '|u1', [
              eyeHeight,
              eyeWidth,
              3,
            ]);
          }
          if (flags.contains('--maps-npy') && maps == null) {
            maps = _NpyWriter(
              p.join(outDir, '${p.basenameWithoutExtension(video)}_vda_${modelWidth}x$modelHeight.npy'),
              '<f4',
              [modelHeight, modelWidth],
            );
          }
          final ops = nativeVideoFrameOps(threads: 2) ?? const DartVideoFrameOps();
          _emit('log', {'line': 'frame work: ${ops.name}'});
          return LocalVideoFrameWorker(
            ops: ops,
            model: (input, width, height) {
              final watch = Stopwatch()..start();
              final output = session
                  .runNamed({
                    'frames': OrtTensor([1, vdaWindowLength, 3, height, width], input),
                  })
                  .values
                  .single;
              windowMs.add(watch.elapsedMilliseconds);
              _emit('window', {'ms_run': watch.elapsedMilliseconds});
              return output.values;
            },
            eyeWidth: eyeWidth,
            eyeHeight: eyeHeight,
            modelWidth: modelWidth,
            modelHeight: modelHeight,
            relief: relief,
            alignment: alignment,
            onMap: (frame) {
              frames?.add(frame.rgb);
              maps?.add(Float32List.fromList(frame.map));
            },
          );
        },
        onProgress: (progress) => _emit('progress', {
          'done': progress.framesDone,
          'total': progress.framesTotal,
          'fps': progress.framesPerSecond,
          'left_s': progress.timeLeft?.inSeconds,
        }),
        onLog: (line) {
          _emit('log', {'line': line});
          if (pauseAfter != null && !paused && line.startsWith('segment $pauseAfter:')) {
            paused = true;
            conversion.pause();
          }
        },
      );
      return conversion;
    }

    try {
      VideoJobResult result;
      try {
        result = await make().run();
      } on VideoJobStopped {
        _emit('log', {'line': 'paused after segment $pauseAfter, resumed'});
        // The frames and maps of the resumed part follow those written before the pause, the held ones again
        result = await make().run();
      }
      await frames?.close();
      await maps?.close();
      final file = File(output);
      final reader = await file.open();
      final probe = await probeSphericalMetadata((offset, length) async {
        await reader.setPosition(offset);
        return reader.read(length);
      });
      await reader.close();
      final sorted = [...windowMs]..sort();
      final median = sorted.isEmpty ? 0 : sorted[sorted.length ~/ 2];
      _emit('done', {
        'video': video,
        'output': output,
        'bytes': file.lengthSync(),
        'frames': result.frames,
        'slots': result.slots,
        'encoder': result.encoder.name,
        'windows': result.windows,
        'cuts': result.cuts,
        'holes_mean': result.holesMean,
        'segments': result.segments,
        'st3d': probe.stereo?.name,
        'st3d_left_right': probe.stereo == StereoLayout.leftRight,
        'window_ms_median': median,
        'ms_per_new_frame': median / vdaStep,
        'quality': quality.name,
        'parallax': parallax,
        'alignment': alignment.name,
      });
    } on Object catch (error, stack) {
      failures++;
      _emit('failed', {'video': video, 'error': '$error', 'stack': '$stack'.split('\n').take(6).join(' | ')});
    } finally {
      session.close();
    }
  }
  return failures;
}
