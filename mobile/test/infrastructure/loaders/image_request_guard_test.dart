// The encoded answers of the platform on Android (crash M1 of the Meta Quest store, 8 November 2026): a format the
// engine has no codec of its own for (HEIF, AVIF, raw files) never reaches the engine, whose fallback decoder aborts
// the app on an OutOfMemoryError; it fails as an ImageDecodeException, which the viewers remember, its buffer freed.
// The formats of the engine still go to it, and off Android every buffer does, as before.

import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/encoded_image_probe.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';

/// A HEIC of an iPhone: ftyp heic, mif1 and heic compatible
final _heic = File('test/fixtures/ai_immersive/codec/display_p3.heic').readAsBytesSync();

/// The head of an animated AVIF (an image sequence), then bytes no decoder reads
final _animatedAvif = Uint8List.fromList([
  ...[0, 0, 0, 0x20],
  ...'ftypavis'.codeUnits,
  ...[0, 0, 0, 0],
  ...'avismsf1miafMA1B'.codeUnits,
  ...List.filled(4096, 0x41),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  late List<int> freed;
  late int engineDecodes;

  setUp(() {
    freed = [];
    engineDecodes = 0;
    ImageRequest.freePlatformBuffer = (pointer) {
      freed.add(pointer.address);
      malloc.free(pointer);
    };
    ImageRequest.describeEncoded = (buffer) {
      engineDecodes++;
      return ui.ImageDescriptor.encoded(buffer);
    };
  });

  tearDown(() {
    ImageRequest.freePlatformBuffer = malloc.free;
    ImageRequest.describeEncoded = ui.ImageDescriptor.encoded;
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, null);
  });

  /// The platform answers [bytes] encoded, in a buffer of its own; its address
  int answerEncoded(Uint8List bytes) {
    final pointer = malloc<Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, (_) async {
      return <Object?>[
        <Object?, Object?>{'pointer': pointer.address, 'length': bytes.length},
      ];
    });
    return pointer.address;
  }

  Future<ImageInfo?> load(String uri) => RemoteImageRequest(
    uri: uri,
    decodeSize: const ui.Size.square(512),
  ).load((_, {getTargetSize}) => throw UnimplementedError('the engine decodes through ImageDescriptor.encoded'));

  test('an encoded HEIC fails as an ImageDecodeException, its buffer freed, the engine never called', () async {
    final address = answerEncoded(_heic);

    final error = await load('https://example.test/original').then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, isA<ImageDecodeException>());
    final cause = (error! as ImageDecodeException).cause;
    expect(cause, isA<UnsupportedEncodedImage>().having((c) => c.kind, 'kind', EncodedImageKind.heif));
    expect((cause as UnsupportedEncodedImage).length, _heic.length);
    expect(freed, [address]);
    expect(engineDecodes, 0);
  });

  test('a WebP still goes to the engine', () async {
    final address = answerEncoded(await File('assets/feature_message/ocr.webp').readAsBytes());

    final info = await load('https://example.test/preview');

    expect(info, isNotNull);
    expect(info!.image.width, greaterThan(0));
    info.dispose();
    expect(engineDecodes, 1);
    expect(freed, [address]);
  });

  test('a photo the native decoder of the platform did not decode is an ImageDecodeException', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, (_) async {
      return <Object?>[
        undecodableImageCode,
        'java.lang.OutOfMemoryError: OOM allocating Bitmap with dimensions 32768 x 16384',
        null,
      ];
    });

    final error = await load('https://example.test/original').then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, isA<ImageDecodeException>());
    expect(
      (error! as ImageDecodeException).cause,
      isA<PlatformException>().having((e) => e.code, 'code', undecodableImageCode),
    );
    expect(engineDecodes, 0);
  });

  test('another error of the platform stays what it is: a network error is tried again', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, (_) async {
      return <Object?>['IOException', 'HTTP 503: Service Unavailable', null];
    });

    final error = await load('https://example.test/original').then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, isA<PlatformException>().having((e) => e.code, 'code', 'IOException'));
  });

  test('the codec of an animated AVIF original fails cleanly, before the engine', () async {
    final address = answerEncoded(_animatedAvif);
    final request = RemoteImageRequest(uri: 'https://example.test/animated');

    final error = await request.loadCodec().then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, isA<ImageDecodeException>());
    expect(
      (error! as ImageDecodeException).cause,
      isA<UnsupportedEncodedImage>().having((c) => c.kind, 'kind', EncodedImageKind.avif),
    );
    expect(freed, [address]);
    expect(engineDecodes, 0);
  });

  test('off Android the engine gets every buffer, as before', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final address = answerEncoded(_heic);

    // Whether the engine of the tests decodes a HEIF or not, it was asked
    final result = await load('https://example.test/original').then<Object?>((info) => info, onError: (Object e) => e);

    expect(engineDecodes, 1);
    expect(freed, [address]);
    if (result is ImageInfo) {
      result.dispose();
    } else {
      expect(result, isA<ImageDecodeException>());
      expect((result! as ImageDecodeException).cause, isNot(isA<UnsupportedEncodedImage>()));
    }
  });
}
