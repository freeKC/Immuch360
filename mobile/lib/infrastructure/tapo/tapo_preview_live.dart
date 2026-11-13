// The live view of a camera through its media port (8800) instead of RTSP: the only local stream of the battery and
// solar cameras (C400 to C460: no RTSP, no ONVIF, no camera account), and a live view without a camera account for the
// others. As the Tapo app, pytapo's Streamer and go2rtc's tapo:// source do: the media port login with the password of
// the TP-Link account (tapo_media_session.dart), then the preview request, answered with encrypted video/mp2t parts
// of the main stream (HD) or of the sub stream (VGA). The MPEG-TS is demuxed (MpegTsDemuxer) and cut into the same
// fragmented MP4 live playlist as the RTSP stream on iPhone and iPad (HlsLiveSegmenter), served from memory by the
// local media bridge: the player gets an http://127.0.0.1 address without any password.
//
// A battery camera sleeps between two uses and does not answer the first connection after a while (the integration
// of Home Assistant tells its users to open the camera in the Tapo app first, HomeAssistant-Tapo-Control#1422): the
// connection is tried a few times before the camera is said not to answer, and the first picture is waited for longer
// than on a mains camera. Each failure says at which step it happened (TapoLiveException), for the diagnostics line
// of the camera page.
//
// The sound is G.711 at the rate of the camera's microphone (8 or 16 kHz): the rate is read from the PTS of the first
// two audio PES before the playlist starts; a stream without sound starts without it after a short wait.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/hls_live_segmenter.dart';
import 'package:immich_mobile/infrastructure/tapo/mpeg_ts_demuxer.dart';
import 'package:immich_mobile/infrastructure/tapo/rtp_h264.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_live_hls.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_media_session.dart';
import 'package:logging/logging.dart';

final _log = Logger('TapoPreviewLive');

/// The live request of the media port (pytapo Streamer._build_preview_payload): HD is the main stream, VGA the sub one
Map<String, Object?> tapoPreviewParams({required bool hd}) => {
  'preview': {
    'audio': ['default'],
    'channels': [0],
    'resolutions': [hd ? 'HD' : 'VGA'],
  },
  'method': 'get',
};

/// The rate of a G.711 sound from two PES: [samples] bytes (one per sample) over [ptsTicks] of the 90 kHz clock,
/// snapped to the rates of the cameras; null when it cannot be told
int? tapoAudioRate(int samples, int ptsTicks) {
  if (samples <= 0 || ptsTicks <= 0) {
    return null;
  }
  final rate = samples * HlsLiveSegmenter.videoTimescale / ptsTicks;
  if (rate >= 6000 && rate <= 10000) {
    return 8000;
  }
  if (rate >= 12000 && rate <= 20000) {
    return 16000;
  }
  return null;
}

class TapoPreviewLiveHls implements LiveHlsStream, GeneratedMedia {
  TapoPreviewLiveHls({
    required this.bridge,
    required this.host,
    required this.port,
    required this.password,
    required this.hd,
    this.withAudio = true,
    this.connectAttempts = 3,
    this.connectTimeout = const Duration(seconds: 6),
    this.wakePause = const Duration(seconds: 2),
    this.audioWait = const Duration(milliseconds: 1500),
    this.firstSegmentTimeout = const Duration(seconds: 30),
    this.stallTimeout = const Duration(seconds: 10),
    this.idleTimeout = const Duration(seconds: 15),
    this.checkPeriod = const Duration(seconds: 1),
    this.connect,
  });

  final MediaBridge bridge;
  final String host;

  /// The media port, 8800 unless the source says otherwise
  final int port;

  /// The password of the TP-Link account
  final String password;

  /// The main stream, else the sub stream
  final bool hd;

  /// Whether the sound is asked for: the live view asks for the video alone when the player refused it with the sound
  final bool withAudio;

  /// Connections tried before the camera is said not to answer (a sleeping battery camera misses the first ones)
  final int connectAttempts;
  final Duration connectTimeout;
  final Duration wakePause;

  /// Longest wait for the second audio PES (the rate of the sound) once the first picture is there
  final Duration audioWait;

  /// Longest wait for the first segment once the camera accepted the request
  final Duration firstSegmentTimeout;

  /// Longest time without a part from the camera
  final Duration stallTimeout;

  /// Longest time without a request of the player, from the first segment on
  final Duration idleTimeout;
  final Duration checkPeriod;
  final TapoSocketConnector? connect;

