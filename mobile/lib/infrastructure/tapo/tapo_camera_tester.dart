// "Test the camera" of the camera form (see TapoCameraTester), and the certificate check of a camera found at a new
// address (see TapoCertificateReader).
//
// The test runs the recordings side (a login with the TP-Link password, then the details, the card, the zone and the
// components in one request) and the live side (OPTIONS and DESCRIBE with the camera account) side by side, each only
// when its secrets are given. The login of the test stays in TapoSessionCache, under the id the camera will have once
// saved, so that the connection opened after the save does not log in again. A refused password is never tried again
// here: the user presses the button again for that. The press is the user asking the camera again: it forgets the
// refusals remembered for the camera, and it is the only login that may trust a camera's first certificate.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_probe.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_control_client.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_https.dart';
import 'package:logging/logging.dart';

final _log = Logger('TapoTest');

/// The recordings check and the live check of [request], each only when its secrets are given
Future<TapoTestResult> testTapoCamera(TapoTestRequest request) => runTapoCameraTest(request);

/// [testTapoCamera] with what the tests replace
@visibleForTesting
Future<TapoTestResult> runTapoCameraTest(
  TapoTestRequest request, {
  TapoControlClient Function(TapoTestRequest request, String password)? client,
  Future<TapoLiveProbe> Function(String host, {required int port, required String user, required String password})?
  rtsp,
}) async {
  final cloudPassword = request.cloudPassword;
  final cameraUser = request.cameraUser?.trim();
  final cameraPassword = request.cameraPassword;
  final recordings = cloudPassword == null || cloudPassword.isEmpty
      ? null
      : _recordings(request, cloudPassword, client);
  final live = cameraUser == null || cameraUser.isEmpty || cameraPassword == null || cameraPassword.isEmpty
      ? null
      : _live(request, cameraUser, cameraPassword, rtsp);
  final recordingsResult = await recordings;
  final liveResult = await live;
  return TapoTestResult(
    details: recordingsResult?.details,
    card: recordingsResult?.card,
    info: recordingsResult?.info,
    recordingsError: recordingsResult?.error,
    live: liveResult?.probe,
    liveError: liveResult?.error,
  );
}

Future<({TapoCameraDetails? details, TapoCardStatus? card, TapoCameraInfo? info, TapoCameraException? error})>
_recordings(
  TapoTestRequest request,
  String password,
  TapoControlClient Function(TapoTestRequest request, String password)? makeClient,
) async {
  final client =
      makeClient?.call(request, password) ??
      TapoControlClient(
        sourceId: request.sourceId,
        host: request.host.trim(),
        password: password,
        known: request.known ?? const TapoCameraInfo(),
        trustFirstCertificate: true,
      );
  client.forgetRefusals();
  try {
    final checked = await client.check();
    return (details: checked.details, card: checked.card, info: client.info, error: null);
  } on TapoCameraException catch (error) {
    _log.info('Test of a camera, recordings: ${error.kind.name}${error.code == null ? '' : ' ${error.code}'}');
    // What the login learned (the certificate seen, the generation) helps the next test even after a refusal
    return (details: null, card: null, info: null, error: error);
  } finally {
    client.close();
  }
}

Future<({TapoLiveProbe? probe, TapoCameraException? error})> _live(
  TapoTestRequest request,
  String user,
  String password,
  Future<TapoLiveProbe> Function(String host, {required int port, required String user, required String password})?
  rtsp,
) async {
  final port = request.known?.rtspPort ?? TapoCameraInfo.defaultRtspPort;
  try {
    final probe = rtsp == null
        ? await probeTapoRtsp(request.host.trim(), port: port, user: user, password: password)
        : await rtsp(request.host.trim(), port: port, user: user, password: password);
    return (probe: probe, error: null);
  } on TapoCameraException catch (error) {
    _log.info('Test of a camera, live: ${error.kind.name}${error.code == null ? '' : ' ${error.code}'}');
    return (probe: null, error: error);
  }
}

/// The SHA-256 of the certificate the camera at [host] shows now (lower case hex), null when it does not answer. The
/// handshake is refused as soon as the certificate is seen: nothing else is sent.
Future<String?> readTapoCertificateSha256(String host) => readTapoCertificate(host);
