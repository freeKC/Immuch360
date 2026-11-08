// The pictures of the files shared to the app for upload on Android: each went whole to the engine (Image.file, at its
// full size for a tile of 64 pixels), whose fallback decoder decodes a HEIF, an AVIF or a raw file and aborts the app
// on an OutOfMemoryError (crash M1 of the Meta Quest store, 8 November 2026). Now each is decoded at most 128 pixels
// on a side, a HEIC by the native decoder, a JPEG by the engine, and a file no decoder reads shows a document.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/services/encoded_image_probe.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/pages/share_intent/share_intent.page.dart';
import 'package:immich_mobile/platform/native_image_decode_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/guarded_image.dart';

import '../../presentation/widgets/images/guarded_image_fakes.dart';

void main() {
  late FakeNativeDecoder native;
  late Directory dir;

  setUp(() {
    native = FakeNativeDecoder(width: 400, height: 300);
    nativeImageDecodeApi = native;
    UndecodablePhotos.instance.clear();
    dir = Directory.systemTemp.createTempSync('share_intent_thumbnail');
  });

  tearDown(() {
    nativeImageDecodeApi = NativeImageDecodeApi();
    dir.deleteSync(recursive: true);
  });

  Future<void> pumpThumbnail(WidgetTester tester, String name, List<int> bytes) async {
    final file = File('${dir.path}/$name')..writeAsBytesSync(bytes);
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: ShareIntentThumbnail(path: file.path))),
      ),
    );
  }

  RawImage? shown() {
    final images = find.byType(RawImage).evaluate().map((element) => element.widget).whereType<RawImage>();
    return images.where((raw) => raw.image != null).firstOrNull;
  }

  Finder document() => find.byIcon(Icons.insert_drive_file_outlined);

  /// Real time for the file and the decoders, frames for the picture
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 100 && shown() == null && document().evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  testWidgets('a HEIC shared to the app is decoded natively at 128 pixels at most', (tester) async {
    await pumpThumbnail(tester, 'IMG_0001.HEIC', heic);
    await settle(tester);

    expect(shown(), isNotNull);
    expect((shown()!.image!.width, shown()!.image!.height), (128, 128));
    expect(native.calls, [(kind: EncodedImageKind.heif, length: heic.length, maxWidth: 128, maxHeight: 128)]);
    expect(tester.getSize(find.byType(ShareIntentThumbnail)), const Size(64, 64));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a JPEG shared to the app is decoded by the engine at 128 pixels at most', (tester) async {
    await pumpThumbnail(tester, 'beach.jpg', img.encodeJpg(img.Image(width: 640, height: 320)));
    await settle(tester);

    expect((shown()!.image!.width, shown()!.image!.height), (128, 64));
    expect(native.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a file no decoder of the device reads shows a document', (tester) async {
    await pumpThumbnail(tester, 'drawing.png', svg);
    await settle(tester);

    expect(document(), findsOneWidget);
    expect(shown(), isNull);
    expect(native.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
