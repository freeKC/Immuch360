// What the camera pages need from a Tapo camera, whatever its login generation. The protocol layer
// (lib/infrastructure/tapo/) implements it; the pages and providers only use these types, so that they are tested
// with fakes and never see a password or a protocol detail.

import 'dart:typed_data';

import 'package:immich_mobile/domain/models/tapo_camera_info.dart';

/// The kinds of failure the camera pages put into words (strings camera_error_*)
enum TapoErrorKind {
  wrongPassword,
  locked,
  notOwner,
  busy,
  unreachable,
  unsupported,
  mediaLocked,
  certificateChanged,
  h265,
  cancelled,
}

class TapoCameraException implements Exception {
  const TapoCameraException(
    this.kind, {
    this.code,
    this.attemptsLeft,
    this.lockedMinutes,
    this.detail,
    this.certificateSha256,
  });

  final TapoErrorKind kind;

  /// The camera's error_code when there is one
  final int? code;

  /// wrongPassword: what the camera tells, null when it does not
  final int? attemptsLeft;

  /// locked
  final int? lockedMinutes;

  /// unsupported: a short protocol detail for the message, never a secret
  final String? detail;

  /// certificateChanged: the new certificate, stored once the user accepts it
  final String? certificateSha256;

  @override
  String toString() => 'TapoCameraException(${kind.name}${code == null ? '' : ' $code'})';
}

/// The steps of a live view, for the diagnostics line of the camera page
enum TapoLiveStep {
  /// The TCP connection (a sleeping battery camera does not answer the first ones)
  connect,

  /// The login of the media port (Digest with the TP-Link password) or of RTSP (the camera account)
  login,

  /// The live request, answered with an error code by a camera that refuses it
  request,

  /// The first picture (an IDR picture and its parameter sets) after the camera accepted
  firstPicture,

  /// A stream that played, then stopped
  stream,
}

/// A live view that failed at [step]
class TapoLiveException extends TapoCameraException {
  const TapoLiveException(this.step, super.kind, {super.code, super.detail});

  TapoLiveException.at(this.step, TapoCameraException cause)
    : super(cause.kind, code: cause.code, detail: cause.detail, attemptsLeft: cause.attemptsLeft);

  final TapoLiveStep step;

  @override
  String toString() => 'TapoLiveException(${step.name} ${kind.name}${code == null ? '' : ' $code'})';
}

/// Where the live view of a camera comes from
enum TapoLiveRoute {
  /// RTSP on 554 with the camera account
  rtsp,

  /// The media port (8800) with the password of the TP-Link account, as the Tapo app: the only local stream of the
  /// battery and solar cameras, and the way to a live view without a camera account
  mediaPort,

  /// A camera without RTSP, and no TP-Link password to use its media port
  needsCloudPassword,

  /// A camera with RTSP, and neither a camera account nor a TP-Link password
  needsAccount,

  /// The address is a hub: its cameras stream through it, which this version does not do
  hub,
}

/// Whether a camera runs on a battery or a solar panel: getDeviceInfo basic_info power or power_mode
/// (HomeAssistant-Tapo-Control utils.isBatteryPowered), else its model (the C4xx outdoor cameras are all battery or
/// solar ones, and none of them has RTSP)
bool tapoIsBatteryCamera({String? model, String? power}) {
  final value = power?.toUpperCase();
  if (value == 'BATTERY' || value == 'SOLAR') {
    return true;
  }
  return RegExp(r'^C4\d\d', caseSensitive: false).hasMatch(model?.trim() ?? '');
}

/// Whether the address is a Tapo hub (H100, H200, H500, ...): its device type, else its model
bool tapoIsHub({String? model, String? deviceType}) {
  if (deviceType != null && deviceType.toUpperCase().contains('HUB')) {
    return true;
  }
  return RegExp(r'^H\d{3}', caseSensitive: false).hasMatch(model?.trim() ?? '');
}

/// The route of the live view of a camera. [rtspFailed]: RTSP did not even connect on this visit (a model this build
/// does not know as a battery one), so the media port is tried when it can be.
TapoLiveRoute tapoLiveRoute({
  String? model,
  String? power,
  String? deviceType,
  required bool hasCameraAccount,
  required bool hasCloudPassword,
  bool rtspFailed = false,
}) {
  if (tapoIsHub(model: model, deviceType: deviceType)) {
    return TapoLiveRoute.hub;
  }
  final noRtsp = rtspFailed || tapoIsBatteryCamera(model: model, power: power);
  if (noRtsp) {
    return hasCloudPassword ? TapoLiveRoute.mediaPort : TapoLiveRoute.needsCloudPassword;
  }
  if (hasCameraAccount) {
    return TapoLiveRoute.rtsp;
  }
  return hasCloudPassword ? TapoLiveRoute.mediaPort : TapoLiveRoute.needsAccount;
}

