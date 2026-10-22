// The head tracker's DLLs on the recorded clip, test/fixtures/video/painted-head-12s.mp4: a public domain painted face
// moving along a known path, absent from 8 s to 9 s (test/fixtures/video/painted-head-12s.txt). Every frame is
// processed at the clip's own timestamps (no wall clock), then filtered and turned into a viewpoint as the Spatial page
// does, and checked against the path: a face in at least 95% of the frames that hold one, none in the gap, the face
// lost 300 ms into the gap and the viewpoint back in the middle a second later, the centre close to the path, the
// viewpoint moving the right way, and the AVX2 and plain builds of the detector giving the same samples.
//
// Two sources of frames:
//   the file source of the DLL (Media Foundation, the same reader setup and luma path as a webcam): Windows, after a
//   Windows build of the app (it holds immuch_head_tracker.dll and the two detector DLLs);
//   the raw frame entry point, with the clip decoded by ffmpeg when it is on the PATH: any system, for instance a gcc
//   build of packages/immuch_head_tracker/test_native on Linux.
//
//   flutter build windows --debug -t lib/main_desktop.dart
//   flutter test test/desktop/spatial/head_tracker_windows_test.dart
// IMMUCH360_BUILD_DIR may name another folder holding the DLLs; IMMUCH360_HEAD_TRACKER_LIBRARY names the tracker's
// library itself (libimmuch_head_tracker.so of test_native/run.sh on Linux).

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';
import 'package:path/path.dart' as p;

const _clip = 'test/fixtures/video/painted-head-12s.mp4';
const _width = 320;
const _height = 240;
const _frames = 180;

/// The tracker's library to test, null when there is none
String? _library() {
  final given = Platform.environment['IMMUCH360_HEAD_TRACKER_LIBRARY'];
  if (given != null && given.isNotEmpty) {
    return File(given).existsSync() ? p.absolute(given) : null;
  }
  if (!Platform.isWindows) {
    return null;
  }
  final build = Platform.environment['IMMUCH360_BUILD_DIR'];
  for (final dir in [
    if (build != null && build.isNotEmpty) build,
    for (final mode in ['Debug', 'Profile', 'Release']) p.join('build', 'windows', 'x64', 'runner', mode),
  ]) {
    final dll = File(p.join(dir, 'immuch_head_tracker.dll'));
    if (dll.existsSync()) {
      return p.absolute(dll.path);
    }
  }
  return null;
}

/// Where the painted face's centre is in frame [index], as a fraction of the width; null in the gap
double? _truthX(int index) {
  final t = index / 15;
  final double x;
  if (t < 8) {
    x = 105 + 90 * math.sin(2 * math.pi * t / 4);
  } else if (t < 9) {
    return null;
  } else {
    x = 105 + 40 * math.sin(2 * math.pi * (t - 9) / 3);
  }
  return (x + 55) / 320;
}

double _percentile(List<double> sorted, double q) => sorted[math.min(sorted.length - 1, (sorted.length * q).floor())];

/// The clip's frames as 8 bit grey, decoded by ffmpeg; null without ffmpeg
Future<List<Uint8List>?> _ffmpegFrames() async {
  ProcessResult result;
  try {
    result = await Process.run('ffmpeg', [
      '-nostdin',
      '-v',
      'error',
      '-i',
      _clip,
      '-vf',
      'format=gray',
      '-f',
      'rawvideo',
      '-',
    ], stdoutEncoding: null);
  } on ProcessException {
    return null;
  }
  if (result.exitCode != 0) {
    return null;
  }
  final bytes = result.stdout as List<int>;
  const size = _width * _height;
  return [
    for (var offset = 0; offset + size <= bytes.length; offset += size)
      Uint8List.fromList(bytes.sublist(offset, offset + size)),
  ];
}

/// What the Spatial page would do with the samples: the filter and the viewpoint, at the desktop sensitivity
class _Replay {
  _Replay(this.samples) {
    for (final sample in samples) {
      viewpoint.onSample(sample, filter.add(sample));
      values.add(viewpoint.valueAt(sample.timeNanos));
    }
  }

  final List<HeadSample> samples;
  final filter = HeadXFilter();
  final viewpoint = HeadViewpoint()..sensitivity = HeadViewpoint.desktopSensitivity;
  final values = <double>[];
}

