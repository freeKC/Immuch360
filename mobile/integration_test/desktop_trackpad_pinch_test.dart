// The pinch of a touchpad and Control with the wheel on a photo, in a built app (28 November 2026): the real Windows
// engine, its window and its pointer converter, under the photo as the asset viewer lays it out (the pages of the
// photos, PhotoView with the vertical drag of the details and of the closing, the desktop zoom over it).
//
// - A pinch of a precision touchpad cannot be made on a hosted runner: Windows has no API that injects touchpad
//   contacts (CreateSyntheticPointerDevice knows touch and pen only), and a virtual precision touchpad needs a signed
//   driver and a restart. So its packets are those the engine sends for one (flutter 3.47 direct_manipulation.cc and
//   flutter_windows_view.cc: an add, a pan and zoom start at the pointer, reports of the scale and of the content's
//   translation in physical pixels, an end), given to the engine's own entry of pointer packets
//   (PlatformDispatcher.onPointerDataPacket), the translation being the one of a content scaled around the pointer.
// - Control and the wheel, as a touchpad without a precision driver sends its pinch, are real input: SendInput moves
//   the pointer over the photo, holds Control and turns the wheel three notches. If no event of it reaches the app
//   (a runner whose session takes no input) the check says so and is skipped, never passed.
// Run in the Windows build job of the desktop workflow:
//   flutter test integration_test/desktop_trackpad_pinch_test.dart -d windows

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/window/desktop_photo_zoom.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // The real input of the system goes to the widgets, not only to the pointer drawn by the test binding
  binding.shouldPropagateDevicePointerEvents = true;

  late List<PhotoViewZoomTarget> targets;
  late PageController pages;
  var verticalDrags = 0;
  var wheelEvents = 0;

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() done, {
    Duration limit = const Duration(seconds: 10),
  }) async {
    final watch = Stopwatch()..start();
    while (!done() && watch.elapsed < limit) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  }

  Future<void> pumpPhotos(WidgetTester tester) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 1600, 800), Paint()..color = const Color(0xFF3366CC));
    final image = await recorder.endRecording().toImage(1600, 800);
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    image.dispose();
    targets = [for (var i = 0; i < 3; i++) PhotoViewZoomTarget()];
    pages = PageController();
    verticalDrags = 0;
    wheelEvents = 0;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              wheelEvents++;
            }
          },
          child: PageView.builder(
            controller: pages,
            itemCount: targets.length,
            itemBuilder: (context, index) => DesktopPhotoZoom(
              target: targets[index],
              child: PhotoView(
                imageProvider: MemoryImage(png),
                index: index,
                tightMode: true,
                enablePanAlways: true,
                maxScale: 12.0,
                desktopZoom: true,
                onPageBuild: targets[index].attach,
                // As the asset viewer: a vertical drag for its details and to close it
                onDragStart: (_, _, _, _) => verticalDrags++,
                onDragUpdate: (_, _, _) {},
                onDragEnd: (_, _, _) {},
              ),
            ),
          ),
        ),
      ),
    );
    await waitFor(tester, () => targets.first.frame != null);
    expect(targets.first.frame, isNotNull, reason: 'the photo decoded and laid out');
  }

  double zoomOf(PhotoViewZoomTarget target) => target.scale / target.frame!.fitScale;

  var pointer = 7000;

  /// The packets of the Windows engine for one touchpad gesture at [at] (logical): the content's translation of a
  /// DirectManipulation content scaled around the pointer, in physical pixels, and the scale since the start
  Future<void> sendEnginePanZoom(WidgetTester tester, Offset at, List<({Offset pan, double scale})> steps) async {
    final view = tester.view;
    final ratio = view.devicePixelRatio;
    final id = pointer++;
    final physical = at * ratio;
    var stamp = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch % 1000000);
    ui.PointerData datum(
      ui.PointerChange change, {
      Offset pan = Offset.zero,
      Offset delta = Offset.zero,
      double scale = 1,
    }) => ui.PointerData(
      viewId: view.viewId,
      timeStamp: stamp,
      change: change,
      kind: PointerDeviceKind.trackpad,
      device: 0x7FFF0000 + id,
      pointerIdentifier: id,
      physicalX: physical.dx,
      physicalY: physical.dy,
      panX: pan.dx,
      panY: pan.dy,
      panDeltaX: delta.dx,
      panDeltaY: delta.dy,
      scale: scale,
    );
    void send(List<ui.PointerData> data) =>
        ui.PlatformDispatcher.instance.onPointerDataPacket!(ui.PointerDataPacket(data: data));
    send([datum(ui.PointerChange.add), datum(ui.PointerChange.panZoomStart)]);
    var previous = Offset.zero;
    for (final step in steps) {
      stamp += const Duration(milliseconds: 14);
      final pan = step.pan * ratio;
      send([datum(ui.PointerChange.panZoomUpdate, pan: pan, delta: pan - previous, scale: step.scale)]);
      previous = pan;
      await Future<void>.delayed(const Duration(milliseconds: 14));
      await tester.pump();
    }
    stamp += const Duration(milliseconds: 14);
    send([datum(ui.PointerChange.panZoomEnd, pan: previous), datum(ui.PointerChange.remove)]);
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pump();
  }

  List<({Offset pan, double scale})> windowsPinch(double to, Offset anchor) {
    const early = [1.0, 1.002, 1.006, 1.012];
    final scales = [...early, for (var i = 1; i <= 26; i++) early.last * math.pow(to / early.last, i / 26).toDouble()];
    return [for (final scale in scales) (pan: anchor * (1 - scale), scale: scale)];
  }

  testWidgets('the engine\'s packets of a pinch zoom the photo two times; no drag, no page turn', (tester) async {
    await pumpPhotos(tester);
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    final at = Offset(size.width / 2, size.height * 0.75);
    await sendEnginePanZoom(tester, at, windowsPinch(2, at));
    // ignore: avoid_print
    print(
      'PINCH engine packets: zoom ${zoomOf(targets.first).toStringAsFixed(3)}, page ${pages.page}, '
      'vertical drags $verticalDrags, window $size at ${tester.view.devicePixelRatio}',
    );
    expect(zoomOf(targets.first), closeTo(2, 0.02));
    expect(pages.page, 0);
    expect(verticalDrags, 0);
    // At fit, two fingers that scroll still turn the page
    targets.first.apply(targets.first.frame!.fitScale, Offset.zero);
    await tester.pump();
    await sendEnginePanZoom(tester, at, [for (var i = 1; i <= 20; i++) (pan: Offset(-15.0 * i, 0), scale: 1.0)]);
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('PINCH engine packets: two finger scroll left at fit, page ${pages.page}');
    expect(pages.page, 1);
  }, skip: !Platform.isWindows);

  testWidgets('Control and three notches of the wheel by SendInput zoom the photo in', (tester) async {
    await pumpPhotos(tester);
    final window = _flutterWindow();
    if (window == null) {
      markTestSkipped('the window of the app was not found');
      return;
    }
    final ratio = tester.view.devicePixelRatio;
    final size = tester.view.physicalSize / ratio;
    final middle = _toScreen(window.view, Offset(size.width / 2, size.height / 2) * ratio);
    final controls = <bool>[];
    bool onKey(KeyEvent event) {
      if (event.logicalKey == LogicalKeyboardKey.controlLeft) {
        controls.add(event is KeyDownEvent);
      }
      return false;
    }

    HardwareKeyboard.instance.addHandler(onKey);
    try {
      _user32.setForeground(window.top);
      _user32.setCursorPos(middle.x, middle.y);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      final sent = <int>[_sendKey(_vkControl, up: false)];
      await Future<void>.delayed(const Duration(milliseconds: 100));
      for (var notch = 0; notch < 3; notch++) {
        sent.add(_sendWheel(120));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await tester.pump();
      }
      sent.add(_sendKey(_vkControl, up: true));
      await waitFor(tester, () => wheelEvents >= 3, limit: const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      // ignore: avoid_print
      print(
        'PINCH SendInput: inputs sent $sent, wheel events seen $wheelEvents, Control seen $controls, zoom '
        '${zoomOf(targets.first).toStringAsFixed(3)}, cursor at $middle',
      );
      if (wheelEvents == 0) {
        markTestSkipped('SendInput reached nothing: this session takes no input');
        return;
      }
      expect(controls, contains(true), reason: 'Control was held');
      expect(zoomOf(targets.first), greaterThan(1.3), reason: 'three notches of 11 %');
      expect(pages.page, 0);
    } finally {
      HardwareKeyboard.instance.removeHandler(onKey);
    }
  }, skip: !Platform.isWindows);
}

