// Reads the raw files of the 2026 camera lot (release 48) from a folder of the development machine and prints what the
// readers give, model by model: IMMUCH_RAW48_DIR=/path/to/samples-48. Each file is only read, in place, and its test
// skipped when it is missing. The files are public samples kept for personal testing (never in a repository):
//   osmo360ii/CAM_20260822131942_0016_D_1.osv  DJI Osmo 360 II, Bennetts BikeSocial review
//   max2/GS010007.360                          GoPro MAX 2, Hugh Hou's comparison folder (GS010018.360 and
//                                              GS010020-trimmed.360, from the Mapillary forum, measured its axes)
//   onex2/VID_20201031_094049_00_188.insv, _10_188.insv, IMG_20201026_154628_00_069.insp  Insta360 ONE X2, 360rumors
//   oners1inch/VID_20220625_140410_00_008.insv, _10_008.insv, LRV_..._11_008.insv, IMG_20220701_170732_00_018.insp
//                                              Insta360 ONE RS 1-inch 360, 360rumors
// The values checked are those read on these files on 14 November 2026 (lots/feat-raw-2026-48.md): what the readers
// must give for the fixes of the lot to hold on real files (the axes themselves were measured against the pictures by
// the lot's scripts, the stitches looked at with raw_2026_stitch_sample_test.dart).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/camera_motion.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dji_motion.dart';
import 'package:immich_mobile/domain/services/raw/dji_osv.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/gopro_eac.dart';
import 'package:immich_mobile/domain/services/raw/gopro_motion.dart';
import 'package:immich_mobile/domain/services/raw/insta360_motion.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/raw/stabilization.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

final _dir = Platform.environment['IMMUCH_RAW48_DIR'];

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

String? _path(String relative) {
  final dir = _dir;
  if (dir == null) {
    return null;
  }
  final path = '$dir/$relative';
  return File(path).existsSync() ? path : null;
}

Future<({ByteRangeReader read, int size})> _open(String path) async {
  final file = await File(path).open();
  addTearDown(file.close);
  Future<Uint8List> read(int offset, int length) async {
    await file.setPosition(offset);
    return file.read(length);
  }

  return (read: read, size: await file.length());
}

String _tracks(SphericalProbe probe) => [
  for (final track in probe.tracks)
    '${track.trackId} ${track.handlerType} "${track.handlerName}" ${track.codec} ${track.codecs} '
            '${track.codedWidth}x${track.codedHeight} ${track.frameRate?.toStringAsFixed(3)}'
        .trim(),
].join('\n  ');

String _motion(CameraMotionTrack? track) {
  if (track == null) {
    return 'no motion track';
  }
  final frames = track.frameTimes;
  return '${track.source.name} ${track.cameraModel} ${track.firmware}: ${track.samples.times.length} samples '
      '(${track.sampleRate?.toStringAsFixed(1)} Hz), ${frames.length} frames '
      '${frames.isEmpty ? '' : '${frames.first.toStringAsFixed(4)} to ${frames.last.toStringAsFixed(4)} s'}, '
      'orientations ${track.frameOrientations?.length}, gravity ${track.frameGravity?.length}, '
      'rolling shutter ${track.rollingShutterMs}, truncated ${track.truncated}';
}

String _lenses(DualFisheyeCalibration calibration) => [
  for (final lens in calibration.lenses)
    'cx ${lens.cx.toStringAsFixed(2)} cy ${lens.cy.toStringAsFixed(2)} fx ${lens.fx?.toStringAsFixed(2)} '
            'xi ${lens.xi} radius ${lens.radius} yaw ${lens.yaw.toStringAsFixed(3)} '
            'pitch ${lens.pitch.toStringAsFixed(3)} roll ${lens.roll.toStringAsFixed(3)}'
        .trim(),
].join('\n  ');

typedef _Insta360Read = ({
  String name,
  Insta360Trailer? trailer,
  DualFisheyeCalibration? calibration,
  CameraMotionTrack? motion,
});