/// The checks of the clip on the samples of one run, printed as a line of the log
void _checkClip(List<HeadSample> samples, String label) {
  expect(samples, hasLength(_frames), reason: label);
  var holding = 0;
  var found = 0;
  var falseFaces = 0;
  int? firstLost;
  final errors = <double>[];
  for (var i = 0; i < samples.length; i++) {
    final sample = samples[i];
    final truth = _truthX(i);
    if (truth == null) {
      if (sample.hasFace) {
        falseFaces++;
      }
      if (sample.lost) {
        firstLost ??= i;
      }
      continue;
    }
    holding++;
    if (sample.hasFace) {
      found++;
      errors.add((sample.faceX - truth).abs());
    }
  }
  errors.sort();
  final times = samples.map((sample) => sample.detectUs / 1000).toList()..sort();
  final replay = _Replay(samples);
  // ignore: avoid_print
  print(
    '$label: faces $found of $holding, false faces in the gap $falseFaces, lost from frame $firstLost, centre error '
    'median ${(_percentile(errors, 0.5) * 100).toStringAsFixed(2)}% p95 ${(_percentile(errors, 0.95) * 100).toStringAsFixed(2)}% '
    'max ${(errors.last * 100).toStringAsFixed(2)}% of the width, detection median ${_percentile(times, 0.5).toStringAsFixed(2)} ms '
    'p95 ${_percentile(times, 0.95).toStringAsFixed(2)} ms, viewpoint at 1 s ${replay.values[15].toStringAsFixed(3)} '
    'and at 3 s ${replay.values[45].toStringAsFixed(3)}',
  );

  expect(found * 100, greaterThanOrEqualTo(holding * 95), reason: '$label: faces found');
  expect(falseFaces, 0, reason: '$label: faces in the gap');
  // The last face is frame 119 (7.933 s): no face but held for 300 ms, then lost from frame 124 (8.267 s)
  expect(firstLost, inInclusiveRange(124, 125), reason: '$label: lost 300 ms into the gap');
  expect(samples[120].state, HeadFaceState.noFace, reason: label);
  expect(_percentile(errors, 0.5), lessThan(0.02), reason: '$label: median centre error');
  expect(_percentile(errors, 0.95), lessThan(0.02), reason: '$label: p95 centre error');
  expect(errors.last, lessThan(0.03), reason: '$label: largest centre error');

  // The face sets the centre at 0 s (the middle of the picture). At 1 s it is at the right of the frame: the user moved
  // to their left, so the view comes from the left camera; at 3 s from the right one
  expect(replay.values[15], lessThan(0.3), reason: '$label: viewpoint at 1 s');
  expect(replay.values[45], greaterThan(0.7), reason: '$label: viewpoint at 3 s');
  // Lost at frame 124: the viewpoint eases back to the middle over one second
  final lost = samples[firstLost!];
  final settled = _Replay(samples.sublist(0, firstLost + 1));
  expect(settled.viewpoint.valueAt(lost.timeNanos + 1000000000), closeTo(0.5, 1e-9), reason: label);
  expect(settled.viewpoint.isAnimating(lost.timeNanos + 500000000), isTrue, reason: label);
  expect(settled.viewpoint.isAnimating(lost.timeNanos + 1000000000), isFalse, reason: label);
}

/// The AVX2 build against the plain one: the same face states, centres within a pixel of the detector image
void _compareBuilds(List<HeadSample> plain, List<HeadSample> avx2) {
  expect(avx2, hasLength(plain.length));
  var largest = 0.0;
  for (var i = 0; i < plain.length; i++) {
    expect(avx2[i].state, plain[i].state, reason: 'frame $i');
    if (plain[i].hasFace) {
      largest = math.max(largest, (avx2[i].faceX - plain[i].faceX).abs());
    }
  }
  // ignore: avoid_print
  print(
    'plain against AVX2: the same states, centres at most ${(largest * 160).toStringAsFixed(2)} pixels of 160 apart',
  );
  expect(largest, lessThanOrEqualTo(1 / 160));
}