  final String _id = _randomId();
  TapoMediaSession? _session;
  HlsLiveSegmenter? _segmenter;
  late final MpegTsDemuxer _demuxer = MpegTsDemuxer(onVideo: _video, onAudio: _audio);
  Timer? _watch;
  final _firstSegment = Completer<void>();
  final _ended = Completer<String>();
  final _released = Completer<void>();

  /// A failure before the first segment, which [start] throws
  final _failure = Completer<TapoLiveException>();
  final _clock = Stopwatch()..start();
  Duration _lastPart = Duration.zero;
  Duration _lastRequest = Duration.zero;
  bool _started = false;
  bool _stopped = false;
  bool _hasAudio = false;

  /// The pictures that came before the playlist could start (the rate of the sound was not known yet)
  final List<H264AccessUnit> _pending = [];
  Duration? _firstPictureAt;
  int? _firstAudioPts;
  int _firstAudioSamples = 0;
  int? _audioRate;
  bool _audioRateTold = false;

  /// The step [start] is at, for a failure it did not foresee
  TapoLiveStep _step = TapoLiveStep.connect;

  @override
  bool get hasAudio => _hasAudio;

  @override
  Future<String> get ended => _ended.future;

  @override
  Future<Uri> start() async {
    await bridge.start();
    final session = await _open();
    if (_stopped) {
      await session.close();
      throw const TapoCameraException(TapoErrorKind.cancelled);
    }
    _session = session;
    _log.info('The media port took the password (${session.passwordHash.name}); asking for the live stream');
    _step = TapoLiveStep.request;
    session.request(tapoPreviewParams(hd: hd));
    _lastPart = _clock.elapsed;
    bridge.registerGenerated(_id, this);
    _watch = Timer.periodic(checkPeriod, (_) => _check());
    unawaited(_pump(session));
    // The first segment, a refusal of the camera, or the end of the stream before it
    final ready = Completer<Object?>();
    void settle(Object? value) => ready.isCompleted ? null : ready.complete(value);
    unawaited(_firstSegment.future.then((_) => settle(null)));
    unawaited(_failure.future.then(settle));
    unawaited(_ended.future.then(settle));
    unawaited(_released.future.then((_) => settle(null)));
    final Object? outcome;
    try {
      outcome = await ready.future.timeout(firstSegmentTimeout);
    } on TimeoutException {
      await stop();
      throw TapoLiveException(_step, TapoErrorKind.unsupported, detail: tapoLiveNoPicture);
    }
    if (outcome is TapoLiveException) {
      await stop();
      throw outcome;
    }
    if (outcome is String) {
      await stop();
      throw TapoLiveException(_step, TapoErrorKind.unreachable, detail: tapoLiveStreamLost);
    }
    if (_stopped) {
      throw const TapoCameraException(TapoErrorKind.cancelled);
    }
    _started = true;
    _lastRequest = _clock.elapsed;
    return bridge.urlFor(_id, tapoLivePlaylistName);
  }

