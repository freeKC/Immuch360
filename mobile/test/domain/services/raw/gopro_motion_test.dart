import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/camera_motion.dart';
import 'package:immich_mobile/domain/services/raw/gopro_motion.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import '../../../fixtures/raw/gopro_gpmf.stub.dart';
import '../../../fixtures/raw/gopro_gpmf_frames.dart';
import '../spherical_probe_fixtures.dart' show mp4Ftyp;

/// Reads [file] as a local file or a server does: fewer bytes at the end, none past it. Records each read.
ByteRangeReader _reader(Uint8List file, [List<(int, int)>? reads]) => (offset, length) async {
  reads?.add((offset, length));
  if (offset >= file.length) {
    return Uint8List(0);
  }
  return Uint8List.sublistView(file, offset, math.min(file.length, offset + length));
};

Future<CameraMotionTrack?> _motion(
  Uint8List file, {
  List<(int, int)>? reads,
  int? fileSize,
  int maxMoovLength = goProMaxMoovLength,
  int maxPayloadLength = goProMaxMotionLength,
}) => readGoProMotion(
  _reader(file, reads),
  fileSize ?? file.length,
  maxMoovLength: maxMoovLength,
  maxPayloadLength: maxPayloadLength,
);

/// The real frames 0 to 7 in two payloads of four, as the camera writes 30 a payload
List<List<int>> _firstPayloads({bool grav = true, bool shut = true}) => [
  for (final range in [(0, 4), (4, 8)])
    goProPayload(
      cori: goProFirstCori.sublist(range.$1, range.$2),
      grav: grav ? goProFirstGrav.sublist(range.$1, range.$2) : null,
      shut: shut ? goProFirstShut.sublist(range.$1, range.$2) : null,
    ),
];

/// Time of frame [i] of a 30000 / 1001 fps video
double _frameTime(int i) => i * 3003 / 90000;

// q v q^-1 for a quaternion (w, x, y, z) and a vector
List<double> _rotate(List<double> q, List<double> v) {
  final (w, x, y, z) = (q[0], q[1], q[2], q[3]);
  // t = 2 u x v, v' = v + w t + u x t
  final tx = 2 * (y * v[2] - z * v[1]);
  final ty = 2 * (z * v[0] - x * v[2]);
  final tz = 2 * (x * v[1] - y * v[0]);
  return [v[0] + w * tx + (y * tz - z * ty), v[1] + w * ty + (z * tx - x * tz), v[2] + w * tz + (x * ty - y * tx)];
}

List<double> _conjugate(List<double> q) => [q[0], -q[1], -q[2], -q[3]];

// Largest angle in degrees between the vectors and their mean direction
double _spread(List<List<double>> vectors) {
  final mean = [0.0, 0.0, 0.0];
  for (final v in vectors) {
    for (var k = 0; k < 3; k++) {
      mean[k] += v[k];
    }
  }
  final norm = math.sqrt(mean[0] * mean[0] + mean[1] * mean[1] + mean[2] * mean[2]);
  var largest = 0.0;
  for (final v in vectors) {
    final length = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    final cos = ((v[0] * mean[0] + v[1] * mean[1] + v[2] * mean[2]) / (norm * length)).clamp(-1.0, 1.0);
    largest = math.max(largest, math.acos(cos) * 180 / math.pi);
  }
  return largest;
}

List<double> _row(Float32List values, int width, int i) => [for (var k = 0; k < width; k++) values[width * i + k]];

