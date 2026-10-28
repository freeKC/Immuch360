// The checks of a generated image (lot P2): grey, pure green left outside the photo of the control frame, size; and the
// size of a PNG read from its header.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/gen/image_checks.dart';
import 'package:path/path.dart' as p;

void main() {
  img.Image gradient(int width, int height, {int channels = 3}) {
    final image = img.Image(width: width, height: height, numChannels: channels);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        image.setPixelRgba(x, y, (x * 255) ~/ width, (y * 255) ~/ height, 128, 255);
      }
    }
    return image;
  }

  test('pure green as M3 counts it: G at least 200, R and B at most 60', () {
    expect(isPureGreen(0, 255, 0), isTrue);
    expect(isPureGreen(60, 200, 60), isTrue);
    expect(isPureGreen(61, 255, 0), isFalse);
    expect(isPureGreen(0, 199, 0), isFalse);
    expect(isPureGreen(0, 255, 61), isFalse);
  });

  test('a uniform grey image has no deviation; a gradient has; the size is told', () {
    final grey = checkGeneratedImage(img.Image(width: 30, height: 10)..clear(img.ColorRgb8(128, 128, 128)));
    expect(grey.lumaDeviation, closeTo(0, 1e-3));
    expect(grey.problemFor(30, 10), contains('a grey image'));
    final good = checkGeneratedImage(gradient(30, 10));
    expect(good.lumaDeviation, greaterThan(20));
    expect(good.greenLeft, 0);
    expect(good.problemFor(30, 10), isNull);
    expect(good.problemFor(40, 10), 'an image of 30 x 10, not 40 x 10');
    // Four channels, or one, read the same
    expect(checkGeneratedImage(gradient(30, 10, channels: 4)).lumaDeviation, closeTo(good.lumaDeviation, 1e-9));
    expect(
      checkGeneratedImage(
        img.Image(width: 8, height: 8, numChannels: 1)..clear(img.ColorRgb8(90, 90, 90)),
      ).lumaDeviation,
      closeTo(0, 1e-3),
    );
  });

  test('the green left is counted outside the photo of the control frame only, at the same relative place', () {
    // A control frame of 40 x 20: the photo on x 10 to 29, y 5 to 14, pure green around it
    final control = img.Image(width: 40, height: 20)..clear(img.ColorRgb8(0, 255, 0));
    img.fillRect(control, x1: 10, y1: 5, x2: 29, y2: 14, color: img.ColorRgb8(200, 180, 160));
    // The image at half the size: the photo on x 5 to 14, y 3 to 7 (rows 2.5 to 7.5)
    final image = gradient(20, 10);
    for (var x = 5; x < 15; x++) {
      image.setPixelRgb(x, 4, 0, 255, 0);
    }
    final inside = checkGeneratedImage(image, control: control);
    expect(inside.greenLeft, 0);
    image.setPixelRgb(0, 0, 0, 255, 0);
    final outside = checkGeneratedImage(image, control: control);
    expect(outside.greenLeft, closeTo(1 / (200 - 50), 1e-9));
    expect(outside.problemFor(20, 10), contains('% of pure green left outside the photo'));
    // Without a control frame, the whole image is outside
    expect(checkGeneratedImage(image).greenLeft, closeTo(11 / 200, 1e-9));
  });

  test('the size of a PNG from its first 24 bytes, null for anything else', () {
    final folder = Directory.systemTemp.createTempSync('image-checks-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final png = p.join(folder.path, 'a.png');
    File(png).writeAsBytesSync(img.encodePng(gradient(37, 11)));
    expect(pngFileSize(png), (37, 11));
    expect(pngSize(Uint8List.fromList(File(png).readAsBytesSync().sublist(0, 24))), (37, 11));
    final jpeg = p.join(folder.path, 'a.jpg');
    File(jpeg).writeAsBytesSync(img.encodeJpg(gradient(8, 8)));
    expect(pngFileSize(jpeg), isNull);
    expect(pngFileSize(p.join(folder.path, 'none.png')), isNull);
    expect(pngSize(Uint8List(10)), isNull);
    final report = checkGeneratedFile(png);
    expect((report.width, report.height), (37, 11));
    expect(() => checkGeneratedFile(p.join(folder.path, 'a.png.txt')), throwsA(isA<FileSystemException>()));
    File(p.join(folder.path, 'b.png')).writeAsStringSync('no image');
    expect(() => checkGeneratedFile(p.join(folder.path, 'b.png')), throwsFormatException);
  });
}
