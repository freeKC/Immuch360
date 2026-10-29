import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/codec/exif_minimal.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';

import 'codec_fixtures.dart';

/// [exif] in a small JPEG, as package:image reads it: another reader than ours
img.ExifData readByPackageImage(Uint8List exif) {
  final jpeg = withSegments(img.encodeJpg(img.Image(width: 8, height: 8)), exif: exif);
  return img.decodeJpgExif(jpeg)!;
}

/// Degrees from the three rationals of a GPS coordinate
double degreesOf(img.IfdValue value) =>
    value.toRational(0).toDouble() + value.toRational(1).toDouble() / 60 + value.toRational(2).toDouble() / 3600;

void main() {
  const full = ImmersiveExif(
    dateTimeOriginal: '2026:10:27 10:12:00',
    offsetTimeOriginal: '+01:00',
    latitude: -33.8568,
    longitude: 151.2153,
    altitude: -12.25,
    software: 'Immuch360 Desktop 3.3.0',
  );

  group('the EXIF of a 3D photo', () {
    test('read by package:image: orientation 1, the date, its offset, the position and Software', () {
      final exif = readByPackageImage(minimalExif(full));
      expect(exif.imageIfd.orientation, 1);
      expect(exif.imageIfd.software, 'Immuch360 Desktop 3.3.0');
      expect(exif.exifIfd[0x9003].toString(), '2026:10:27 10:12:00');
      expect(exif.exifIfd[0x9011].toString(), '+01:00');
      expect(exif.gpsIfd.gpsLatitudeRef, 'S');
      expect(degreesOf(exif.gpsIfd[0x0002]!), closeTo(33.8568, 1e-7));
      expect(exif.gpsIfd.gpsLongitudeRef, 'E');
      expect(degreesOf(exif.gpsIfd[0x0004]!), closeTo(151.2153, 1e-7));
      expect(exif.gpsIfd[0x0005]!.toInt(), 1, reason: 'below sea level');
      expect(exif.gpsIfd[0x0006]!.toDouble(), 12.25);
    });

    test('no make, no model, no thumbnail', () {
      final bytes = minimalExif(full);
      final exif = readByPackageImage(bytes);
      expect(exif.imageIfd.hasMake, isFalse);
      expect(exif.imageIfd.hasModel, isFalse);
      expect(exif.directories.containsKey('ifd1'), isFalse);
      // IFD0 points to no next IFD
      final ifd0Entries = bytes[6 + 8] | bytes[6 + 9] << 8;
      final next = 6 + 8 + 2 + 12 * ifd0Entries;
      expect(bytes.sublist(next, next + 4), [0, 0, 0, 0]);
    });

    test('read back by our own reader', () {
      final kept = keptExif(minimalExif(full), software: 'again');
      expect(kept.dateTimeOriginal, full.dateTimeOriginal);
      expect(kept.offsetTimeOriginal, full.offsetTimeOriginal);
      expect(kept.latitude, closeTo(full.latitude!, 1e-7));
      expect(kept.longitude, closeTo(full.longitude!, 1e-7));
      expect(kept.altitude, closeTo(full.altitude!, 1e-9));
      expect(kept.software, 'again');
      expect(exifOrientation(minimalExif(full)), 1);
    });

    test('without a date or a position, only IFD0 with the orientation', () {
      final bytes = minimalExif(const ImmersiveExif());
      final exif = readByPackageImage(bytes);
      expect(exif.imageIfd.orientation, 1);
      expect(exif.imageIfd.hasSoftware, isFalse);
      expect(exif.gpsIfd.isEmpty, isTrue);
      expect(exif.exifIfd.isEmpty, isTrue);
      // "Exif\0\0", the TIFF header, one entry, no next IFD
      expect(bytes, hasLength(6 + 8 + 2 + 12 + 4));
    });

    test('a latitude without a longitude is no position', () {
      final exif = readByPackageImage(minimalExif(const ImmersiveExif(latitude: 45)));
      expect(exif.gpsIfd.isEmpty, isTrue);
    });

    test('text outside printable ASCII becomes "?"', () {
      final exif = readByPackageImage(minimalExif(const ImmersiveExif(software: 'Immuch360 Bêta\u0001')));
      expect(exif.imageIfd.software, 'Immuch360 B?ta?');
    });
  });

  group('the EXIF of an original', () {
    test('what a 3D photo keeps of a drone photo: the date, its offset and the position, south and west', () {
      final camera = codecExpected['exifCamera'] as Map<String, dynamic>;
      final exif = JpegHeader.read(codecFixture('exif_camera.jpg')).exif;
      final kept = keptExif(exif, software: 'Immuch360 Desktop 3.3.0');
      expect(kept.dateTimeOriginal, camera['dateTimeOriginal']);
      expect(kept.offsetTimeOriginal, camera['offsetTimeOriginal']);
      expect(kept.latitude, closeTo(camera['latitude'] as double, 1e-7));
      expect(kept.longitude, closeTo(camera['longitude'] as double, 1e-7));
      expect(kept.altitude, camera['altitude']);
      expect(kept.software, 'Immuch360 Desktop 3.3.0', reason: 'not the software of the drone');
      expect(exifOrientation(exif), camera['orientation']);

      final written = minimalExif(kept);
      for (final word in [camera['make'], camera['model'], camera['software']].cast<String>()) {
        expect(latin1.decode(written).contains(word), isFalse, reason: word);
      }
      // Written back south and west, as another reader and ours read it
      final reread = readByPackageImage(written);
      expect(reread.gpsIfd.gpsLatitudeRef, 'S');
      expect(reread.gpsIfd.gpsLongitudeRef, 'W');
      expect(keptExif(written, software: 'again').latitude, closeTo(camera['latitude'] as double, 1e-7));
      expect(keptExif(written, software: 'again').longitude, closeTo(camera['longitude'] as double, 1e-7));
    });

    test('the orientation of each fixture, 1 when absent or unreadable', () {
      for (var orientation = 1; orientation <= 8; orientation++) {
        final exif = JpegHeader.read(codecFixture('orientation_$orientation.jpg')).exif;
        expect(exifOrientation(exif), orientation);
      }
      expect(exifOrientation(null), 1);
      expect(exifOrientation(Uint8List.fromList(ascii.encode('Exif\u0000\u0000II*\u0000'))), 1);
      expect(exifOrientation(Uint8List.fromList(List.filled(40, 0xFF))), 1);
      expect(keptExif(null).dateTimeOriginal, isNull);
    });

    test('a big endian EXIF, as many cameras write it', () {
      // "Exif\0\0", "MM\0*", IFD0 at 8 with the orientation 8, no next IFD
      final exif = Uint8List.fromList([
        ...ascii.encode('Exif'), 0, 0, //
        0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8,
        0, 1,
        0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 8, 0, 0,
        0, 0, 0, 0,
      ]);
      expect(exifOrientation(exif), 8);
    });

    test('values that point past the end are left out, not the whole EXIF', () {
      // The GPS IFD comes last, its rationals at the very end: cut them off
      final exif = minimalExif(full);
      final kept = keptExif(Uint8List.sublistView(exif, 0, exif.length - 30));
      expect(kept.dateTimeOriginal, full.dateTimeOriginal);
      expect(kept.latitude, isNull);
      expect(kept.longitude, isNull);
    });
  });
}
