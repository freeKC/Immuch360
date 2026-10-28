// The field of view of the photo a 360° panorama is generated around (lot P3, design-final 2026-10-27, section 4.3,
// point 2): from the focal length equivalent to 35 mm of its EXIF (the diagonal of 43.27 mm, then the width and the
// height of its frame), else from MoGe-2 (the focal length recover_focal_shift finds), else the 65° M3 guessed; the
// horizon level. fovGuessed when the EXIF does not tell.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/panorama/erp_projection.dart';
import 'package:immich_mobile/desktop/ai/panorama/photo_fov.dart';

import '../fakes/fake_backends.dart';

double _degrees(double radians) => radians * 180 / math.pi;

void main() {
  test('a focal length of 36 mm equivalent on a 3:2 photo: the frame of 36 x 24 mm, 53.13° x 36.87°', () {
    final fov = photoFovOfExif(6000, 4000, 36)!;
    final width = 43.27 * 3 / math.sqrt(13);
    final height = 43.27 * 2 / math.sqrt(13);
    expect(fov.hfov, closeTo(_degrees(2 * math.atan(width / 2 / 36)), 1e-9));
    expect(fov.vfov, closeTo(_degrees(2 * math.atan(height / 2 / 36)), 1e-9));
    expect(fov.hfov, closeTo(53.13, 0.01));
    expect(fov.source, PhotoFovSource.exif);
    expect(fov.guessed, isFalse);
  });

  test('a portrait photo takes the width of its own frame', () {
    final fov = photoFovOfExif(3000, 4000, 26)!;
    expect(fov.hfov, lessThan(fov.vfov));
    expect(fov.vfov, closeTo(verticalFieldOfView(fov.hfov, 3000, 4000), 1e-9));
  });

  test('no focal length, or none that means anything: the EXIF does not tell', () {
    expect(photoFovOfExif(4000, 3000, null), isNull);
    expect(photoFovOfExif(4000, 3000, 0), isNull);
    expect(photoFovOfExif(4000, 3000, -5), isNull);
  });

  test('the focal length of MoGe-2, relative to the half diagonal: guessed', () {
    // 4:3, the view plane spans 0.8 across: a focal length of 1 sees 2 * atan(0.8) across
    final fov = photoFovOfModel(4000, 3000, 1.0);
    expect(fov.hfov, closeTo(_degrees(2 * math.atan(0.8)), 1e-9));
    expect(fov.vfov, closeTo(_degrees(2 * math.atan(0.6)), 1e-9));
    expect(fov.source, PhotoFovSource.model);
    expect(fov.guessed, isTrue);
  });

  test('neither: 65° across, guessed, as M3 did', () {
    final fov = photoFovGuess(4000, 3000);
    expect(fov.hfov, 65);
    expect(fov.vfov, closeTo(verticalFieldOfView(65, 4000, 3000), 1e-9));
    expect(fov.source, PhotoFovSource.guess);
    expect(fov.guessed, isTrue);
  });

  test('a field of view beyond what a pinhole can show is kept within 5° and 150°', () {
    expect(photoFovOfExif(6000, 4000, 1)!.hfov, 150);
    expect(photoFovOfExif(6000, 4000, 5000)!.hfov, 5);
    expect(photoFovOfModel(4000, 3000, 0.01).hfov, 150);
  });

  test('MoGe-2 run on the photo reduced to its input finds the focal length its points were made with', () {
    final photo = SbsDecoded(width: 1600, height: 1200, rgba: Uint8List(4 * 1600 * 1200));
    final geometry = FakeGeometryBackend(shape: FakeGeometryShape.floor, focal: 1.25);
    final focal = modelFocalOf(photo, geometry);
    expect(focal, closeTo(1.25, 1e-3));
    expect(geometry.calls, 1);
    final fov = photoFovOfModel(photo.width, photo.height, focal);
    expect(fov.hfov, closeTo(_degrees(2 * math.atan(0.8 / 1.25)), 0.1));
  });
}
