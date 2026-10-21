// The keys of a TV remote, a keyboard and a game pad that the viewers and the players read themselves, beyond the
// arrows and OK that Flutter already turns into focus moves and taps. The Android key codes behind each logical key
// are those of Flutter's Android key map (KEYCODE_DPAD_CENTER is select, KEYCODE_CHANNEL_UP is channelUp...).

import 'dart:math';

import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/window/desktop_shortcuts.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';

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

/// Zoom in: channel up (most remotes have no zoom key), the zoom and page keys, the right shoulder of a game pad;
/// on a computer also + and = (desktop_shortcuts.dart)
Set<LogicalKeyboardKey> get remoteZoomInKeys => CurrentPlatform.isDesktop ? _desktopZoomInKeys : _remoteZoomInKeys;

final _remoteZoomInKeys = {
  LogicalKeyboardKey.channelUp,
  LogicalKeyboardKey.zoomIn,
  LogicalKeyboardKey.pageUp,
  LogicalKeyboardKey.gameButtonRight1,
};

final _desktopZoomInKeys = desktopZoomInKeys(_remoteZoomInKeys);

/// Zoom out: channel down, the zoom and page keys, the left shoulder of a game pad; on a computer also -
Set<LogicalKeyboardKey> get remoteZoomOutKeys => CurrentPlatform.isDesktop ? _desktopZoomOutKeys : _remoteZoomOutKeys;

final _remoteZoomOutKeys = {
  LogicalKeyboardKey.channelDown,
  LogicalKeyboardKey.zoomOut,
  LogicalKeyboardKey.pageDown,
  LogicalKeyboardKey.gameButtonLeft1,
};

final _desktopZoomOutKeys = desktopZoomOutKeys(_remoteZoomOutKeys);

/// The next item of a viewer
final remoteNextItemKeys = {LogicalKeyboardKey.mediaTrackNext};

/// The previous item of a viewer
final remotePreviousItemKeys = {LogicalKeyboardKey.mediaTrackPrevious};

/// The first item of a viewer: none on a remote, Home on a computer (desktop_shortcuts.dart)
Set<LogicalKeyboardKey> get remoteFirstItemKeys => CurrentPlatform.isDesktop ? desktopFirstItemKeys : const {};

/// The last item of a viewer: none on a remote, End on a computer
Set<LogicalKeyboardKey> get remoteLastItemKeys => CurrentPlatform.isDesktop ? desktopLastItemKeys : const {};

/// Fast forward; on a computer also L, while no text field has the keyboard (desktop_shortcuts.dart)
Set<LogicalKeyboardKey> get remoteSeekForwardKeys =>
    CurrentPlatform.isDesktop ? desktopSeekForwardKeys(_remoteSeekForwardKeys) : _remoteSeekForwardKeys;

final _remoteSeekForwardKeys = {LogicalKeyboardKey.mediaFastForward};

/// Rewind; on a computer also J
Set<LogicalKeyboardKey> get remoteSeekBackwardKeys =>
    CurrentPlatform.isDesktop ? desktopSeekBackwardKeys(_remoteSeekBackwardKeys) : _remoteSeekBackwardKeys;

final _remoteSeekBackwardKeys = {LogicalKeyboardKey.mediaRewind};

/// The details of the item shown: info, and Menu for the remotes without an info key (most of those of Google TV, which
/// also hold OK for them, see [remoteOkHoldForDetails]); on a computer info and I, its Menu key keeps its own meaning
Set<LogicalKeyboardKey> get remoteDetailsKeys =>
    CurrentPlatform.isDesktop ? desktopDetailsKeys(_remoteInfoKeys) : _remoteDetailsKeys;

final _remoteInfoKeys = {LogicalKeyboardKey.info};

final _remoteDetailsKeys = {LogicalKeyboardKey.info, LogicalKeyboardKey.contextMenu};

