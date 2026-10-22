// The live stream of a camera pulled in Dart, for the live view on iPhone and iPad (AVPlayer has no RTSP): one RTSP
// connection to the camera (554) with the camera account, the H.264 video and the G.711 sound as RTP inside it
// (interleaved, RTP over TCP as Media3 and libmpv do on the other platforms), kept alive at half the session timeout
// and ended with TEARDOWN. It grows out of the connection of "Test the camera" (rtsp_probe.dart) and keeps its rules:
// Digest only, never Basic, and the account and the Authorization header stay in this file, never in a log or in the
// text of an error.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_probe.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_media_session.dart';
import 'package:logging/logging.dart';

final _log = Logger('RtspSession');

/// One RTP or RTCP packet of the connection, on its interleaved channel (0 video RTP, 2 audio RTP, odd: RTCP)
class RtspInterleaved {
  const RtspInterleaved(this.channel, this.data);

  final int channel;
  final Uint8List data;
}

/// The interleaved channel of the video RTP packets
const rtspVideoChannel = 0;

/// The interleaved channel of the sound RTP packets
const rtspAudioChannel = 2;

/// The sound encodings the live view turns into PCM (G.711)
const rtspPlayableAudio = {'PCMA', 'PCMU'};

/// A camera stream being played: what the camera announced and set up, and its packets. [close] ends it.
class RtspSession {
  RtspSession._(this._connection, this._uri, this._aggregate, this.video, this.audio, this._keepAliveEvery) {
    _keepAlive = Timer.periodic(_keepAliveEvery, (_) => unawaited(_sendKeepAlive()));
  }

  /// Plays the stream at [path] of the camera at [host] with the camera account [user] and [password]: OPTIONS,
  /// DESCRIBE (answered with Digest), SETUP of the H.264 video and, with [withAudio], of the G.711 sound, then PLAY.
  /// Throws a [TapoCameraException]: wrongPassword when the camera refuses the account, h265 for an H.265 stream,
  /// unreachable, or unsupported. [keepAlive] replaces half the session timeout the camera announces (tests).
  static Future<RtspSession> open(
    String host, {
    int port = 554,
    String path = tapoRtspHdPath,
    required String user,
    required String password,
    bool withAudio = true,
    Duration timeout = const Duration(seconds: 8),
    Duration? keepAlive,
    TapoSocketConnector? connect,
  }) async {
    connect ??= _connect;
    final uri = 'rtsp://${host.contains(':') ? '[$host]' : host}:$port$path';
    var connection = await _RtspStreamConnection.open(host, port, timeout, connect);
    try {
      await connection.request('OPTIONS', uri);
      var answer = await connection.request('DESCRIBE', uri, {'Accept': 'application/sdp'});
      if (answer.status == 401) {
        final digest = RtspDigest.of(answer.headers['www-authenticate'] ?? const []);
        if (digest == null) {
          throw const TapoCameraException(TapoErrorKind.unsupported, detail: 'RTSP authentication');
        }
        connection.authorize(digest, user, password);
        try {
          if (connection.isClosed) {
            throw const TapoCameraException(TapoErrorKind.unreachable, detail: 'RTSP closed');
          }
          answer = await connection.request('DESCRIBE', uri, {'Accept': 'application/sdp'});
        } on TapoCameraException catch (error) {
          // A camera that closes the connection after its challenge: once more on a new one
          if (error.kind != TapoErrorKind.unreachable || !connection.isClosed) {
            rethrow;
          }
          await connection.close();
          connection = await _RtspStreamConnection.open(host, port, timeout, connect)
            ..authorize(digest, user, password);
          answer = await connection.request('DESCRIBE', uri, {'Accept': 'application/sdp'});
        }
      }
      _check(answer, 'DESCRIBE');
      final sdp = parseSdp(answer.body);
      final video = sdp.tracks.where((track) => track.media == 'video').firstOrNull;
      if (video == null) {
        throw const TapoCameraException(TapoErrorKind.unsupported, detail: 'no video');
      }
      if (video.encoding == 'H265') {
        throw const TapoCameraException(TapoErrorKind.h265);
      }
      if (video.encoding != 'H264') {
        throw TapoCameraException(TapoErrorKind.unsupported, detail: 'video ${video.encoding ?? 'unknown'}');
      }
      final audio = withAudio
          ? sdp.tracks
                .where((track) => track.media == 'audio' && rtspPlayableAudio.contains(track.encoding))
                .firstOrNull
          : null;
      // The base of the relative controls: Content-Base, else Content-Location, else the request URL
      final base = answer.headers['content-base']?.first ?? answer.headers['content-location']?.first ?? uri;
      final aggregate = _resolve(base, sdp.control);

      answer = await connection.request('SETUP', _resolve(base, video.control), {
        'Transport': 'RTP/AVP/TCP;unicast;interleaved=$rtspVideoChannel-${rtspVideoChannel + 1}',
      });
      _check(answer, 'SETUP');
      final sessionHeader = answer.headers['session']?.first;
      if (sessionHeader == null) {
        throw const TapoCameraException(TapoErrorKind.unsupported, detail: 'RTSP without session');
      }
      connection.session = sessionHeader.split(';').first.trim();
      final announced = int.tryParse(RegExp(r'timeout\s*=\s*(\d+)').firstMatch(sessionHeader)?.group(1) ?? '');
      final every = keepAlive ?? Duration(seconds: ((announced ?? 60) ~/ 2).clamp(5, 60));

      var audioTrack = audio;
      if (audio != null) {
        answer = await connection.request('SETUP', _resolve(base, audio.control), {
          'Transport': 'RTP/AVP/TCP;unicast;interleaved=$rtspAudioChannel-${rtspAudioChannel + 1}',
        });
        if (answer.status != 200) {
          // The video alone rather than nothing
          _log.info('The camera refused the sound track (${answer.status}): the live view plays without it');
          audioTrack = null;
        }
      }

      answer = await connection.request('PLAY', aggregate, {'Range': 'npt=0.000-'});
      _check(answer, 'PLAY');
      final session = RtspSession._(connection, uri, aggregate, video, audioTrack, every);
      session._readRtpInfo(answer.headers['rtp-info']?.first, base);
      return session;
    } catch (error) {
      await connection.close();
      rethrow;
    }
  }

