// The photo viewer under a laptop's touchpad (8 November 2026): a trackpad's two finger pan and pinch reach the photo's
// recognizer as pan and zoom events, before any pointer went down on the photo. Its axis check read a starting point
// that only a down event sets ("Null check operator used on a null value" on each new photo); now those events go to
// the scale recognizer, which zooms the photo, and a touch drag afterwards behaves as before.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';

/// An image whose only frame is [image], at once
class _ReadyImageProvider extends ImageProvider<_ReadyImageProvider> {
  _ReadyImageProvider(this.image);

  final ui.Image image;

  @override
  Future<_ReadyImageProvider> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_ReadyImageProvider key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: image.clone())));
}

void main() {
  late PhotoViewController controller;

  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    controller = PhotoViewController();
  });

  tearDown(() {
    controller.dispose();
  });

  // A photo of the asset viewer: the page view of the photos asks the horizontal axis check of the scope
  Future<void> pumpPhoto(WidgetTester tester) async {
    final image = (await tester.runAsync(() => createTestImage(width: 400, height: 200)))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 600,
            child: PhotoViewGestureDetectorScope(
              axis: Axis.horizontal,
              child: PhotoView(index: 0, imageProvider: _ReadyImageProvider(image), controller: controller),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // Two fingers on the touchpad: a pan of 40 px, then a pinch to twice the size, then the fingers lift
  Future<void> pinchWithTouchpad(WidgetTester tester) async {
    final center = tester.getCenter(find.byType(PhotoView));
    final touchpad = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await touchpad.panZoomStart(center);
    await tester.pump();
    await touchpad.panZoomUpdate(center, pan: const Offset(40, 0));
    await tester.pump();
    await touchpad.panZoomUpdate(center, pan: const Offset(40, 0), scale: 2);
    await tester.pump();
    await touchpad.panZoomEnd();
    await tester.pumpAndSettle();
  }

  testWidgets('a touchpad pinch on a photo nobody touched throws nothing', (tester) async {
    await pumpPhoto(tester);

    await pinchWithTouchpad(tester);

    expect(tester.takeException(), isNull);
  });

  testWidgets('a touchpad pinch zooms a photo nobody touched', (tester) async {
    await pumpPhoto(tester);
    // The photo contained in its box
    final before = controller.scale;
    expect(before, isNotNull);

    await pinchWithTouchpad(tester);

    expect(controller.scale, closeTo(before! * 2, 0.01), reason: 'the pinch reached the scale recognizer');
  });

  testWidgets('a touch drag after the touchpad pinch runs as before', (tester) async {
    await pumpPhoto(tester);
    await pinchWithTouchpad(tester);

    await tester.dragFrom(tester.getCenter(find.byType(PhotoView)), const Offset(-60, 0));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