  /// The login of the media port, tried again while the camera does not answer (it may be waking up)
  Future<TapoMediaSession> _open() async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await TapoMediaSession.open(
          host,
          password,
          port: port,
          timeout: connectTimeout,
          connect: connect ?? _socketConnect,
        );
      } on TapoCameraException catch (error) {
        if (error.kind == TapoErrorKind.unreachable && attempt < connectAttempts && !_stopped) {
          _log.info('The media port did not answer (attempt $attempt of $connectAttempts); trying again');
          await Future<void>.delayed(wakePause);
          continue;
        }
        if (error.kind == TapoErrorKind.unreachable) {
          throw TapoLiveException.at(TapoLiveStep.connect, error);
        }
        throw TapoLiveException.at(TapoLiveStep.login, error);
      }
    }
  }

  static Future<Socket> _socketConnect(String host, int port, Duration timeout) =>
      Socket.connect(host, port, timeout: timeout);

  Future<void> _pump(TapoMediaSession session) async {
    try {
      while (!_stopped) {
        final TapoMediaPart? part;
        try {
          // A camera that just woke up may take a while to send its first part
          part = await session.next(timeout: _step == TapoLiveStep.request ? firstSegmentTimeout : stallTimeout);
        } on TimeoutException {
          _lose(tapoLiveStreamLost);
          return;
        }
        if (part == null) {
          _lose(tapoLiveStreamLost);
          return;
        }
        _lastPart = _clock.elapsed;
        if (part.isJson) {
          final control = tapoControlPart(part.body);
          final code = control.errorCode;
          if (code != null) {
            _fail(
              TapoLiveException(
                TapoLiveStep.request,
                tapoBusyCodes.contains(code) ? TapoErrorKind.busy : TapoErrorKind.unsupported,
                code: code,
              ),
            );
            return;
          }
          if (control.finished) {
            _lose(tapoLiveStreamLost);
            return;
          }
        } else if (part.contentType.startsWith('video/mp2t')) {
          if (_step == TapoLiveStep.request) {
            _step = TapoLiveStep.firstPicture;
          }
          _demuxer.feed(part.body, wallMs: part.wallMs);
        }
      }
    } on TapoCameraException catch (error) {
      _fail(TapoLiveException.at(_step, error));
    } catch (error) {
      _log.warning('The live stream of the media port failed: ${error.runtimeType}');
      _lose(tapoLiveStreamLost);
    }
  }

  void _video(TsVideoFrame frame) {
    if (_stopped) {
      return;
    }
    if (_demuxer.videoCodec == TsVideoCodec.h265) {
      _fail(const TapoLiveException(TapoLiveStep.firstPicture, TapoErrorKind.h265));
      return;
    }
    final pts = frame.pts;
    if (pts == null) {
      return;
    }
    final unit = H264AccessUnit(pts & 0xffffffff, frame.nalUnits);
    final segmenter = _segmenter;
    if (segmenter != null) {
      segmenter.addVideo(unit);
      return;
    }
    if (_pending.isEmpty && !unit.isIdr) {
      // The playlist starts at an IDR picture
      return;
    }
    _firstPictureAt ??= _clock.elapsed;
    _pending.add(unit);
    if (!withAudio || _audioRateTold || _clock.elapsed - _firstPictureAt! >= audioWait) {
      _startSegmenter();
    }
  }

  void _audio(TsAudioChunk chunk) {
    if (_stopped || !withAudio) {
      return;
    }
    final pts = chunk.pts;
    if (!_audioRateTold) {
      if (pts == null) {
        return;
      }
      final first = _firstAudioPts;
      if (first == null) {
        _firstAudioPts = pts;
        _firstAudioSamples = chunk.samples.length;
        return;
      }
      _audioRate = tapoAudioRate(_firstAudioSamples, pts - first);
      _audioRateTold = true;
      if (_pending.isNotEmpty) {
        _startSegmenter();
      }
    }
    final segmenter = _segmenter;
    final rate = _audioRate;
    if (segmenter == null || rate == null || !_hasAudio || pts == null) {
      return;
    }
    final table = chunk.codec == TsAudioCodec.alaw ? alawToPcm16 : ulawToPcm16;
    final samples = Int16List(chunk.samples.length);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = table[chunk.samples[i]];
    }
    segmenter.addAudio((pts * rate ~/ HlsLiveSegmenter.videoTimescale) & 0xffffffff, samples);
  }

  void _startSegmenter() {
    final rate = withAudio ? _audioRate : null;
    _hasAudio = rate != null;
    final segmenter = _segmenter = HlsLiveSegmenter(
      audioRate: rate,
      onSegment: (_) {
        if (!_firstSegment.isCompleted) {
          _step = TapoLiveStep.stream;
          _firstSegment.complete();
        }
      },
    );
    for (final unit in _pending) {
      segmenter.addVideo(unit);
    }
    _pending.clear();
  }

  void _check() {
    if (_stopped) {
      return;
    }
    final now = _clock.elapsed;
    if (_step != TapoLiveStep.request && now - _lastPart > stallTimeout) {
      _lose(tapoLiveStreamLost);
    } else if (_started && now - _lastRequest > idleTimeout) {
      _lose(tapoLivePlayerGone);
    } else if (_segmenter == null && _firstPictureAt != null && now - _firstPictureAt! >= audioWait) {
      // A stream without sound: the playlist starts without it
      _startSegmenter();
    }
  }

  void _fail(TapoLiveException failure) {
    if (_stopped) {
      return;
    }
    _log.info('The live stream of the media port stopped: $failure');
    if (!_started) {
      if (!_failure.isCompleted) {
        _failure.complete(failure);
      }
      return;
    }
    _lose(tapoLiveStreamLost);
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
    final session = _session;
    _session = null;
    if (session != null) {
      // "do stop" frees the camera's session slot: it serves two viewers at most
      session.stop();
      await session.close();
    }
    _segmenter = null;
    _pending.clear();
  }

  static String _randomId() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return 'live-${String.fromCharCodes(List.generate(24, (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length))))}';
  }
}
