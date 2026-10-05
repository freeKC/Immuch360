import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/gopro_eac.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import '../../../fixtures/raw/gopro.stub.dart';
import '../spherical_probe_fixtures.dart';

ByteRangeReader _reader(Uint8List file) => (offset, length) async {
  final start = math.min(offset, file.length);
  return Uint8List.sublistView(file, start, math.min(file.length, start + length));
};

Future<SphericalProbe> _probe(Uint8List file) => probeSphericalMetadata(_reader(file));

const _degree = math.pi / 180;

void main() {
  group('GoProEacGeometry', () {
    test('lays out the faces of the MAX and of the MAX 2, 8 and 10 bit', () {
      for (final (width, height, overlap, half, middle, right) in [
        (4096, 1344, 32, 688, 1376, 2720),
        (5888, 1920, 64, 992, 1984, 3904),
        (5952, 1920, 96, 1008, 2016, 3936),
      ]) {
        final geometry = GoProEacGeometry(trackWidth: width, trackHeight: height);

        expect(GoProEacGeometry.fits(width, height), isTrue, reason: '$width x $height');
        expect(
          (geometry.face, geometry.overlap, geometry.half, geometry.middle, geometry.right),
          (height, overlap, half, middle, right),
          reason: '$width x $height',
        );
        expect(geometry.right + 2 * geometry.half, width, reason: 'the track ends with the right slot');
      }
    });

    test('does not fit other track sizes', () {
      for (final (width, height) in [(3840, 3840), (5760, 2880), (4097, 1344), (4400, 1344), (4095, 1365), (0, 0)]) {
        expect(GoProEacGeometry.fits(width, height), isFalse, reason: '$width x $height');
      }
    });

    test('names the camera and turns the view into its frame by the size of its faces', () {
      const max = GoProEacGeometry(trackWidth: 4096, trackHeight: 1344);
      const max2 = GoProEacGeometry(trackWidth: 5952, trackHeight: 1920);

      expect(goProCameraName(max), 'GoPro MAX');
      expect(goProCameraName(max2), 'GoPro MAX 2');
      expect(goProCameraName(const GoProEacGeometry(trackWidth: 3072, trackHeight: 1008)), 'GoPro');
      expect(goProViewToCamera(max), [0.0, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]);
      expect(goProViewToCamera(max2), [1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0]);
    });

    test('has six faces, three per track, each with three orthogonal unit axes', () {
      const faces = GoProEacGeometry.faces;
      expect(faces.map((face) => (face.texture, face.slot)), [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2)]);
      for (final face in faces) {
        // right x down is a unit vector along forward: the three axes are unit and orthogonal
        final cross = (
          x: face.right.y * face.down.z - face.right.z * face.down.y,
          y: face.right.z * face.down.x - face.right.x * face.down.z,
          z: face.right.x * face.down.y - face.right.y * face.down.x,
        );
        expect(cross.x.abs() + cross.y.abs() + cross.z.abs(), 1, reason: '$face');
        expect(
          (cross.x * face.forward.x + cross.y * face.forward.y + cross.z * face.forward.z).abs(),
          1,
          reason: '$face',
        );
      }
    });
  });

  group('goProEacGeometryOf', () {
    test('takes the first two video tracks of a MAX file, the sound and the metadata between them', () async {
      final probe = await _probe(goProFile());

      expect(probe.videoTracks.map((track) => (track.trackId, track.handlerName)), [
        (1, 'GoPro H.265'),
        (6, 'GoPro H.265'),
      ]);
      expect(goProEacGeometryOf(probe), const GoProEacGeometry(trackWidth: 4096, trackHeight: 1344));

      final max2 = await _probe(goProFile(width: 5952, height: 1920, bitDepth: 10));
      expect(goProEacGeometryOf(max2), const GoProEacGeometry(trackWidth: 5952, trackHeight: 1920));
      expect(max2.videoTracks.map((track) => track.bitDepth), [10, 10]);
    });

    test('gives nothing for tracks of another shape, of two sizes, or for one video track', () async {
      expect(goProEacGeometryOf(await _probe(goProFile(width: 3840, height: 3840))), isNull);
      expect(goProEacGeometryOf(await _probe(goProFile(secondWidth: 4160))), isNull);
      expect(
        goProEacGeometryOf(
          await _probe(mp4File(mp4Moov([mp4VideoTrack([], width: 4096, height: 1344, handlerType: 'vide')]))),
        ),
        isNull,
      );
      expect(goProEacGeometryOf(const SphericalProbe()), isNull);
    });
  });

  group('goProEacSamples', () {
    // The MAX 2 8 bit layout and the table as is: the vectors max2-reframe-resolve proto/eac.py gives, its pixel
    // centres moved to half pixels
    const geometry = GoProEacGeometry(trackWidth: 5888, trackHeight: 1920);
    final viewToCamera = goProViewToCamera(geometry);

    Vec3 direction(double lonDegrees, double latDegrees) => viewDirection(lonDegrees * _degree, latDegrees * _degree);

    void expectSamples(Vec3 view, List<(int, double, double, double)> expected, String reason) {
      final samples = goProEacSamples(geometry, viewToCamera, view);
      expect(samples, hasLength(expected.length), reason: '$reason: $samples');
      for (var i = 0; i < expected.length; i++) {
        final (texture, x, y, weight) = expected[i];
        expect(samples[i].texture, texture, reason: reason);
        expect(samples[i].x, closeTo(x, 1e-3), reason: reason);
        expect(samples[i].y, closeTo(y, 1e-3), reason: reason);
        expect(samples[i].weight, closeTo(weight, 1e-6), reason: reason);
      }
    }

    test('reads the six axes where eac.py reads them', () {
      expectSamples((x: 0, y: 0, z: 1), [(0, 2944.0, 960.0, 1)], 'forward');
      expectSamples((x: 0, y: 0, z: -1), [(1, 2944.0, 960.0, 1)], 'backward');
      expectSamples((x: 1, y: 0, z: 0), [(0, 4864.0, 960.0, 0.5078125), (0, 4928.0, 960.0, 0.4921875)], 'right');
      expectSamples((x: -1, y: 0, z: 0), [(0, 960.0, 960.0, 0.5078125), (0, 1024.0, 960.0, 0.4921875)], 'left');
      expectSamples((x: 0, y: -1, z: 0), [(1, 4864.0, 960.0, 0.5078125), (1, 4928.0, 960.0, 0.4921875)], 'up');
      expectSamples((x: 0, y: 1, z: 0), [(1, 960.0, 960.0, 0.5078125), (1, 1024.0, 960.0, 0.4921875)], 'down');
    });

    test('reads directions off the axes where eac.py reads them', () {
      expectSamples(direction(30, 0), [(0, 3584.0, 960.0, 1)], '30 degrees right of forward');
      expectSamples(direction(0, 20), [(0, 2944.0, 533.333, 1)], '20 degrees above forward');
      expectSamples(
        (x: -math.cos(2 * _degree), y: 0, z: math.sin(2 * _degree)),
        [(0, 1066.667, 960.0, 1)],
        '2 degrees from left toward the front',
      );
      expectSamples(direction(170, 5), [(1, 3052.304, 746.667, 1)], 'longitude 170, latitude 5');
    });

    test('gives every direction shares that add up to 1, inside the tracks', () {
      final random = math.Random(18);
      for (var i = 0; i < 2000; i++) {
        final view = direction(random.nextDouble() * 360 - 180, math.asin(random.nextDouble() * 2 - 1) / _degree);
        final samples = goProEacSamples(geometry, viewToCamera, view);

        expect(samples, isNotEmpty);
        expect(samples.fold(0.0, (sum, sample) => sum + sample.weight), closeTo(1, 1e-9));
        for (final sample in samples) {
          expect(sample.x, inInclusiveRange(0.5, geometry.trackWidth - 0.5));
          expect(sample.y, inInclusiveRange(0.5, geometry.trackHeight - 0.5));
        }
      }
    });

    test('turns the view of a MAX a quarter turn about the front axis', () {
      const max = GoProEacGeometry(trackWidth: 4096, trackHeight: 1344);
      // Straight up in the view is the camera's up, which the MAX table puts along its -x: the left face
      final up = goProEacSamples(max, goProViewToCamera(max), (x: 0, y: -1, z: 0));
      expect(up.map((sample) => sample.texture), everyElement(0));
      expect(up.first.x, lessThan(max.middle));
      // Forward stays the middle of the front face
      final forward = goProEacSamples(max, goProViewToCamera(max), (x: 0, y: 0, z: 1)).single;
      expect((forward.texture, forward.x, forward.y), (0, 1376.0 + 672, 672.0));
    });
  });
}
