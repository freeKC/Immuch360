// A photo opened from another app ("Open with") on Android: it went whole to the engine (FileImage), whose fallback
// decoder decodes a HEIF, an AVIF or a raw file at its full size and aborts the app on an OutOfMemoryError (crash M1
// of the Meta Quest store, 8 November 2026). Now such a file goes to the native decoder, at most the long side the
// budget of the device lets a viewer decode, a JPEG stays with the engine, and a file that is no image says it did not
// decode.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/encoded_image_probe.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/platform/native_image_decode_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/guarded_image.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';

import 'guarded_image_fakes.dart';

final _opened = LocalAsset(
  id: 'opened',
  name: 'opened',
  type: AssetType.image,
  createdAt: DateTime(2026, 11, 8),
  updatedAt: DateTime(2026, 11, 8),
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);

void main() {
  late FakeNativeDecoder native;
  late Directory dir;

  setUp(() {
    native = FakeNativeDecoder();
    nativeImageDecodeApi = native;
    UndecodablePhotos.instance.clear();
    dir = Directory.systemTemp.createTempSync('open_with_guard');
  });

  tearDown(() {
    nativeImageDecodeApi = NativeImageDecodeApi();
    dir.deleteSync(recursive: true);
  });

  Future<void> pumpOpened(WidgetTester tester, String path) async {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Image(
          image: getFullImageProvider(_opened, localFilePath: path),
          errorBuilder: (_, _, _) => const Text('not decoded'),
        ),
      ),
    );
  }

  RawImage? shown() {
    final images = find.byType(RawImage).evaluate().map((element) => element.widget).whereType<RawImage>();
    return images.where((raw) => raw.image != null).firstOrNull;
  }

  /// Real time for the file and the decoders, frames for the image
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 100 && shown() == null && find.text('not decoded').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  testWidgets('a HEIC opened from another app is decoded natively, at most the side of the budget', (tester) async {
    final file = File('${dir.path}/IMG_0001.HEIC')..writeAsBytesSync(heic);
    await pumpOpened(tester, file.path);
    await settle(tester);

    expect((shown()!.image!.width, shown()!.image!.height), (40, 30));
    // The budget of the tests is the large one: 8192 pixels on the long side, 4096 on a TV
    expect(native.calls, [(kind: EncodedImageKind.heif, length: heic.length, maxWidth: 8192, maxHeight: 8192)]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a JPEG opened from another app keeps the engine, at its size', (tester) async {
    final file = File('${dir.path}/beach.jpg')..writeAsBytesSync(img.encodeJpg(img.Image(width: 64, height: 32)));
    await pumpOpened(tester, file.path);
    await settle(tester);

    expect((shown()!.image!.width, shown()!.image!.height), (64, 32));
    expect(native.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a file that is no image says it did not decode, without any decoder', (tester) async {
    final file = File('${dir.path}/logo.jpg')..writeAsBytesSync(svg);
    await pumpOpened(tester, file.path);
    await settle(tester);

    expect(find.text('not decoded'), findsOneWidget);
    expect(native.calls, isEmpty);
    expect(UndecodablePhotos.instance.failureOf('open:${file.path}'), isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('the provider of a file opened from another app is the guarded one', () {
    final provider = getFullImageProvider(_opened, localFilePath: '/storage/emulated/0/Download/a.heic');
    expect(provider, isA<GuardedFileImage>());
  });
}
