// Where the DJI live video stands, in the words a pilot needs (p2/design-ux-phone-2026-10-24.md, sections 3.4 and 7):
// one pure function from the states and reasons the native side already sends, and the state of the picture measured
// here. The live screen draws the step card of the stage, or the picture when it is live. Nothing here asks anything of
// the native side.

import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_video.widget.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';

enum DjiLiveStage {
  /// The environment is not read yet
  checking,

  /// This device cannot be a USB accessory: no app on it can read a remote over a cable
  noUsb,

  /// Nothing plugged in yet in this session
  plug,

  /// A remote is listed; Android may be asking which app opens it
  chooser,

  /// The USB permission dialog is up
  allow,

  /// The permission was refused, or could not be asked for
  refused,

  /// The permission is held and the open failed: another app (DJI Fly) has the remote
  busy,

  /// The remote is open and answers; no drone yet
  remote,

  /// The drone answers; no picture yet
  drone,

  /// A picture came out of the decoder in the last two seconds
  live,

  /// The picture stopped while the link is open, after a live picture in this session
  noPicture,

  /// The remote was unplugged, or went away after it was open in this session
  unplugged,

  /// The link dropped for another reason; the native side tries again
  lost,

  /// Bytes arrive that Immuch360 cannot read
  unread,

  /// A saved capture plays in place of the cable
  capture,
}

/// How many of the three dots (Remote, Drone, Picture) are filled at [stage]
int djiLiveDots(DjiLiveStage stage) => switch (stage) {
  DjiLiveStage.checking ||
  DjiLiveStage.noUsb ||
  DjiLiveStage.plug ||
  DjiLiveStage.unplugged ||
  DjiLiveStage.capture => 0,
  DjiLiveStage.chooser ||
  DjiLiveStage.allow ||
  DjiLiveStage.refused ||
  DjiLiveStage.busy ||
  DjiLiveStage.remote ||
  DjiLiveStage.lost ||
  DjiLiveStage.unread => 1,
  DjiLiveStage.drone || DjiLiveStage.noPicture => 2,
  DjiLiveStage.live => 3,
};

/// The stage of [state]. [hadRemote]: a remote was open earlier in this session, so that nothing listed now is an
/// unplug rather than the first plug (the 24 October 2026 session ended on reads failed, then nothing listed).
/// [hadPicture]: a live picture showed earlier in this session, so that an open link without a picture says the
/// picture stopped rather than walking the steps again.
DjiLiveStage djiLiveStage(DjiLinkPageState state, {bool hadRemote = false, bool hadPicture = false}) {
  final snapshot = state.snapshot;
  if (snapshot?.source?.replay ?? false) {
    return DjiLiveStage.capture;
  }
  final environment = state.environment;
  if (environment == null) {
    return DjiLiveStage.checking;
  }
  if (!environment.transportPossible) {
    return DjiLiveStage.noUsb;
  }
  if (snapshot == null) {
    return DjiLiveStage.checking;
  }
  final flows = djiLinkPictureFlows(snapshot.videoDecode);
  final unplug = snapshot.reason == DjiLinkReason.detached;
  return switch (snapshot.state) {
    DjiLinkState.unsupportedTransport => DjiLiveStage.noUsb,
    DjiLinkState.unsupportedProtocol => DjiLiveStage.unread,
    DjiLinkState.absent => unplug || hadRemote ? DjiLiveStage.unplugged : DjiLiveStage.plug,
    DjiLinkState.accessoryDetected => DjiLiveStage.chooser,
    DjiLinkState.permissionPending => DjiLiveStage.allow,
    DjiLinkState.permissionDenied =>
      snapshot.reason == DjiLinkReason.openFailed ? DjiLiveStage.busy : DjiLiveStage.refused,
    DjiLinkState.accessoryOpen || DjiLinkState.linkUsable || DjiLinkState.controllerIdentified =>
      flows
          ? DjiLiveStage.live
          : hadPicture
          ? DjiLiveStage.noPicture
          : DjiLiveStage.remote,
    DjiLinkState.aircraftLinked || DjiLinkState.videoReady || DjiLinkState.telemetryReady =>
      flows
          ? DjiLiveStage.live
          : hadPicture
          ? DjiLiveStage.noPicture
          : DjiLiveStage.drone,
    DjiLinkState.linkLost || DjiLinkState.recovering => unplug ? DjiLiveStage.unplugged : DjiLiveStage.lost,
  };
}

/// Whether a remote holds the cable at [stage]: the stages from the open on
bool djiLiveRemoteOpen(DjiLiveStage stage) => switch (stage) {
  DjiLiveStage.remote || DjiLiveStage.drone || DjiLiveStage.live || DjiLiveStage.noPicture => true,
  _ => false,
};

/// After this many seconds on the plug step, the card asks to check the cable
const djiLiveSlowPlugSeconds = 20;

/// After this many seconds with the remote open and no drone, the card says what to try
const djiLiveSlowRemoteSeconds = 15;

/// After this many seconds with the drone and no picture, the card points at Diagnostics
const djiLiveSlowDroneSeconds = 10;

/// Whether the card of [stage] adds its "Nothing yet?" hint after [seconds] in it
bool djiLiveSlow(DjiLiveStage stage, int seconds) => switch (stage) {
  DjiLiveStage.plug => seconds >= djiLiveSlowPlugSeconds,
  DjiLiveStage.remote => seconds >= djiLiveSlowRemoteSeconds,
  DjiLiveStage.drone => seconds >= djiLiveSlowDroneSeconds,
  _ => false,
};

/// The picture as measured here, which is the signal a pilot can trust today: what the picture does
enum DjiLivePicture {
  /// A picture in the last 500 ms, 20 pictures per second or more, none lost lately
  live,

  /// Pictures come, but fewer, or one was lost in the last few seconds
  weak,

  /// No new picture for more than 500 ms
  stale,

  /// No picture for two seconds or more: the screen is black
  none,
}

/// A picture older than this is no longer called live
const djiLiveStaleMs = 500;

/// Fewer pictures per second than this is a weak picture; the stream of the Neo 2 is 30 per second
const djiLiveLiveRate = 20;

/// The state of the picture from the decoder's counters; [lostRecently] when the lost pictures grew in the last 5 s
DjiLivePicture djiLivePicture(DjiLinkDecode? decode, {bool lostRecently = false}) {
  if (decode == null || !djiLinkPictureFlows(decode)) {
    return DjiLivePicture.none;
  }
  final ago = decode.lastOutputAgoMs ?? djiLinkPictureTimeoutMs;
  if (ago > djiLiveStaleMs) {
    return DjiLivePicture.stale;
  }
  if (lostRecently || decode.picturesPerSecond < djiLiveLiveRate) {
    return DjiLivePicture.weak;
  }
  return DjiLivePicture.live;
}
