// The head tracker's own library on the three computers, with no webcam: the build machines have none, so recorded
// data goes through the same paths a webcam's frames would.
//
// - The One Euro filter of the native tracker gives the values printed by the phones' OneEuroFilter.kt
//   (test/fixtures/spatial/head_viewpoint_vectors.json), as the Dart copy does.
// - ht_predict gives what HeadSample.predictedAt gives, sample for sample.
// - The face followed: a larger face behind never takes the view, a recenter takes the largest again.
// - The recorded landmark track of the clip (test/fixtures/spatial/painted-head-12s.track, written by
//   packages/immuch_head_tracker/test_native/run.sh from test/fixtures/video/painted-head-12s.mp4) played through the
//   fake camera "track:", the same thread, callback and session as a webcam: every frame comes, the face is lost in
//   the gap and found after it, and the viewpoint of the Spatial views follows the head the right way.
// - On macOS, the clip itself through the camera path of AVFoundation ("file:"), with the NEON detector on arm64.
//
// Which library: IMMUCH360_HEAD_TRACKER_LIBRARY (the gcc build of test_native on Linux), else the app's build on
// Windows (IMMUCH360_BUILD_DIR or build/windows/x64/runner/*), else on macOS the dylib the package's build hook made
// for this test run (under build/). Without one the tests are skipped, unless IMMUCH360_REQUIRE_HEAD_TRACKER is 1 (the
// desktop workflow sets it where a library must be there).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';
import 'package:path/path.dart' as p;

const _track = 'test/fixtures/spatial/painted-head-12s.track';
const _clip = 'test/fixtures/video/painted-head-12s.mp4';

String? _findIn(Directory folder, bool Function(File file) wanted) {
  if (!folder.existsSync()) {
    return null;
  }
  for (final entity in folder.listSync(recursive: true, followLinks: false)) {
    if (entity is File && wanted(entity)) {
      return entity.absolute.path;
    }
  }
  return null;
}

