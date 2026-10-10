// When the controls of the 360° player of the computers show (spherical_controls.dart, design 4.3): for 3 s after a
// move or a key while the video plays, with the cursor hidden after; all the time while it does not play, while the
// pointer is over them and while one of them has the keyboard focus; hidden during a drag; a click on the view shows
// or hides them.

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/spherical_controls.dart';

void main() {
  group('the controls', () {
    test('shown while the video does not play, hidden 3 s after the last move once it plays', () {
      fakeAsync((async) {
        final controls = SphericalControlsVisibility();
        var changes = 0;
        controls.addListener(() => changes++);
        expect(controls.visible, isTrue);
        async.elapse(const Duration(seconds: 10));
        expect(controls.visible, isTrue, reason: 'loading or paused: they stay');

        controls.playing = true;
        async.elapse(const Duration(seconds: 2));
        expect(controls.visible, isTrue);
        controls.activity();
        async.elapse(const Duration(seconds: 2));
        expect(controls.visible, isTrue, reason: 'the move restarted the 3 s');
        async.elapse(const Duration(seconds: 1));
        expect(controls.visible, isFalse);
        expect(controls.cursorHidden, isTrue);

        controls.playing = false;
        expect(controls.visible, isTrue, reason: 'paused: they come back');
        expect(changes, greaterThanOrEqualTo(2));
        controls.dispose();
      });
    });

    test('kept while the pointer is over them or a control has the focus', () {
      fakeAsync((async) {
        final controls = SphericalControlsVisibility()..playing = true;
        controls.hovered = true;
        async.elapse(const Duration(seconds: 10));
        expect(controls.visible, isTrue);
        controls.hovered = false;
        async.elapse(const Duration(seconds: 2));
        expect(controls.visible, isTrue, reason: 'leaving them counts as a move');
        async.elapse(const Duration(seconds: 1));
        expect(controls.visible, isFalse);

        controls.focused = true;
        expect(controls.visible, isTrue);
        async.elapse(const Duration(seconds: 10));
        expect(controls.visible, isTrue, reason: 'a control reached with Tab never disappears');
        controls.focused = false;
        expect(controls.visible, isFalse);
        controls.dispose();
      });
    });

    test('hidden during a drag; a click shows them, a second one hides them', () {
      fakeAsync((async) {
        final controls = SphericalControlsVisibility()..playing = true;
        controls.dragStarted();
        expect(controls.visible, isFalse);
        controls.dragEnded();
        expect(controls.visible, isFalse, reason: 'a drag is no move of the pointer over the controls');

        controls.toggle();
        expect(controls.visible, isTrue);
        controls.toggle();
        expect(controls.visible, isFalse);

        // Paused, a click does not hide them
        controls.playing = false;
        controls.toggle();
        expect(controls.visible, isTrue);
        controls.dispose();
      });
    });

    test('the time as the players write it, and the keys that show the controls', () {
      expect(formatPlayerTime(const Duration(seconds: 5)), '0:05');
      expect(formatPlayerTime(const Duration(minutes: 12, seconds: 34)), '12:34');
      expect(formatPlayerTime(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
      const key = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyJ,
        logicalKey: LogicalKeyboardKey.keyJ,
        timeStamp: Duration.zero,
      );
      expect(showsControls(key), isTrue);
      const shift = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.shiftLeft,
        logicalKey: LogicalKeyboardKey.shiftLeft,
        timeStamp: Duration.zero,
      );
      expect(showsControls(shift), isFalse);
    });
  });
}
