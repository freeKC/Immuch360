// The stabilisation of a raw 360° video in the player of the computers (issue 14, lot d2): the table Flutter builds
// from the camera's motion track (raw_video_stabilization.dart) reaches renderer C of media_kit_360, which turns each
// frame it draws by the correction of that frame's time (package:media_kit_video/sphere.dart, setStabilization; its
// IMMUCH360-NOTE.md patch 14 tells how the time of the frame drawn is known). Windows only: renderer C draws the 360°
// view there, and the computers without it play the video flat, where a table would turn nothing.
//
// The open of SphericalVideoApi pushes the player's route and returns at once, and the table comes later
// (openStabilizedSphericalVideo): the messages wait in [DesktopStabilizationInbox], keyed by the URL the player opens,
// as the Android player's StabilizationInbox keeps them. [StabilizationSwitch] holds the rules of the switch, those of
// the Android player (PlayerStabilization.kt) without the CAMM tracks, which mpv does not apply.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit_video/sphere.dart';

/// What Flutter said about the stabilisation of the video at [url] (SphericalVideoApi.setStabilization)
@immutable
class DesktopStabilizationMessage {
  const DesktopStabilizationMessage({
    required this.url,
    required this.enabled,
    required this.hasTrack,
    this.table,
    this.summary,
  });

  final String url;

  /// The setting: where the switch starts
  final bool enabled;

  /// The file has a motion track the app reads: the switch shows; with no [table] yet, the track is being read
  final bool hasTrack;
  final PluginStabilization? table;

  /// What the table did, for the logs
  final String? summary;

  @override
  String toString() =>
      'DesktopStabilizationMessage(${enabled ? 'on' : 'off'}, ${hasTrack ? (table ?? 'reading') : 'no track'})';
}

/// The messages of [DesktopStabilizationMessage] until the player of their URL reads them, then as they come: the
/// latest one of each URL is kept, so that a player that opens after the table was built still gets it
class DesktopStabilizationInbox {
  DesktopStabilizationInbox();

  /// The inbox of the app: the platform API posts there, the player's route reads there
  static final instance = DesktopStabilizationInbox();

  final _latest = <String, DesktopStabilizationMessage>{};
  final _messages = StreamController<DesktopStabilizationMessage>.broadcast(sync: true);

  /// The messages as they come
  Stream<DesktopStabilizationMessage> get messages => _messages.stream;

  /// The latest message about [url], null when none came
  DesktopStabilizationMessage? latestFor(String url) => _latest[url];

  void post(DesktopStabilizationMessage message) {
    _latest[message.url] = message;
    _messages.add(message);
  }

  /// The player of [url] closed: its messages go
  void forget(String url) => _latest.remove(url);
}

/// The table as renderer C takes it, from what SphericalVideoApi.setStabilization gives; null for none, and for a
/// table whose lengths do not match (four values a frame)
PluginStabilization? pluginStabilizationOf(Int64List? timesUs, Float64List? corrections) {
  if (timesUs == null || corrections == null || timesUs.isEmpty || corrections.length != 4 * timesUs.length) {
    return null;
  }
  return PluginStabilization(timesUs: timesUs, corrections: corrections);
}

/// Whether the 360° player of this computer stabilises: renderer C draws the view on Windows only; elsewhere the video
/// plays flat
bool desktopStabilizationSupported({bool? windows, bool? rendererSupported, bool? videoAvailable}) =>
    (windows ?? (!kIsWeb && Platform.isWindows)) &&
    (rendererSupported ?? PluginRenderer.supported) &&
    (videoAvailable ?? false);

/// What the player knows of the motion track of the file
enum StabilizationTrack { unknown, pending, ready, none }

/// A notice to show for a few seconds
enum StabilizationNotice { stabilized, noTrack }

/// The stabilisation switch of the 360° player and what follows from it: whether its button shows, which table the
/// frames get, which notice to show. The rules of the Android player (StabilizationSwitch of PlayerStabilization.kt),
/// without the CAMM tracks. The button shows for a raw video whose track Flutter reads or has read, while the view is
/// the stitched sphere ([stitched]); off, the frames get no correction (off means the raw video); the switch starts at
/// the setting Flutter sends before the video opens, until the user presses it.
class StabilizationSwitch {
  /// The switch starts [enabled], as the setting, until Flutter sends it
  StabilizationSwitch({this._enabled = true});

  bool _enabled;
  StabilizationTrack _track = StabilizationTrack.unknown;
  PluginStabilization? _table;
  bool _touched = false;
  bool _turnedOnByUser = false;
  bool _stabilizedNoticeShown = false;

  /// The view is the stitched sphere, whose picture the table describes; false while the video plays flat or shows its
  /// lenses as recorded, where the table would turn nothing
  bool stitched = true;

  bool get enabled => _enabled;
  StabilizationTrack get track => _track;

  /// The table of the file, once Flutter sent it
  PluginStabilization? get table => _table;

  /// The user pressed the button in this player: the setting no longer moves the switch
  bool get wasTouched => _touched;

  bool get buttonVisible => stitched && (_track == StabilizationTrack.pending || _track == StabilizationTrack.ready);

  /// Whether the frames are corrected: on, stitched, with a table
  bool get active => _enabled && stitched && _table != null;

  /// What Flutter said about the file: the table, or that it reads the track ([hasTrack] without a table), or that the
  /// file has none. A file without a track says so only when the user turned the switch on in this player.
  StabilizationNotice? onTrack({required bool hasTrack, PluginStabilization? table}) {
    _table = hasTrack ? table : null;
    _track = !hasTrack
        ? StabilizationTrack.none
        : table != null
        ? StabilizationTrack.ready
        : StabilizationTrack.pending;
    return _track == StabilizationTrack.none && _enabled && _turnedOnByUser ? StabilizationNotice.noTrack : null;
  }

  /// The setting Flutter sent, unless the user already pressed the button in this player
  void onSetting(bool enabled) {
    if (!_touched) {
      _enabled = enabled;
    }
  }

  /// The user pressed the button: the switch flips. Turned on, the notice tells what the user gets: stabilised with a
  /// table, no track when the file turned out to have none, nothing while the track is read (the notice comes with the
  /// first corrected frame).
  StabilizationNotice? toggle() {
    _touched = true;
    _enabled = !_enabled;
    if (!_enabled) {
      return null;
    }
    _turnedOnByUser = true;
    if (_table != null) {
      _stabilizedNoticeShown = true;
      return StabilizationNotice.stabilized;
    }
    return _track == StabilizationTrack.none ? StabilizationNotice.noTrack : null;
  }

  /// The frames are corrected from now on: the first time in this player tells the user, once
  StabilizationNotice? onStabilized() {
    if (_stabilizedNoticeShown) {
      return null;
    }
    _stabilizedNoticeShown = true;
    return StabilizationNotice.stabilized;
  }
}
