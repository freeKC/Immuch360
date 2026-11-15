// Stitches frames of the raw files of the 2026 camera lot (release 48) with the pure Dart math of the app, to look at
// them and to compare the two lens orders at the seam. IMMUCH_RAW48_DIR=/path/to/samples-48 (the files, see
// raw_2026_sample_test.dart), IMMUCH_RAW48_FRAMES=/path/to/frames (RGBA frames ffmpeg decoded from them:
// x2_00.rgba and x2_10.rgba 1024 x 1024 at 2 s, rs_00.rgba and rs_10.rgba at 10 s, osmo2_t0.rgba and osmo2_t1.rgba at
// 4 s, max2_t0.rgba and max2_t1.rgba 2976 x 960 at 10 s, x2_photo.rgba and rs_photo.rgba 2048 x 1024) and
// IMMUCH_STITCH_OUT=/a/directory for the PNG pictures. Skipped unless the three are set.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dji_osv.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_stitcher.dart';
import 'package:immich_mobile/domain/services/raw/gopro_eac.dart';
import 'package:immich_mobile/domain/services/raw/gopro_motion.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';
import 'package:immich_mobile/domain/services/raw/raw_sampler.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_plan.dart';
import 'package:immich_mobile/domain/services/raw/stabilization.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/providers/raw/dual_fisheye.provider.dart';

final _dir = Platform.environment['IMMUCH_RAW48_DIR'];
final _frames = Platform.environment['IMMUCH_RAW48_FRAMES'];
final _out = Platform.environment['IMMUCH_STITCH_OUT'];

const _width = 1024;
const _height = 512;

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

Future<({ByteRangeReader read, int size})> _open(String relative) async {
  final file = await File('$_dir/$relative').open();
  addTearDown(file.close);
  Future<Uint8List> read(int offset, int length) async {
    await file.setPosition(offset);
    return file.read(length);
  }

  return (read: read, size: await file.length());
}

RgbaTexture _texture(String name, int width, int height) =>
    (rgba: File('$_frames/$name').readAsBytesSync(), width: width, height: height);

void _write(String name, Uint8List rgba) {
  Directory(_out!).createSync(recursive: true);
  File('$_out/$name.png').writeAsBytesSync(encodeOpaquePng(rgba, _width, _height));
}

double _grey(RgbaTexture texture, double x, double y) {
  final colour = Float64List(3);
  addBilinearRgba(texture, x, y, 1, colour);
  return 0.299 * colour[0] + 0.587 * colour[1] + 0.114 * colour[2];
}

/// Mean absolute grey difference of the two lenses where both have weight, in levels of 255, and the pixels compared
({double difference, int pixels}) _seam(FisheyePairSampler sampler, List<RgbaTexture> textures) {
  final declared = sampler.textureSizes;
  var sum = 0.0;
  var pixels = 0;
  for (var j = 0; j < _height; j++) {
    for (var i = 0; i < _width; i++) {
      final (:lon, :lat) = equirectAngles(i, j, _width, _height);
      final lenses = sampler.sampleLenses(lon, lat);
      if (lenses.length != 2) {
        continue;
      }
      double grey(RawSample sample) {
        final texture = textures[sample.texture];
        final size = declared[sample.texture];
        return _grey(texture, sample.x * texture.width / size.width, sample.y * texture.height / size.height);
      }

      sum += (grey(lenses[0].sample) - grey(lenses[1].sample)).abs();
      pixels++;
    }
  }
  return (difference: pixels == 0 ? double.nan : sum / pixels, pixels: pixels);
}

/// Stitches a pair of whole lens textures both ways round and prints the seam of each order
void _pair(String label, DualFisheyeCalibration calibration, List<RgbaTexture> textures) {
  for (final order in const [
    [0, 1],
    [1, 0],
  ]) {
    final sampler = FisheyePairSampler(
      calibration,
      regions: FisheyePairSampler.wholeTextureRegions(order),
      textureSizes: [
        for (final _ in textures) (width: calibration.canvasSquare.round(), height: calibration.canvasSquare.round()),
      ],
    );
    final seam = _seam(sampler, textures);
    _print('$label, texture of lens $order: seam ${seam.difference.toStringAsFixed(2)} over ${seam.pixels} pixels');
    _write('${label}_${order.join()}', stitchRawRgba(textures, sampler, width: _width, height: _height));
  }
}