/// How long OK held on a viewer itself opens the details, with the remote control layout: a shorter press is a plain
/// OK, which then acts on its release. Most remotes of Google TV have no info key, and the menu of the top bar is
/// hidden there (view only).
const remoteOkHoldForDetails = Duration(milliseconds: 700);

/// Whether [event] zooms in: a key of [remoteZoomInKeys], or on a computer any key that types "+"
bool isRemoteZoomIn(KeyEvent event) =>
    remoteZoomInKeys.contains(event.logicalKey) || (CurrentPlatform.isDesktop && typesZoomInCharacter(event));

/// Whether [event] zooms out: a key of [remoteZoomOutKeys], or on a computer any key that types "-"
bool isRemoteZoomOut(KeyEvent event) =>
    remoteZoomOutKeys.contains(event.logicalKey) || (CurrentPlatform.isDesktop && typesZoomOutCharacter(event));

/// How far fast forward and rewind, the -10 s and +10 s buttons, and left and right where they seek (see
/// [remoteVideoArrows]) move a video
const remoteSeekStep = Duration(seconds: 10);

/// How long the controls of a video that plays stay on screen after they show or after the last key (on a TV any key,
/// see [remoteKeyShowsVideoControls])
const videoControlsHideAfter = Duration(seconds: 5);

/// What left and right do on a video, while the viewer itself has the focus (not a button of its controls)
enum RemoteVideoArrows {
  /// The previous or next item of the viewer
  navigate,

  /// 10 s back or forward in the video
  seek,
}

/// What left and right do on a video, while the viewer itself has the focus. The whole policy of the arrows on a
/// video is here, for the asset viewer and the video page of a share.
///
/// With the remote control layout ([tvMode]) they go to the previous or next item whatever the video does: it plays,
/// loads, is paused or ended. Fast forward, rewind and the -10 s and +10 s buttons of the controls seek. Only a video
/// without [hasNeighbours] (a file opened on its own) seeks with them. This departs from the TV-PC criterion of Google
/// Play (left and right rewind and fast forward the media that plays), a choice made after a test on a real TV: a
/// video that loops never let them reach the next item. Back to TV-PC: seek while [playing] here.
///
/// Elsewhere (a keyboard or a game pad on a phone or a computer) they seek while the video [playing] and go to the
/// previous or next item once it is paused or ended, as the players of a computer do.
RemoteVideoArrows remoteVideoArrows({required bool tvMode, required bool playing, required bool hasNeighbours}) {
  if (tvMode) {
    return hasNeighbours ? RemoteVideoArrows.navigate : RemoteVideoArrows.seek;
  }
  return playing ? RemoteVideoArrows.seek : RemoteVideoArrows.navigate;
}

/// Whether OK on a video, while the viewer itself has the focus, shows the controls with play and pause focused (so
/// that a second OK pauses, as the controller of Media3 does) rather than pause or play at once: with the remote
/// control layout ([tvMode]) only
bool remoteVideoOkFocusesControls({required bool tvMode}) => tvMode;

/// The keys that never bring back the controls of a video on a TV: left and right and the next and previous keys go
/// to another item and leave the controls as they are, Back goes back, the volume is the TV's, info and Menu open the
/// details
final _keysThatKeepVideoControlsHidden = {
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.mediaTrackNext,
  LogicalKeyboardKey.mediaTrackPrevious,
  LogicalKeyboardKey.goBack,
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.browserBack,
  LogicalKeyboardKey.audioVolumeUp,
  LogicalKeyboardKey.audioVolumeDown,
  LogicalKeyboardKey.audioVolumeMute,
  LogicalKeyboardKey.info,
  LogicalKeyboardKey.contextMenu,
};

/// Whether [key] brings back the controls of a video on a TV: any key but those that go to another item, Back, the
/// volume, info and Menu
bool remoteKeyShowsVideoControls(LogicalKeyboardKey key) => !_keysThatKeepVideoControlsHidden.contains(key);

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
