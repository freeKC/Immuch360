// The decoder of the encoded images that do not come through ImageRequest (shares, other apps, cameras, posters), on
// Android: the formats of the engine go to it as before, HEIF, AVIF and raw files to the native decoder within the
// bounds of the caller, text and empty files nowhere, so that the engine's fallback decoder, which aborts the app on
// an OutOfMemoryError (crash M1 of the Meta Quest store, 8 November 2026), never gets a buffer. Off Android, the
// engine.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/services/encoded_image_probe.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/platform/native_image_decode_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/guarded_image.dart';

/// What the native decoder was asked
typedef NativeCall = ({EncodedImageKind kind, int length, int maxWidth, int maxHeight});

/// A stand in for the native decoder of Android: it records what it is asked and answers RGBA pixels of [width] x
/// [height] within the bounds asked, or throws [error]
class FakeNativeDecoder extends NativeImageDecodeApi {
  FakeNativeDecoder({this.width = 40, this.height = 30});

  final int width;
  final int height;
  final calls = <NativeCall>[];
  PlatformException? error;

  @override
  Future<Map<String, int>> decodeEncoded(int pointer, int length, int maxWidth, int maxHeight) async {
    // Read before the first await, while the caller holds the bytes
    final head = Uint8List.fromList(Pointer<Uint8>.fromAddress(pointer).asTypedList(math.min(length, 64)));
    calls.add((kind: sniffEncodedImage(head), length: length, maxWidth: maxWidth, maxHeight: maxHeight));
    final error = this.error;
    if (error != null) {
      throw error;
    }
    final w = maxWidth > 0 ? math.min(width, maxWidth) : width;
    final h = maxHeight > 0 ? math.min(height, maxHeight) : height;
    final pixels = malloc<Uint8>(w * h * 4)..asTypedList(w * h * 4).fillRange(0, w * h * 4, 0xFF);
    return {'pointer': pixels.address, 'width': w, 'height': h, 'rowBytes': w * 4};
  }
}

/// The error of the native decoder of Android for a photo it could not hold
PlatformException outOfMemory() => PlatformException(
  code: undecodableImageCode,
  message: 'java.lang.OutOfMemoryError: OOM allocating Bitmap with dimensions 32768 x 16384',
);

final heic = File('test/fixtures/ai_immersive/codec/display_p3.heic').readAsBytesSync();

/// The head of a DNG, a raw file built like a TIFF, then bytes no decoder of the tests reads
final dng = Uint8List.fromList([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, ...List.filled(2048, 0x11)]);

/// The head of an AVIF, then bytes no decoder of the tests reads
final avif = Uint8List.fromList([
  ...[0, 0, 0, 0x1C],
  ...'ftypavif'.codeUnits,
  ...[0, 0, 0, 0],
  ...'mif1miafMA1B'.codeUnits,
  ...List.filled(2048, 0x22),
]);