// user32 by FFI, x64: the window of the app, the pointer and SendInput

const _vkControl = 0x11;

class _User32 {
  _User32() : _library = DynamicLibrary.open('user32.dll');

  final DynamicLibrary _library;

  late final findWindow = _library
      .lookupFunction<IntPtr Function(Pointer<Utf16>, Pointer<Utf16>), int Function(Pointer<Utf16>, Pointer<Utf16>)>(
        'FindWindowW',
      );
  late final findWindowEx = _library
      .lookupFunction<
        IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
        int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
      >('FindWindowExW');
  late final getForegroundWindow = _library.lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
  late final setForeground = _library.lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetForegroundWindow');
  late final setCursorPos = _library.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
    'SetCursorPos',
  );
  late final clientToScreen = _library
      .lookupFunction<Int32 Function(IntPtr, Pointer<Int32>), int Function(int, Pointer<Int32>)>('ClientToScreen');
  late final sendInput = _library
      .lookupFunction<Uint32 Function(Uint32, Pointer<Uint8>, Int32), int Function(int, Pointer<Uint8>, int)>(
        'SendInput',
      );
}

final _user32 = _User32();

/// The top window of the app (its debug class, then its release one, then the one in front) and the Flutter view in it
({int top, int view})? _flutterWindow() {
  int find(String name) {
    final className = name.toNativeUtf16();
    try {
      return _user32.findWindow(className, nullptr);
    } finally {
      malloc.free(className);
    }
  }

  var top = find('IMMUCH360_DESKTOP_DEBUG_WINDOW');
  if (top == 0) {
    top = find('IMMUCH360_DESKTOP_WINDOW');
  }
  if (top == 0) {
    top = _user32.getForegroundWindow();
  }
  if (top == 0) {
    return null;
  }
  final viewClass = 'FLUTTERVIEW'.toNativeUtf16();
  try {
    final view = _user32.findWindowEx(top, 0, viewClass, nullptr);
    return (top: top, view: view == 0 ? top : view);
  } finally {
    malloc.free(viewClass);
  }
}