void main() {
  final library = _library();
  final skip = library == null
      ? 'no head tracker library: build the app for Windows first, set IMMUCH360_BUILD_DIR, or set '
            'IMMUCH360_HEAD_TRACKER_LIBRARY'
      : null;
  // The desktop workflow names the build it tests: a build folder without the DLLs fails, rather than every test
  // below being skipped without a word
  final build = Platform.environment['IMMUCH360_BUILD_DIR'];
  if (library == null && Platform.isWindows && build != null && build.isNotEmpty) {
    test('the head tracker DLL is in IMMUCH360_BUILD_DIR', () {
      fail('IMMUCH360_BUILD_DIR is $build, which holds no immuch_head_tracker.dll');
    });
  }

  test('the library loads and tells what it runs with', () {
    final tracker = HeadTracker.load(library);
    final now = tracker.nowUs();
    expect(now, greaterThan(0));
    expect(tracker.nowUs(), greaterThanOrEqualTo(now));
    final processor = tracker.openFrames();
    expect(processor.info().detector, tracker.cpuAvx2 ? FaceDetectorBuild.avx2 : FaceDetectorBuild.plain);
    processor.close();
    if (!tracker.cpuAvx2) {
      expect(
        () => tracker.openFrames(options: const HeadTrackerOptions(detector: FaceDetectorBuild.avx2)),
        throwsA(isA<HeadTrackerException>().having((e) => e.error, 'error', HeadTrackerError.noAvx2)),
      );
    }
    expect(
      () => tracker.openFrames(options: const HeadTrackerOptions(detectEvery: -1)),
      throwsA(isA<HeadTrackerException>().having((e) => e.error, 'error', HeadTrackerError.argument)),
    );
    // ignore: avoid_print
    print('${tracker.library}: AVX2 build usable ${tracker.cpuAvx2}');
  }, skip: skip);

  test('the file source on the clip (Media Foundation)', () {
    final tracker = HeadTracker.load(library);
    final runs = <FaceDetectorBuild, List<HeadSample>>{};
    for (final build in [FaceDetectorBuild.plain, if (tracker.cpuAvx2) FaceDetectorBuild.avx2]) {
      final HeadFileReader reader;
      try {
        reader = tracker.openFile(
          File(_clip).absolute.path,
          options: HeadTrackerOptions(detector: build, detectEvery: 1),
        );
      } on HeadTrackerException catch (error) {
        if (!Platform.isWindows && error.error == HeadTrackerError.noMediaFoundation) {
          markTestSkipped('no Media Foundation here: the file source is Windows only');
          return;
        }
        fail(
          'the clip does not open through Media Foundation: $error. A Windows Server needs the Media Foundation '
          'feature (Install-WindowsFeature Server-Media-Foundation), a Windows N edition the Media Feature Pack',
        );
      }
      final info = reader.info();
      expect(info.detector, build);
      expect((info.width, info.height), (_width, _height));
      expect(info.nativeFourcc, 'H264');
      final samples = <HeadSample>[];
      for (HeadSample? sample = reader.next(); sample != null; sample = reader.next()) {
        samples.add(sample);
      }
      expect(reader.next(), isNull);
      reader.close();
      // The file's own timestamps, one frame every 1/15 s
      for (var i = 1; i < samples.length; i++) {
        expect(samples[i].timeUs - samples[i - 1].timeUs, closeTo(66667, 2), reason: 'frame $i');
        expect(samples[i].sequence, i + 1);
      }
      _checkClip(samples, 'Media Foundation, ${build.name}');
      runs[build] = samples;
    }
    if (runs.length == 2) {
      _compareBuilds(runs[FaceDetectorBuild.plain]!, runs[FaceDetectorBuild.avx2]!);
    }
  }, skip: skip);

  test('the raw frame entry point on the clip decoded by ffmpeg', () async {
    final frames = await _ffmpegFrames();
    if (frames == null) {
      markTestSkipped('no ffmpeg on the PATH');
      return;
    }
    expect(frames, hasLength(_frames));
    final tracker = HeadTracker.load(library);
    final runs = <FaceDetectorBuild, List<HeadSample>>{};
    for (final build in [FaceDetectorBuild.plain, if (tracker.cpuAvx2) FaceDetectorBuild.avx2]) {
      final processor = tracker.openFrames(options: HeadTrackerOptions(detector: build));
      final samples = [
        for (final (index, frame) in frames.indexed)
          processor.process(frame, _width, _height, index * 1000000000 ~/ 15),
      ];
      processor.close();
      _checkClip(samples, 'raw frames, ${build.name}');
      runs[build] = samples;
    }
    if (runs.length == 2) {
      _compareBuilds(runs[FaceDetectorBuild.plain]!, runs[FaceDetectorBuild.avx2]!);
    }
  }, skip: skip);

  // The capture thread, the samples it posts across threads to the session, and the end of a camera, with the clip
  // played at its own pace through the camera path (the camera id "file:<path>" of ht_api.h, for the tests)
  HeadCamera clipCamera() => HeadCamera(id: 'file:${File(_clip).absolute.path}', name: 'recorded clip');

  HeadTrackingSession? startClip(HeadTracker tracker) {
    try {
      return tracker.start(clipCamera(), options: const HeadTrackerOptions(detectEvery: 1));
    } on HeadTrackerException catch (error) {
      if (!Platform.isWindows && error.error == HeadTrackerError.noMediaFoundation) {
        return null;
      }
      rethrow;
    }
  }

  test('a camera session on the clip: samples in order, then the end of the camera', () async {
    final tracker = HeadTracker.load(library);
    final session = startClip(tracker);
    if (session == null) {
      markTestSkipped('no Media Foundation here: the camera path is Windows only');
      return;
    }
    final samples = <HeadSample>[];
    final ended = Completer<Object>();
    session.samples.listen(
      samples.add,
      onError: ended.complete,
      onDone: () {
        if (!ended.isCompleted) {
          ended.complete('closed');
        }
      },
    );
    final watch = Stopwatch()..start();
    final end = await ended.future.timeout(const Duration(seconds: 40));
    watch.stop();
    expect(end, isA<HeadTrackerException>().having((e) => e.error, 'error', HeadTrackerError.deviceLost));
    expect(session.error?.error, HeadTrackerError.deviceLost);
    final info = session.info();
    expect(info.nativeFourcc, 'H264');
    expect((info.width, info.height), (_width, _height));
    await session.close();

    // Paced as a camera: about the 12 s of the clip, each frame stamped with the clock of the session
    expect(watch.elapsed, greaterThan(const Duration(seconds: 10)));
    expect(samples.length, greaterThan(150), reason: 'samples given');
    var faces = 0;
    var holding = 0;
    for (var i = 0; i < samples.length; i++) {
      final sample = samples[i];
      if (i > 0) {
        expect(sample.sequence, greaterThan(samples[i - 1].sequence));
        expect(sample.timeUs, greaterThanOrEqualTo(samples[i - 1].timeUs));
      }
      final truth = _truthX(sample.sequence - 1);
      if (truth == null) {
        expect(sample.hasFace, isFalse, reason: 'frame ${sample.sequence - 1} is in the gap');
        continue;
      }
      holding++;
      if (sample.hasFace) {
        faces++;
        expect((sample.faceX - truth).abs(), lessThan(0.03), reason: 'frame ${sample.sequence - 1}');
      }
    }
    expect(faces * 100, greaterThanOrEqualTo(holding * 95));
    final span = samples.last.timeUs - samples.first.timeUs;
    expect(span, greaterThan(9000000));
    expect(session.nowUs(), greaterThanOrEqualTo(samples.last.timeUs));
    // ignore: avoid_print
    print(
      'camera path: ${samples.length} samples in ${watch.elapsed}, faces $faces of $holding, ${info.detector.name}',
    );
  }, skip: skip);

  test('closing a camera session while it streams releases it at once, and nothing follows', () async {
    final tracker = HeadTracker.load(library);
    final session = startClip(tracker);
    if (session == null) {
      markTestSkipped('no Media Foundation here: the camera path is Windows only');
      return;
    }
    var events = 0;
    final firstFive = Completer<void>();
    session.samples.listen(
      (sample) {
        events++;
        if (events == 5 && !firstFive.isCompleted) {
          firstFive.complete();
        }
      },
      onError: (Object error) {
        if (!firstFive.isCompleted) {
          firstFive.completeError(error);
        }
      },
    );
    await firstFive.future.timeout(const Duration(seconds: 20));
    final watch = Stopwatch()..start();
    await session.close();
    watch.stop();
    final atClose = events;
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    expect(session.isClosed, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(events, atClose);
    // ignore: avoid_print
    print('closed after $atClose samples in ${watch.elapsedMilliseconds} ms');
  }, skip: skip);

  test('no camera is opened by listing them, and a missing one is an error of the session', () async {
    final tracker = HeadTracker.load(library);
    List<HeadCamera> cameras;
    try {
      cameras = await tracker.cameras();
    } on HeadTrackerException catch (error) {
      expect(error.error, Platform.isWindows ? isNot(HeadTrackerError.noMediaFoundation) : anything);
      markTestSkipped('no camera list here: $error');
      return;
    }
    // ignore: avoid_print
    print('cameras: $cameras, default ${defaultHeadCamera(cameras)}');
    final session = tracker.start(const HeadCamera(id: r'\\?\no-such-camera', name: 'none'));
    final error = await session.samples.first.then<Object>((sample) => sample, onError: (Object error) => error);
    expect(error, isA<HeadTrackerException>().having((e) => e.error, 'error', HeadTrackerError.noCamera));
    await session.close();
  }, skip: skip);
}
