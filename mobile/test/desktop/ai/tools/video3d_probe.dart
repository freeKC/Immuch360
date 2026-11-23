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
//   sphere    for --sphere: the frame of the MP4 (square, top and bottom), what the app's probe reads (st3d, sv3d,
//             half sphere) and how the two eyes of frame 50 differ, from each other and from the source's frame 50, near
//             the poles, at the equator and across the seam
//
//   --ffmpeg DIR --ort LIBRARY --model FILE --out DIR [--quality standard] [--strength normal]
//   [--alignment upstream|tenFrame] [--packing full|half] [--segment 30] [--no-fade]
//   [--frames-npy] [--maps-npy] [--pause-after N] [--sphere EYE_WIDTH] VIDEO...
// DIR holds bin/ffmpeg and bin/ffprobe (an archive of the FFmpeg program unpacked). Each video gives
// <out>/<name>_3D_LRF_Full_SBS.mp4 (or Half), its work folder beside it. --maps-npy writes the aligned maps of the
// model (float32 [frames, height, width]) and --frames-npy the eye frames (uint8 [frames, height, width, 3]) next to
// it, for depth.py and analyse.py of the probe. --pause-after N pauses the job after its segment N and resumes it at
// once: the resume check (not with the .npy files, whose held frames would come twice). --sphere EYE_WIDTH makes a
// 360° video a 360° 3D video of eyes EYE_WIDTH wide (lot ai-360-3d-51), <name>_360_3D.mp4, with the worker of the
// sphere.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/desktop/ai/video3d/sphere_video_worker.dart';
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

/// The frame [index] of the video [path] decoded by [ffmpeg] as RGB, and its size; null when it was not read
Future<({int width, int height, List<int> pixels})?> _decodedFrame(String ffmpeg, String path, int index) async {
  final ffprobe = p.join(p.dirname(ffmpeg), Platform.isWindows ? 'ffprobe.exe' : 'ffprobe');
  final size = await Process.run(ffprobe, [
    '-v',
    'error',
    '-select_streams',
    'v:0',
    '-show_entries',
    'stream=width,height',
    '-of',
    'csv=p=0',
    path,
  ]);
  final parts = '${size.stdout}'.trim().split(',');
  final width = parts.length >= 2 ? int.tryParse(parts[0]) : null;
  final height = parts.length >= 2 ? int.tryParse(parts[1]) : null;
  if (width == null || height == null) {
    return null;
  }
  final decoded = await Process.run(ffmpeg, [
    '-v',
    'error',
    '-i',
    path,
    '-frames:v',
    '${index + 1}',
    '-f',
    'rawvideo',
    '-pix_fmt',
    'rgb24',
    'pipe:1',
  ], stdoutEncoding: null);
  final bytes = decoded.stdout as List<int>;
  final frame = width * height * 3;
  final last = bytes.length ~/ frame - 1;
  if (last < 0) {
    return null;
  }
  return (width: width, height: height, pixels: bytes.sublist(last * frame, (last + 1) * frame));
}

