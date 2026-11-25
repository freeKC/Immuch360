// The PhotoView of the asset viewer under the desktop zoom (release 53, lib/desktop/window/desktop_photo_zoom.dart).
// Why a zoomed photo did not move under the mouse in release 52: the asset viewer gives PhotoView a vertical drag (for
// its details and the drag down that closes it), whose slop is one logical pixel for a mouse, while PhotoView's own
// recognizer waits for a fifth of the touch slop: the vertical drag won every mouse drag. With desktopZoom the mouse
// belongs to the desktop zoom, which pans, and the double click is its own; the phones keep PhotoView as it was.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/window/desktop_photo_zoom.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';

/// A picture of 1600 x 800 in a window of 800 x 600: the fit is a scale of 0.5, its pixels one to one a scale of 1
Future<Uint8List> _png(WidgetTester tester, {int width = 1600, int height = 800}) async =>
    (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = Colors.teal);
      final image = await recorder.endRecording().toImage(width, height);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    }))!;

void main() {
  late PhotoViewZoomTarget target;
  late List<PhotoViewScaleState> states;
  late int verticalDrags;
  late int taps;

  setUp(() {
    target = PhotoViewZoomTarget(devicePixelRatio: 1);
    states = [];
    verticalDrags = 0;
    taps = 0;
  });
  tearDown(() => target.dispose());

  Widget photoApp({required bool desktop, required ImageProvider image}) {
    final photo = PhotoView(
      imageProvider: image,
      index: 0,
      tightMode: true,
      enablePanAlways: true,
      filterQuality: FilterQuality.high,
      maxScale: 12.0,
      desktopZoom: desktop,
      onPageBuild: target.attach,
      scaleStateChangedCallback: states.add,
      // As the asset viewer does: a vertical drag for its details and to close it
      onDragStart: (_, _, _, _) => verticalDrags++,
      onDragUpdate: (_, _, _) {},
      onDragEnd: (_, _, _) {},
      // As the asset viewer does: a tap shows or hides its bars
      onTapUp: (_, _, _) => taps++,
    );
    return MaterialApp(
      home: SizedBox(
        width: 800,
        height: 600,
        child: desktop ? DesktopPhotoZoom(target: target, child: photo) : photo,
      ),
    );
  }

  Future<void> pumpPhoto(WidgetTester tester, {required bool desktop}) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final image = MemoryImage(await _png(tester));
    await tester.pumpWidget(photoApp(desktop: desktop, image: image));
    // The picture decodes outside the fake clock
    await tester.runAsync(() => precacheImage(image, tester.element(find.byType(PhotoView))));
    await tester.pump();
    await tester.pump();
    expect(target.frame, isNotNull, reason: 'the photo is laid out');
    expect(target.frame!.fitScale, closeTo(0.5, 1e-9));
  }

  Future<void> drag(WidgetTester tester, Offset by) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 300));
    await mouse.down(const Offset(400, 300));
    await mouse.moveBy(by / 2);
    await mouse.moveBy(by / 2);
    await mouse.up();
    await mouse.removePointer();
    await tester.pump();
  }

  testWidgets('release 52: without the desktop zoom a mouse drag never moves a zoomed photo', (tester) async {
    await pumpPhoto(tester, desktop: false);
    target.apply(1, Offset.zero);
    await tester.pump();
    await drag(tester, const Offset(60, 40));
    await tester.pump(const Duration(seconds: 1));
    expect(target.position, Offset.zero);
    expect(verticalDrags, 1, reason: 'the vertical drag of the viewer took it');
  });

  testWidgets('the desktop zoom: the mouse drag pans the zoomed photo within its edges', (tester) async {
    await pumpPhoto(tester, desktop: true);
    target.apply(1, Offset.zero);
    await tester.pump();
    expect(states.last, PhotoViewScaleState.zoomedIn);
    await drag(tester, const Offset(60, 40));
    expect(target.position, const Offset(60, 40));
    // 1600 x 800 in 800 x 600: 400 and 100 at most each way
    await drag(tester, const Offset(-3000, -3000));
    expect(target.position, const Offset(-400, -100));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('the wheel zooms in, the fit is the first scale state again', (tester) async {
    await pumpPhoto(tester, desktop: true);
    final mouse = TestPointer(51, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(const Offset(500, 300)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -300)));
    await tester.pump();
    expect(target.scale, closeTo(0.5 / (0.9 * 0.9 * 0.9), 1e-6));
    expect(states.last, PhotoViewScaleState.zoomedIn);
    expect(desktopZoomFit(target), isTrue);
    await tester.pump();
    expect(target.scale, closeTo(0.5, 1e-9));
    expect(states.last, PhotoViewScaleState.initial, reason: 'the viewer shows its bars again');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a double click shows the pixels one to one, then the whole photo; PhotoView keeps out of it', (
    tester,
  ) async {
    await pumpPhoto(tester, desktop: true);
    Future<void> doubleClick() async {
      await tester.tapAt(const Offset(600, 300), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(const Offset(600, 300), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await tester.pump(desktopZoomAnimation + const Duration(milliseconds: 20));
    }

    await doubleClick();
    expect(target.scale, closeTo(1, 1e-6));
    expect(states.last, PhotoViewScaleState.zoomedIn);
    await doubleClick();
    expect(target.scale, closeTo(0.5, 1e-9));
    expect(states.last, PhotoViewScaleState.initial);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('the phones: the double tap still goes through the scale states of PhotoView', (tester) async {
    await pumpPhoto(tester, desktop: false);
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(states, contains(PhotoViewScaleState.covering));
  });

  testWidgets('repair round: the original in place of the preview during an animated zoom keeps its end', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The preview of 800 x 400 (fit 1, one to one 5) and the original of 4000 x 2000 (fit 0.2, one to one 1)
    final preview = MemoryImage(await _png(tester, width: 800, height: 400));
    final original = MemoryImage(await _png(tester, width: 4000, height: 2000));
    target.originalPixels = const Size(4000, 2000);
    await tester.pumpWidget(photoApp(desktop: true, image: preview));
    final context = tester.element(find.byType(PhotoView));
    await tester.runAsync(() async {
      await precacheImage(preview, context);
      // Already in the cache, as a photo zoomed before and opened again
      await precacheImage(original, context);
    });
    await tester.pump();
    await tester.pump();
    expect(target.frame!.fitScale, closeTo(1, 1e-9));
    expect(target.frame!.oneToOneScale, closeTo(5, 1e-9));

    // The key 1, animated: the original comes in the middle of the animation
    expect(desktopZoomOneToOne(target, animate: true), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(photoApp(desktop: true, image: original));
    await tester.pump();
    expect(target.frame!.fitScale, closeTo(0.2, 1e-9), reason: 'the original is laid out');
    await tester.pump(desktopZoomAnimation);
    await tester.pump();
    expect(desktopZoomLevel(target), closeTo(1, 1e-6), reason: '100 %, not 500 %');
    expect(target.scale, lessThanOrEqualTo(target.frame!.maxScale + 1e-9));

    // The way back to the fit, the original coming at the same moment for a fresh preview
    await tester.pumpWidget(photoApp(desktop: true, image: preview));
    await tester.pump();
    expect(target.frame!.fitScale, closeTo(1, 1e-9));
    expect(desktopZoomLevel(target), closeTo(1, 1e-6), reason: 'the zoom follows the picture shown');
    expect(desktopZoomFit(target, animate: true), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(photoApp(desktop: true, image: original));
    await tester.pump();
    await tester.pump(desktopZoomAnimation);
    await tester.pump();
    expect(target.scale, closeTo(0.2, 1e-9));
    expect(target.position, Offset.zero);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('repair round: a short sideways drag pans a zoomed photo and is no tap; a click still is', (
    tester,
  ) async {
    await pumpPhoto(tester, desktop: true);
    target.apply(1, Offset.zero);
    await tester.pump();
    await drag(tester, const Offset(12, 0));
    await tester.pump(const Duration(seconds: 1));
    expect(target.position, const Offset(12, 0));
    expect(taps, 0, reason: 'the bars stay as they are');
    await tester.tapAt(const Offset(400, 300), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(seconds: 1));
    expect(taps, 1);
    expect(target.position, const Offset(12, 0));
  });

  testWidgets('repair round: a trackpad pinch stays between the fit and the largest zoom, as the wheel', (
    tester,
  ) async {
    await pumpPhoto(tester, desktop: true);
    final frame = target.frame!;
    expect(frame.maxScale, closeTo(4, 1e-9), reason: '400 % of the pixels one to one');
    Future<void> pinch(double by) async {
      final pad = await tester.createGesture(kind: PointerDeviceKind.trackpad);
      await pad.panZoomStart(const Offset(400, 300));
      await tester.pump();
      for (var i = 1; i <= 4; i++) {
        await pad.panZoomUpdate(const Offset(400, 300), scale: math.pow(by, i / 4).toDouble());
        await tester.pump();
      }
      await pad.panZoomEnd();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    await pinch(40);
    expect(target.scale, closeTo(frame.maxScale, 1e-9));
    await pinch(0.01);
    expect(target.scale, closeTo(frame.fitScale, 1e-9));
    expect(states.last, PhotoViewScaleState.initial);
  });
}
