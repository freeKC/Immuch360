// The stage of the DJI live video from the states and reasons the native side sends (design 3.4 and 7), and the state
// of the picture from the decoder's counters: a pure function each, tested row by row.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_stage.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';

import '../../pages/drone/dji_link_fakes.dart';

DjiLinkPageState _state(DjiLinkSnapshot? snapshot, {bool transport = true}) =>
    DjiLinkPageState(environment: fakeEnvironment(accessoryFeature: transport, flavour: 'phone'), snapshot: snapshot);

DjiLiveStage _stage(
  DjiLinkState state, {
  DjiLinkReason? reason,
  DjiLinkDecode? decode,
  DjiLinkSource? source,
  bool hadRemote = false,
  bool hadPicture = false,
}) => djiLiveStage(
  _state(fakeSnapshot(state: state, reason: reason, decode: decode, source: source)),
  hadRemote: hadRemote,
  hadPicture: hadPicture,
);

void main() {
  test('each state and reason of the native side gives its step', () {
    expect(djiLiveStage(const DjiLinkPageState()), DjiLiveStage.checking);
    expect(djiLiveStage(_state(null)), DjiLiveStage.checking);
    expect(djiLiveStage(_state(null, transport: false)), DjiLiveStage.noUsb);
    expect(_stage(DjiLinkState.unsupportedTransport), DjiLiveStage.noUsb);
    expect(_stage(DjiLinkState.absent, reason: DjiLinkReason.looking), DjiLiveStage.plug);
    expect(_stage(DjiLinkState.absent, reason: DjiLinkReason.nothingListed), DjiLiveStage.plug);
    expect(_stage(DjiLinkState.accessoryDetected, reason: DjiLinkReason.listed), DjiLiveStage.chooser);
    expect(_stage(DjiLinkState.accessoryDetected, reason: DjiLinkReason.waitingForChooser), DjiLiveStage.chooser);
    expect(_stage(DjiLinkState.permissionPending, reason: DjiLinkReason.permissionAsked), DjiLiveStage.allow);
    expect(_stage(DjiLinkState.permissionDenied, reason: DjiLinkReason.permissionRefused), DjiLiveStage.refused);
    expect(
      _stage(DjiLinkState.permissionDenied, reason: DjiLinkReason.permissionRequestFailed),
      DjiLiveStage.refused,
    );
    // The permission is held and the open failed: DJI Fly, or another app, has the remote
    expect(_stage(DjiLinkState.permissionDenied, reason: DjiLinkReason.openFailed), DjiLiveStage.busy);
    expect(_stage(DjiLinkState.accessoryOpen, reason: DjiLinkReason.opened), DjiLiveStage.remote);
    expect(_stage(DjiLinkState.linkUsable, reason: DjiLinkReason.probeReturns), DjiLiveStage.remote);
    expect(_stage(DjiLinkState.controllerIdentified, reason: DjiLinkReason.framesParse), DjiLiveStage.remote);
    expect(_stage(DjiLinkState.aircraftLinked, reason: DjiLinkReason.aircraftFrames), DjiLiveStage.drone);
    expect(_stage(DjiLinkState.telemetryReady), DjiLiveStage.drone);
    expect(_stage(DjiLinkState.aircraftLinked, decode: fakeDecode()), DjiLiveStage.live);
    expect(_stage(DjiLinkState.videoReady, decode: fakeDecode()), DjiLiveStage.live);
    // A picture out of the decoder is live whatever the step the native side says
    expect(_stage(DjiLinkState.controllerIdentified, decode: fakeDecode()), DjiLiveStage.live);
    expect(_stage(DjiLinkState.linkLost, reason: DjiLinkReason.readsFailed), DjiLiveStage.lost);
    expect(_stage(DjiLinkState.recovering), DjiLiveStage.lost);
    expect(_stage(DjiLinkState.unsupportedProtocol), DjiLiveStage.unread);
  });

  test('an unplug is told apart from the first plug', () {
    expect(_stage(DjiLinkState.absent, reason: DjiLinkReason.detached), DjiLiveStage.unplugged);
    expect(_stage(DjiLinkState.linkLost, reason: DjiLinkReason.detached), DjiLiveStage.unplugged);
    // The 24 October 2026 session ended on reads failed, then nothing listed: once a remote was open, an unplug
    expect(_stage(DjiLinkState.absent, reason: DjiLinkReason.nothingListed, hadRemote: true), DjiLiveStage.unplugged);
    expect(_stage(DjiLinkState.absent, reason: DjiLinkReason.nothingListed), DjiLiveStage.plug);
  });

  test('a picture that stops after a live one says so instead of walking the steps again', () {
    expect(_stage(DjiLinkState.aircraftLinked, hadPicture: true), DjiLiveStage.noPicture);
    expect(_stage(DjiLinkState.controllerIdentified, hadPicture: true), DjiLiveStage.noPicture);
    expect(
      _stage(DjiLinkState.aircraftLinked, decode: fakeDecode(lastOutputAgoMs: 2500), hadPicture: true),
      DjiLiveStage.noPicture,
    );
    // The link itself went: the steps again
    expect(_stage(DjiLinkState.linkLost, reason: DjiLinkReason.readsFailed, hadPicture: true), DjiLiveStage.lost);
  });

  test('a start that failed is a stage of its own, never a black screen with no words', () {
    // The environment could not be read
    expect(djiLiveStage(const DjiLinkPageState(error: 'no bridge')), DjiLiveStage.failed);
    expect(djiLiveStage(const DjiLinkPageState(error: 'no bridge', reading: true)), DjiLiveStage.checking);
    // The link could not start: the snapshot the capture asked for says nothing was plugged in
    final notStarted = DjiLinkPageState(
      environment: fakeEnvironment(flavour: 'phone'),
      snapshot: fakeSnapshot(state: DjiLinkState.absent, reason: DjiLinkReason.looking),
      error: 'no bridge',
    );
    expect(djiLiveStage(notStarted), DjiLiveStage.failed);
    // An error while the link listens (an export that failed) is not a failed start
    expect(djiLiveStage(notStarted.copyWith(listening: true)), DjiLiveStage.plug);
    // A device with no USB accessory support says so first
    expect(
      djiLiveStage(DjiLinkPageState(environment: fakeEnvironment(accessoryFeature: false), error: 'no bridge')),
      DjiLiveStage.noUsb,
    );
    expect(djiLiveDots(DjiLiveStage.failed), 0);
    expect(djiLiveRemoteOpen(DjiLiveStage.failed), isFalse);
  });

  test('a capture being played is a stage of its own, also where no cable can be read', () {
    final playing = DjiLinkSource(replay: true, playing: true, name: 'dji-link-20261023-102731');
    expect(_stage(DjiLinkState.absent, source: playing), DjiLiveStage.capture);
    expect(
      djiLiveStage(_state(fakeSnapshot(state: DjiLinkState.unsupportedTransport, source: playing), transport: false)),
      DjiLiveStage.capture,
    );
  });

  test('the dots fill with the steps', () {
    expect(djiLiveDots(DjiLiveStage.plug), 0);
    expect(djiLiveDots(DjiLiveStage.unplugged), 0);
    expect(djiLiveDots(DjiLiveStage.chooser), 1);
    expect(djiLiveDots(DjiLiveStage.allow), 1);
    expect(djiLiveDots(DjiLiveStage.remote), 1);
    expect(djiLiveDots(DjiLiveStage.drone), 2);
    expect(djiLiveDots(DjiLiveStage.live), 3);
  });

  test('the hints come after 20 s on the plug step, 15 s with the remote, 10 s with the drone', () {
    expect(djiLiveSlow(DjiLiveStage.plug, 19), isFalse);
    expect(djiLiveSlow(DjiLiveStage.plug, 20), isTrue);
    expect(djiLiveSlow(DjiLiveStage.remote, 14), isFalse);
    expect(djiLiveSlow(DjiLiveStage.remote, 15), isTrue);
    expect(djiLiveSlow(DjiLiveStage.drone, 9), isFalse);
    expect(djiLiveSlow(DjiLiveStage.drone, 10), isTrue);
    expect(djiLiveSlow(DjiLiveStage.live, 600), isFalse);
    expect(djiLiveSlow(DjiLiveStage.lost, 600), isFalse);
  });

  test('the picture state is what the decoder does, measured here', () {
    expect(djiLivePicture(null), DjiLivePicture.none);
    expect(djiLivePicture(fakeDecode(lastOutputAgoMs: null)), DjiLivePicture.none);
    expect(djiLivePicture(fakeDecode(lastOutputAgoMs: 2100)), DjiLivePicture.none);
    expect(djiLivePicture(fakeDecode(lastOutputAgoMs: 900)), DjiLivePicture.stale);
    expect(djiLivePicture(fakeDecode(lastOutputAgoMs: 40, picturesPerSecond: 12)), DjiLivePicture.weak);
    expect(djiLivePicture(fakeDecode(lastOutputAgoMs: 40), lostRecently: true), DjiLivePicture.weak);
    expect(djiLivePicture(fakeDecode(lastOutputAgoMs: 40)), DjiLivePicture.live);
  });
}