class TapoCameraDetails {
  const TapoCameraDetails({
    required this.alias,
    required this.model,
    required this.firmware,
    required this.mac,
    this.zoneId,
    this.power,
    this.deviceType,
  });

  /// device_alias, the name given in the Tapo app
  final String alias;
  final String model;
  final String firmware;

  /// aa-bb-cc-dd-ee-ff, lower case: the discoveryId of the source
  final String mac;
  final String? zoneId;

  /// basic_info power (or power_mode): BATTERY, SOLAR, ... null when the camera does not tell (a mains one)
  final String? power;

  /// basic_info dev_type or device_type: SMART.IPCAMERA, SMART.TAPOHUB, ...
  final String? deviceType;
}

enum TapoCardState { normal, absent, other }

class TapoCardStatus {
  const TapoCardStatus({
    required this.state,
    required this.status,
    this.usedBytes,
    this.totalBytes,
    this.oldestRecording,
  });

  final TapoCardState state;

  /// The camera's own word for the state ("normal", "formatting"...), shown when state is other
  final String status;
  final int? usedBytes;
  final int? totalBytes;
  final DateTime? oldestRecording;
}

enum TapoClipKind { motion, person, pet, vehicle, babyCry, animal, continuous, other }

class TapoClip {
  const TapoClip({
    required this.start,
    required this.end,
    required this.videoType,
    required this.kind,
    required this.path,
  });

  /// UTC
  final DateTime start;
  final DateTime end;

  /// The camera's video_type code
  final int videoType;
  final TapoClipKind kind;

  /// Its path in the camera's NetworkFileSystem: `/<yyyy-mm-dd>/<start>-<end>.mov`, the day in the camera's zone, the
  /// bounds in UTC seconds; what NetworkVideoRoute opens once the clip is fetched
  final String path;

  Duration get duration => end.difference(start);
}

/// Codecs of the live streams read from the SDP, for the test line
class TapoLiveProbe {
  const TapoLiveProbe({this.video, this.audio});

  final String? video;
  final String? audio;
}

class TapoTestRequest {
  const TapoTestRequest({
    required this.sourceId,
    required this.host,
    this.cloudPassword,
    this.cameraUser,
    this.cameraPassword,
    this.known,
  });

  /// The id the source has or will have: the login of the test is handed to the connection opened after the save
  final String sourceId;
  final String host;
  final String? cloudPassword;
  final String? cameraUser;
  final String? cameraPassword;

  /// What an existing camera already knows (protocol, passcode form, pinned certificate)
  final TapoCameraInfo? known;

  // The passwords never show in a log or an error message
  @override
  String toString() => 'TapoTestRequest($sourceId $host)';
}

class TapoTestResult {
  const TapoTestResult({this.details, this.card, this.info, this.recordingsError, this.live, this.liveError});

  /// Recordings side, when a cloud password was given
  final TapoCameraDetails? details;
  final TapoCardStatus? card;

  /// What the login learned, saved with the source
  final TapoCameraInfo? info;
  final TapoCameraException? recordingsError;

  /// Live side, when a camera account was given
  final TapoLiveProbe? live;
  final TapoCameraException? liveError;
}

/// The recordings of an open camera. The NetworkFileSystem of a tapo source implements it; its methods throw
/// TapoCameraException only.
abstract interface class TapoRecordings {
  /// What the connection knows now; differs from the stored one when a login learned something new
  TapoCameraInfo get info;

  Future<TapoCameraDetails> details();

  Future<TapoCardStatus> cardStatus();

  /// Days with recordings, "yyyy-mm-dd" in the camera's zone, newest first, over the last 24 months
  Future<List<String>> days({bool refresh = false});

  /// Clips of [day], oldest first
  Future<List<TapoClip>> clips(String day, {bool refresh = false});

  /// The camera's picture of an event clip, null for a clip without one (continuous recording)
  Future<Uint8List?> thumbnail(TapoClip clip);

  bool isFetched(TapoClip clip);

  /// Fetches [clip] into the cache; [onProgress] from 0 to 1; completing [cancel] stops it with kind cancelled
  Future<void> fetch(TapoClip clip, {void Function(double progress)? onProgress, Future<void>? cancel});

  Future<void> deleteCopy(TapoClip clip);

  Future<int> cacheBytes();

  Future<void> clearCache();
}

/// "Test the camera": the recordings check and the live check side by side, each only when its secrets are given
typedef TapoCameraTester = Future<TapoTestResult> Function(TapoTestRequest request);

/// The SHA-256 of the certificate the camera at [host] shows now (lower case hex), null when it does not answer; read
/// before a relocated camera is saved at its new address
typedef TapoCertificateReader = Future<String?> Function(String host);
