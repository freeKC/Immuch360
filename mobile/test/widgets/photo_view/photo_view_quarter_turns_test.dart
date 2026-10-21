// PhotoView turned by quarter turns (the one-key rotation of the viewers): the fit and the zoom levels follow the
// turned size, and a new image given with new turns keeps the old turns until its first frame, so that a picture
// turned on the server takes the place of the one turned on screen in the same frame.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';

/// An image whose first frame comes when [complete] is called
class _GatedImageProvider extends ImageProvider<_GatedImageProvider> {
  _GatedImageProvider(this.image);

  final ui.Image image;
  final _frame = Completer<ImageInfo>();

  void complete() => _frame.complete(ImageInfo(image: image.clone()));

  @override
  Future<_GatedImageProvider> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_GatedImageProvider key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_frame.future);
}

void main() {
  late ui.Image landscape;
  late ui.Image portrait;

  Future<void> pumpPhoto(WidgetTester tester, ImageProvider image, {required int quarterTurns}) => tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: SizedBox(
          width: 300,
          height: 600,
          child: PhotoView(
            index: 0,
            imageProvider: image,
            quarterTurns: quarterTurns,
            gaplessPlayback: true,
            filterQuality: FilterQuality.high,
            tightMode: true,
            enablePanAlways: true,
          ),
        ),
      ),
    ),
  );

  RotatedBox rotatedBox(WidgetTester tester) => tester.widget<RotatedBox>(find.byType(RotatedBox));

  setUp(() {
    PaintingBinding.instance.imageCache.clear();
  });

  testWidgets('fits a turned landscape photo to a portrait screen by its turned size', (tester) async {
    landscape = (await tester.runAsync(() => createTestImage(width: 400, height: 200)))!;
    final image = _GatedImageProvider(landscape)..complete();

    await pumpPhoto(tester, image, quarterTurns: 0);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(RotatedBox)), const Size(300, 150), reason: 'scale 0.75 unturned');

    await pumpPhoto(tester, image, quarterTurns: 1);
    await tester.pumpAndSettle();
    expect(rotatedBox(tester).quarterTurns, 1);
    // 200 x 400 once turned, contained in 300 x 600: scale 1.5
    expect(tester.getSize(find.byType(RotatedBox)), const Size(300, 600));
    expect(tester.getSize(find.byType(Image)), const Size(600, 300), reason: 'the image itself is drawn unturned');

    await pumpPhoto(tester, image, quarterTurns: 2);
    await tester.pumpAndSettle();
    expect(rotatedBox(tester).quarterTurns, 2);
    expect(tester.getSize(find.byType(RotatedBox)), const Size(300, 150));
  });

  testWidgets('keeps the turns of the frame on screen until the new image has its first frame', (tester) async {
    landscape = (await tester.runAsync(() => createTestImage(width: 400, height: 200)))!;
    portrait = (await tester.runAsync(() => createTestImage(width: 200, height: 400)))!;
    final turnedOnScreen = _GatedImageProvider(landscape)..complete();
    final turnedOnServer = _GatedImageProvider(portrait);

    await pumpPhoto(tester, turnedOnScreen, quarterTurns: 1);
    await tester.pumpAndSettle();
    expect(rotatedBox(tester).quarterTurns, 1);

    // The server's picture comes, turned already: no turn for it, but not before it is there
    await pumpPhoto(tester, turnedOnServer, quarterTurns: 0);
    await tester.pump();
    expect(rotatedBox(tester).quarterTurns, 1, reason: 'the old frame is still drawn, turned');
    expect(tester.getSize(find.byType(RotatedBox)), const Size(300, 600));

    turnedOnServer.complete();
    await tester.pumpAndSettle();
    expect(rotatedBox(tester).quarterTurns, 0);
    expect(tester.getSize(find.byType(RotatedBox)), const Size(300, 600), reason: 'the same picture on screen');
  });
}
