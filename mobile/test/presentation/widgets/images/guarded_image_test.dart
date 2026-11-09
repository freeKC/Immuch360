// The decoder of the encoded images that do not come through ImageRequest (shares, other apps, cameras, posters), on
// Android: the formats of the engine go to it as before, HEIF, AVIF and raw files to the native decoder within the
// bounds of the caller, text and empty files nowhere, so that the engine's fallback decoder, which aborts the app on
// an OutOfMemoryError (crash M1 of the Meta Quest store, 8 November 2026), never gets a buffer. Off Android, the
// engine.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/services/encoded_image_probe.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/platform/native_image_decode_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/guarded_image.dart';

import 'guarded_image_fakes.dart';

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

    test('a side left unbounded or at the default is bounded by the side the budget of the device allows', () async {
      addTearDown(() => TiffBudget.current = TiffBudget.large);
      const side = guardedImageMaxSide;
      await sizeOf(decodeEncodedBytes(heic, maxWidth: side, maxHeight: 0, source: 'test'));
      TiffBudget.current = TiffBudget.small;
      await sizeOf(decodeEncodedBytes(heic, maxWidth: side, maxHeight: side, source: 'test'));
      await sizeOf(decodeEncodedBytes(heic, maxWidth: 384, maxHeight: 0, source: 'test'));
      await sizeOf(decodeEncodedBytes(heic, maxWidth: 8191, maxHeight: 4095, source: 'test'));

      expect(native.calls.map((call) => (call.maxWidth, call.maxHeight)), [
        (8192, 8192),
        (4096, 4096),
        (384, 4096),
        (8191, 4095),
      ]);
    });

    test('the native decodes wait for a turn, as many at once as the budget of the device allows', () async {
      addTearDown(() => TiffBudget.current = TiffBudget.large);
      TiffBudget.current = TiffBudget.small;
      final held = _HeldNativeDecoder();
      nativeImageDecodeApi = held;

      final first = sizeOf(decodeEncodedBytes(heic, maxWidth: 800, maxHeight: 800, source: 'test'));
      final second = sizeOf(decodeEncodedBytes(avif, maxWidth: 800, maxHeight: 800, source: 'test'));
      await pumpEventQueue();
      expect(held.calls.map((call) => call.kind), [EncodedImageKind.heif], reason: 'one decode at once on a TV');

      held.releaseNext();
      expect(await first, (40, 30));
      await pumpEventQueue();
      expect(held.calls.map((call) => call.kind), [EncodedImageKind.heif, EncodedImageKind.avif]);
      held.releaseNext();
      expect(await second, (40, 30));
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

/// A native decoder that answers only when the test lets it, one call after the other
class _HeldNativeDecoder extends FakeNativeDecoder {
  final _held = <Completer<void>>[];

  @override
  Future<Map<String, int>> decodeEncoded(int pointer, int length, int maxWidth, int maxHeight) async {
    // The fake reads the head and records the call before its first await, while the caller holds the bytes
    final answer = super.decodeEncoded(pointer, length, maxWidth, maxHeight);
    final release = Completer<void>();
    _held.add(release);
    await release.future;
    return answer;
  }

  /// Lets the oldest call that waits answer
  void releaseNext() => _held.removeAt(0).complete();
}
