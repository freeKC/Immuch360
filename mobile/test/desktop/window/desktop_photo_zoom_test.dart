// The zoom and pan of a still picture with a mouse, a trackpad and a keyboard on a computer (release 53,
// lib/desktop/window/desktop_photo_zoom.dart): the wheel zooms around the pointer, out at fit does nothing, a drag
// pans a zoomed picture within its edges and does nothing at fit, a double click goes to the pixels one to one and
// back, a trackpad pinch zooms around the fingers, the keys + - 0 1 and the arrows, and the level that shows for a
// moment.

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/window/desktop_photo_zoom.dart';

/// A window of 800 x 600 at a pixel ratio of 1, a picture of 4000 x 2000 pixels: fitted 800 x 400, one to one at 5
const _window = Size(800, 600);
const _pixels = Size(4000, 2000);

void main() {
  DesktopZoomFrame frame() => DesktopZoomFrame.of(
    viewport: _window,
    picture: const Size(800, 400),
    fitScale: 1,
    devicePixelRatio: 1,
    originalPixels: _pixels,
  );

  /// Where the point of the picture under [screen] (from the middle of the window) is, at scale 1 from its middle
  Offset pictureAt(Offset screen, double scale, Offset position) => (screen - position) / scale;

  group('the geometry', () {
    test('one to one, the fit and the largest scale', () {
      final f = frame();
      expect(f.fitScale, 1);
      expect(f.oneToOneScale, closeTo(5, 1e-9));
      expect(f.maxScale, closeTo(5 * desktopZoomBeyondOneToOne, 1e-9));
      // A small picture still zooms: 4 times its fit
      final small = DesktopZoomFrame.of(
        viewport: _window,
        picture: const Size(800, 400),
        fitScale: 1,
        devicePixelRatio: 1,
        originalPixels: const Size(100, 50),
      );
      expect(small.maxScale, closeTo(desktopZoomMinRange, 1e-9));
      // The screen at 200 %: the pixels one to one need half the scale
      final retina = DesktopZoomFrame.of(
        viewport: _window,
        picture: const Size(800, 400),
        fitScale: 1,
        devicePixelRatio: 2,
        originalPixels: _pixels,
      );
      expect(retina.oneToOneScale, closeTo(2.5, 1e-9));
      // A cap of the view wins
      final capped = DesktopZoomFrame.of(
        viewport: _window,
        picture: const Size(800, 400),
        fitScale: 1,
        devicePixelRatio: 1,
        originalPixels: _pixels,
        cap: 8,
      );
      expect(capped.maxScale, 8);
    });

    test('a zoom around a point keeps that point of the picture under it', () {
      final f = frame();
      const focal = Offset(250, -120);
      final before = pictureAt(focal, 1, Offset.zero);
      final next = desktopZoomAround(f, 1, Offset.zero, 3, focal);
      expect(next.scale, 3);
      final after = pictureAt(focal, next.scale, next.position);
      expect(after.dx, closeTo(before.dx, 1e-9));
      expect(after.dy, closeTo(before.dy, 1e-9));
    });

    test('never past the edges, never under the fit nor past the largest scale', () {
      final f = frame();
      // At 2: the picture is 1600 x 800 in a window of 800 x 600, so 400 and 100 at most each way
      expect(desktopZoomClamp(f, 2, const Offset(5000, -5000)), const Offset(400, -100));
      // At the fit the picture is narrower than the window on no axis but its height: in the middle
      expect(desktopZoomClamp(f, 1, const Offset(30, 30)), Offset.zero);
      expect(desktopZoomAround(f, 2, const Offset(100, 50), 0.2, Offset.zero), (scale: 1.0, position: Offset.zero));
      expect(desktopZoomAround(f, 2, Offset.zero, 1000, Offset.zero).scale, f.maxScale);
    });
  });

  group('the keys', () {
    test('+ - 0 1, the arrows and Escape; nothing while typing', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      DesktopZoomKey? of(LogicalKeyboardKey key, {String? character, bool typing = false}) => desktopZoomKeyOf(
        KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: key,
          character: character,
          timeStamp: Duration.zero,
        ),
        typing: typing,
      );
      expect(of(LogicalKeyboardKey.numpadAdd), DesktopZoomKey.zoomIn);
      expect(of(LogicalKeyboardKey.equal, character: '='), DesktopZoomKey.zoomIn);
      expect(of(LogicalKeyboardKey.minus, character: '-'), DesktopZoomKey.zoomOut);
      expect(of(LogicalKeyboardKey.digit0, character: '0'), DesktopZoomKey.fit);
      expect(of(LogicalKeyboardKey.numpad1), DesktopZoomKey.oneToOne);
      expect(of(LogicalKeyboardKey.arrowRight), DesktopZoomKey.panRight);
      expect(of(LogicalKeyboardKey.escape), DesktopZoomKey.escape);
      expect(of(LogicalKeyboardKey.digit1, character: '1', typing: true), isNull);
      expect(of(LogicalKeyboardKey.keyA, character: 'a'), isNull);
      // The page keys of a TV remote zoom there only: on a computer they keep their meaning (repair round of 53)
      expect(of(LogicalKeyboardKey.pageUp), isNull);
      expect(of(LogicalKeyboardKey.pageDown), isNull);
      expect(of(LogicalKeyboardKey.channelUp), isNull);
    });

    test('the zoom keys are always taken, the arrows and Escape only once zoomed in', () {
      final target = DesktopZoomController()..layout(frame());
      addTearDown(target.dispose);
      expect(desktopZoomApplyKey(target, DesktopZoomKey.panLeft, animate: false), isFalse);
      expect(desktopZoomApplyKey(target, DesktopZoomKey.escape, animate: false), isFalse);
      expect(desktopZoomApplyKey(target, DesktopZoomKey.zoomOut, animate: false), isTrue);
      expect(target.scale, 1);
      expect(desktopZoomApplyKey(target, DesktopZoomKey.zoomIn, animate: false), isTrue);
      expect(target.scale, closeTo(desktopZoomKeyStep, 1e-9));
      expect(desktopZoomApplyKey(target, DesktopZoomKey.oneToOne, animate: false), isTrue);
      expect(target.scale, closeTo(5, 1e-9));
      // The arrow to the right shows more of the right side: the picture moves left
      expect(desktopZoomApplyKey(target, DesktopZoomKey.panRight, animate: false), isTrue);
      expect(target.position.dx, closeTo(-_window.width * desktopZoomPanShare, 1e-9));
      expect(desktopZoomApplyKey(target, DesktopZoomKey.escape, animate: false), isTrue);
      expect(target.scale, 1);
      expect(target.position, Offset.zero);
      expect(desktopZoomApplyKey(target, DesktopZoomKey.escape, animate: false), isFalse);
    });
  });

  group('the mouse and the trackpad', () {
    late DesktopZoomController controller;

    setUp(() => controller = DesktopZoomController());
    tearDown(() => controller.dispose());

    Future<void> pumpView(WidgetTester tester) async {
      tester.view.physicalSize = _window;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopZoomView(
            controller: controller,
            pixelSize: _pixels,
            child: const ColoredBox(key: Key('picture'), color: Colors.blue),
          ),
        ),
      );
    }

    Offset middle(WidgetTester tester) => tester.getCenter(find.byType(DesktopZoomView));

    Future<void> wheel(WidgetTester tester, Offset at, double dy, {double dx = 0}) async {
      final mouse = TestPointer(41, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(at));
      await tester.sendEventToBinding(mouse.scroll(Offset(dx, dy)));
      await tester.pump();
    }

    testWidgets('the wheel zooms around the pointer and keeps that point under it', (tester) async {
      await pumpView(tester);
      // On the middle line: the picture, lower than the window, stays in its middle up and down until it fills it
      final at = middle(tester) + const Offset(200, 0);
      final focal = at - middle(tester);
      for (var i = 0; i < 5; i++) {
        await wheel(tester, at, -100);
      }
      const expected = 1 / (0.9 * 0.9 * 0.9 * 0.9 * 0.9);
      expect(controller.scale, closeTo(expected, 1e-6));
      final after = pictureAt(focal, controller.scale, controller.position);
      expect(after.dx, closeTo(focal.dx, 1e-6));
      expect(after.dy, closeTo(focal.dy, 1e-6));
      // The level, as a share of the pixels of the original: 1.69 of the fit, which shows a fifth of them
      expect(tester.widget<AnimatedOpacity>(find.byKey(const Key('desktop_zoom_level'))).opacity, 1);
      expect(find.text('34%'), findsOneWidget);
      await tester.pump(desktopZoomIndicatorFor + const Duration(milliseconds: 50));
      expect(tester.widget<AnimatedOpacity>(find.byKey(const Key('desktop_zoom_level'))).opacity, 0);
      // Out again to the fit, then nothing more
      for (var i = 0; i < 10; i++) {
        await wheel(tester, at, 100);
      }
      expect(controller.scale, 1);
      expect(controller.position, Offset.zero);
    });

    testWidgets('out at fit does nothing; a sideways wheel pans only a zoomed picture', (tester) async {
      await pumpView(tester);
      await wheel(tester, middle(tester), 100);
      expect(controller.scale, 1);
      expect(
        tester.widget<AnimatedOpacity>(find.byKey(const Key('desktop_zoom_level'))).opacity,
        0,
        reason: 'no level for a wheel that changed nothing',
      );
      await wheel(tester, middle(tester), 0, dx: 50);
      expect(controller.position, Offset.zero);
      controller.apply(2, Offset.zero);
      await wheel(tester, middle(tester), 0, dx: 50);
      expect(controller.position, const Offset(-50, 0));
    });

    testWidgets('a drag at fit does not pan; zoomed in, it pans within the edges with a grab cursor', (tester) async {
      await pumpView(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: middle(tester));
      await mouse.down(middle(tester));
      await mouse.moveBy(const Offset(120, 40));
      await mouse.up();
      await tester.pump();
      expect(controller.position, Offset.zero);

      controller.apply(2, Offset.zero);
      await tester.pump();
      MouseCursor cursor() => tester
          .widget<MouseRegion>(
            find.descendant(of: find.byType(DesktopPhotoZoom), matching: find.byType(MouseRegion)).first,
          )
          .cursor;
      expect(cursor(), SystemMouseCursors.grab);
      await mouse.down(middle(tester));
      await tester.pump();
      expect(cursor(), SystemMouseCursors.grabbing);
      await mouse.moveBy(const Offset(120, 40));
      await tester.pump();
      expect(controller.position, const Offset(120, 40));
      // Far past the edges: 400 and 100 at most at scale 2
      await mouse.moveBy(const Offset(2000, 2000));
      await mouse.up();
      await tester.pump();
      expect(controller.position, const Offset(400, 100));
      expect(cursor(), SystemMouseCursors.grab);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a double click shows the pixels one to one around the click, then the whole picture', (tester) async {
      await pumpView(tester);
      final at = middle(tester) + const Offset(-100, 50);
      Future<void> doubleClick() async {
        await tester.tapAt(at, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tapAt(at, kind: PointerDeviceKind.mouse);
        await tester.pump();
        await tester.pump(desktopZoomAnimation + const Duration(milliseconds: 20));
      }

      await doubleClick();
      expect(controller.scale, closeTo(5, 1e-6));
      final under = pictureAt(at - middle(tester), controller.scale, controller.position);
      expect(under.dx, closeTo(-100, 1e-6));
      expect(under.dy, closeTo(50, 1e-6));
      expect(find.text('100%'), findsOneWidget);

      await doubleClick();
      expect(controller.scale, 1);
      expect(controller.position, Offset.zero);
    });

    testWidgets('a trackpad pinch zooms around the fingers, two fingers pan once zoomed', (tester) async {
      await pumpView(tester);
      final trackpad = TestPointer(42, PointerDeviceKind.trackpad);
      final at = middle(tester) + const Offset(100, -60);
      await tester.sendEventToBinding(trackpad.panZoomStart(at));
      await tester.sendEventToBinding(trackpad.panZoomUpdate(at, scale: 2));
      await tester.sendEventToBinding(trackpad.panZoomUpdate(at, scale: 3));
      await tester.sendEventToBinding(trackpad.panZoomEnd());
      await tester.pump();
      expect(controller.scale, closeTo(3, 1e-6));
      final under = pictureAt(at - middle(tester), controller.scale, controller.position);
      expect(under.dx, closeTo(100, 1e-6));
      expect(under.dy, closeTo(-60, 1e-6));
      final before = controller.position;
      await tester.sendEventToBinding(trackpad.panZoomStart(at));
      await tester.sendEventToBinding(trackpad.panZoomUpdate(at, pan: const Offset(-30, 10)));
      await tester.sendEventToBinding(trackpad.panZoomEnd());
      await tester.pump();
      expect(controller.position, before + const Offset(-30, 10));
    });

    testWidgets('a new window keeps the zoom relative to the fit', (tester) async {
      await pumpView(tester);
      controller.apply(2, const Offset(100, 0));
      tester.view.physicalSize = const Size(400, 300);
      await tester.pump();
      expect(controller.frame!.viewport, const Size(400, 300));
      expect(controller.scale, 2);
      expect(controller.position, const Offset(100, 0));
    });
  });
}
