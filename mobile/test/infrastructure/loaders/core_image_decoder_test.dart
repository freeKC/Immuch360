// The Rust core of upstream called through dart:ffi (core_image_decoder.dart), on the machine that runs the tests: the
// build hook of native_core compiles it for flutter test as for the builds of the computers. The fixtures are the
// JPEG XL files of the Android lab (mobile/test/fixtures/android_lab/ORIGIN.txt): a preview of 720 x 480 and the
// preview of a 360 photo, 1440 x 720.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/encoded_image_probe.dart';
import 'package:immich_mobile/infrastructure/loaders/core_image_decoder.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/presentation/widgets/images/guarded_image.dart';

const _fixtures = 'test/fixtures/android_lab';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final preview = File('$_fixtures/lab_preview.jxl').readAsBytesSync();
  final spherePreview = File('$_fixtures/lab_360_preview.jxl').readAsBytesSync();
  final jpeg = File('$_fixtures/lab_thumbnail.jpg').readAsBytesSync();

  Future<(int, int)> sizeOf(Future<ui.ImageDescriptor?> decode) async {
    final descriptor = (await decode)!;
    addTearDown(descriptor.dispose);
    return (descriptor.width, descriptor.height);
  }

  group('the core through dart:ffi', () {
    test('the fixtures are JPEG XL', () {
      expect(sniffEncodedImage(preview), EncodedImageKind.jxl);
      expect(sniffEncodedImage(spherePreview), EncodedImageKind.jxl);
    });

    test('decodes a JPEG XL preview at its own size', () async {
      expect(await sizeOf(decodeBytesWithCore(preview)), (720, 480));
      expect(await sizeOf(decodeBytesWithCore(spherePreview)), (1440, 720));
    });

    test('bounds the long side, the aspect kept, and never enlarges', () async {
      expect(await sizeOf(decodeBytesWithCore(preview, maxPixelSize: 360)), (360, 240));
      expect(await sizeOf(decodeBytesWithCore(spherePreview, maxPixelSize: 1024)), (1024, 512));
      expect(await sizeOf(decodeBytesWithCore(preview, maxPixelSize: 100000)), (720, 480));
    });

    test('covers a target as the phones do', () async {
      expect(await sizeOf(decodeBytesWithCore(preview, targetWidth: 100, targetHeight: 100)), (150, 100));
      expect(await sizeOf(decodeBytesWithCore(preview, targetWidth: 2000, targetHeight: 2000)), (720, 480));
    });

    test('gives opaque pixels of the drawing', () async {
      final descriptor = (await decodeBytesWithCore(preview))!;
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      final data = (await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      frame.image.dispose();
      codec.dispose();
      descriptor.dispose();
      final pixels = data.buffer.asUint8List();
      expect(pixels.length, 720 * 480 * 4);
      var colours = 0;
      for (var offset = 0; offset < pixels.length; offset += 4 * 997) {
        expect(pixels[offset + 3], 255, reason: 'alpha at ${offset ~/ 4}');
        if (pixels[offset] + pixels[offset + 1] + pixels[offset + 2] > 0) {
          colours++;
        }
      }
      expect(colours, greaterThan(0), reason: 'not a black picture');
    });

    test('bytes that are no JPEG XL, or a cut one, give a CoreDecodeException', () async {
      await expectLater(decodeBytesWithCore(jpeg), throwsA(isA<CoreDecodeException>()));
      await expectLater(
        decodeBytesWithCore(Uint8List.sublistView(preview, 0, preview.length ~/ 3)),
        throwsA(isA<CoreDecodeException>()),
      );
      await expectLater(decodeBytesWithCore(Uint8List(0)), throwsA(isA<CoreDecodeException>()));
    });

    test('a decode stopped first gives no picture', () async {
      final handle = CoreDecodeHandle()..stop();
      expect(await decodeBytesWithCore(preview, handle: handle), isNull);
    });

    test('many decodes at once all end', () async {
      final sizes = await Future.wait([
        for (var i = 0; i < 12; i++) sizeOf(decodeBytesWithCore(i.isEven ? preview : spherePreview, maxPixelSize: 512)),
      ]);
      expect(sizes.toSet(), {(512, 342), (512, 256)});
    });
  });

  group('the loaders of the computers', () {
    const channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
      RemoteImageApi.pigeonChannelCodec,
    );
    late List<int> freed;
    final realFree = ImageRequest.freePlatformBuffer;

    // The API of the phones, made before a test pretends to be a computer: its messages are the ones answered here
    setUpAll(() => expect(remoteImageApi, isA<RemoteImageApi>()));

    setUp(() {
      freed = [];
      ImageRequest.freePlatformBuffer = (pointer) {
        freed.add(pointer.address);
        realFree(pointer);
      };
    });

    tearDown(() {
      ImageRequest.freePlatformBuffer = realFree;
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, null);
    });

    // The platform answering the encoded bytes [bytes], as DesktopRemoteImageApi does; the address of its buffer
    int answerEncoded(Uint8List bytes) {
      final pointer = malloc<Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, (
        _,
      ) async {
        return <Object?>[
          <Object?, Object?>{'pointer': pointer.address, 'length': bytes.length},
        ];
      });
      return pointer.address;
    }

    for (final platform in [TargetPlatform.linux, TargetPlatform.windows, TargetPlatform.macOS]) {
      test('a JPEG XL thumbnail of the server is decoded by the core on ${platform.name}', () async {
        debugDefaultTargetPlatformOverride = platform;
        final address = answerEncoded(preview);
        final request = RemoteImageRequest(uri: 'https://example.test/thumbnail', decodeSize: const ui.Size(360, 240));

        final info = (await request.load((_, {getTargetSize}) => throw UnimplementedError()))!;

        expect((info.image.width, info.image.height), (360, 240));
        info.image.dispose();
        expect(freed, [address], reason: 'the buffer of the platform freed once');
      });
    }

    test('a JPEG XL preview at its full size for the viewers', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      answerEncoded(spherePreview);
      final request = RemoteImageRequest(uri: 'https://example.test/preview');

      final info = (await request.load((_, {getTargetSize}) => throw UnimplementedError()))!;

      expect((info.image.width, info.image.height), (1440, 720));
      info.image.dispose();
    });

    test('a cut JPEG XL is a photo that does not decode, its buffer freed', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final address = answerEncoded(Uint8List.sublistView(preview, 0, 200));
      final request = RemoteImageRequest(uri: 'https://example.test/thumbnail');

      await expectLater(
        request.load((_, {getTargetSize}) => throw UnimplementedError()),
        throwsA(isA<ImageDecodeException>().having((e) => e.cause, 'cause', isA<CoreDecodeException>())),
      );
      expect(freed, [address]);
    });

    test('on Android an encoded JPEG XL never reaches the engine: the platform decodes it before', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      answerEncoded(preview);
      final request = RemoteImageRequest(uri: 'https://example.test/thumbnail');

      await expectLater(
        request.load((_, {getTargetSize}) => throw UnimplementedError()),
        throwsA(isA<ImageDecodeException>().having((e) => e.cause, 'cause', isA<UnsupportedEncodedImage>())),
      );
    });

    test('a guarded JPEG XL (a share, a file opened) fits its bounds on a computer', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      for (final (bytes, maxWidth, maxHeight, expected) in [
        (preview, 360, 360, (360, 240)),
        (preview, 1000, 1000, (720, 480)),
        (spherePreview, 400, 400, (400, 200)),
        (preview, 0, 100, (150, 100)),
      ]) {
        final codec = await decodeEncodedBytes(bytes, maxWidth: maxWidth, maxHeight: maxHeight, source: 'test');
        final frame = await codec.getNextFrame();
        expect((frame.image.width, frame.image.height), expected, reason: 'within ${maxWidth}x$maxHeight');
        frame.image.dispose();
        codec.dispose();
      }
    });
  });
}