Future<_Insta360Read> _insta360(String path) async {
  final file = await _open(path);
  final name = path.split('/').last;
  _print(
    '== $name (${file.size} bytes): kind ${rawMediaKindOfName(name, isVideo: !name.endsWith('.insp'))}, '
    'split pair ${splitPairOf(name)}',
  );
  final trailer = await readInsta360Trailer(file.read, file.size);
  _print('trailer: $trailer');
  DualFisheyeCalibration? calibration;
  CameraMotionTrack? motion;
  if (trailer != null) {
    calibration = calibrationOf(trailer);
    _print(
      'calibration ${calibration?.model.name}, canvas ${calibration?.canvasSquare}, down ${calibration?.downBody}'
      '\n  ${calibration == null ? '' : _lenses(calibration)}',
    );
    _print(
      'V1 ${trailer.offsetV1 == null ? null : parseInsta360OffsetV1(trailer.offsetV1!)?.model.name}, '
      'V3 ${trailer.offsetV3 == null ? null : parseInsta360OffsetV3(trailer.offsetV3!)?.model.name}, '
      'V6 ${trailer.offsetV6 == null ? null : parseInsta360OffsetV6(trailer.offsetV6!)?.model.name}',
    );
    _print('track order ${insta360TrackOrder(trailer)}');
  }
  if (!name.endsWith('.insp')) {
    final probe = await probeSphericalMetadata(file.read);
    _print('tracks:\n  ${_tracks(probe)}');
    motion = await readInsta360Motion(file.read, file.size);
    _print('motion: ${_motion(motion)}');
    if (motion != null && motion.samples.times.isNotEmpty) {
      final times = motion.samples.times;
      final rates = motion.samples.rotationRates;
      final accelerations = motion.samples.accelerations;
      _print(
        'first samples at ${times.take(3).toList()}, first frame at ${motion.frameTimes.firstOrNull}, '
        'rate ${rates.take(3).toList()}, acceleration ${accelerations.take(3).toList()}',
      );
    }
  }
  return (name: name, trailer: trailer, calibration: calibration, motion: motion);
}

// Upright: gravity along body +y within [degrees], the down of the view of dual_fisheye_math.dart
Matcher _alongPlusY(double degrees) => predicate<List<double>>(
  (down) => down[1] >= math.cos(degrees * math.pi / 180),
  'gravity along body +y within $degrees degrees',
);

