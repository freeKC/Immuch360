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

class TapoCameraDetails {
  const TapoCameraDetails({
    required this.alias,
    required this.model,
    required this.firmware,
    required this.mac,
    this.zoneId,
  });

  /// device_alias, the name given in the Tapo app
  final String alias;
  final String model;
  final String firmware;

  /// aa-bb-cc-dd-ee-ff, lower case: the discoveryId of the source
  final String mac;
  final String? zoneId;
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
