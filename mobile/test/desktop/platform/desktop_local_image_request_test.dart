import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';

/// LocalImageRequest on the computers: DesktopLocalImageApi answers with the encoded file, which the request decodes at
/// most 16384 pixels on the long side, the aspect ratio kept, as Android and iOS bound their decodes
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.LocalImageApi.requestImage',
    LocalImageApi.pigeonChannelCodec,
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, null);
  });

  /// A PNG of one colour, drawn for the test
  Future<Uint8List> png(int width, int height) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xFF3366CC), ui.BlendMode.src);
    final image = await recorder.endRecording().toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// The image LocalImageRequest makes of [bytes], answered in the encoded shape of DesktopLocalImageApi
  Future<ui.Image> load(Uint8List bytes, ui.Size size) async {
    final pointer = malloc<Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, (_) async {
      return <Object?>[
        <Object?, Object?>{'pointer': pointer.address, 'length': bytes.length},
      ];
    });
    final request = LocalImageRequest(localId: 'long', size: size, assetType: AssetType.image);

    return (await request.load((_, {getTargetSize}) => throw UnimplementedError()))!.image;
  }

  test('bounds the original of a long image to 16384 pixels, its shape kept', () async {
    final image = await load(await png(20000, 100), ui.Size.zero);

    expect(image.width, 16384);
    expect(image.height, 82);
    image.dispose();
  });

  test('bounds a cover decode whose long side is still beyond the limit', () async {
    // a cover of 20 by 20 halves the image to 17000 by 20, still too long
    final image = await load(await png(34000, 40), const ui.Size.square(20));

    expect(image.width, 16384);
    expect(image.height, 19);
    image.dispose();
  });

  test('leaves an image within the limit at its size', () async {
    final image = await load(await png(2000, 100), ui.Size.zero);

    expect(image.width, 2000);
    expect(image.height, 100);
    image.dispose();
  });

  test('keeps the cover decode of an image within the limit', () async {
    final image = await load(await png(2000, 100), const ui.Size.square(50));

    expect(image.width, 1000);
    expect(image.height, 50);
    image.dispose();
  });
}