String? _library() {
  final given = Platform.environment['IMMUCH360_HEAD_TRACKER_LIBRARY'];
  if (given != null && given.isNotEmpty) {
    return File(given).existsSync() ? p.absolute(given) : null;
  }
  if (Platform.isWindows) {
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
  if (Platform.isMacOS) {
    // The build hook's output for this run: a dylib, or the framework Flutter made of it
    return _findIn(Directory('build'), (file) {
      final name = p.basename(file.path);
      return name == 'libimmuch_head_tracker.dylib' ||
          (name == 'immuch_head_tracker' && p.basename(file.parent.path) == 'immuch_head_tracker.framework') ||
          (name == 'immuch_head_tracker' && file.path.contains('immuch_head_tracker.framework'));
    });
  }
  return null;
}

/// The lines of a track: time and faces
List<(int, List<HeadLandmarks>)> _readTrack(String path) {
  final lines = <(int, List<HeadLandmarks>)>[];
  for (final line in File(path).readAsLinesSync()) {
    final text = line.split('#').first.trim();
    if (text.isEmpty) {
      continue;
    }
    final numbers = text.split(RegExp(r'[\s,]+')).map(double.parse).toList();
    final faces = <HeadLandmarks>[
      for (var i = 1; i + 3 < numbers.length; i += 4)
        HeadLandmarks(
          score: numbers[i].round(),
          eyeX: numbers[i + 1],
          eyeY: numbers[i + 2],
          eyeDistance: numbers[i + 3],
        ),
    ];
    lines.add((numbers.first.round(), faces));
  }
  return lines;
}

void main() {
  final library = _library();
  final required = Platform.environment['IMMUCH360_REQUIRE_HEAD_TRACKER'] == '1';
  final skip = library == null && !required ? 'no head tracker library here (see the top of this file)' : null;
  if (library == null && required) {
    test('the head tracker library is there', () {
      fail('IMMUCH360_REQUIRE_HEAD_TRACKER is 1 and no head tracker library was found');
    });
    return;
  }

  test('the library loads and tells its build', () {
    final tracker = HeadTracker.load(library);
    final processor = tracker.openFrames();
    final detector = processor.info().detector;
    processor.close();
    // ignore: avoid_print
    print('${tracker.library}: detector ${detector.name}, AVX2 usable ${tracker.cpuAvx2}');
    if (Platform.isMacOS) {
      expect(detector, anyOf(FaceDetectorBuild.neon, FaceDetectorBuild.plain));
    } else {
      expect(detector, tracker.cpuAvx2 ? FaceDetectorBuild.avx2 : FaceDetectorBuild.plain);
    }
  }, skip: skip);

  test("the native One Euro filter gives the values of the phones' OneEuroFilter.kt", () {
    final vectors = jsonDecode(
      File('test/fixtures/spatial/head_viewpoint_vectors.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final rows = (vectors['oneEuro']! as List).cast<List>();
    final tracker = HeadTracker.load(library);
    var processor = tracker.openFrames();
    for (var i = 0; i < rows.length; i++) {
      if (i == 50) {
        // The vectors reset the filter here: a new tracker starts afresh
        processor.close();
        processor = tracker.openFrames();
      }
      final row = rows[i];
      final x = (row[1] as num).toDouble();
      // head_x = 0.5 - eye_x, the filter runs on head_x x 640
      final sample = processor.processLandmarks([
        HeadLandmarks(score: 90, eyeX: 0.5 - x / 640, eyeY: 0.5, eyeDistance: 0.1),
      ], (row[0] as num).toInt());
      expect(sample.filteredX * 640, closeTo((row[2] as num).toDouble(), 1e-6), reason: 'row $i');
    }
    processor.close();
  }, skip: skip);

  test('ht_predict gives what HeadSample.predictedAt gives, and recenter takes the largest face again', () {
    final tracker = HeadTracker.load(library);
    final processor = tracker.openFrames();
    final track = _readTrack(_track);
    var compared = 0;
    for (final (timeUs, faces) in track.take(110)) {
      final sample = processor.processLandmarks(faces, timeUs * 1000);
      for (final ahead in [0, 10000, 25000, 60000]) {
        final native = processor.predict(timeUs + ahead);
        final dart = sample.predictedAt(timeUs + ahead);
        if (dart == null) {
          expect(native, isNull);
        } else {
          expect(native, closeTo(dart, 1e-12), reason: 'at $timeUs + $ahead');
          compared++;
        }
      }
    }
    expect(compared, greaterThan(300));
    // A larger face behind: the one followed stays
    const user = HeadLandmarks(score: 90, eyeX: 0.4, eyeY: 0.45, eyeDistance: 0.08);
    const behind = HeadLandmarks(score: 95, eyeX: 0.8, eyeY: 0.4, eyeDistance: 0.2);
    var sample = processor.processLandmarks([user], 20000000000);
    sample = processor.processLandmarks([behind, user], 20033000000);
    expect(sample.eyeX, closeTo(0.4, 1e-9));
    expect(sample.faces, 2);
    processor.recenter();
    sample = processor.processLandmarks([behind, user], 20066000000);
    expect(sample.eyeX, closeTo(0.8, 1e-9));
    processor.close();
  }, skip: skip);

  test('the recorded landmark track through the fake camera: every frame, the loss, the viewpoint', () async {
    final tracker = HeadTracker.load(library);
    final lines = _readTrack(_track);
    final session = tracker.start(HeadCamera(id: 'track:${File(_track).absolute.path}', name: 'recorded track'));
    final samples = <HeadSample>[];
    final ended = Completer<Object>();
    final viewpoint = HeadViewpoint()..sensitivity = HeadViewpoint.desktopSensitivity;
    final viewpoints = <double>[];
    session.samples.listen(
      (sample) {
        samples.add(sample);
        if (sample.hasFace) {
          viewpoint.onFace(sample.filteredX, sample.timeNanos);
        } else if (sample.lost) {
          viewpoint.onLost(sample.timeNanos);
        }
        viewpoints.add(viewpoint.valueAt(sample.timeNanos));
      },
      onError: ended.complete,
      onDone: () {
        if (!ended.isCompleted) {
          ended.complete('closed');
        }
      },
    );
    final end = await ended.future.timeout(const Duration(seconds: 30));
    await session.close();
    expect(end, isA<HeadTrackerException>().having((e) => e.error, 'error', HeadTrackerError.deviceLost));
    // A sample may be skipped when two come before the session reads one, as with a webcam; never one twice
    expect(samples.length, greaterThanOrEqualTo(lines.length - 3));
    expect(samples.map((s) => s.sequence).toSet(), hasLength(samples.length));
    final withFace = lines.where((line) => line.$2.isNotEmpty).length;
    final found = samples.where((s) => s.hasFace).length;
    expect(found, greaterThanOrEqualTo(withFace - 3));
    expect(samples.any((s) => s.lost), isTrue, reason: 'the face is lost in the gap of the clip');
    // The eye midpoint is the track's, the filter starts on it
    final first = samples.firstWhere((s) => s.hasFace);
    expect(first.eyeX, closeTo(lines.first.$2.first.eyeX, 1e-9));
    expect(first.filteredX, closeTo(0.5 - first.eyeX, 1e-9));
    // The painted head goes to the right of the frame in its first second (the user's left): the view moves to the
    // left camera, below the middle, as on the phones
    final second = samples.indexWhere((s) => s.timeUs - samples.first.timeUs > 900000);
    expect(viewpoints[second], lessThan(HeadViewpoint.centreViewpoint));
    expect(viewpoints.every((v) => v >= HeadViewpoint.minViewpoint && v <= HeadViewpoint.maxViewpoint), isTrue);
    // ignore: avoid_print
    print(
      'track: ${samples.length} samples of ${lines.length} lines, $found with a face, viewpoint at 1 s '
      '${viewpoints[second].toStringAsFixed(3)}',
    );
  }, skip: skip);

  test('macOS: the clip through the camera path of AVFoundation', () async {
    final tracker = HeadTracker.load(library);
    final session = tracker.start(HeadCamera(id: 'file:${File(_clip).absolute.path}', name: 'recorded clip'));
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
    final end = await ended.future.timeout(const Duration(seconds: 40));
    final info = session.info();
    await session.close();
    expect(end, isA<HeadTrackerException>().having((e) => e.error, 'error', HeadTrackerError.deviceLost));
    final faces = samples.where((s) => s.hasFace).length;
    // ignore: avoid_print
    print(
      'AVFoundation: ${samples.length} samples, $faces with a face, detector ${info.detector.name}, '
      'median detection ${(samples.map((s) => s.detectUs).toList()..sort())[samples.length ~/ 2] / 1000} ms',
    );
    expect(samples.length, greaterThan(150));
    expect(faces, greaterThan(140));
    expect(samples.any((s) => s.lost), isTrue);
  }, skip: skip ?? (Platform.isMacOS ? null : 'macOS only'));
}
