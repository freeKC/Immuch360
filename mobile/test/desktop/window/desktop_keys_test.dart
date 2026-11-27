// The keys a computer adds to those of a remote control (design 4.1 and 4.2): plus and minus by the character typed
// whatever the layout, letters only while no text field has the keyboard, the window keys of the shell (select all
// among them), the back button of a mouse. The phones keep their sets unchanged.

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/window/desktop_shortcuts.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';

const _desktops = [TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux];

KeyDownEvent _down(LogicalKeyboardKey logical, {String? character, PhysicalKeyboardKey? physical}) => KeyDownEvent(
  physicalKey: physical ?? PhysicalKeyboardKey.keyA,
  logicalKey: logical,
  character: character,
  timeStamp: Duration.zero,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('the phones', () {
    test('keep the zoom keys of a remote, unchanged', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(remoteZoomInKeys, {
        LogicalKeyboardKey.channelUp,
        LogicalKeyboardKey.zoomIn,
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.gameButtonRight1,
      });
      expect(remoteZoomOutKeys, {
        LogicalKeyboardKey.channelDown,
        LogicalKeyboardKey.zoomOut,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.gameButtonLeft1,
      });
    });

    test('keep the seek and details keys of a remote, without letters', () {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(remoteSeekForwardKeys, {LogicalKeyboardKey.mediaFastForward}, reason: platform.name);
        expect(remoteSeekBackwardKeys, {LogicalKeyboardKey.mediaRewind}, reason: platform.name);
        expect(remoteDetailsKeys, {LogicalKeyboardKey.info, LogicalKeyboardKey.contextMenu}, reason: platform.name);
      }
    });

    test('have no key for the first and the last item', () {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(remoteFirstItemKeys, isEmpty, reason: platform.name);
        expect(remoteLastItemKeys, isEmpty, reason: platform.name);
      }
    });

    test('zoom by key only: a typed "+" or "-" is no zoom key there', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(isRemoteZoomIn(_down(LogicalKeyboardKey.channelUp)), isTrue);
      expect(isRemoteZoomOut(_down(LogicalKeyboardKey.pageDown)), isTrue);
      expect(isRemoteZoomIn(_down(LogicalKeyboardKey.equal, character: '+')), isFalse);
      expect(isRemoteZoomOut(_down(LogicalKeyboardKey.digit6, character: '-')), isFalse);
    });
  });

  group('a computer', () {
    test('adds + = and - of the keyboard and of the number pad to the zoom keys', () {
      for (final platform in _desktops) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          remoteZoomInKeys,
          containsAll([
            LogicalKeyboardKey.pageUp,
            LogicalKeyboardKey.add,
            LogicalKeyboardKey.equal,
            LogicalKeyboardKey.numpadAdd,
          ]),
        );
        expect(
          remoteZoomOutKeys,
          containsAll([LogicalKeyboardKey.pageDown, LogicalKeyboardKey.minus, LogicalKeyboardKey.numpadSubtract]),
        );
        expect(remoteZoomInKeys.intersection(remoteZoomOutKeys), isEmpty);
      }
    });

    test('zooms by the character typed, so that AZERTY and QWERTZ work as QWERTY does', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      // AZERTY: "+" is Shift and the "=" key, "-" is the "6" key of the main row
      expect(isRemoteZoomIn(_down(LogicalKeyboardKey.equal, character: '+')), isTrue);
      expect(isRemoteZoomOut(_down(LogicalKeyboardKey.digit6, character: '-')), isTrue);
      // QWERTZ: "+" has a key of its own, whatever logical key the embedder gives it
      expect(isRemoteZoomIn(_down(LogicalKeyboardKey.bracketRight, character: '+')), isTrue);
      // The number pad
      expect(isRemoteZoomIn(_down(LogicalKeyboardKey.numpadAdd)), isTrue);
      expect(isRemoteZoomOut(_down(LogicalKeyboardKey.numpadSubtract)), isTrue);
      // "6" itself is no zoom key
      expect(isRemoteZoomOut(_down(LogicalKeyboardKey.digit6, character: '6')), isFalse);
      expect(isRemoteZoomIn(_down(LogicalKeyboardKey.digit6, character: '6')), isFalse);
    });

    test('adds L, J and I while no text field has the keyboard', () {
      for (final platform in _desktops) {
        debugDefaultTargetPlatformOverride = platform;
        expect(remoteSeekForwardKeys, {LogicalKeyboardKey.mediaFastForward, LogicalKeyboardKey.keyL});
        expect(remoteSeekBackwardKeys, {LogicalKeyboardKey.mediaRewind, LogicalKeyboardKey.keyJ});
        expect(remoteDetailsKeys, {LogicalKeyboardKey.info, LogicalKeyboardKey.keyI});
      }
    });

    test('adds Home and End for the first and the last item', () {
      for (final platform in _desktops) {
        debugDefaultTargetPlatformOverride = platform;
        expect(remoteFirstItemKeys, {LogicalKeyboardKey.home}, reason: platform.name);
        expect(remoteLastItemKeys, {LogicalKeyboardKey.end}, reason: platform.name);
      }
    });

    testWidgets('leaves the letters to a text field that has the keyboard', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final field = FocusNode();
      final button = FocusNode();
      addTearDown(field.dispose);
      addTearDown(button.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: Column(
              children: [
                TextField(focusNode: field),
                TextButton(focusNode: button, onPressed: () {}, child: const Text('button')),
              ],
            ),
          ),
        ),
      );

      field.requestFocus();
      await tester.pump();
      expect(isTypingText(), isTrue);
      expect(remoteSeekForwardKeys, {LogicalKeyboardKey.mediaFastForward});
      expect(remoteSeekBackwardKeys, {LogicalKeyboardKey.mediaRewind});
      expect(remoteDetailsKeys, {LogicalKeyboardKey.info});

      button.requestFocus();
      await tester.pump();
      expect(isTypingText(), isFalse);
      expect(remoteDetailsKeys, contains(LogicalKeyboardKey.keyI));
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('the window keys', () {
    test('F11 and Escape anywhere, F alone and only while not typing', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(desktopWindowKeyOf(_down(LogicalKeyboardKey.f11)), DesktopWindowKey.toggleFullScreen);
      expect(desktopWindowKeyOf(_down(LogicalKeyboardKey.escape)), DesktopWindowKey.escape);
      expect(
        desktopWindowKeyOf(_down(LogicalKeyboardKey.keyF, character: 'f'), typing: false),
        DesktopWindowKey.toggleFullScreenInViewer,
      );
      expect(desktopWindowKeyOf(_down(LogicalKeyboardKey.keyF, character: 'f'), typing: true), isNull);
      expect(desktopWindowKeyOf(_down(LogicalKeyboardKey.keyW, character: 'w'), typing: false), isNull);
    });

    test('a held key or a release toggles nothing', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      const repeat = KeyRepeatEvent(
        physicalKey: PhysicalKeyboardKey.f11,
        logicalKey: LogicalKeyboardKey.f11,
        timeStamp: Duration.zero,
      );
      const up = KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.f11,
        logicalKey: LogicalKeyboardKey.f11,
        timeStamp: Duration.zero,
      );
      expect(desktopWindowKeyOf(repeat), isNull);
      expect(desktopWindowKeyOf(up), isNull);
    });

    testWidgets('H starts or stops the headset view, Shift H recenters it, never while typing nor with Control', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final h = _down(LogicalKeyboardKey.keyH, character: 'h', physical: PhysicalKeyboardKey.keyH);
      expect(desktopWindowKeyOf(h, typing: false), DesktopWindowKey.toggleHeadsetView);
      expect(desktopWindowKeyOf(h, typing: true), isNull);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      expect(desktopWindowKeyOf(h, typing: false), DesktopWindowKey.recenterHeadsetView);
      expect(desktopWindowKeyOf(h, typing: true), isNull);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      expect(desktopWindowKeyOf(h, typing: false), isNull, reason: 'Control H is left to the pages');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Control F is left to the pages, Command W and Control Command F serve macOS', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      expect(desktopWindowKeyOf(_down(LogicalKeyboardKey.keyF), typing: false), isNull);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      expect(desktopWindowKeyOf(_down(LogicalKeyboardKey.keyW), typing: false), DesktopWindowKey.closeViewer);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      expect(desktopWindowKeyOf(_down(LogicalKeyboardKey.keyF), typing: false), DesktopWindowKey.toggleFullScreen);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Alt Left goes back on Windows and Linux, Command [ on macOS, never while typing', (tester) async {
      final left = _down(LogicalKeyboardKey.arrowLeft, physical: PhysicalKeyboardKey.arrowLeft);
      final bracket = _down(LogicalKeyboardKey.bracketLeft, character: '[', physical: PhysicalKeyboardKey.bracketLeft);
      for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          desktopWindowKeyOf(left, typing: false),
          isNull,
          reason: '${platform.name}: Left alone is the viewers\'',
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        expect(desktopWindowKeyOf(left, typing: false), DesktopWindowKey.back, reason: platform.name);
        expect(desktopWindowKeyOf(left, typing: true), isNull, reason: '${platform.name}: the field keeps it');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        expect(desktopWindowKeyOf(left, typing: false), isNull, reason: '${platform.name}: with Shift');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        expect(desktopWindowKeyOf(bracket, typing: false), isNull, reason: '${platform.name}: Control [');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      }

      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      expect(desktopWindowKeyOf(left, typing: false), isNull, reason: 'Option Left moves by word on macOS');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      expect(desktopWindowKeyOf(bracket, typing: false), DesktopWindowKey.back);
      expect(desktopWindowKeyOf(bracket, typing: true), isNull);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Control A selects all on Windows and Linux, Command A on macOS, never while typing', (tester) async {
      for (final platform in _desktops) {
        debugDefaultTargetPlatformOverride = platform;
        final mac = platform == TargetPlatform.macOS;
        final selectKey = mac ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
        final otherKey = mac ? LogicalKeyboardKey.controlLeft : LogicalKeyboardKey.metaLeft;
        final a = _down(LogicalKeyboardKey.keyA, character: 'a');
        expect(desktopWindowKeyOf(a, typing: false), isNull, reason: '${platform.name}: A alone');

        await tester.sendKeyDownEvent(selectKey);
        expect(desktopWindowKeyOf(a, typing: false), DesktopWindowKey.selectAll, reason: platform.name);
        expect(
          desktopWindowKeyOf(a, typing: true),
          isNull,
          reason: '${platform.name}: the text field selects its text',
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        expect(desktopWindowKeyOf(a, typing: false), isNull, reason: '${platform.name}: with Shift');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(selectKey);

        await tester.sendKeyDownEvent(otherKey);
        expect(desktopWindowKeyOf(a, typing: false), isNull, reason: '${platform.name}: the other modifier');
        await tester.sendKeyUpEvent(otherKey);
      }
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Control C copies on Windows and Linux, Command C on macOS, never while typing', (tester) async {
      for (final platform in _desktops) {
        debugDefaultTargetPlatformOverride = platform;
        final mac = platform == TargetPlatform.macOS;
        final copyKey = mac ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
        final otherKey = mac ? LogicalKeyboardKey.controlLeft : LogicalKeyboardKey.metaLeft;
        final c = _down(LogicalKeyboardKey.keyC, character: 'c');
        expect(desktopWindowKeyOf(c, typing: false), isNull, reason: '${platform.name}: C alone');

        await tester.sendKeyDownEvent(copyKey);
        expect(desktopWindowKeyOf(c, typing: false), DesktopWindowKey.copy, reason: platform.name);
        expect(desktopWindowKeyOf(c, typing: true), isNull, reason: '${platform.name}: the text field copies its text');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        expect(desktopWindowKeyOf(c, typing: false), isNull, reason: '${platform.name}: with Shift');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        expect(desktopWindowKeyOf(c, typing: false), isNull, reason: '${platform.name}: with Alt');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyUpEvent(copyKey);

        await tester.sendKeyDownEvent(otherKey);
        expect(desktopWindowKeyOf(c, typing: false), isNull, reason: '${platform.name}: the other modifier');
        await tester.sendKeyUpEvent(otherKey);
      }
      debugDefaultTargetPlatformOverride = null;
    });
  });

  test('the back button of a mouse, and no other button, goes back', () {
    expect(isMouseBackButton(const PointerDownEvent(kind: PointerDeviceKind.mouse, buttons: kBackMouseButton)), isTrue);
    expect(
      isMouseBackButton(const PointerDownEvent(kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton)),
      isFalse,
    );
    expect(
      isMouseBackButton(const PointerDownEvent(kind: PointerDeviceKind.mouse, buttons: kForwardMouseButton)),
      isFalse,
    );
  });

  test('a wheel notch up zooms in, down zooms out, a sideways scroll does nothing', () {
    expect(wheelZoomFactor(const PointerScrollEvent(scrollDelta: Offset(0, -100))), lessThan(1));
    expect(wheelZoomFactor(const PointerScrollEvent(scrollDelta: Offset(0, 100))), greaterThan(1));
    expect(wheelZoomFactor(const PointerScrollEvent(scrollDelta: Offset(40, 0))), isNull);
  });

  test('the wheel zooms in proportion to the move: small moves add up to one notch', () {
    const notch = 100.0;
    double factor(double dy) => wheelZoomFactor(PointerScrollEvent(scrollDelta: Offset(0, dy)), notch: notch)!;

    // One notch: 10 %
    expect(factor(-notch), closeTo(0.9, 1e-9));
    expect(factor(notch), closeTo(1 / 0.9, 1e-9));
    // A high resolution wheel sending a notch as four moves zooms as much as one notch, not four times as much
    final quarter = factor(-notch / 4);
    expect(quarter, greaterThan(0.9));
    expect(quarter * quarter * quarter * quarter, closeTo(0.9, 1e-9));
    // One large jump counts for three notches at most
    expect(factor(-notch * 20), closeTo(0.9 * 0.9 * 0.9, 1e-9));
    expect(factor(notch * 20), closeTo(1 / (0.9 * 0.9 * 0.9), 1e-9));
  });

  test('a notch is what the embedder of each computer sends, the scale of the screen included on Windows', () {
    expect(desktopWheelNotch(TargetPlatform.windows, 1), 100);
    // The internal panel of a laptop at 200 %: the same 100 physical pixels, so 50 logical ones
    expect(desktopWheelNotch(TargetPlatform.windows, 2), 50);
    expect(desktopWheelNotch(TargetPlatform.linux, 2), 53);
    expect(desktopWheelNotch(TargetPlatform.macOS, 2), 40);
  });

  testWidgets('one notch of Windows zooms 10 % on a screen at 100 % and at 200 %', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final ratio in [1.0, 2.0]) {
      tester.view.devicePixelRatio = ratio;
      // 100 physical pixels, as the event reaches the app: in logical pixels of the screen it comes from
      final event = PointerScrollEvent(viewId: tester.view.viewId, scrollDelta: Offset(0, -100 / ratio));
      expect(wheelZoomFactor(event), closeTo(0.9, 1e-9), reason: 'scale $ratio');
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('fewer animations asked by the system stop the inertia on a computer only', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Builder(
          builder: (built) {
            context = built;
            return const SizedBox();
          },
        ),
      ),
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(desktopReducedMotion(context), isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(desktopReducedMotion(context), isFalse);
    debugDefaultTargetPlatformOverride = null;
  });
}
