// The Rust codec of mobile/packages/immuch_sbs_codec through dart:ffi, as the AI job will call it: a pair written with
// its segments in the order of SbsCodec and read back by package:image and the XMP reader of the app, the ICC
// profile kept byte for byte, the subsampling and the quality written as asked, transparency laid on black, CMYK and
// RGB stored originals in their colours, a broken file refused with SbsCodecException, a copy that finds no memory
// refused as outOfMemory. The library is built by the package's build hook on Windows, Linux and macOS; elsewhere, or
// without Rust, these tests are skipped with the reason. IMMUCH360_SBS_MEASURE (a JPEG) adds the measure of the plan,
// a photo decoded and laid twice side by side, then encoded, with the time of each step printed.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// Pure Dart, already in the lock through maplibre_gl, as in lib/desktop/library/local_image_codec.dart
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/codec/native_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec_licenses.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immuch_sbs_codec/immuch_sbs_codec.dart' as native;

/// A smooth pair, the right eye moved by two pixels, opaque
SbsPicture pair(int eyeWidth, int height) {
  final width = eyeWidth * 2;
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final column = x < eyeWidth ? x : x - eyeWidth + 2;
      final at = (y * width + x) * 4;
      rgba[at] = (column * 255) ~/ eyeWidth;
      rgba[at + 1] = (y * 255) ~/ height;
      rgba[at + 2] = 96 + (column + y) % 64;
      rgba[at + 3] = 255;
    }
  }
  return SbsPicture(width: width, height: height, rgba: rgba);
}

/// An ICC profile of [length] bytes for RGB data: a header that says so, then a pattern
Uint8List rgbProfile(int length) {
  final data = Uint8List.fromList(List.generate(length, (i) => (i * 7) % 251));
  ByteData.sublistView(data).setUint32(0, length);
  data.setAll(16, ascii.encode('RGB '));
  data.setAll(36, ascii.encode('acsp'));
  return data;
}

/// The marker segments before the scan: (marker, payload without its length)
List<(int, Uint8List)> segmentsOf(Uint8List jpeg) {
  expect(jpeg.sublist(0, 2), [0xff, 0xd8]);
  final found = <(int, Uint8List)>[];
  var at = 2;
  while (at + 4 <= jpeg.length) {
    expect(jpeg[at], 0xff, reason: 'a marker at $at');
    final marker = jpeg[at + 1];
    final length = jpeg[at + 2] << 8 | jpeg[at + 3];
    found.add((marker, jpeg.sublist(at + 4, at + 2 + length)));
    if (marker == 0xda) {
      break;
    }
    at += 2 + length;
  }
  return found;
}

/// The mean of the differences of the colour channels of two RGBA lists
double meanError(Uint8List a, Uint8List b) {
  var sum = 0;
  for (var i = 0; i < a.length; i++) {
    if (i % 4 != 3) {
      sum += (a[i] - b[i]).abs();
    }
  }
  return sum / (a.length / 4 * 3);
}

/// An allocator with no memory left: it refuses as malloc does through package:ffi
class NoMemory implements Allocator {
  const NoMemory();

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) =>
      throw ArgumentError('Could not allocate $byteCount bytes.');

  @override
  void free(Pointer<NativeType> pointer) {}
}

/// The JPEGs of packages/immuch_sbs_codec/rust/fixtures (Pillow and libjpeg-turbo), eight 8 x 8 blocks of one colour
/// each, and the colour libjpeg-turbo shows for each block
const adobeFixtures = {
  'adobe_cmyk.jpg': [
    [255, 255, 255],
    [0, 255, 255],
    [255, 0, 255],
    [255, 255, 0],
    [0, 0, 0],
    [127, 127, 127],
    [191, 95, 0],
    [49, 190, 216],
  ],
  'adobe_rgb.jpg': [
    [255, 255, 255],
    [255, 0, 0],
    [0, 255, 0],
    [0, 0, 255],
    [0, 0, 0],
    [200, 100, 50],
    [30, 160, 220],
    [128, 128, 128],
  ],
};

StereoPhotoXmp sampleXmp() => StereoPhotoXmp.estimated(
  eyeWidth: 48,
  eyeHeight: 32,
  depthModelSha256: depthModelOnnxSha256,
  sourceName: 'salon é.jpg',
  sourceSize: 4182311,
  sourceSha1: 'qUqP5cyxm6YcTAhz05Hph5gvu9M=',
  sourceQuarterTurns: 0,
  created: '2026-10-27T10:12:00+01:00',
  creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
);

