// What the pages of a camera of another brand ask of the network: the WS-Discovery search, the reading of a camera's
// ONVIF services at a typed address (its usual ports tried in turn), the stream addresses of the chosen profiles, and
// the test of a stream (RTSP DESCRIBE, nothing played) with what this device makes of its codecs. Each failure comes
// as an IpCameraException that the pages put into words.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/services/ip_camera.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/ipcam/camera_address.dart';
import 'package:immich_mobile/infrastructure/ipcam/onvif_client.dart';
import 'package:immich_mobile/infrastructure/ipcam/ws_discovery.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_probe.dart';
import 'package:logging/logging.dart';

final _log = Logger('IpCameraService');

/// Where this app plays a stream: the players of each platform (see the lot report of release 48)
enum CameraPlayer {
  /// Media3 on Android phones, Android TV and the Quest: H.264, H.265, AAC, G.711
  media3,

  /// Dart RTSP to HLS on iPhone and iPad: H.264 with G.711 sound (AAC plays without its sound)
  dartHls,

  /// libmpv on Windows, Linux and macOS: everything FFmpeg reads, MJPEG and RTSPS included
  libmpv,
}

CameraPlayer get currentCameraPlayer => CurrentPlatform.isDesktop
    ? CameraPlayer.libmpv
    : defaultTargetPlatform == TargetPlatform.iOS
    ? CameraPlayer.dartHls
    : CameraPlayer.media3;

/// Whether [player] shows a picture of [video] (an SDP or ONVIF encoding), null when the codec is unknown and the
/// player is left to try
bool? playsVideo(CameraPlayer player, String? video) {
  final codec = switch (video?.toUpperCase()) {
    'H264' => 'H264',
    'H265' || 'HEVC' => 'H265',
    'JPEG' || 'MJPEG' => 'JPEG',
    'MPEG4' || 'MP4V-ES' => 'MPEG4',
    null || '' => null,
    final String other => other,
  };
  if (codec == null) {
    return null;
  }
  return switch (player) {
    CameraPlayer.libmpv => true,
    CameraPlayer.media3 => codec == 'H264' || codec == 'H265' || codec == 'MPEG4',
    CameraPlayer.dartHls => codec == 'H264',
  };
}

/// The result of the test of a stream
class IpCameraStreamTest {
  const IpCameraStreamTest({required this.video, required this.audio, required this.playsHere});

  final String? video;
  final String? audio;

  /// Whether this device shows its picture (null: unknown codec, tried anyway)
  final bool? playsHere;
}

/// A camera read through ONVIF, ready to add
class IpCameraSetup {
  const IpCameraSetup({
    required this.port,
    required this.path,
    required this.reading,
    required this.main,
    this.sub,
    this.mainStream,
    this.subStream,
    this.snapshot,
  });

  /// The port and path of the device service that answered
  final int port;
  final String path;
  final OnvifCameraReading reading;
  final OnvifProfile main;
  final OnvifProfile? sub;

  /// The stream addresses on the host of the source, without account
  final CameraStreamAddress? mainStream;
  final CameraStreamAddress? subStream;
  final String? snapshot;
}

class IpCameraService {
  IpCameraService({
    this.post,
    Future<List<String>> Function()? localAddresses,
    Stream<DiscoveredOnvifDevice> Function({required List<String> localAddresses, List<String> unicastHosts})? discover,
    Future<TapoLiveProbe> Function(CameraStreamAddress address, String user, String password)? probe,
  }) : _localAddresses = localAddresses ?? localIPv4Addresses,
       _discover = discover ?? _defaultDiscover,
       _probe = probe ?? _defaultProbe;

  /// The HTTP of the ONVIF calls, the real one when null (tests give a fake camera)
  final OnvifPost? post;
  final Future<List<String>> Function() _localAddresses;
  final Stream<DiscoveredOnvifDevice> Function({required List<String> localAddresses, List<String> unicastHosts})
  _discover;
  final Future<TapoLiveProbe> Function(CameraStreamAddress address, String user, String password) _probe;

  static Stream<DiscoveredOnvifDevice> _defaultDiscover({
    required List<String> localAddresses,
    List<String> unicastHosts = const [],
  }) => discoverOnvifDevices(localAddresses: localAddresses, unicastHosts: unicastHosts);

  static Future<TapoLiveProbe> _defaultProbe(CameraStreamAddress address, String user, String password) =>
      probeTapoRtsp(address.host, port: address.port, path: address.pathAndQuery, user: user, password: password);

  /// The ONVIF devices of the network for a few seconds, and [typedHost] asked in unicast when given
  Stream<DiscoveredOnvifDevice> search({String? typedHost}) async* {
    final local = await _localAddresses();
    yield* _discover(localAddresses: local, unicastHosts: [?typedHost]);
  }

