// The Rust core through dart:ffi on the computer that runs the desktop tests (Windows in the Windows job, Linux in the
// Linux one): the library the hook of native_core builds for that system, and the free() of its C runtime for the
// pixels (ucrtbase.dll on Windows, the C library elsewhere). A free of the wrong heap would corrupt it, so many decodes
// in a row are run. The cases that do not depend on the system are in
// test/infrastructure/loaders/core_image_decoder_test.dart.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/loaders/core_image_decoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final preview = File('test/fixtures/android_lab/lab_preview.jxl').readAsBytesSync();
  final spherePreview = File('test/fixtures/android_lab/lab_360_preview.jxl').readAsBytesSync();

  Future<(int, int)> sizeOf(Future<ui.ImageDescriptor?> decode) async {
    final descriptor = (await decode)!;
    final size = (descriptor.width, descriptor.height);
    descriptor.dispose();
    return size;
  }

  test('the core decodes the JPEG XL previews of a server on ${Platform.operatingSystem}', () async {
    expect(await sizeOf(decodeBytesWithCore(preview)), (720, 480));
    expect(await sizeOf(decodeBytesWithCore(spherePreview)), (1440, 720));
    expect(await sizeOf(decodeBytesWithCore(preview, maxPixelSize: 360)), (360, 240));
    expect(await sizeOf(decodeBytesWithCore(preview, targetWidth: 100, targetHeight: 100)), (150, 100));
  });

  test('sixty decodes in a row and twelve at once free their pixels with the right C runtime', () async {
    for (var i = 0; i < 60; i++) {
      final size = await sizeOf(decodeBytesWithCore(i.isEven ? preview : spherePreview, maxPixelSize: 256));
      expect(size, i.isEven ? (256, 171) : (256, 128));
    }
    final sizes = await Future.wait([for (var i = 0; i < 12; i++) sizeOf(decodeBytesWithCore(spherePreview))]);
    expect(sizes.toSet(), {(1440, 720)});
  });

  test('a cut JPEG XL is refused, the next one still decodes', () async {
    await expectLater(decodeBytesWithCore(Uint8List.sublistView(preview, 0, 300)), throwsA(isA<CoreDecodeException>()));
    expect(await sizeOf(decodeBytesWithCore(preview)), (720, 480));
  });
}