void _photo(String label, DualFisheyeCalibration calibration, RgbaTexture frame) {
  for (final (name, downBody) in [
    ('level', calibration.downBody),
    ('body', const [1.0, 0.0, 0.0]),
  ]) {
    final sampler = FisheyePairSampler(
      calibration.copyWith(downBody: downBody),
      regions: FisheyePairSampler.sideBySideRegions(),
      textureSizes: [(width: frame.width, height: frame.height)],
    );
    final seam = _seam(sampler, [frame]);
    _print('$label $name (down $downBody): seam ${seam.difference.toStringAsFixed(2)}');
    _write('${label}_$name', stitchRawRgba([frame], sampler, width: _width, height: _height));
  }
}

Future<DualFisheyeCalibration> _insta360Video(String relative) async {
  final file = await _open(relative);
  final trailer = (await readInsta360Trailer(file.read, file.size))!;
  final calibration = calibrationOf(trailer)!.copyWith(layoutHints: insta360LayoutHintsOf(trailer));
  return calibrationInVideoWindow(calibration);
}

void main() {
  final skip = _dir == null || _frames == null || _out == null ? 'Set IMMUCH_RAW48_DIR, _FRAMES and STITCH_OUT' : false;

  test('Insta360 ONE X2 and ONE RS 1-inch 360 split pairs and photos', () async {
    for (final (label, video, photo, prefix) in [
      ('x2', 'onex2/VID_20201031_094049_00_188.insv', 'onex2/IMG_20201026_154628_00_069.insp', 'x2'),
      ('rs', 'oners1inch/VID_20220625_140410_00_008.insv', 'oners1inch/IMG_20220701_170732_00_018.insp', 'rs'),
    ]) {
      final calibration = await _insta360Video(video);
      _print('$label video: window canvas ${calibration.canvasSquare}, down ${calibration.downBody}');
      final textures = [_texture('${prefix}_00.rgba', 1024, 1024), _texture('${prefix}_10.rgba', 1024, 1024)];
      _pair('${label}_video', calibration, textures);
      _pair('${label}_video_body', calibration.copyWith(downBody: const [1.0, 0.0, 0.0]), textures);

      final file = await _open(photo);
      final trailer = (await readInsta360Trailer(file.read, file.size))!;
      _photo('${label}_photo', calibrationOf(trailer)!, _texture('${prefix}_photo.rgba', 2048, 1024));
    }
  }, skip: skip);

  test('DJI Osmo 360 II', () async {
    final file = await _open('osmo360ii/CAM_20260822131942_0016_D_1.osv');
    final dji = await readDjiOsvCalibration(file.read);
    final calibration = dji?.calibration ?? nominalOsmo360();
    _print('Osmo 360 II: ${calibration.source.name} calibration of ${calibration.cameraModel}');
    final textures = [_texture('osmo2_t0.rgba', 1024, 1024), _texture('osmo2_t1.rgba', 1024, 1024)];
    _pair('osmo2', calibration, textures);
    // Lens 1 placed by its own yaw, pitch and roll rather than by the quaternions, and the nominal Osmo 360
    final [lens0, lens1] = calibration.lenses;
    final byAngles = DualFisheyeLens(
      cx: lens1.cx,
      cy: lens1.cy,
      yaw: lens1.yaw,
      pitch: lens1.pitch,
      roll: lens1.roll,
      fx: lens1.fx,
      fy: lens1.fy,
      k1: lens1.k1,
      k2: lens1.k2,
      k3: lens1.k3,
      k4: lens1.k4,
      k5: lens1.k5,
      viewToLens: (djiLensRotation(lens1.yaw, lens1.pitch, lens1.roll) * djiViewToWorld).values,
    );
    _pair('osmo2_angles', calibration.copyWith(lenses: [lens0, byAngles]), textures);
    _pair('osmo2_nominal', nominalOsmo360(), textures);
  }, skip: skip);

  test('GoPro MAX 2', () async {
    final file = await _open('max2/GS010007.360');
    final geometry = goProEacGeometryOf(await probeSphericalMetadata(file.read))!;
    final textures = [_texture('max2_t0.rgba', 2976, 960), _texture('max2_t1.rgba', 2976, 960)];
    _write('max2', stitchRawRgba(textures, GoProEacSampler(geometry), width: _width, height: _height));
  }, skip: skip);

  // Frame j turned back to frame i by CORI, for each candidate rotation M from the view of the stitch to the GPMF axes:
  // read frame j at M^T q_j q_i^-1 M v and compare with frame i at v. The candidate that the camera's own orientation
  // turns back best is the axes of the GPMF (m18_<frame>_t<track>.rgba, 2944 x 960, from GS010018.360).
  test('GoPro MAX 2 axes of the GPMF against the picture', () async {
    final file = await _open('max2/GS010018.360');
    final geometry = goProEacGeometryOf(await probeSphericalMetadata(file.read))!;
    final motion = (await readGoProMotion(file.read, file.size))!;
    final q = motion.frameOrientations!;
    Mat3 rotationOf(int frame) => quaternionMatrix(q[4 * frame], q[4 * frame + 1], q[4 * frame + 2], q[4 * frame + 3])!;
    final camera = Mat3(goProViewToCamera(geometry));
    final candidates = <String, Mat3>{
      'identity': Mat3.identity,
      'half turn about y': rotationY(math.pi),
      'quarter turn about y': rotationY(math.pi / 2),
      'three quarters about y': rotationY(-math.pi / 2),
      'MAX matrix': goProViewToGpmf,
    };
    const frames = [60, 84, 108, 132, 156, 180, 290, 310, 330, 350];
    List<RgbaTexture> texturesOf(int frame) => [
      _texture('m18_${frame}_t0.rgba', 2944, 960),
      _texture('m18_${frame}_t1.rgba', 2944, 960),
    ];
    Float64List grey(Uint8List rgba) {
      final out = Float64List(rgba.length ~/ 4);
      for (var i = 0; i < out.length; i++) {
        out[i] = 0.299 * rgba[4 * i] + 0.587 * rgba[4 * i + 1] + 0.114 * rgba[4 * i + 2];
      }
      return out;
    }

    const width = 512;
    const height = 256;
    final totals = {for (final name in candidates.keys) name: 0.0};
    var unturned = 0.0;
    for (var k = 0; k + 1 < frames.length; k++) {
      final i = frames[k];
      final j = frames[k + 1];
      if (j - i > 30) {
        continue;
      }
      final reference = grey(stitchRawRgba(texturesOf(i), GoProEacSampler(geometry), width: width, height: height));
      final moved = texturesOf(j);
      final relative = rotationOf(j) * rotationOf(i).transposed;
      double difference(Mat3 viewToCamera) {
        final picture = grey(
          stitchRawRgba(
            moved,
            GoProEacSampler(geometry, viewToCamera: viewToCamera.values),
            width: width,
            height: height,
          ),
        );
        // Above the horizon only: the car the camera rides on fills the lower half and turns with it
        var sum = 0.0;
        var count = 0;
        for (var row = height * 25 ~/ 180; row < height * 88 ~/ 180; row++) {
          for (var p = row * width; p < (row + 1) * width; p++) {
            sum += (picture[p] - reference[p]).abs();
            count++;
          }
        }
        return sum / count;
      }

      final still = difference(camera);
      unturned += still;
      final line = StringBuffer('frames $i to $j: unturned ${still.toStringAsFixed(2)}');
      final trace = relative.values[0] + relative.values[4] + relative.values[8];
      line.write(' (turn ${(math.acos(((trace - 1) / 2).clamp(-1.0, 1.0)) * 180 / math.pi).toStringAsFixed(1)} deg)');
      for (final MapEntry(key: name, value: m) in candidates.entries) {
        for (final (suffix, turn) in [('', relative), (' inverse', relative.transposed)]) {
          final value = difference(camera * m.transposed * turn * m);
          totals['$name$suffix'] = (totals['$name$suffix'] ?? 0) + value;
          line.write(', $name$suffix ${value.toStringAsFixed(2)}');
        }
      }
      _print(line.toString());
    }
    for (final frame in frames) {
      _write('m18_$frame', stitchRawRgba(texturesOf(frame), GoProEacSampler(geometry), width: _width, height: _height));
    }
    _print('totals: unturned ${unturned.toStringAsFixed(2)}, $totals');
  }, skip: skip);
}