void main() {
  group('readGoProMotion on real values of the GoPro MAX sample', () {
    test('gives CORI, GRAV and SHUT of each frame at the time of the video frame, as gpmf.py does', () async {
      final reads = <(int, int)>[];
      final track = await _motion(goProMotionFile(_firstPayloads(), videoFrames: 596), reads: reads);
      expect(track, isNotNull);
      track!;
      expect(track.source, CameraMotionSource.goProGpmf);
      expect(track.timeOrigin, CameraMotionTimeOrigin.firstFrame);
      expect(track.cameraModel, goProMaxName);
      expect(track.firmware, goProMaxFirmware);
      expect(track.truncated, isFalse);
      expect(track.samples.isEmpty, isTrue);
      expect(track.sampleRate, isNull);
      expect(track.frameTimes.length, 8);
      for (var i = 0; i < 8; i++) {
        expect(track.frameTimes[i], closeTo(_frameTime(i), 1e-12));
        final orientation = _row(track.frameOrientations!, 4, i);
        final gravity = _row(track.frameGravity!, 3, i);
        for (var k = 0; k < 4; k++) {
          expect(orientation[k], closeTo(goProFirstCoriExpected[i][k], 1e-7));
        }
        for (var k = 0; k < 3; k++) {
          expect(gravity[k], closeTo(goProFirstGravExpected[i][k], 1e-7));
        }
        expect(track.frameExposures[i], closeTo(goProFirstShut[i], 1e-12));
      }
      // The orientations are unit quaternions to within the steps of 1/32767
      for (var i = 0; i < 8; i++) {
        final q = _row(track.frameOrientations!, 4, i);
        expect(math.sqrt(q.fold(0.0, (sum, v) => sum + v * v)), closeTo(1, 2e-4));
      }
      // The top level boxes, the moov box, then one read per payload
      expect(reads.length, lessThanOrEqualTo(5));
    });

    test('turns GRAV into one direction of the world with the inverse of CORI, not with CORI', () async {
      // One payload per spread frame: every 25th frame over the 20 s of the sample
      final payloads = [
        for (var i = 0; i < goProSpreadFrames.length; i++)
          goProPayload(cori: [goProSpreadCori[i]], grav: [goProSpreadGrav[i]], shut: [0.0003]),
      ];
      final track = (await _motion(goProMotionFile(payloads, videoFrames: 596)))!;
      final count = goProSpreadFrames.length;
      expect(track.frameTimes.length, count);
      final orientations = [for (var i = 0; i < count; i++) _row(track.frameOrientations!, 4, i)];
      final gravity = [for (var i = 0; i < count; i++) _row(track.frameGravity!, 3, i)];
      for (var i = 0; i < count; i++) {
        for (var k = 0; k < 4; k++) {
          expect(orientations[i][k], closeTo(goProSpreadCoriExpected[i][k], 1e-7));
        }
        for (var k = 0; k < 3; k++) {
          expect(gravity[i][k], closeTo(goProSpreadGravExpected[i][k], 1e-7));
        }
      }
      // The camera turns a lot over these frames: up to 180 degrees from the first
      var turned = 0.0;
      for (final q in orientations) {
        final dot =
            (q[0] * orientations.first[0] +
                    q[1] * orientations.first[1] +
                    q[2] * orientations.first[2] +
                    q[3] * orientations.first[3])
                .abs()
                .clamp(0.0, 1.0);
        turned = math.max(turned, 2 * math.acos(dot) * 180 / math.pi);
      }
      expect(turned, greaterThan(150));

      // World gravity: q^-1 g q, the camera's gravity turned into the world
      final world = [for (var i = 0; i < count; i++) _rotate(_conjugate(orientations[i]), gravity[i])];
      final spread = _spread(world);
      expect(spread, closeTo(goProSpreadWorldGravityDegrees, 0.01));
      expect(spread, lessThan(1.7));
      final wrongWay = _spread([for (var i = 0; i < count; i++) _rotate(orientations[i], gravity[i])]);
      expect(wrongWay, closeTo(goProSpreadWrongWayDegrees, 0.05));
      expect(wrongWay, greaterThan(100));
    });

    test('gives as many frames as the video has, when the GPMF has more', () async {
      final track = (await _motion(goProMotionFile(_firstPayloads(), videoFrames: 6)))!;
      expect(track.frameTimes.length, 6);
      expect(track.frameOrientations!.length, 24);
      expect(track.frameGravity!.length, 18);
      expect(track.frameExposures.length, 6);
      expect(track.frameTimes.last, closeTo(_frameTime(5), 1e-12));
    });

    test('takes the times of the payloads without a video track', () async {
      final track = (await _motion(goProMotionFile(_firstPayloads(), withVideo: false, payloadTicks: [1001, 867])))!;
      expect(track.timeOrigin, CameraMotionTimeOrigin.firstSample);
      expect(track.frameTimes.length, 8);
      for (var i = 0; i < 4; i++) {
        expect(track.frameTimes[i], closeTo(i * 1.001 / 4, 1e-12));
        expect(track.frameTimes[4 + i], closeTo(1.001 + i * 0.867 / 4, 1e-12));
      }
    });

    test('reads chunks of several payloads, and 64 bit chunk offsets', () async {
      final payloads = [..._firstPayloads(), goProPayload(cori: goProFirstCori, grav: goProFirstGrav)];
      for (final (perChunk, co64) in [(2, false), (3, true), (1, true)]) {
        final track = (await _motion(goProMotionFile(payloads, perChunk: perChunk, co64: co64)))!;
        expect(track.frameTimes.length, 16, reason: 'perChunk $perChunk, co64 $co64');
        for (var i = 0; i < 16; i++) {
          expect(track.frameOrientations![4 * i], closeTo(goProFirstCoriExpected[i % 8][0], 1e-7));
          expect(track.frameGravity![3 * i + 2], closeTo(goProFirstGravExpected[i % 8][2], 1e-7));
        }
      }
    });

    test('finds the track by its handler name when the sample entry is not gpmd', () async {
      final track = await _motion(goProMotionFile(_firstPayloads(), entry: 'mett'));
      expect(track?.frameTimes.length, 8);
    });

    test('counts SHUT and GRAV entries over the payloads, SHUT running on its own clock', () async {
      // The sample has 29, 30 or 31 SHUT entries in a payload of 30 CORI entries, 596 in all for 596 frames
      final exposures = [for (var i = 0; i < 9; i++) 0.001 * (i + 1)];
      final payloads = [
        goProPayload(
          cori: goProFirstCori.sublist(0, 4),
          grav: goProFirstGrav.sublist(0, 4),
          shut: exposures.sublist(0, 3),
        ),
        goProPayload(
          cori: goProFirstCori.sublist(4, 8),
          grav: goProFirstGrav.sublist(4, 8),
          shut: exposures.sublist(3, 9),
        ),
      ];
      final track = (await _motion(goProMotionFile(payloads)))!;
      expect(track.frameTimes.length, 8);
      expect(track.frameExposures.length, 8);
      for (var i = 0; i < 8; i++) {
        expect(track.frameExposures[i], closeTo(exposures[i], 1e-9));
        expect(track.frameGravity![3 * i + 1], closeTo(goProFirstGravExpected[i][1], 1e-7));
      }
    });

    test('divides each element by its own SCAL when there is one per element', () async {
      final payload = goProPayload(
        cori: goProFirstCori.sublist(0, 2),
        grav: goProFirstGrav.sublist(0, 2),
        gravScale: [1, 2, 4],
      );
      final track = (await _motion(goProMotionFile([payload])))!;
      expect(track.frameGravity!.sublist(0, 3), [
        goProFirstGrav[0][0] / 1,
        goProFirstGrav[0][1] / 2,
        goProFirstGrav[0][2] / 4,
      ]);
    });
  });

  group('readGoProMotion on incomplete files', () {
    test('gives NaN gravity and exposure for the frames past the end of GRAV or SHUT', () async {
      final payloads = [
        goProPayload(
          cori: goProFirstCori.sublist(0, 4),
          grav: goProFirstGrav.sublist(0, 4),
          shut: goProFirstShut.sublist(0, 4),
        ),
        goProPayload(cori: goProFirstCori.sublist(4, 8)),
      ];
      final track = (await _motion(goProMotionFile(payloads)))!;
      expect(track.frameTimes.length, 8);
      expect(track.frameGravity![3 * 3].isFinite, isTrue);
      expect(track.frameGravity![3 * 4].isNaN, isTrue);
      expect(track.frameExposures[3].isFinite, isTrue);
      expect(track.frameExposures[4].isNaN, isTrue);
    });

    test('gives no gravity and no exposures when the file has none', () async {
      final track = (await _motion(goProMotionFile(_firstPayloads(grav: false, shut: false))))!;
      expect(track.frameGravity, isNull);
      expect(track.frameExposures, isEmpty);
      expect(track.frameOrientations!.length, 32);
    });

    test('gives null without a moov box, a GPMF track or CORI', () async {
      expect(await _motion(Uint8List.fromList([0, 0, 0, 8, ...'free'.codeUnits])), isNull);
      expect(await _motion(goProMotionFile(_firstPayloads(), entry: 'fdsc', handlerName: 'GoPro SOS')), isNull);
      // A HERO5 to HERO7 writes ACCL and GYRO only
      expect(await _motion(goProMotionFile([goProPayload(), goProPayload()])), isNull);
      expect(await _motion(goProMotionFile([])), isNull);
    });

    test('gives null for a moov box longer than the most it reads', () async {
      final file = goProMotionFile(_firstPayloads(), moovPadding: 4096);
      expect(await _motion(file, maxMoovLength: 4096), isNull);
      expect(await _motion(file, maxMoovLength: 8192), isNotNull);
    });

    test('stops at the most payload bytes it reads, and says the track is cut', () async {
      final payloads = _firstPayloads();
      final track = (await _motion(goProMotionFile(payloads), maxPayloadLength: payloads.first.length + 10))!;
      expect(track.frameTimes.length, 4);
      expect(track.truncated, isTrue);
    });

    test('keeps the payloads before one past the end of the file, or read short', () async {
      final payloads = _firstPayloads();
      final file = goProMotionFile(payloads);
      // Each payload follows 64 bytes standing for its video frames, after ftyp and the header of mdat
      final secondEnd = mp4Ftyp.length + 8 + 64 + payloads[0].length + 64 + payloads[1].length;
      final cut = (await _motion(file, fileSize: secondEnd - 1))!;
      expect(cut.truncated, isTrue);
      expect(cut.frameTimes.length, 4);

      // A server that sends half of the second payload
      final read = _reader(file);
      final short = (await readGoProMotion((offset, length) async {
        final bytes = await read(offset, length);
        return length == payloads[1].length && offset > mp4Ftyp.length + 8 + 64 + payloads[0].length
            ? Uint8List.sublistView(bytes, 0, length ~/ 2)
            : bytes;
      }, file.length))!;
      expect(short.truncated, isTrue);
      expect(short.frameTimes.length, 4);
    });

    test('keeps the streams before a GPMF item whose length runs past its payload', () async {
      final good = goProPayload(cori: goProFirstCori.sublist(0, 4), grav: goProFirstGrav.sublist(0, 4));
      // The DEVC of the second payload says it is longer than it is: nothing of it is read
      final damaged = goProPayload(cori: goProFirstCori.sublist(4, 8), grav: goProFirstGrav.sublist(4, 8));
      damaged[6] = 0xff;
      damaged[7] = 0xff;
      // A stream whose CORI item says more entries than it has: the stream stops there
      final damagedItem = gpmfNest('DEVC', [
        gpmfString('DVNM', goProMaxName),
        gpmfNest('STRM', [
          gpmfScale([32767]),
          gpmfItem('CORI', 0x73, 8, List.filled(8, 0), repeat: 3),
        ]),
      ]);
      final track = (await _motion(goProMotionFile([good, damaged, damagedItem])))!;
      expect(track.frameTimes.length, 4);
      expect(track.frameOrientations![0], closeTo(goProFirstCoriExpected[0][0], 1e-7));
    });

    test('skips a CORI stream whose entries are not four values', () async {
      final odd = gpmfNest('DEVC', [
        gpmfNest('STRM', [
          gpmfScale([32767]),
          gpmfInt16Rows('CORI', goProFirstGrav.sublist(0, 2)),
        ]),
      ]);
      expect(await _motion(goProMotionFile([odd])), isNull);
    });
  });
}