final svg = Uint8List.fromList('<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>'.codeUnits);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNativeDecoder native;
  late int engineDecodes;
  late Directory dir;

  Future<ui.Codec> engine(ui.ImmutableBuffer buffer, {ui.TargetImageSizeCallback? getTargetSize}) {
    engineDecodes++;
    return ui.instantiateImageCodecWithSize(buffer, getTargetSize: getTargetSize);
  }

  setUp(() {
    native = FakeNativeDecoder();
    nativeImageDecodeApi = native;
    engineDecodes = 0;
    UndecodablePhotos.instance.clear();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    dir = Directory.systemTemp.createTempSync('guarded_image');
  });

  tearDown(() {
    nativeImageDecodeApi = NativeImageDecodeApi();
    debugDefaultTargetPlatformOverride = null;
    dir.deleteSync(recursive: true);
  });

  /// The size of the first frame of [codec]
  Future<(int, int)> sizeOf(Future<ui.Codec> codec) async {
    final frame = await (await codec).getNextFrame();
    final size = (frame.image.width, frame.image.height);
    frame.image.dispose();
    return size;
  }

  Future<Object?> errorOf(Future<Object?> future) => future.then<Object?>((_) => null, onError: (Object e) => e);

  /// What [provider] gives: the size of its image, or its error
  Future<Object?> resolve(ImageProvider provider) async {
    final done = Completer<Object?>();
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        if (!done.isCompleted) {
          done.complete((info.image.width, info.image.height));
        }
        info.dispose();
      },
      onError: (error, _) {
        if (!done.isCompleted) {
          done.complete(error);
        }
      },
    );
    stream.addListener(listener);
    final result = await done.future.timeout(const Duration(seconds: 10));
    stream.removeListener(listener);
    return result;
  }

  group('on Android', () {
    test('a HEIC, a DNG and an AVIF go to the native decoder, within the bounds of the caller', () async {
      final heicCodec = decodeEncodedBytes(heic, maxWidth: 800, maxHeight: 600, source: 'test', decode: engine);
      expect(await sizeOf(heicCodec), (40, 30));
      await sizeOf(decodeEncodedBytes(dng, maxWidth: 4096, maxHeight: 4096, source: 'test', name: 'IMG_0001.DNG'));
      await sizeOf(decodeEncodedBytes(avif, maxWidth: 8191, maxHeight: 4095, source: 'test'));

      expect(native.calls, [
        (kind: EncodedImageKind.heif, length: heic.length, maxWidth: 800, maxHeight: 600),
        (kind: EncodedImageKind.tiff, length: dng.length, maxWidth: 4096, maxHeight: 4096),
        (kind: EncodedImageKind.avif, length: avif.length, maxWidth: 8191, maxHeight: 4095),
      ]);
      expect(engineDecodes, 0);
    });

    test('the image the native decoder gives is the size it answers', () async {
      native = FakeNativeDecoder(width: 800, height: 400);
      nativeImageDecodeApi = native;
      expect(await sizeOf(decodeEncodedBytes(heic, maxWidth: 400, maxHeight: 400, source: 'test')), (400, 400));
      expect(await sizeOf(decodeEncodedBytes(heic, maxWidth: 0, maxHeight: 0, source: 'test')), (800, 400));
    });

    test('a JPEG and a PNG go to the engine, fitted within the bounds as ResizeImage fits them', () async {
      final jpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 64, height: 32)));
      final png = Uint8List.fromList(img.encodePng(img.Image(width: 30, height: 60)));

      Future<(int, int)> engineSize(Uint8List bytes, int bound) =>
          sizeOf(decodeEncodedBytes(bytes, maxWidth: bound, maxHeight: bound, source: 'test', decode: engine));
      expect(await engineSize(jpeg, 16), (16, 8));
      expect(await engineSize(png, 16), (8, 16));
      expect(await engineSize(jpeg, 4096), (64, 32));
      expect(engineDecodes, 3);
      expect(native.calls, isEmpty);
    });

    test('an SVG and an empty file are refused, without the engine nor the native decoder', () async {
      for (final (bytes, kind) in [(svg, EncodedImageKind.text), (Uint8List(0), EncodedImageKind.empty)]) {
        final error = await errorOf(decodeEncodedBytes(bytes, maxWidth: 800, maxHeight: 800, source: 'test'));
        expect(error, isA<ImageDecodeException>(), reason: kind.name);
        expect(
          (error! as ImageDecodeException).cause,
          isA<UnsupportedEncodedImage>().having((e) => e.kind, 'kind', kind),
        );
      }
      expect(engineDecodes, 0);
      expect(native.calls, isEmpty);
    });

    test('a TIFF named so goes to the Dart decoder', () async {
      final tiff = Uint8List.fromList(img.encodeTiff(img.Image(width: 64, height: 32)));

      final codec = decodeEncodedBytes(tiff, maxWidth: 32, maxHeight: 32, source: 'test', name: 'scan.tif');
      expect(await sizeOf(codec), (32, 16));
      expect(native.calls, isEmpty);
      expect(engineDecodes, 0);
    });

    test('a failure of the native decoder is an ImageDecodeException', () async {
      native.error = outOfMemory();

      final error = await errorOf(decodeEncodedBytes(heic, maxWidth: 800, maxHeight: 800, source: 'test'));

      expect(error, isA<ImageDecodeException>());
      expect((error! as ImageDecodeException).cause, native.error);
    });

    test('a file goes where its first bytes say, and one the native decoder fails on is not read again', () async {
      final heicFile = File('${dir.path}/IMG_0001.HEIC')..writeAsBytesSync(heic);
      final jpegFile = File('${dir.path}/beach.jpg')
        ..writeAsBytesSync(img.encodeJpg(img.Image(width: 64, height: 32)));
      final svgFile = File('${dir.path}/logo.png')..writeAsBytesSync(svg);

      expect(await resolve(GuardedFileImage(jpegFile.path, source: 'test', maxWidth: 32, maxHeight: 32)), (32, 16));
      expect(native.calls, isEmpty);
      expect(await resolve(GuardedFileImage(heicFile.path, source: 'test', maxWidth: 128, maxHeight: 128)), (40, 30));
      expect(native.calls.single.maxWidth, 128);
      expect(await resolve(GuardedFileImage(svgFile.path, source: 'test')), isA<ImageDecodeException>());

      native.error = outOfMemory();
      native.calls.clear();
      PaintingBinding.instance.imageCache.clear();
      final remembered = GuardedFileImage(heicFile.path, source: 'test', undecodableKey: 'file:${heicFile.path}');
      expect(await resolve(remembered), isA<ImageDecodeException>());
      expect(UndecodablePhotos.instance.failureOf('file:${heicFile.path}'), isA<ImageDecodeException>());
      await pumpEventQueue();
      expect(await resolve(remembered), isA<ImageDecodeException>());
      expect(native.calls, hasLength(1), reason: 'remembered for the session, not decoded again');
    });

    test('a photo in memory goes where its first bytes say', () async {
      final jpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 64, height: 32)));
      expect(await resolve(GuardedMemoryImage(jpeg, source: 'test')), (64, 32));
      expect(await resolve(GuardedMemoryImage(heic, source: 'test', maxWidth: 384, maxHeight: 384)), (40, 30));
      expect(await resolve(GuardedMemoryImage(svg, source: 'test')), isA<ImageDecodeException>());
      expect(native.calls.map((call) => call.kind), [EncodedImageKind.heif]);
      // Known by the identity of its bytes, as MemoryImage
      expect(GuardedMemoryImage(jpeg, source: 'a'), GuardedMemoryImage(jpeg, source: 'b'));
      expect(GuardedMemoryImage(jpeg, source: 'a'), isNot(GuardedMemoryImage(Uint8List.fromList(jpeg), source: 'a')));
    });
  });

  test('off Android nothing goes to the native decoder: the engine decodes every buffer, as before', () async {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux]) {
      debugDefaultTargetPlatformOverride = platform;
      // The engine of the tests may have no HEIF decoder: it was asked either way
      await errorOf(sizeOf(decodeEncodedBytes(heic, maxWidth: 800, maxHeight: 800, source: 'test', decode: engine)));
      await errorOf(sizeOf(decodeEncodedBytes(svg, maxWidth: 800, maxHeight: 800, source: 'test', decode: engine)));
    }
    expect(native.calls, isEmpty);
    expect(engineDecodes, 8);
  });

  test('the fit of the engine is the one of ResizeImage', () {
    final fit = fitTargetSize(8191, 4095);
    ui.TargetImageSize sized(int width, int height) => fit(width, height);
    expect((sized(32768, 16384).width, sized(32768, 16384).height), (8191, 4095));
    expect((sized(4000, 2000).width, sized(4000, 2000).height), (4000, 2000));
    final square = fitTargetSize(4096, 4096);
    expect((square(12000, 9000).width, square(12000, 9000).height), (4096, 3072));
    expect((square(3000, 4000).width, square(3000, 4000).height), (3000, 4000));
    final wide = fitTargetSize(256, 0);
    expect((wide(1024, 512).width, wide(1024, 512).height), (256, 128));
  });
}