/// [client] (physical pixels of [window]) on the screen
({int x, int y}) _toScreen(int window, Offset client) {
  final point = malloc<Int32>(2);
  try {
    point[0] = client.dx.round();
    point[1] = client.dy.round();
    _user32.clientToScreen(window, point);
    return (x: point[0], y: point[1]);
  } finally {
    malloc.free(point);
  }
}

/// One INPUT of 40 bytes: its type, then its MOUSEINPUT or KEYBDINPUT from byte 8
int _send(void Function(Pointer<Uint8> input) fill) {
  const size = 40;
  final input = calloc<Uint8>(size);
  try {
    fill(input);
    return _user32.sendInput(1, input, size);
  } finally {
    calloc.free(input);
  }
}

/// A notch of the wheel, [delta] 120 away from the user (which scrolls up and zooms in)
int _sendWheel(int delta) => _send((input) {
  final words = input.cast<Int32>();
  words[0] = 0; // INPUT_MOUSE
  words[4] = delta; // mouseData, byte 16
  words[5] = 0x0800; // MOUSEEVENTF_WHEEL, byte 20
});

int _sendKey(int key, {required bool up}) => _send((input) {
  input.cast<Int32>()[0] = 1; // INPUT_KEYBOARD
  (input + 8).cast<Uint16>()[0] = key; // wVk
  (input + 12).cast<Uint32>()[0] = up ? 0x0002 : 0; // KEYEVENTF_KEYUP
});
