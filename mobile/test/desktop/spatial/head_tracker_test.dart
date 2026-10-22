// packages/immuch_head_tracker without its DLLs: the ports of the phones' filter and viewpoint against the values the
// Kotlin classes print (test/fixtures/spatial/head_viewpoint_vectors.json), the mirror sign, the default camera (never an
// infrared one), the camera list, the status codes, the stream of a session, the native structures, and the vendored
// libfacedetection (pinned blobs, the licence on the licence page).

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/spatial/head_tracker_licenses.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';
import 'package:immuch_head_tracker/src/native_head_tracker.dart' show HtInfo, HtOptions, HtSample;
import 'package:path/path.dart' as p;

const _package = 'packages/immuch_head_tracker';

Map<String, Object?> _vectors() =>
    jsonDecode(File('test/fixtures/spatial/head_viewpoint_vectors.json').readAsStringSync()) as Map<String, Object?>;

HeadSample _sample({
  required int sequence,
  int timeUs = 0,
  double faceX = double.nan,
  HeadFaceState state = HeadFaceState.face,
}) => HeadSample(
  timeUs: timeUs,
  sequence: sequence,
  faceX: faceX,
  faceY: 0.4,
  faceWidth: 0.2,
  faceHeight: 0.25,
  confidence: 0.9,
  state: state,
  detectUs: 3000,
  frameWidth: 640,
  frameHeight: 480,
  faces: state == HeadFaceState.face ? 1 : 0,
);

/// The git blob id of a file as the vendored commit has it (LF line ends: a checkout on Windows may give CRLF)
String _blob(File file) {
  final text = file.readAsBytesSync();
  final bytes = <int>[];
  for (var i = 0; i < text.length; i++) {
    if (text[i] == 13 && i + 1 < text.length && text[i + 1] == 10) {
      continue;
    }
    bytes.add(text[i]);
  }
  return sha1.convert([...utf8.encode('blob ${bytes.length}\u0000'), ...bytes]).toString();
}