  /// Reads the camera at [host]: on [port] (its usual ports in turn when null) and [path]; its profiles, the main and
  /// sub ones picked, and their stream addresses. One try of the account per port that answers as ONVIF; the ports
  /// that do not answer cost nothing. Throws [IpCameraException].
  Future<IpCameraSetup> readOnvif({
    required String host,
    int? port,
    String path = onvifDevicePath,
    String user = '',
    String password = '',
  }) async {
    IpCameraException? last;
    for (final candidate in port == null ? onvifCandidatePorts : [port]) {
      final client = OnvifClient(host: host, port: candidate, path: path, user: user, password: password, post: post);
      final OnvifCameraReading reading;
      try {
        reading = await client.read();
      } on IpCameraException catch (error) {
        if (error.kind == IpCameraErrorKind.unreachable || error.kind == IpCameraErrorKind.notOnvif) {
          // The most telling failure is kept: something answering beats nothing
          if (last == null || last.kind == IpCameraErrorKind.unreachable) {
            last = error;
          }
          continue;
        }
        rethrow;
      }
      final picked = pickOnvifProfiles(reading.profiles);
      if (picked == null) {
        throw const IpCameraException(IpCameraErrorKind.noProfile);
      }
      final media = reading.services.media;
      final mainStream = await client.streamUri(media, picked.main.token);
      final sub = picked.sub;
      CameraStreamAddress? subStream;
      if (sub != null) {
        try {
          subStream = await client.streamUri(media, sub.token);
        } on IpCameraException catch (error) {
          _log.info('The sub stream has no address (${error.kind.name}): the main one serves both');
        }
      }
      final snapshot = await client.snapshotUri(media, picked.main.token);
      return IpCameraSetup(
        port: candidate,
        path: path,
        reading: reading,
        main: picked.main,
        sub: subStream == null ? null : sub,
        mainStream: mainStream,
        subStream: subStream,
        snapshot: snapshot,
      );
    }
    throw last ?? const IpCameraException(IpCameraErrorKind.unreachable);
  }

  /// Tests a stream: DESCRIBE with the account (none until the camera asks), its codecs read in the SDP, and whether
  /// this device plays them. An RTSPS address is tested through the plain port of a UniFi console; another is not
  /// tested here (no TLS in this client) and left to the player of a computer. Throws [IpCameraException].
  Future<IpCameraStreamTest> testStream(
    CameraStreamAddress address, {
    String user = '',
    String password = '',
    CameraPlayer? player,
  }) async {
    final on = player ?? currentCameraPlayer;
    final plain = phonePlayableAddress(address);
    if (plain == null) {
      if (on != CameraPlayer.libmpv) {
        throw const IpCameraException(IpCameraErrorKind.secureNotHere);
      }
      return const IpCameraStreamTest(video: null, audio: null, playsHere: null);
    }
    final TapoLiveProbe probe;
    try {
      probe = await _probe(plain, user, password);
    } on TapoCameraException catch (error) {
      throw ipCameraErrorOf(error, hasAccount: user.isNotEmpty);
    }
    final plays = playsVideo(on, probe.video);
    return IpCameraStreamTest(video: probe.video, audio: probe.audio, playsHere: plays);
  }
}

/// An RTSP failure of the shared client in the words of the pages of a camera of another brand
IpCameraException ipCameraErrorOf(TapoCameraException error, {required bool hasAccount}) => switch (error.kind) {
  TapoErrorKind.wrongPassword when !hasAccount || error.detail == rtspNeedsAccount => const IpCameraException(
    IpCameraErrorKind.needsAccount,
    status: 401,
  ),
  TapoErrorKind.wrongPassword => const IpCameraException(IpCameraErrorKind.wrongPassword, status: 401),
  TapoErrorKind.unreachable => const IpCameraException(IpCameraErrorKind.unreachable),
  TapoErrorKind.h265 => const IpCameraException(IpCameraErrorKind.codecNotPlayableHere, detail: 'H.265'),
  // Basic only, or an algorithm this client does not answer
  TapoErrorKind.unsupported when error.detail == 'RTSP authentication' => const IpCameraException(
    IpCameraErrorKind.basicOnly,
    status: 401,
  ),
  TapoErrorKind.unsupported when error.code == 404 => const IpCameraException(
    IpCameraErrorKind.noProfile,
    status: 404,
    detail: 'RTSP 404',
  ),
  _ => IpCameraException(IpCameraErrorKind.other, status: error.code, detail: error.detail ?? error.kind.name),
};