  static Future<Socket> _connect(String host, int port, Duration timeout) =>
      Socket.connect(host, port, timeout: timeout);

  static void _check(_RtspMessage answer, String method) {
    if (answer.status == 401) {
      throw const TapoCameraException(TapoErrorKind.wrongPassword, code: 401);
    }
    if (answer.status == 453) {
      // Not enough bandwidth: the camera already serves its viewers
      throw const TapoCameraException(TapoErrorKind.busy, code: 453);
    }
    if (answer.status != 200) {
      throw TapoCameraException(
        TapoErrorKind.unsupported,
        code: answer.status,
        detail: 'RTSP $method ${answer.status}',
      );
    }
  }

  /// [control] against [base] (RFC 2326 C.1.1): absolute, or appended to the base
  static String _resolve(String base, String control) {
    if (control.isEmpty || control == '*') {
      return base;
    }
    if (control.toLowerCase().startsWith('rtsp://')) {
      return control;
    }
    return base.endsWith('/') ? '$base$control' : '$base/$control';
  }

  final _RtspStreamConnection _connection;
  final String _uri;
  final String _aggregate;
  final Duration _keepAliveEvery;
  late final Timer _keepAlive;

  /// The video the camera sends (H.264)
  final RtspTrack video;

  /// The sound set up (G.711), null without one
  final RtspTrack? audio;

  /// The RTP time of the start of the stream on each track (RTP-Info of PLAY), null when the camera does not tell:
  /// what places the sound against the video
  int? videoRtpTime;
  int? audioRtpTime;

  /// The RTP packets of the stream; done when the connection ends, with a [TapoCameraException] when the camera cut it
  Stream<RtspInterleaved> get packets => _connection.packets;

