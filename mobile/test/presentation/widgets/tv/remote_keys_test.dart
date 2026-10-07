// The keys of a remote control and how fast the arrows turn a 360° view: a short press nudges it, holding speeds up
// to a third of a turn per second, and a zoomed in view turns slower.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';

void main() {
  group('remoteTurnSpeed', () {
    test('starts at 40 degrees per second, and reaches 120 after half a second', () {
      expect(remoteTurnSpeed(0, 90), 40);
      expect(remoteTurnSpeed(0.25, 90), 80);
      expect(remoteTurnSpeed(0.5, 90), 120);
      expect(remoteTurnSpeed(5, 90), 120);
    });

    test('a frame that comes a little before the key went down counts as the start', () {
      expect(remoteTurnSpeed(-0.01, 90), 40);
    });

    test('scales with the field of view: a zoomed in view turns slower', () {
      expect(remoteTurnSpeed(5, 45), 60);
      expect(remoteTurnSpeed(5, 15), closeTo(20, 1e-9));
      expect(remoteTurnSpeed(0, 115), closeTo(40 * 115 / 90, 1e-9));
    });

    test('up and down at three quarters', () {
      expect(remotePitchFactor, 0.75);
    });
  });

  group('the keys', () {
    test('OK is the centre of the D-pad, Enter and the A button', () {
      expect(
        remoteOkKeys,
        containsAll([LogicalKeyboardKey.select, LogicalKeyboardKey.enter, LogicalKeyboardKey.gameButtonA]),
      );
      expect(remoteOkKeys, isNot(contains(LogicalKeyboardKey.space)));
    });

    test('channel up and down zoom, as the zoom and page keys and the shoulders of a game pad', () {
      expect(remoteZoomInKeys, containsAll([LogicalKeyboardKey.channelUp, LogicalKeyboardKey.zoomIn]));
      expect(remoteZoomInKeys, containsAll([LogicalKeyboardKey.pageUp, LogicalKeyboardKey.gameButtonRight1]));
      expect(remoteZoomOutKeys, containsAll([LogicalKeyboardKey.channelDown, LogicalKeyboardKey.zoomOut]));
      expect(remoteZoomOutKeys, containsAll([LogicalKeyboardKey.pageDown, LogicalKeyboardKey.gameButtonLeft1]));
      expect(remoteZoomInKeys.intersection(remoteZoomOutKeys), isEmpty);
    });

    test('the play and pause keys: the toggle toggles, play plays and pause pauses', () {
      expect(remotePlayPauseWantsPlay(LogicalKeyboardKey.mediaPlayPause, isPlaying: true), isFalse);
      expect(remotePlayPauseWantsPlay(LogicalKeyboardKey.mediaPlayPause, isPlaying: false), isTrue);
      expect(remotePlayPauseWantsPlay(LogicalKeyboardKey.mediaPlay, isPlaying: true), isTrue);
      expect(remotePlayPauseWantsPlay(LogicalKeyboardKey.mediaPause, isPlaying: false), isFalse);
    });

    test('a press is the key going down, never its repeat nor its release', () {
      const key = LogicalKeyboardKey.arrowRight;
      const physical = PhysicalKeyboardKey.arrowRight;
      expect(
        isRemotePress(const KeyDownEvent(physicalKey: physical, logicalKey: key, timeStamp: Duration.zero)),
        isTrue,
      );
      expect(
        isRemotePress(const KeyRepeatEvent(physicalKey: physical, logicalKey: key, timeStamp: Duration.zero)),
        isFalse,
      );
      expect(
        isRemotePress(const KeyUpEvent(physicalKey: physical, logicalKey: key, timeStamp: Duration.zero)),
        isFalse,
      );
    });

    test('left and right seek by 10 s', () {
      expect(remoteSeekStep, const Duration(seconds: 10));
    });
  });
}
