// The keys of a TV remote, a keyboard and a game pad that the viewers and the players read themselves, beyond the
// arrows and OK that Flutter already turns into focus moves and taps. The Android key codes behind each logical key
// are those of Flutter's Android key map (KEYCODE_DPAD_CENTER is select, KEYCODE_CHANNEL_UP is channelUp...).

import 'dart:math';

import 'package:flutter/services.dart';

/// OK of a remote, Enter of a keyboard, A of a game pad
final remoteOkKeys = {
  LogicalKeyboardKey.select,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.gameButtonA,
};

/// Play and pause: the toggle of most remotes, and the two keys of the others
final remotePlayPauseKeys = {
  LogicalKeyboardKey.mediaPlayPause,
  LogicalKeyboardKey.mediaPlay,
  LogicalKeyboardKey.mediaPause,
};

/// Zoom in: channel up (most remotes have no zoom key), the zoom and page keys, the right shoulder of a game pad
final remoteZoomInKeys = {
  LogicalKeyboardKey.channelUp,
  LogicalKeyboardKey.zoomIn,
  LogicalKeyboardKey.pageUp,
  LogicalKeyboardKey.gameButtonRight1,
};

/// Zoom out: channel down, the zoom and page keys, the left shoulder of a game pad
final remoteZoomOutKeys = {
  LogicalKeyboardKey.channelDown,
  LogicalKeyboardKey.zoomOut,
  LogicalKeyboardKey.pageDown,
  LogicalKeyboardKey.gameButtonLeft1,
};

/// The next item of a viewer
final remoteNextItemKeys = {LogicalKeyboardKey.mediaTrackNext};

/// The previous item of a viewer
final remotePreviousItemKeys = {LogicalKeyboardKey.mediaTrackPrevious};

/// Fast forward
final remoteSeekForwardKeys = {LogicalKeyboardKey.mediaFastForward};

/// Rewind
final remoteSeekBackwardKeys = {LogicalKeyboardKey.mediaRewind};

/// The details of the item shown
final remoteDetailsKeys = {LogicalKeyboardKey.info};

/// How far left and right, fast forward and rewind move a playing video (the Play TV criterion TV-PC)
const remoteSeekStep = Duration(seconds: 10);

/// Whether [event] is a press, not the repeat of a held key nor a release
bool isRemotePress(KeyEvent event) => event is KeyDownEvent;

/// What a play or pause key asks of a player that [isPlaying]: true to play, false to pause. The toggle key toggles,
/// the play key always plays and the pause key always pauses.
bool remotePlayPauseWantsPlay(LogicalKeyboardKey key, {required bool isPlaying}) {
  if (key == LogicalKeyboardKey.mediaPlay) {
    return true;
  }
  if (key == LogicalKeyboardKey.mediaPause) {
    return false;
  }
  return !isPlaying;
}

/// Degrees per second the 360° photo viewer turns once an arrow has been held for [heldSeconds], at the field of
/// view [fieldOfView] (in degrees): a short press nudges the view by a few degrees, holding accelerates up to a third
/// of a turn per second, and a zoomed in view turns slower so that the image moves on screen at the same pace. Up and
/// down use three quarters of it. The native 360° video player uses the same ramp without the field of view factor.
double remoteTurnSpeed(double heldSeconds, double fieldOfView) =>
    min(40 + 160 * max(heldSeconds, 0), 120) * fieldOfView / 90;

/// Up and down turn the 360° views a little slower than left and right
const remotePitchFactor = 0.75;