  void _readRtpInfo(String? rtpInfo, String base) {
    if (rtpInfo == null) {
      return;
    }
    int? rtpTime(RtspTrack track) {
      final url = _resolve(base, track.control);
      for (final part in rtpInfo.split(',')) {
        final fields = {
          for (final field in part.split(';'))
            if (field.contains('='))
              field.substring(0, field.indexOf('=')).trim().toLowerCase(): field
                  .substring(field.indexOf('=') + 1)
                  .trim(),
        };
        final partUrl = fields['url'];
        if (partUrl == null) {
          continue;
        }
        // An absolute URL, or the control alone
        if (partUrl == url || (track.control.isNotEmpty && partUrl.endsWith(track.control))) {
          return int.tryParse(fields['rtptime'] ?? '');
        }
      }
      return null;
    }

    videoRtpTime = rtpTime(video);
    final audio = this.audio;
    if (audio != null) {
      audioRtpTime = rtpTime(audio);
    }
  }

  Future<void> _sendKeepAlive() async {
    if (_connection.isClosed) {
      return;
    }
    try {
      // OPTIONS with the session, as Media3 does: every camera answers it
      await _connection.request('OPTIONS', _uri);
    } catch (error) {
      _log.fine('The keep alive of the live stream got no answer: ${error.runtimeType}');
    }
  }

  /// Ends the stream: TEARDOWN (not awaited for long: a camera that went away does not answer), then the connection
  Future<void> close() async {
    _keepAlive.cancel();
    if (!_connection.isClosed) {
      try {
        await _connection.request('TEARDOWN', _aggregate).timeout(const Duration(seconds: 2));
      } catch (_) {
        // The camera ends the session at its timeout
      }
    }
    await _connection.close();
  }
}

/// An RTSP answer
class _RtspMessage {
  const _RtspMessage(this.status, this.headers, this.body);

  final int status;

  /// Header names in lower case; a header given several times keeps every value
  final Map<String, List<String>> headers;
  final String body;
}

/// One TCP connection carrying the RTSP requests and answers and the interleaved packets (RFC 2326 10.12): a `$`, the
/// channel, a 16 bit length and the packet, between the text messages. One request at a time.
class _RtspStreamConnection {
  _RtspStreamConnection(this._socket, this._timeout) {
    _subscription = _socket.listen(
      _onData,
      onError: (Object _) => _end(const TapoCameraException(TapoErrorKind.unreachable, detail: 'RTSP lost')),
      onDone: () => _end(const TapoCameraException(TapoErrorKind.unreachable, detail: 'RTSP closed')),
      cancelOnError: true,
    );
  }

