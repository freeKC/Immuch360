// The poster of the Save to Immich sheet of a splat scene on Android: a JPEG the viewer or the app draws, which went to
// the engine as it came (Image.memory). Now its first bytes decide: a JPEG goes to the engine as before, a format the
// engine has no codec of its own for to the native decoder, never to the fallback decoder of the engine that aborts the
// app out of memory (crash M1 of the Meta Quest store, 8 November 2026), and bytes no decoder reads show a placeholder.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/services/encoded_image_probe.dart';
import 'package:immich_mobile/platform/native_image_decode_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/guarded_image.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_save_launch.dart';

import '../images/guarded_image_fakes.dart';

void main() {
  late FakeNativeDecoder native;

  setUp(() {
    native = FakeNativeDecoder();
    nativeImageDecodeApi = native;
  });

  tearDown(() => nativeImageDecodeApi = NativeImageDecodeApi());

  Future<void> pumpPoster(WidgetTester tester, Uint8List poster) async {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SplatSavePosterImage(poster: poster)),
      ),
    );
  }

  RawImage? shown() {
    final images = find.byType(RawImage).evaluate().map((element) => element.widget).whereType<RawImage>();
    return images.where((raw) => raw.image != null).firstOrNull;
  }

  Finder placeholder() => find.byKey(splatSavePosterPlaceholderKey);

  /// Real time for the decoders, frames for the poster
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 100 && shown() == null && placeholder().evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  testWidgets('a JPEG poster goes to the engine, as before', (tester) async {
    await pumpPoster(tester, Uint8List.fromList(img.encodeJpg(img.Image(width: 96, height: 64))));
    await settle(tester);

    expect((shown()!.image!.width, shown()!.image!.height), (96, 64));
    expect(native.calls, isEmpty);
    expect(placeholder(), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a poster that is no JPEG nor any image of the device shows a placeholder', (tester) async {
    await pumpPoster(tester, svg);
    await settle(tester);

    expect(placeholder(), findsOneWidget);
    expect(shown(), isNull);
    expect(native.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a HEIC poster goes to the native decoder, never to the engine', (tester) async {
    await pumpPoster(tester, heic);
    await settle(tester);

    expect(shown(), isNotNull);
    expect(native.calls.single.kind, EncodedImageKind.heif);
    await tester.pumpWidget(const SizedBox());
  });
}