/// The frame [index] of the top and bottom MP4 [path] and of its [source], decoded by [ffmpeg]: the size of the MP4,
/// the mean difference of its two eyes over three rows near each pole (rows 3 to 5 of each eye from its top and its
/// bottom: away from the edges of the frame and from the line between the eyes, where the chroma and the deblocking of
/// the codec mix the two eyes) and over the three rows of the equator, the same rows measured against the source
/// (how much further the right eye is from it than the left one: each eye's own codec noise cancels out, what stays is
/// the shift of the right eye), and the jump across the seam of each eye (the last column against the first, along
/// the equator band)
Future<Map<String, Object?>> _sphereFrame(String ffmpeg, String path, String source, int index) async {
  final out = await _decodedFrame(ffmpeg, path, index);
  if (out == null) {
    throw StateError('Frame $index of $path not read');
  }
  final width = out.width;
  final pixels = out.pixels;
  final eye = out.height ~/ 2;
  final original = await _decodedFrame(ffmpeg, source, index);
  final same = original != null && original.width == width && original.height == eye;
  final north = [3, 4, 5];
  final south = [eye - 6, eye - 5, eye - 4];
  final equator = [eye ~/ 2 - 1, eye ~/ 2, eye ~/ 2 + 1];

  // The mean difference over [ys] of rows of [a] from [aTop] and rows of [b] from [bTop]
  double rows(List<int> a, int aTop, List<int> b, int bTop, List<int> ys) {
    var sum = 0;
    for (final y in ys) {
      for (var i = 0; i < width * 3; i++) {
        sum += (a[(aTop + y) * width * 3 + i] - b[(bTop + y) * width * 3 + i]).abs();
      }
    }
    return sum / (ys.length * width * 3);
  }

  double eyes(List<int> ys) => rows(pixels, eye, pixels, 0, ys);
  // How much further the right eye is from the source than the left one
  double? excess(List<int> ys) =>
      same ? rows(pixels, eye, original.pixels, 0, ys) - rows(pixels, 0, original.pixels, 0, ys) : null;

  double seam(int top) {
    var sum = 0;
    for (var y = eye ~/ 2 - 8; y < eye ~/ 2 + 8; y++) {
      for (var c = 0; c < 3; c++) {
        sum += (pixels[((top + y) * width) * 3 + c] - pixels[((top + y) * width + width - 1) * 3 + c]).abs();
      }
    }
    return sum / 48;
  }

  final northExcess = excess(north);
  final southExcess = excess(south);
  return {
    'width': width,
    'height': out.height,
    'frame': index,
    'source_read': same,
    'pole_diff': (eyes(north) + eyes(south)) / 2,
    'equator_diff': eyes(equator),
    'pole_excess': northExcess == null || southExcess == null ? null : math.max(northExcess.abs(), southExcess.abs()),
    'equator_excess': excess(equator),
    'seam_left': seam(0),
    'seam_right': seam(eye),
  };
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
  final sphere = int.tryParse(options['--sphere'] ?? '');
  final relief = VideoReliefSettings(
    parallax: parallax,
    packing: packing,
    edgeFade: !flags.contains('--no-fade'),
    sphere: sphere != null,
  );
  final runtime = OrtRuntime.load(ortLibrary);
  final ffmpeg = p.join(ffmpegDir, 'bin', Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg');
  final ffprobe = p.join(ffmpegDir, 'bin', Platform.isWindows ? 'ffprobe.exe' : 'ffprobe');
  Directory(outDir).createSync(recursive: true);
  var failures = 0;

  for (final video in videos) {
    final name = sphere != null ? sphereOutputName(video) : videoOutputName(video, packing);
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
          sphereEyeWidth: sphere,
          keys: {
            'com.immuch360.kind': sphere != null ? 'StereoVideo360' : 'StereoVideo',
            'com.immuch360.pipeline': sphere != null ? 'relief-360-video' : 'relief-v1-video',
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
          Float32List run(Float32List input, int width, int height) {
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
          }

          if (sphere != null) {
            return LocalSphereVideoFrameWorker(
              ops: ops,
              model: run,
              eyeWidth: eyeWidth,
              eyeHeight: eyeHeight,
              side: modelWidth,
              shiftDegrees: relief.sphereShiftDegrees,
              alignment: alignment,
            );
          }
          return LocalVideoFrameWorker(
            ops: ops,
            model: run,
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
      if (sphere != null) {
        _emit('sphere', {
          'output': output,
          'st3d_top_bottom': probe.stereo == StereoLayout.topBottom,
          'sv3d': probe.hasSphericalMetadata,
          'half_sphere': probe.halfSphere,
          ...await _sphereFrame(ffmpeg, output, video, 50),
        });
      }
    } on Object catch (error, stack) {
      failures++;
      _emit('failed', {'video': video, 'error': '$error', 'stack': '$stack'.split('\n').take(6).join(' | ')});
    } finally {
      session.close();
    }
  }
  return failures;
}