  static Future<_RtspStreamConnection> open(
    String host,
    int port,
    Duration timeout,
    TapoSocketConnector connect,
  ) async {
    try {
      // Destroyed by close
      // ignore: close_sinks
      final socket = await connect(host, port, timeout);
      try {
        socket.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {
        // A test socket
      }
      return _RtspStreamConnection(socket, timeout);
    } on SocketException {
      throw TapoCameraException(TapoErrorKind.unreachable, detail: host);
    } on TimeoutException {
      throw TapoCameraException(TapoErrorKind.unreachable, detail: host);
    }
  }

  /// Most bytes waited for in one message: an answer or a packet never comes near it
  static const _maxPending = 1024 * 1024;

  final Socket _socket;
  final Duration _timeout;
  late final StreamSubscription<Uint8List> _subscription;
  final _packets = StreamController<RtspInterleaved>(sync: true);
  Uint8List _pending = Uint8List(0);
  int _sequence = 0;
  bool _closed = false;
  Completer<_RtspMessage>? _waiting;
  Future<void> _previous = Future.value();

  /// The Session header of the requests once SETUP gave one
  String? session;

  RtspDigest? _digest;
  String? _user;
  String? _password;

  bool get isClosed => _closed;

  Stream<RtspInterleaved> get packets => _packets.stream;

  /// Answers each next request with [digest] and the account
  void authorize(RtspDigest digest, String user, String password) {
    _digest = digest;
    _user = user;
    _password = password;
  }

  /// Sends [method] on [uri] once the previous request is answered, and waits for its answer
  Future<_RtspMessage> request(String method, String uri, [Map<String, String> headers = const {}]) {
    final answer = _previous.then((_) => _send(method, uri, headers));
    _previous = answer.then<void>((_) {}, onError: (Object _) {});
    return answer;
  }

  Future<_RtspMessage> _send(String method, String uri, Map<String, String> headers) async {
    if (_closed) {
      throw const TapoCameraException(TapoErrorKind.unreachable, detail: 'RTSP closed');
    }
    _sequence++;
    final text = StringBuffer('$method $uri RTSP/1.0\r\nCSeq: $_sequence\r\nUser-Agent: Immuch360\r\n');
    final digest = _digest;
    if (digest != null) {
      text.write('Authorization: ${digest.authorization(method, uri, _user!, _password!)}\r\n');
    }
    final session = this.session;
    if (session != null) {
      text.write('Session: $session\r\n');
    }
    headers.forEach((name, value) => text.write('$name: $value\r\n'));
    text.write('\r\n');
    final waiting = _waiting = Completer<_RtspMessage>();
    try {
      _socket.add(utf8.encode(text.toString()));
      return await waiting.future.timeout(_timeout);
    } on TimeoutException {
      throw const TapoCameraException(TapoErrorKind.unreachable, detail: 'RTSP silent');
    } finally {
      if (identical(_waiting, waiting)) {
        _waiting = null;
      }
    }
  }

  void _onData(Uint8List chunk) {
    if (_closed) {
      return;
    }
    final data = _pending.isEmpty
        ? chunk
        : (BytesBuilder(copy: false)
                ..add(_pending)
                ..add(chunk))
              .takeBytes();
    var offset = 0;
    while (offset < data.length && !_closed) {
      if (data[offset] == 0x24) {
        if (data.length - offset < 4) {
          break;
        }
        final channel = data[offset + 1];
        final length = (data[offset + 2] << 8) | data[offset + 3];
        if (data.length - offset - 4 < length) {
          break;
        }
        _packets.add(RtspInterleaved(channel, Uint8List.sublistView(data, offset + 4, offset + 4 + length)));
        offset += 4 + length;
        continue;
      }
      final end = _headerEnd(data, offset);
      if (end < 0) {
        break;
      }
      final lines = latin1.decode(Uint8List.sublistView(data, offset, end)).split('\r\n');
      final headers = <String, List<String>>{};
      for (final line in lines.skip(1)) {
        final colon = line.indexOf(':');
        if (colon > 0) {
          headers
              .putIfAbsent(line.substring(0, colon).trim().toLowerCase(), () => [])
              .add(line.substring(colon + 1).trim());
        }
      }
      final length = int.tryParse(headers['content-length']?.first ?? '') ?? 0;
      if (data.length - end - 4 < length) {
        break;
      }
      final body = utf8.decode(Uint8List.sublistView(data, end + 4, end + 4 + length), allowMalformed: true);
      offset = end + 4 + length;
      final first = lines.first.split(' ');
      if (first.first.startsWith('RTSP/')) {
        final waiting = _waiting;
        _waiting = null;
        waiting?.complete(_RtspMessage(int.tryParse(first.elementAtOrNull(1) ?? '') ?? 0, headers, body));
      }
      // A request of the camera (rare): nothing the live view needs to answer
    }
    // The views given out point into [data], which is never written again: the rest is copied apart
    _pending = offset >= data.length ? Uint8List(0) : Uint8List.fromList(Uint8List.sublistView(data, offset));
    if (_pending.length > _maxPending) {
      _end(const TapoCameraException(TapoErrorKind.unsupported, detail: 'RTSP framing'));
      unawaited(close());
    }
  }

  /// The start of the blank line that ends the headers of the message at [from], -1 when it did not arrive yet
  static int _headerEnd(Uint8List data, int from) {
    for (var i = from; i + 3 < data.length; i++) {
      if (data[i] == 13 && data[i + 1] == 10 && data[i + 2] == 13 && data[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  void _end(TapoCameraException reason) {
    if (_closed) {
      return;
    }
    _closed = true;
    final waiting = _waiting;
    _waiting = null;
    waiting?.completeError(reason);
    _packets.addError(reason);
    unawaited(_packets.close());
  }

  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      final waiting = _waiting;
      _waiting = null;
      waiting?.completeError(const TapoCameraException(TapoErrorKind.cancelled));
      unawaited(_packets.close());
    }
    await _subscription.cancel();
    _socket.destroy();
  }
}
