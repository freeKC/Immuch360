// How long the engine's descriptor of a photo lives: the codec of an animation keeps it while it plays, all its frames
// read, and frees it when the codec goes; a codec that could not be made frees it at once; a damaged file fails rather
// than leave its load pending.

import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';

/// A real GIF of two frames of 1 x 1 pixel, red then blue
final _twoFrameGif = Uint8List.fromList([
  ...'GIF89a'.codeUnits,
  ...[1, 0, 1, 0, 0x80, 0, 0],
  ...[255, 0, 0, 0, 0, 255],
  for (final code in [0x44, 0x4c]) ...[
    ...[0x21, 0xf9, 4, 0, 1, 0, 0, 0],
    ...[0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0],
    ...[2, 2, code, 1, 0],
  ],
  0x3b,
]);

/// The descriptor of the engine, its disposals counted; [failCodec] makes its codec fail
class _CountingDescriptor implements ui.ImageDescriptor {
  _CountingDescriptor(this._inner, {this.failCodec = false});

  final ui.ImageDescriptor _inner;
  final bool failCodec;
  int disposals = 0;

  @override
  int get width => _inner.width;

  @override
  int get height => _inner.height;

  @override
  int get bytesPerPixel => _inner.bytesPerPixel;

  @override
  Future<ui.Codec> instantiateCodec({
    int? targetWidth,
    int? targetHeight,
    ui.TargetPixelFormat targetFormat = ui.TargetPixelFormat.dontCare,
  }) async {
    if (failCodec) {
      throw StateError('no codec');
    }
    return _inner.instantiateCodec(targetWidth: targetWidth, targetHeight: targetHeight, targetFormat: targetFormat);
  }

  @override
  void dispose() {
    disposals++;
    if (disposals == 1) {
      _inner.dispose();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  late List<_CountingDescriptor> descriptors;
  var failCodec = false;

  void answer(Uint8List bytes) {
    final pointer = malloc<Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, (_) async {
      return <Object?>[
        <Object?, Object?>{'pointer': pointer.address, 'length': bytes.length},
      ];
    });
  }

  setUp(() {
    descriptors = [];
    failCodec = false;
    ImageRequest.describeEncoded = (buffer) async {
      final descriptor = _CountingDescriptor(await ui.ImageDescriptor.encoded(buffer), failCodec: failCodec);
      descriptors.add(descriptor);
      return descriptor;
    };
  });

  tearDown(() {
    ImageRequest.describeEncoded = ui.ImageDescriptor.encoded;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, null);
  });

  test('the codec of an animation plays all its frames, then frees its descriptor with itself', () async {
    answer(_twoFrameGif);
    final codec = (await RemoteImageRequest(uri: 'https://example.test/animation').loadCodec())!;

    expect(codec.frameCount, 2);
    for (var i = 0; i < 2; i++) {
      final frame = await codec.getNextFrame();
      final pixels = await frame.image.toByteData();
      expect(pixels!.buffer.asUint8List().take(4).toList(), i == 0 ? [255, 0, 0, 255] : [0, 0, 255, 255]);
      frame.image.dispose();
    }
    expect(descriptors.single.disposals, 0, reason: 'the frames come from the descriptor while the codec lives');

    codec.dispose();
    codec.dispose();
    expect(descriptors.single.disposals, 1, reason: 'once, whatever the number of disposals of the codec');
  });

  test('a photo read to its first frame frees its descriptor', () async {
    answer(_twoFrameGif);

    final info = await RemoteImageRequest(uri: 'https://example.test/photo').load((_, {getTargetSize}) {
      throw UnimplementedError();
    });

    expect(info, isNotNull);
    expect(descriptors.single.disposals, 1);
    info!.dispose();
  });

  test('a codec that cannot be made frees its descriptor at once', () async {
    failCodec = true;
    answer(_twoFrameGif);

    await expectLater(RemoteImageRequest(uri: 'https://example.test/animation').loadCodec(), throwsStateError);

    expect(descriptors.single.disposals, 1);
  });

  test('damaged bytes fail rather than leave the load pending', () async {
    answer(Uint8List(4));

    await expectLater(RemoteImageRequest(uri: 'https://example.test/damaged').loadCodec(), throwsA(isA<Exception>()));
  });
}
