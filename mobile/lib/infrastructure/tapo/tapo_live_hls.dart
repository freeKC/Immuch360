// The live view of a camera on iPhone and iPad (AVPlayer has no RTSP): the RTSP stream pulled in Dart with the camera
// account (RtspSession), cut into a live HLS playlist of fragmented MP4 (HlsLiveSegmenter) and served from memory by
// the local media bridge under a random id. The player gets an http://127.0.0.1 address without any account: the
// camera account never leaves Dart.
//
// One session per view and per stream (HD or SD): a camera serves two viewers at most, the Tapo app included. It ends
// when the view stops it, when the camera stops sending, and when the player has not asked for anything for a while
// (a player gone without a word), so that the camera never keeps a viewer for nothing.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/hls_live_segmenter.dart';
import 'package:immich_mobile/infrastructure/tapo/rtp_h264.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_session.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_media_session.dart';
import 'package:logging/logging.dart';

final _log = Logger('TapoLiveHls');

/// Why a live playlist ended or never started, for the state line of the live view
const tapoLiveNoPicture = 'no picture from the camera';
const tapoLiveStreamLost = 'the camera stopped sending';
const tapoLivePlayerGone = 'the player stopped asking';

/// The name of the playlist of a session on the bridge
const tapoLivePlaylistName = 'live.m3u8';

/// A live playlist of a camera, as the live view on iPhone and iPad uses it: the tests give a fake one
abstract class LiveHlsStream {
  /// Plays the camera and waits for the first segment: the address of the playlist on the bridge. Throws a
  /// [TapoCameraException] (wrongPassword, h265, busy, unreachable, unsupported).
  Future<Uri> start();

  /// Whether the playlist carries the sound of the camera
  bool get hasAudio;

  /// Completes when the stream ended by itself after [start], with the reason; never after [stop]
  Future<String> get ended;

  /// Ends the stream: TEARDOWN, and the playlist leaves the bridge
  Future<void> stop();
}

/// Makes the live playlist of the stream at [path] of the camera at [host]
typedef LiveHlsStarter = LiveHlsStream Function({
  required String host,
  required int port,
  required String path,
  required String user,
  required String password,
  required bool withAudio,
});

class TapoLiveHls implements LiveHlsStream, GeneratedMedia {
  TapoLiveHls({
    required this.bridge,
    required this.host,
    required this.port,
    required this.path,
    required this.user,
    required this.password,
    this.withAudio = true,
    this.firstSegmentTimeout = const Duration(seconds: 20),
    this.stallTimeout = const Duration(seconds: 10),
    this.idleTimeout = const Duration(seconds: 15),
    this.checkPeriod = const Duration(seconds: 1),
    this.connect,
  });

  final MediaBridge bridge;
  final String host;
  final int port;
  final String path;
  final String user;
  final String password;

  /// Whether the sound is asked for: the live view asks for the video alone when AVPlayer refused the playlist with it
  final bool withAudio;

  /// Longest wait for the first segment once the camera plays (its first IDR picture, then one GOP)
  final Duration firstSegmentTimeout;

  /// Longest time without a packet from the camera
  final Duration stallTimeout;

  /// Longest time without a request of the player, from the first segment on
  final Duration idleTimeout;
  final Duration checkPeriod;
  final TapoSocketConnector? connect;

  final String _id = _randomId();
  RtspSession? _rtsp;
  HlsLiveSegmenter? _segmenter;
  StreamSubscription<RtspInterleaved>? _packets;
  Timer? _watch;
  final _firstSegment = Completer<void>();
  final _ended = Completer<String>();
  final _released = Completer<void>();
  final _clock = Stopwatch()..start();
  Duration _lastPacket = Duration.zero;
  Duration _lastRequest = Duration.zero;
  bool _started = false;
  bool _stopped = false;
  bool _hasAudio = false;

  @override
  bool get hasAudio => _hasAudio;

  @override
  Future<String> get ended => _ended.future;