void main() {
  group('OneEuroFilter', () {
    test('gives the values of OneEuroFilter.kt', () {
      final rows = (_vectors()['oneEuro']! as List).cast<List>();
      final filter = OneEuroFilter();
      for (var i = 0; i < rows.length; i++) {
        if (i == 50) {
          filter.reset();
        }
        final row = rows[i];
        final value = filter.filter((row[1] as num).toDouble(), (row[0] as num).toInt());
        expect(value, closeTo((row[2] as num).toDouble(), 1e-9), reason: 'row $i');
      }
      expect(rows, hasLength(80));
    });
  });

  group('HeadViewpoint', () {
    test('gives the values of HeadViewpoint in HeadTracker.kt, at both sensitivities', () {
      final rows = (_vectors()['viewpoint']! as List).cast<List>();
      HeadViewpoint? viewpoint;
      double? sensitivity;
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i];
        final rowSensitivity = (row[0] as num).toDouble();
        if (viewpoint == null || sensitivity != rowSensitivity) {
          viewpoint = HeadViewpoint()..sensitivity = rowSensitivity;
          sensitivity = rowSensitivity;
        }
        final now = (row[1] as num).toInt();
        switch (row[2]) {
          case 'face':
            viewpoint.onFace((row[3] as num).toDouble(), now);
          case 'lost':
            viewpoint.onLost(now);
          case 'recenter':
            viewpoint
              ..recenter()
              ..onFace((row[3] as num).toDouble(), now);
        }
        // The Kotlin class computes in 32 bit floats
        expect(viewpoint.valueAt(now), closeTo((row[4] as num).toDouble(), 2e-6), reason: 'row $i');
        expect(viewpoint.isAnimating(now), row[5], reason: 'row $i');
      }
      expect(rows.map((row) => row[0]).toSet(), {2.0, 3.0});
    });

    test('a head moving to the right of the user moves the viewpoint towards the right camera', () {
      final viewpoint = HeadViewpoint()..sensitivity = HeadViewpoint.desktopSensitivity;
      // A webcam does not mirror: the head moving to the user's right moves to the left of the frame
      final centred = _sample(sequence: 1, faceX: 0.5);
      final right = _sample(sequence: 2, timeUs: 1000000, faceX: 0.45);
      final left = _sample(sequence: 3, timeUs: 2000000, faceX: 0.55);
      expect(right.headX, closeTo(0.05, 1e-12));
      expect(left.headX, closeTo(-0.05, 1e-12));
      viewpoint.onFace(centred.headX, centred.timeNanos);
      viewpoint.onFace(right.headX, right.timeNanos);
      expect(viewpoint.valueAt(right.timeNanos + 400000000), closeTo(0.65, 1e-12));
      viewpoint.onFace(left.headX, left.timeNanos);
      expect(viewpoint.valueAt(left.timeNanos), closeTo(0.35, 1e-12));
      // Kept between 0.15 and 0.85
      viewpoint.onFace(_sample(sequence: 4, faceX: 0.05).headX, left.timeNanos);
      expect(viewpoint.valueAt(left.timeNanos), HeadViewpoint.maxViewpoint);
    });

    test('a lost face eases back to the middle in one second', () {
      final viewpoint = HeadViewpoint()..sensitivity = 3;
      viewpoint.onFace(0, 0);
      viewpoint.onFace(0.1, 500000000);
      expect(viewpoint.valueAt(500000000), closeTo(0.8, 1e-12));
      viewpoint.onLost(600000000);
      expect(viewpoint.valueAt(1100000000), closeTo(0.65, 1e-12));
      expect(viewpoint.valueAt(1600000000), closeTo(0.5, 1e-12));
      expect(viewpoint.isAnimating(1600000000), isFalse);
    });
  });

  group('HeadXFilter', () {
    test('filters headX on the 640 pixel scale and starts afresh after a loss', () {
      final filter = HeadXFilter();
      expect(filter.add(_sample(sequence: 1, faceX: 0.3)), closeTo(0.2, 1e-12));
      final second = filter.add(_sample(sequence: 2, timeUs: 66667, faceX: 0.2))!;
      expect(second, greaterThan(0.2));
      expect(second, lessThan(0.3));
      final reference = OneEuroFilter();
      reference.filter(0.2 * 640, 0);
      expect(second, closeTo(reference.filter(0.3 * 640, 66667000) / 640, 1e-12));
      // No face but not lost yet: the filter keeps its history
      expect(filter.add(_sample(sequence: 3, timeUs: 133333, state: HeadFaceState.noFace)), isNull);
      expect(filter.add(_sample(sequence: 4, timeUs: 200000, faceX: 0.2)), isNot(closeTo(0.3, 1e-9)));
      // Lost: the next face passes unfiltered
      filter.add(_sample(sequence: 5, timeUs: 600000, state: HeadFaceState.lost));
      expect(filter.add(_sample(sequence: 6, timeUs: 666667, faceX: 0.9)), closeTo(-0.4, 1e-12));
      expect(filter.rawX, closeTo(-0.4, 1e-12));
    });

    test('a sample without a face has no headX', () {
      expect(_sample(sequence: 1, state: HeadFaceState.noFace).headX, isNaN);
      expect(_sample(sequence: 1, faceX: 0.01).headX, closeTo(0.49, 1e-12));
    });
  });

  group('cameras', () {
    test('an infrared camera is never the default', () {
      const ir = HeadCamera(id: 'a', name: 'USB2.0 IR UVC WebCam');
      const colour = HeadCamera(id: 'b', name: 'USB2.0 FHD UVC WebCam');
      expect(defaultHeadCamera([ir, colour]), colour);
      expect(defaultHeadCamera([ir]), isNull);
      expect(defaultHeadCamera(const []), isNull);
      for (final name in [
        'USB2.0 IR UVC WebCam',
        'Integrated IR Camera',
        'HP IR Camera',
        'Windows Hello Face Software Device',
        'Intel(R) RealSense(TM) Depth Camera 415',
        'Infrared Camera',
        'IR-Camera',
      ]) {
        expect(looksInfrared(name), isTrue, reason: name);
      }
      for (final name in [
        'USB2.0 FHD UVC WebCam',
        'Integrated Camera',
        'Logitech BRIO',
        'Mirror Cam',
        'HD Webcam C270',
        'OBS Virtual Camera',
      ]) {
        expect(looksInfrared(name), isFalse, reason: name);
      }
    });

    test('the list of ht_list_cameras', () {
      final cameras = parseHeadCameras(
        r'[{"id":"\\\\?\\usb#vid_0c45&pid_6366#a","name":"USB2.0 FHD UVC WebCam"},'
        r'{"id":"\\\\?\\usb#vid_0c45&pid_6367#b","name":"USB2.0 IR UVC WebCam"},{"id":"","name":"no id"},'
        r'{"id":"c"}]',
      );
      expect(cameras.map((camera) => camera.name), ['USB2.0 FHD UVC WebCam', 'USB2.0 IR UVC WebCam', '']);
      expect(cameras.first.id, r'\\?\usb#vid_0c45&pid_6366#a');
      expect(cameras[1].infrared, isTrue);
      expect(parseHeadCameras('[]'), isEmpty);
    });
  });

  group('status codes', () {
    test('map to errors', () {
      expect(HeadTrackerStatus.errorOf(0), isNull);
      expect(HeadTrackerStatus.errorOf(1), isNull);
      expect(HeadTrackerStatus.errorOf(-1), HeadTrackerError.accessDenied);
      expect(HeadTrackerStatus.errorOf(-2), HeadTrackerError.noMediaFoundation);
      expect(HeadTrackerStatus.errorOf(-3), HeadTrackerError.noCamera);
      expect(HeadTrackerStatus.errorOf(-4), HeadTrackerError.cameraBusy);
      expect(HeadTrackerStatus.errorOf(-5), HeadTrackerError.deviceLost);
      expect(HeadTrackerStatus.errorOf(-6), HeadTrackerError.noDetector);
      expect(HeadTrackerStatus.errorOf(-7), HeadTrackerError.noAvx2);
      expect(HeadTrackerStatus.errorOf(-8), HeadTrackerError.format);
      expect(HeadTrackerStatus.errorOf(-9), HeadTrackerError.argument);
      expect(HeadTrackerStatus.errorOf(-10), HeadTrackerError.failed);
      expect(HeadTrackerStatus.errorOf(-99), HeadTrackerError.failed);
      expect(
        HeadTrackerException.fromStatus(-1, hresult: 0x80070005 - 0x100000000).toString(),
        'HeadTrackerException(accessDenied, 0x80070005)',
      );
      expect(cameraPrivacySettingsUri, 'ms-settings:privacy-webcam');
    });

    test('FOURCC of the native formats', () {
      expect(fourccText(0x3231564E), 'NV12');
      expect(fourccText(0x47504A4D), 'MJPG');
      expect(fourccText(0x32595559), 'YUY2');
      expect(fourccText(22), '22');
      expect(fourccText(0), '');
    });
  });

  group('HeadTrackingSession', () {
    test('gives each sample once, then the error that stopped the camera', () async {
      ({HeadSample sample, int status})? latest;
      final session = HeadTrackingSession.forTesting(latest: () => latest, nowUs: () => 42);
      final events = <Object>[];
      final done = Completer<void>();
      session.samples.listen(events.add, onError: events.add, onDone: done.complete);
      session.signal(1, 0);
      expect(session.latest, isNull);
      latest = (sample: _sample(sequence: 1, faceX: 0.5), status: 0);
      session.signal(1, 0);
      // The listener may post several calls for one sample
      session.signal(1, 0);
      latest = (sample: _sample(sequence: 3, faceX: 0.4), status: 0);
      session.signal(2, 0);
      session.signal(3, 0);
      latest = (sample: _sample(sequence: 3, faceX: 0.4), status: HeadTrackerStatus.deviceLost);
      session.signal(4, HeadTrackerStatus.deviceLost);
      session.signal(5, 0);
      await session.close();
      await done.future;
      expect(events, hasLength(3));
      expect((events[0] as HeadSample).sequence, 1);
      expect((events[1] as HeadSample).sequence, 3);
      expect((events[2] as HeadTrackerException).error, HeadTrackerError.deviceLost);
      expect(session.error?.error, HeadTrackerError.deviceLost);
      expect(session.latest?.sequence, 3);
      expect(session.nowNanos(), 42000);
      expect(session.isClosed, isTrue);
      // Signals after the close are ignored, a second close is the same
      session.signal(6, 0);
      await session.close();
    });
  });

  group('native structures', () {
    test('have the sizes of ht_api.h', () {
      expect(sizeOf<HtOptions>(), 32);
      expect(sizeOf<HtSample>(), 80);
      expect(sizeOf<HtInfo>(), 32);
      expect(headTrackerApiVersion, 1);
      final header = File(p.join(_package, 'src', 'ht_api.h')).readAsStringSync();
      expect(header, contains('#define HT_API_VERSION $headTrackerApiVersion\n'));
      for (final (name, value) in [
        ('HT_E_ACCESS_DENIED', HeadTrackerStatus.accessDenied),
        ('HT_E_NO_MEDIA_FOUNDATION', HeadTrackerStatus.noMediaFoundation),
        ('HT_E_NO_CAMERA', HeadTrackerStatus.noCamera),
        ('HT_E_CAMERA_BUSY', HeadTrackerStatus.cameraBusy),
        ('HT_E_DEVICE_LOST', HeadTrackerStatus.deviceLost),
        ('HT_E_NO_DETECTOR', HeadTrackerStatus.noDetector),
        ('HT_E_NO_AVX2', HeadTrackerStatus.noAvx2),
        ('HT_E_FORMAT', HeadTrackerStatus.format),
        ('HT_E_ARGUMENT', HeadTrackerStatus.argument),
        ('HT_E_FAILED', HeadTrackerStatus.failed),
      ]) {
        expect(header, contains('#define $name ($value)\n'), reason: name);
      }
      for (final (index, name) in ['UNKNOWN', 'ABSENT', 'TURNED_OFF', 'OFF', 'STUCK_ON'].indexed) {
        expect(header, contains('#define HT_FRAMING_$name $index\n'));
        expect(AutoFramingState.values[index].name.toUpperCase(), name.replaceAll('_', ''));
      }
    });
  });

  group('libfacedetection', () {
    final folder = p.join(_package, 'third_party', 'libfacedetection');

    test('is the pinned commit, file for file', () {
      final readme = File(p.join(folder, 'README.md')).readAsStringSync();
      expect(readme, contains('commit `$libfacedetectionCommit`'));
      final pins = {
        for (final match in RegExp(r'^\| `([^`]+)`[^|]*\| `([0-9a-f]{40})` \|$', multiLine: true).allMatches(readme))
          match.group(1)!: match.group(2)!,
      };
      expect(
        pins.keys,
        unorderedEquals([
          'LICENSE',
          'src/facedetectcnn.h',
          'src/facedetectcnn.cpp',
          'src/facedetectcnn-model.cpp',
          'src/facedetectcnn-data.cpp',
        ]),
      );
      for (final MapEntry(key: path, value: blob) in pins.entries) {
        expect(_blob(File(p.join(folder, path))), blob, reason: path);
      }
      final files = Directory(folder)
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => p.posix.joinAll(p.split(p.relative(file.path, from: folder))));
      expect(files.toSet(), {...pins.keys, 'README.md'});
    });

    test('its licence on the licence page is LICENSE', () {
      final licence = File(p.join(folder, 'LICENSE')).readAsStringSync().replaceAll('\r\n', '\n');
      expect(libfacedetectionLicense, licence.trimRight());
      final entry = libfacedetectionLicenseEntry();
      expect(entry.packages, ['libfacedetection']);
      final text = entry.paragraphs.map((paragraph) => paragraph.text).join('\n');
      expect(text, contains(libfacedetectionCommit));
      expect(text, contains('Copyright (c) 2015-2019, Shiqi Yu, all rights reserved.'));
      expect(text, contains('Redistributions in binary form must reproduce the above copyright notice'));
      expect(entry, isA<LicenseEntryWithLineBreaks>());
    });

    test('the app adds it to the licence page', () async {
      final entries = await headTrackerLicenseEntries().toList();
      expect(entries.map((entry) => entry.packages.toList()), [
        ['libfacedetection'],
      ]);
    });
  });
}
