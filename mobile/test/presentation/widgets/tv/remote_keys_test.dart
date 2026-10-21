// The keys of a remote control and how fast the arrows turn a 360° view: a short press nudges it, holding speeds up
// to a third of a turn per second, and a zoomed in view turns slower. On a video, what left, right and OK do, and
// which keys bring its controls back on a TV.

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

    test('the seeks are 10 s, and the controls of a video hide after 5 s', () {
      expect(remoteSeekStep, const Duration(seconds: 10));
      expect(videoControlsHideAfter, const Duration(seconds: 5));
    });
  });

  group('left and right on a video', () {
    const navigate = RemoteVideoArrows.navigate;
    const seek = RemoteVideoArrows.seek;

    test('on a TV they go to the previous or next item whatever the video does', () {
      for (final playing in [true, false]) {
        expect(remoteVideoArrows(tvMode: true, playing: playing, hasNeighbours: true), navigate, reason: '$playing');
      }
    });

    test('on a TV a video without neighbours (a file opened on its own) seeks with them', () {
      for (final playing in [true, false]) {
        expect(remoteVideoArrows(tvMode: true, playing: playing, hasNeighbours: false), seek, reason: '$playing');
      }
    });

    test('elsewhere they seek while it plays and go to the previous or next item once paused, as before', () {
      for (final hasNeighbours in [true, false]) {
        expect(remoteVideoArrows(tvMode: false, playing: true, hasNeighbours: hasNeighbours), seek);
        expect(remoteVideoArrows(tvMode: false, playing: false, hasNeighbours: hasNeighbours), navigate);
      }
    });

    test('OK shows the controls on a TV, and plays or pauses elsewhere', () {
      expect(remoteVideoOkFocusesControls(tvMode: true), isTrue);
      expect(remoteVideoOkFocusesControls(tvMode: false), isFalse);
    });
  });

  group('the keys that bring back the controls of a video on a TV', () {
    test('any key: OK, the media keys, up and down, the channels, the colours, the numbers', () {
      for (final key in [
        LogicalKeyboardKey.select,
        LogicalKeyboardKey.mediaPlayPause,
        LogicalKeyboardKey.mediaFastForward,
        LogicalKeyboardKey.mediaRewind,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.channelUp,
        LogicalKeyboardKey.colorF0Red,
        LogicalKeyboardKey.digit1,
      ]) {
        expect(remoteKeyShowsVideoControls(key), isTrue, reason: key.debugName);
      }
    });

    test('but those that go to another item, Back, the volume, info and Menu', () {
      for (final key in [
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.mediaTrackNext,
        LogicalKeyboardKey.mediaTrackPrevious,
        LogicalKeyboardKey.goBack,
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.audioVolumeUp,
        LogicalKeyboardKey.audioVolumeDown,
        LogicalKeyboardKey.audioVolumeMute,
        LogicalKeyboardKey.info,
        LogicalKeyboardKey.contextMenu,
      ]) {
        expect(remoteKeyShowsVideoControls(key), isFalse, reason: key.debugName);
      }
    });
  });

  test('info and Menu open the details on a remote, OK held 700 ms too', () {
    expect(remoteDetailsKeys, {LogicalKeyboardKey.info, LogicalKeyboardKey.contextMenu});
    expect(remoteOkHoldForDetails, const Duration(milliseconds: 700));
  });
}