  @override
  Future<Uri> start() async {
    await bridge.start();
    final rtsp = await RtspSession.open(
      host,
      port: port,
      path: path,
      user: user,
      password: password,
      withAudio: withAudio,
      connect: connect,
    );
    if (_stopped) {
      await rtsp.close();
      throw const TapoCameraException(TapoErrorKind.cancelled);
    }
    _rtsp = rtsp;
    final audio = rtsp.audio;
    final audioTable = switch (audio?.encoding) {
      'PCMA' when audio!.channels == 1 => alawToPcm16,
      'PCMU' when audio!.channels == 1 => ulawToPcm16,
      _ => null,
    };
    _hasAudio = audioTable != null;
    final (sps, pps) = _parameterSets(rtsp.video.fmtp['sprop-parameter-sets']);
    final segmenter = _segmenter = HlsLiveSegmenter(
      audioRate: audioTable == null ? null : (audio!.clockRate > 0 ? audio.clockRate : 8000),
      videoRtpTime: rtsp.videoRtpTime,
      audioRtpTime: rtsp.audioRtpTime,
      sps: sps,
      pps: pps,
      onSegment: (_) {
        if (!_firstSegment.isCompleted) {
          _firstSegment.complete();
        }
      },
    );
    final depacketizer = H264Depacketizer(segmenter.addVideo);
    final videoType = rtsp.video.payloadType;
    final audioType = audio?.payloadType;
    _lastPacket = _clock.elapsed;
    _packets = rtsp.packets.listen(
      (packet) {
        _lastPacket = _clock.elapsed;
        if (packet.channel == rtspVideoChannel) {
          final rtp = RtpPacket.parse(packet.data);
          if (rtp != null && rtp.payloadType == videoType) {
            depacketizer.add(rtp);
          }
        } else if (packet.channel == rtspAudioChannel && audioTable != null) {
          final rtp = RtpPacket.parse(packet.data);
          if (rtp != null && rtp.payloadType == audioType) {
            final payload = rtp.payload;
            final samples = Int16List(payload.length);
            for (var i = 0; i < payload.length; i++) {
              samples[i] = audioTable[payload[i]];
            }
            segmenter.addAudio(rtp.timestamp, samples);
          }
        }
      },
      onError: (Object error) => _lose(tapoLiveStreamLost),
      onDone: () => _lose(tapoLiveStreamLost),
    );
    bridge.registerGenerated(_id, this);
    _watch = Timer.periodic(checkPeriod, (_) => _check());
    // The first segment, or the end of the stream before it
    final ready = Completer<String?>();
    unawaited(_firstSegment.future.then((_) => ready.isCompleted ? null : ready.complete()));
    unawaited(_ended.future.then((reason) => ready.isCompleted ? null : ready.complete(reason)));
    unawaited(_released.future.then((_) => ready.isCompleted ? null : ready.complete()));
    final String? lost;
    try {
      lost = await ready.future.timeout(firstSegmentTimeout);
    } on TimeoutException {
      await stop();
      throw const TapoCameraException(TapoErrorKind.unsupported, detail: tapoLiveNoPicture);
    }
    if (lost != null) {
      await stop();
      throw const TapoCameraException(TapoErrorKind.unreachable, detail: tapoLiveStreamLost);
    }
    if (_stopped) {
      throw const TapoCameraException(TapoErrorKind.cancelled);
    }
    _started = true;
    _lastRequest = _clock.elapsed;
    return bridge.urlFor(_id, tapoLivePlaylistName);
  }

  void _check() {
    if (_stopped) {
      return;
    }
    final now = _clock.elapsed;
    if (now - _lastPacket > stallTimeout) {
      _lose(tapoLiveStreamLost);
    } else if (_started && now - _lastRequest > idleTimeout) {
      _lose(tapoLivePlayerGone);
    }
  }

  void _lose(String reason) {
    if (_stopped) {
      return;
    }
    _log.info('The live stream ended: $reason');
    if (!_ended.isCompleted) {
      _ended.complete(reason);
    }
    unawaited(_release());
  }

  @override
  GeneratedFile? file(String name) {
    final segmenter = _segmenter;
    if (segmenter == null || _stopped) {
      return null;
    }
    _lastRequest = _clock.elapsed;
    if (name == tapoLivePlaylistName) {
      final playlist = segmenter.playlist();
      return playlist == null
          ? null
          : GeneratedFile(Uint8List.fromList(utf8.encode(playlist)), 'application/vnd.apple.mpegurl');
    }
    final init = RegExp(r'^init(\d+)\.mp4$').firstMatch(name);
    if (init != null) {
      final bytes = segmenter.init(int.parse(init.group(1)!));
      return bytes == null ? null : GeneratedFile(bytes, 'video/mp4');
    }
    final segment = RegExp(r'^seg(\d+)\.m4s$').firstMatch(name);
    if (segment != null) {
      final found = segmenter.segment(int.parse(segment.group(1)!));
      return found == null ? null : GeneratedFile(found.bytes, 'video/mp4');
    }
    return null;
  }

  @override
  Future<void> stop() => _release();

  Future<void> _release() async {
    if (_stopped) {
      return;
    }
    _stopped = true;
    _released.complete();
    _watch?.cancel();
    _watch = null;
    bridge.unregisterGenerated(_id);
    await _packets?.cancel();
    _packets = null;
    await _rtsp?.close();
    _rtsp = null;
    _segmenter = null;
  }

  /// The SPS and PPS of sprop-parameter-sets (RFC 6184), null when the SDP does not hold them
  static (Uint8List?, Uint8List?) _parameterSets(String? sprop) {
    Uint8List? sps;
    Uint8List? pps;
    for (final value in sprop?.split(',') ?? const <String>[]) {
      try {
        final nal = base64.decode(value.trim());
        if (nal.isEmpty) {
          continue;
        }
        if ((nal[0] & 0x1f) == 7) {
          sps ??= nal;
        } else if ((nal[0] & 0x1f) == 8) {
          pps ??= nal;
        }
      } on FormatException {
        continue;
      }
    }
    return (sps, pps);
  }

  static String _randomId() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return 'live-${String.fromCharCodes(List.generate(24, (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length))))}';
  }
}