void main() {
  test('DJI Osmo 360 II', () async {
    final path = _path('osmo360ii/CAM_20260822131942_0016_D_1.osv')!;
    final file = await _open(path);
    _print('top level boxes: ${await listTopLevelBoxes(file.read)}');
    final probe = await probeSphericalMetadata(file.read);
    _print('tracks:\n  ${_tracks(probe)}');
    final dji = await readDjiOsvCalibration(file.read);
    _print('camd: $dji');
    if (dji != null) {
      _print('calibration ${dji.calibration.source.name}\n  ${_lenses(dji.calibration)}');
      _print('view to lens: ${[for (final lens in dji.calibration.lenses) lens.viewToLens]}');
    }
    final motion = await readDjiMotion(file.read, file.size);
    _print('motion: ${_motion(motion)}');
    final table = motion == null ? null : stabilizationOfCameraMotion(motion);
    _print('stabilisation: $table');

    // The camd track found, the calibration of the file with both lenses placed by their quaternions
    expect(dji, isNotNull, reason: 'the camd content, a track sample on the Osmo 360 II');
    expect((dji!.model, dji.firmware, dji.schema), ('Osmo 360 II', '01.01.02.10', 'dvtm_OQ102.proto'));
    expect(dji.calibration.source, DualFisheyeSource.file);
    expect(dji.calibration.lenses, hasLength(2));
    expect(dji.calibration.lenses[0].fx, closeTo(1053.16, 0.01));
    expect(dji.calibration.lenses.every((lens) => lens.viewToLens != null), isTrue, reason: 'both quaternions read');
    // The attitude, 25 fps from 2-1-5, a frame quaternion and a table for each of the 258 frames
    expect((motion!.cameraModel, motion.frameTimes.length), ('Osmo 360 II', 258));
    expect(motion.frameTimes.last, closeTo(10.28, 1e-6));
    expect(motion.frameOrientations, hasLength(4 * 258));
    expect(table!.length, 258);
    // The orientations at a few delays, for the check against the picture (raw-2026/dji_vision48.py)
    final dump = Platform.environment['IMMUCH_RAW48_DUMP'];
    if (dump != null) {
      final delays = <String, Object>{};
      for (final delay in const [-10000.0, 0.0, 4000.0, 6000.0, 8500.0, 10000.0, 12000.0, 16000.0, 20000.0]) {
        final track = (await readDjiMotion(file.read, file.size, attitudeDelayUs: delay))!;
        delays['$delay'] = {'times': track.frameTimes, 'orientations': track.frameOrientations};
      }
      File(dump).writeAsStringSync(jsonEncode(delays));
    }
  }, skip: _path('osmo360ii/CAM_20260822131942_0016_D_1.osv') == null ? 'no Osmo 360 II sample' : false);

  test('GoPro MAX 2', () async {
    final path = _path('max2/GS010007.360')!;
    final file = await _open(path);
    final probe = await probeSphericalMetadata(file.read);
    _print('tracks:\n  ${_tracks(probe)}');
    final geometry = goProEacGeometryOf(probe);
    _print('geometry: $geometry, camera ${geometry == null ? null : goProCameraName(geometry)}');
    final motion = await readGoProMotion(file.read, file.size);
    _print('motion: ${_motion(motion)}');
    _print('axes measured: ${goProAxesMeasured(motion?.cameraModel)}');
    final table = await readGoProStabilization(file.read, file.size, face: geometry?.face);
    _print('stabilisation: $table');

    expect(geometry?.face, goProMax2Face);
    expect((motion!.cameraModel, motion.firmware, motion.frameTimes.length), ('MAX2', 'H24.02.01.09.71', 2749));
    expect(goProViewToGpmfOf(motion.cameraModel, face: geometry!.face)!.values, Mat3.identity.values);
    // On its tripod, GRAV along GPMF +y, the down of the view, which these axes take as the same
    final gravities = motion.frameGravity!;
    expect(gravities[1], greaterThan(0.999));
    expect(table, isNotNull, reason: 'the MAX 2 gets its table');
    expect(table!.length, 2749);
    final orientations = motion.frameOrientations!;
    for (final frame in [0, 1, motion.frameTimes.length ~/ 2, motion.frameTimes.length - 1]) {
      _print(
        'frame $frame at ${motion.frameTimes[frame].toStringAsFixed(4)} s: CORI '
        '${orientations.sublist(4 * frame, 4 * frame + 4)}, GRAV ${gravities.sublist(3 * frame, 3 * frame + 3)}, '
        'SHUT ${motion.frameExposures.length > frame ? motion.frameExposures[frame] : null}',
      );
    }
  }, skip: _path('max2/GS010007.360') == null ? 'no GoPro MAX 2 sample' : false);

  for (final (camera, files, check) in <(String, List<String>, void Function(List<_Insta360Read>))>[
    (
      'Insta360 ONE X2',
      [
        'onex2/VID_20201031_094049_00_188.insv',
        'onex2/VID_20201031_094049_10_188.insv',
        'onex2/IMG_20201026_154628_00_069.insp',
      ],
      (reads) {
        final [video, second, photo] = reads;
        expect(video.trailer!.cameraModel, 'Insta360 ONE X2');
        expect(video.trailer!.isRawGyro, isFalse);
        expect(insta360ImuAxesOf(video.trailer!.cameraModel), Insta360ImuAxes.xSeries);
        // The frame record and field 24 in milliseconds: 139 frames over 4.6 s, not squeezed into 5 ms
        final motion = video.motion!;
        expect(motion.frameTimes.length, 139);
        expect(motion.frameTimes.first, closeTo(0.011, 1e-9));
        expect(motion.frameTimes.last, closeTo(4.615, 1e-9));
        expect(motion.sampleRate, closeTo(500, 1));
        expect(second.trailer, isNull, reason: 'lens 1 of the pair carries no trailer');
        expect(photo.calibration?.model, DualFisheyeModel.mei);
      },
    ),
    (
      'Insta360 ONE RS 1-inch 360',
      [
        'oners1inch/VID_20220625_140410_00_008.insv',
        'oners1inch/VID_20220625_140410_10_008.insv',
        'oners1inch/LRV_20220625_140410_11_008.insv',
        'oners1inch/IMG_20220701_170732_00_018.insp',
      ],
      (reads) {
        final [video, second, lrv, photo] = reads;
        expect(video.trailer!.cameraModel, 'Insta360 OneRS');
        expect(insta360ImuAxesOf(video.trailer!.cameraModel), Insta360ImuAxes.oneRs360);
        // Upright and level with the axes of the ONE RS 360 (on their side with those of the X series)
        expect(video.calibration!.downBody, _alongPlusY(3));
        expect(lrv.calibration!.downBody, _alongPlusY(3));
        expect(photo.calibration!.downBody, _alongPlusY(2));
        final motion = video.motion!;
        expect(motion.frameTimes.length, 1141);
        expect(motion.frameTimes.last, closeTo(47.5, 1e-6));
        expect(motion.sampleRate, closeTo(986, 1));
        // At rest the accelerometer, in the body frame, points up: along body -y
        expect(motion.samples.accelerations[1], lessThan(-0.9));
        expect(second.trailer, isNull, reason: 'lens 1 of the pair carries no trailer');
      },
    ),
  ]) {
    test(camera, () async {
      final reads = <_Insta360Read>[];
      for (final relative in files) {
        final path = _path(relative);
        expect(path, isNotNull, reason: '$relative, next to ${files.first}');
        reads.add(await _insta360(path!));
      }
      check(reads);
    }, skip: _path(files.first) == null ? 'no $camera sample' : false);
  }
}
