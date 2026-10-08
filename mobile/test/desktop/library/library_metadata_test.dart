import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_metadata.dart';
import 'package:path/path.dart' as p;

import 'library_fixtures.dart';

MediaMetadata _image(Uint8List bytes) => readMediaMetadata(BytesSource(bytes), LibraryMediaKind.image);

MediaMetadata _video(Uint8List bytes) => readMediaMetadata(BytesSource(bytes), LibraryMediaKind.video);

void main() {
  group('JPEG', () {
    test('date taken with its offset, orientation, GPS and the frame size', () {
      final tiff = tiffBytes(
        ifd0: const [
          (0x0112, 3, [6]),
          (0x0132, 2, '2020:01:01 00:00:00'),
        ],
        exif: const [(0x9003, 2, '2024:07:14 18:30:05'), (0x9011, 2, '+02:00')],
        gps: [(1, 2, 'N'), (2, 5, gpsDegrees(48.8584)), (3, 2, 'W'), (4, 5, gpsDegrees(2.2945))],
      );
      final metadata = _image(jpegBytes(width: 4000, height: 3000, tiff: tiff));

      expect(metadata.takenAt, DateTime.utc(2024, 7, 14, 16, 30, 5));
      expect(metadata.orientation, 6);
      expect((metadata.width, metadata.height), (4000, 3000));
      // Turned by a quarter: shown in portrait, as the Android gallery gives it
      expect((metadata.displayWidth, metadata.displayHeight), (3000, 4000));
      expect(metadata.latitude, closeTo(48.8584, 1e-4));
      expect(metadata.longitude, closeTo(-2.2945, 1e-4));
      expect(metadata.projection, isNull);
    });

    test('a date without an offset is the local time of this computer, little endian EXIF too', () {
      final tiff = tiffBytes(littleEndian: true, exif: const [(0x9003, 2, '2023:12:31 23:59:58')]);
      final metadata = _image(jpegBytes(width: 10, height: 20, tiff: tiff));

      expect(metadata.takenAt, DateTime(2023, 12, 31, 23, 59, 58).toUtc());
      expect(metadata.orientation, 0);
    });

    test('the GPano projection of the XMP: a 360° photo', () {
      final metadata = _image(jpegBytes(width: 5760, height: 2880, gpanoProjection: 'equirectangular'));

      expect(metadata.projection, 'equirectangular');
      expect((metadata.displayWidth, metadata.displayHeight), (5760, 2880));
      expect(metadata.takenAt, isNull);
    });

    test('blank or impossible dates are left out', () {
      expect(exifDateToUtc('0000:00:00 00:00:00', null), isNull);
      expect(exifDateToUtc('    :  :     :  :  ', null), isNull);
      expect(exifDateToUtc(null, null), isNull);
      expect(exifDateToUtc('2024:02:03 04:05:06', '-05:30'), DateTime.utc(2024, 2, 3, 9, 35, 6));
    });

    test('a cut or damaged file gives what it holds, without throwing', () {
      final whole = jpegBytes(
        width: 100,
        height: 50,
        tiff: tiffBytes(exif: const [(0x9003, 2, '2024:01:02 03:04:05')]),
      );
      for (var length = 0; length < whole.length; length += 7) {
        expect(() => _image(Uint8List.sublistView(whole, 0, length)), returnsNormally, reason: 'cut at $length');
      }
      final damaged = Uint8List.fromList(whole)..fillRange(30, 60, 0xff);
      expect(() => _image(damaged), returnsNormally);
    });
  });

  group('other images', () {
    test('PNG, animated or not', () {
      expect(
        (_image(pngBytes(width: 640, height: 480)).width, _image(pngBytes(width: 640, height: 480)).height),
        (640, 480),
      );
      expect(_image(pngBytes(width: 1, height: 1)).animated, isFalse);
      expect(_image(pngBytes(width: 1, height: 1, animated: true)).animated, isTrue);
    });

    test('WebP and GIF', () {
      final webp = _image(webpBytes(width: 1920, height: 1080, animated: true));
      expect((webp.width, webp.height, webp.animated), (1920, 1080, true));
      final gif = _image(gifBytes(width: 320, height: 240));
      expect((gif.width, gif.height, gif.animated), (320, 240, true));
    });

    test('HEIF: the size of the primary item, its rotation and the date of its Exif item', () {
      final tiff = tiffBytes(exif: const [(0x9003, 2, '2025:05:06 07:08:09'), (0x9011, 2, '+00:00')]);
      final metadata = _image(heifBytes(width: 4032, height: 3024, quarterTurns: 3, tiff: tiff));

      expect((metadata.width, metadata.height), (4032, 3024));
      // Three quarters anticlockwise: a quarter clockwise, EXIF 6
      expect(metadata.orientation, 6);
      expect((metadata.displayWidth, metadata.displayHeight), (3024, 4032));
      expect(metadata.takenAt, DateTime.utc(2025, 5, 6, 7, 8, 9));
    });

    test('a TIFF based raw file: its EXIF', () {
      final tiff = tiffBytes(
        littleEndian: true,
        ifd0: const [
          (0x0100, 4, [6000]),
          (0x0101, 4, [4000]),
          (0x0112, 3, [1]),
        ],
        exif: const [(0x9003, 2, '2022:08:09 10:11:12'), (0x9011, 2, '+01:00')],
      );
      final metadata = _image(tiff);

      expect((metadata.width, metadata.height), (6000, 4000));
      expect(metadata.takenAt, DateTime.utc(2022, 8, 9, 9, 11, 12));
    });

    test('a file of no known format gives nothing', () {
      expect(_image(Uint8List.fromList(List.filled(64, 7))).width, isNull);
      expect(_image(Uint8List(0)).width, isNull);
    });
  });

  group('videos', () {
    test('duration, size and creation date from the movie box at the end of the file', () {
      final created = DateTime.utc(2024, 9, 1, 12, 0, 0);
      final metadata = _video(mp4Bytes(width: 5760, height: 2880, durationMs: 61500, created: created));

      expect(metadata.durationMs, 61500);
      expect((metadata.displayWidth, metadata.displayHeight), (5760, 2880));
      expect(metadata.takenAt, created);
    });

    test('a video turned by a quarter is shown in portrait; the movie box may come first', () {
      final metadata = _video(mp4Bytes(width: 1920, height: 1080, durationMs: 1000, rotation: 90, moovAtEnd: false));

      expect(metadata.orientation, 6);
      expect((metadata.displayWidth, metadata.displayHeight), (1080, 1920));
      // No clock set: no date
      expect(metadata.takenAt, isNull);
    });

    test('a video that is not an ISO media file gives nothing', () {
      expect(_video(Uint8List.fromList([0x1a, 0x45, 0xdf, 0xa3, ...List.filled(60, 0)])).durationMs, 0);
    });
  });

  test('a file that cannot be read says so, so that the scanner reads it again; a damaged one was read', () {
    final dir = Directory.systemTemp.createTempSync('library_metadata_test_');
    addTearDown(() => dir.deleteSync(recursive: true));

    expect(readMediaMetadataSync(p.join(dir.path, 'gone.jpg'), LibraryMediaKind.image).readFailed, isTrue);
    final damaged = File(p.join(dir.path, 'damaged.jpg'))..writeAsBytesSync(List.filled(64, 7));
    final read = readMediaMetadataSync(damaged.path, LibraryMediaKind.image);
    expect((read.readFailed, read.width), (false, null));
  });
}
