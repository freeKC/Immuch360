// Reads the trailer and the EXIF head of a real Insta360 photo or video of the development machine and prints what it
// gives: IMMUCH_INSTA_SAMPLE=/path/to/IMG_..._00_001.insp. The file is only read, in place.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

final _sample = Platform.environment['IMMUCH_INSTA_SAMPLE'];

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

void main() {
  test('reads the calibration of a real Insta360 file', () async {
    final path = _sample!;
    final file = await File(path).open();
    addTearDown(file.close);
    final fileSize = await file.length();
    var reads = 0;
    var bytesRead = 0;
    Future<Uint8List> read(int offset, int length) async {
      reads++;
      await file.setPosition(offset);
      final bytes = await file.read(length);
      bytesRead += bytes.length;
      return bytes;
    }

    final ByteRangeReader reader = read;
    final trailer = await readInsta360Trailer(reader, fileSize);
    _print('$path: $fileSize bytes; the trailer took $reads reads, $bytesRead bytes');
    _print('$trailer');
    expect(trailer, isNotNull, reason: 'no Insta360 trailer');

    final head = path.toLowerCase().endsWith('.insp') ? await readInsta360PhotoHead(reader) : null;
    _print('EXIF head: $head');
    // The calibrations kept by camera model are found by the model of the EXIF of a photo without trailer
    if (head?.cameraModel != null) {
      expect(head!.cameraModel, trailer!.cameraModel, reason: 'the EXIF and the trailer name the model alike');
    }

    final calibration = calibrationOf(trailer!, accelerometer: head?.imu?.accelerometer);
    expect(calibration, isNotNull, reason: 'no calibration string');
    _print(const JsonEncoder.withIndent('  ').convert(calibration!.toJson()));

    // Field 19 is one lens's square for a video recorded as a split pair: a side by side frame is two squares
    final frameHeight = trailer.imageHeight ?? calibration.canvasSquare.round();
    final frameWidth = 2 * frameHeight;
    _print('rawProjection: ${calibration.toNativeJson(frameWidth: frameWidth, frameHeight: frameHeight)}');

    expect(calibration.lenses, hasLength(2));
    expect(calibration.source, DualFisheyeSource.file);
    for (var i = 0; i < 2; i++) {
      final lens = calibration.lenses[i];
      expect(lens.cx, inInclusiveRange(i * calibration.canvasSquare, (i + 1) * calibration.canvasSquare));
      expect(lens.cy, inInclusiveRange(0, calibration.canvasSquare));
    }
    // Upright, gravity follows body +x
    final tilt = math.acos(calibration.downBody[0].clamp(-1.0, 1.0)) * 180 / math.pi;
    _print('gravity in the body frame: ${calibration.downBody}, the camera leaning ${tilt.toStringAsFixed(2)} degrees');
    _print('the centre of the view reads ${samplePixel(calibration, frameWidth, frameHeight, 0, 0)}');
  }, skip: _sample == null ? 'Set IMMUCH_INSTA_SAMPLE to the path of an Insta360 .insp or .insv file' : false);
}