void main() {
  const codec = NativeSbsCodec();
  final Object skip = NativeSbsCodec.available
      ? false
      : 'native codec not built here: ${NativeSbsCodec.unavailableReason}';

  test('names itself native', () => expect(codec.name, 'native'));

  test('a pair with its EXIF, XMP and ICC, in that order, read back by package:image and the XMP reader', () {
    final picture = pair(48, 32);
    final exif = Uint8List.fromList([...ascii.encode('Exif'), 0, 0, ...ascii.encode('MM'), 0, 42, 0, 0, 0, 8, 0, 0]);
    final xmp = sampleXmp();
    final icc = rgbProfile(70000);
    final jpeg = codec.encodeSbs(picture, SbsEncodeOptions(quality: 92, exif: exif, xmp: xmp.toXml(), iccProfile: icc));

    final segments = segmentsOf(jpeg);
    expect(segments[0].$1, 0xe1);
    expect(segments[0].$2, exif);
    expect(segments[1].$1, 0xe1);
    expect(ascii.decode(segments[1].$2.sublist(0, 28)), 'http://ns.adobe.com/xap/1.0/');
    expect(segments[2].$1, 0xe2);
    expect(segments[3].$1, 0xe2);
    expect(segments.map((segment) => segment.$1), isNot(contains(0xe0)), reason: 'no JFIF segment');
    expect(jpeg.sublist(jpeg.length - 2), [0xff, 0xd9]);

    final image = img.decodeJpg(jpeg)!;
    expect((image.width, image.height), (96, 32));
    final read = StereoPhotoXmp.findIn(jpeg)!;
    expect(read.sourceName, 'salon é.jpg');
    expect(read.sourceSha1, xmp.sourceSha1);
    expect(read.derivativeId, xmp.derivativeId);

    final decoded = codec.decodeJpeg(jpeg);
    expect((decoded.width, decoded.height), (96, 32));
    expect(decoded.iccProfile, icc, reason: 'the profile copied byte for byte over two chunks');
    expect(meanError(decoded.rgba, picture.rgba), lessThan(2));
  }, skip: skip);

  test('an original written by package:image decoded as package:image decodes it, no colour conversion', () {
    final source = img.Image(width: 64, height: 40);
    for (var y = 0; y < 40; y++) {
      for (var x = 0; x < 64; x++) {
        source.setPixelRgb(x, y, x * 4, y * 6, 200 - x);
      }
    }
    final jpeg = img.encodeJpg(source, quality: 95);
    final reference = img.decodeJpg(jpeg)!.convert(numChannels: 4);
    final decoded = codec.decodeJpeg(jpeg);
    expect((decoded.width, decoded.height), (64, 40));
    expect(decoded.iccProfile, isNull);
    expect(meanError(decoded.rgba, reference.toUint8List()), lessThan(1.5));
  }, skip: skip);

  test('the subsampling and the quality written as asked', () {
    final picture = pair(40, 24);
    for (final (subsampling, luma) in [
      (ChromaSubsampling.s444, 0x11),
      (ChromaSubsampling.s422, 0x21),
      (ChromaSubsampling.s420, 0x22),
      (ChromaSubsampling.s440, 0x12),
      (ChromaSubsampling.s411, 0x41),
    ]) {
      final jpeg = codec.encodeSbs(picture, SbsEncodeOptions(quality: 90, subsampling: subsampling));
      final frame = segmentsOf(jpeg).firstWhere((segment) => segment.$1 == 0xc0).$2;
      expect(frame[7], luma, reason: '$subsampling');
      expect(codec.decodeJpeg(jpeg).width, 80);
    }
    // At quality 50 the IJG tables are those of Annex K: 16 first in the luminance table
    final jpeg = codec.encodeSbs(picture, const SbsEncodeOptions(quality: 50));
    final luma = segmentsOf(jpeg).firstWhere((segment) => segment.$1 == 0xdb && segment.$2[0] == 0).$2;
    expect(luma.sublist(1, 4), [16, 11, 12]);
  }, skip: skip);

  test('transparency laid on black', () {
    final rgba = Uint8List(16 * 16 * 4);
    for (var i = 0; i < rgba.length; i += 4) {
      rgba.setAll(i, [220, 220, 220, i < rgba.length ~/ 2 ? 0 : 255]);
    }
    final jpeg = codec.encodeSbs(SbsPicture(width: 16, height: 16, rgba: rgba), const SbsEncodeOptions(quality: 95));
    final decoded = codec.decodeJpeg(jpeg);
    expect(decoded.rgba[0], lessThan(8));
    expect(decoded.rgba[decoded.rgba.length - 4], greaterThan(210));
  }, skip: skip);

  test('CMYK of the Photoshop kind and RGB stored as is come out opaque, in their colours', () {
    for (final MapEntry(key: name, value: colours) in adobeFixtures.entries) {
      final decoded = codec.decodeJpeg(File('packages/immuch_sbs_codec/rust/fixtures/$name').readAsBytesSync());
      expect((decoded.width, decoded.height), (64, 8), reason: name);
      for (var at = 0; at < decoded.rgba.length; at += 4) {
        final x = (at ~/ 4) % decoded.width;
        expect(decoded.rgba[at + 3], 255, reason: '$name: alpha at pixel ${at ~/ 4}');
        for (var channel = 0; channel < 3; channel++) {
          expect(
            (decoded.rgba[at + channel] - colours[x ~/ 8][channel]).abs(),
            lessThanOrEqualTo(2),
            reason: '$name: channel $channel of pixel ${at ~/ 4}',
          );
        }
      }
      expect(decoded.iccProfile, isNull, reason: name);
    }
  }, skip: skip);

  test('a copy that finds no memory is refused as outOfMemory, not an ArgumentError', () {
    final picture = pair(8, 8);
    final jpeg = codec.encodeSbs(picture, const SbsEncodeOptions(quality: 90));
    final outOfMemory = throwsA(
      isA<native.NativeCodecException>().having((e) => e.status, 'status', native.NativeCodecStatus.outOfMemory),
    );
    expect(() => native.decodeJpeg(jpeg, allocator: const NoMemory()), outOfMemory);
    expect(
      () => native.encodeJpeg(
        picture.rgba,
        width: picture.width,
        height: picture.height,
        quality: 90,
        allocator: const NoMemory(),
      ),
      outOfMemory,
    );
  }, skip: skip);

  test('a broken file and a refused segment become SbsCodecException', () {
    expect(() => codec.decodeJpeg(Uint8List.fromList(utf8.encode('not a jpeg'))), throwsA(isA<SbsCodecException>()));
    expect(() => codec.decodeJpeg(Uint8List(0)), throwsA(isA<SbsCodecException>()));
    final exifWithoutSignature = Uint8List.fromList([0x4d, 0x4d, 0, 42]);
    expect(
      () => codec.encodeSbs(pair(8, 8), SbsEncodeOptions(quality: 90, exif: exifWithoutSignature)),
      throwsA(isA<SbsCodecException>().having((e) => e.message, 'message', startsWith('invalidArgument:'))),
    );
    expect(
      () => codec.encodeSbs(pair(8, 8), SbsEncodeOptions(quality: 90, xmp: 'x' * 70000)),
      throwsA(isA<SbsCodecException>().having((e) => e.message, 'message', startsWith('segmentTooLarge:'))),
    );
  }, skip: skip);

  test('every subsampling of the contract has its number in the C interface', () {
    for (final subsampling in ChromaSubsampling.values) {
      expect(nativeSubsampling(subsampling).name, subsampling.name);
    }
  });

  group('licence page', () {
    test('the texts of the library, with the IJG sentence', () async {
      final entries = await sbsCodecLicenseEntries().toList();
      expect(entries.single.packages, sbsCodecLicensePackages);
      final text = entries.single.paragraphs.map((paragraph) => paragraph.text).join('\n');
      expect(text, contains('This software is based in part on the work of the Independent JPEG Group.'));
      expect(text, contains('Volker Ströbel'));
      expect(text, contains('zune-image developers'));
      expect(text, contains('Thomas G. Lane, Guido Vollbeding'));
    }, skip: skip);

    test('the fallback, with the IJG sentence, when the library gives nothing or fails', () async {
      for (final texts in [() => null, () => throw StateError('no library')]) {
        final entries = await sbsCodecLicenseEntries(texts).toList();
        final text = entries.single.paragraphs.map((paragraph) => paragraph.text).join('\n');
        expect(text, contains('This software is based in part on the work of the Independent JPEG Group.'));
        expect(text, contains('mobile/packages/immuch_sbs_codec/licenses'));
      }
    });
  });

  final measure = Platform.environment['IMMUCH360_SBS_MEASURE'];
  test('measure: decode a photo, lay it twice side by side, encode the pair', () {
    final bytes = File(measure!).readAsBytesSync();
    final watch = Stopwatch()..start();
    final decoded = codec.decodeJpeg(bytes);
    final decodeTime = watch.elapsedMilliseconds;
    final width = decoded.width;
    final height = decoded.height;
    final rgba = Uint8List(width * 2 * height * 4);
    for (var y = 0; y < height; y++) {
      final row = decoded.rgba.sublist(y * width * 4, (y + 1) * width * 4);
      rgba.setAll(y * width * 8, row);
      rgba.setAll(y * width * 8 + width * 4, row);
    }
    final picture = SbsPicture(width: width * 2, height: height, rgba: rgba);
    stdout.writeln('$measure: $width x $height, decoded through dart:ffi in $decodeTime ms');
    for (final subsampling in [ChromaSubsampling.s420, ChromaSubsampling.s444]) {
      watch.reset();
      final jpeg = codec.encodeSbs(
        picture,
        SbsEncodeOptions(quality: 92, subsampling: subsampling, iccProfile: decoded.iccProfile),
      );
      stdout.writeln(
        'pair ${width * 2} x $height, ${(width * 2 * height / 1e6).toStringAsFixed(1)} Mpx, $subsampling, quality 92: '
        'encoded through dart:ffi in ${watch.elapsedMilliseconds} ms, ${(jpeg.length / 1e6).toStringAsFixed(1)} MB',
      );
    }
  }, skip: measure == null ? 'IMMUCH360_SBS_MEASURE names no photo' : skip);
}
