// An RTSP server on 127.0.0.1 that answers as the cameras do: OPTIONS, DESCRIBE refused with a Digest challenge then
// answered with the SDP, SETUP of interleaved tracks, PLAY with RTP-Info, then the RTP packets it was given on their
// channels. It keeps every request for the tests to read, and can cut the connection as a camera that restarts.
// Synthetic values only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';

const fakeRtspRealm = 'TP-Link IP-Camera';
const fakeRtspNonce = '0123456789abcdef';
const fakeRtspSession = '5A3B1C9D';

/// The SPS and PPS of the H.264 test pattern of test/fixtures/tapo (64x36, High), as the cameras put them in the SDP
const fakeSpropParameterSets = 'Z2QACqyyCP8+AiAAAAMAIAAAAwPB4kTJ,aOvDyyLA';

String fakeRtspSdp({String video = 'H264', String? audio = 'PCMA', bool sessionControl = false}) =>
    'v=0\r\n'
    'o=- 14665860 31787219 1 IN IP4 192.0.2.30\r\n'
    's=Session streamed by "TP-LINK RTSP Server"\r\n'
    't=0 0\r\n'
    '${sessionControl ? 'a=control:*\r\n' : ''}'
    'm=video 0 RTP/AVP 96\r\n'
    'c=IN IP4 0.0.0.0\r\n'
    'b=AS:4096\r\n'
    'a=control:track1\r\n'
    'a=rtpmap:96 $video/90000\r\n'
    'a=fmtp:96 packetization-mode=1; profile-level-id=64000A; sprop-parameter-sets=$fakeSpropParameterSets\r\n'
    '${audio == null ? '' : 'm=audio 0 RTP/AVP 8\r\na=rtpmap:8 $audio/8000\r\na=control:track2\r\n'}';

class FakeRtspCamera {
  FakeRtspCamera._(
    this._server, {
    required this.user,
    required this.password,
    required this.qop,
    required this.basicOnly,
    required this.sdp,
    required this.refuseAudio,
    required this.sessionTimeout,
    required this.rtpInfo,
    required this.closeAfterChallenge,
    required this.playStatus,
    required this.frames,
    required this.chunkSize,
  }) {
    _server.listen(_accept);
  }

  static Future<FakeRtspCamera> start({
    String user = 'viewer',
    String password = 'camera-account-pw',
    bool qop = false,
    bool basicOnly = false,
    String? sdp,
    bool refuseAudio = false,
    int? sessionTimeout = 60,
    bool rtpInfo = true,
    bool closeAfterChallenge = false,
    int playStatus = 200,
    List<(int, Uint8List)> frames = const [],
    int chunkSize = 1500,
  }) async => FakeRtspCamera._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    user: user,
    password: password,
    qop: qop,
    basicOnly: basicOnly,
    sdp: sdp ?? fakeRtspSdp(),
    refuseAudio: refuseAudio,
    sessionTimeout: sessionTimeout,
    rtpInfo: rtpInfo,
    closeAfterChallenge: closeAfterChallenge,
    playStatus: playStatus,
    frames: frames,
    chunkSize: chunkSize,
  );

  final ServerSocket _server;
  final String user;
  final String password;
  final bool qop;
  final bool basicOnly;
  final String sdp;
  final bool refuseAudio;
  final int? sessionTimeout;
  final bool rtpInfo;
  final bool closeAfterChallenge;
  final int playStatus;

  /// What follows the answer to PLAY: (channel, RTP packet)
  final List<(int, Uint8List)> frames;

  /// The size of the writes after PLAY: messages and packets cut anywhere, as TCP does
  final int chunkSize;

  /// Every request received, whole
  final List<String> requests = [];
  final List<Socket> _sockets = [];
  final _played = Completer<void>();
  final _tornDown = Completer<void>();

  int get port => _server.port;

  List<String> get methods => [for (final request in requests) request.split(' ').first];

  /// Completes once PLAY was answered and the packets sent
  Future<void> get played => _played.future;

  /// Completes at the first TEARDOWN
  Future<void> get tornDown => _tornDown.future;

  /// The value of [name] in [request], null when it has none
  static String? header(String request, String name) {
    for (final line in request.split('\r\n').skip(1)) {
      final colon = line.indexOf(':');
      if (colon > 0 && line.substring(0, colon).trim().toLowerCase() == name.toLowerCase()) {
        return line.substring(colon + 1).trim();
      }
    }
    return null;
  }

  void _accept(Socket socket) {
    _sockets.add(socket);
    var buffer = '';
    socket.listen((data) {
      buffer += latin1.decode(data);
      while (buffer.contains('\r\n\r\n')) {
        final end = buffer.indexOf('\r\n\r\n');
        final request = buffer.substring(0, end);
        buffer = buffer.substring(end + 4);
        requests.add(request);
        unawaited(_answer(socket, request));
      }
    }, onError: (Object _) {});
  }

  Future<void> _answer(Socket socket, String request) async {
    final line = request.split('\r\n').first.split(' ');
    final method = line.first;
    final uri = line[1];
    final cseq = header(request, 'CSeq');
    String reply(String status, [Map<String, String> headers = const {}, String body = '']) {
      final out = StringBuffer('RTSP/1.0 $status\r\nCSeq: $cseq\r\n');
      headers.forEach((name, value) => out.write('$name: $value\r\n'));
      if (body.isNotEmpty) {
        out.write('Content-Length: ${utf8.encode(body).length}\r\n');
      }
      out.write('\r\n$body');
      return out.toString();
    }

    void send(String text) {
      try {
        socket.add(utf8.encode(text));
      } catch (_) {
        // The client went
      }
    }

    if (method == 'OPTIONS') {
      return send(reply('200 OK', {'Public': 'OPTIONS, DESCRIBE, SETUP, TEARDOWN, PLAY, GET_PARAMETER'}));
    }
    final authorization = header(request, 'Authorization');
    final challenge = basicOnly
        ? 'Basic realm="x"'
        : 'Digest realm="$fakeRtspRealm", nonce="$fakeRtspNonce"${qop ? ', qop="auth"' : ''}';
    if (authorization == null || basicOnly || !_valid(authorization, method, uri)) {
      send(reply('401 Unauthorized', {'WWW-Authenticate': challenge}));
      if (closeAfterChallenge) {
        await socket.flush();
        socket.destroy();
      }
      return;
    }
    switch (method) {
      case 'DESCRIBE':
        return send(reply('200 OK', {'Content-Type': 'application/sdp', 'Content-Base': '$uri/'}, sdp));
      case 'SETUP':
        if (refuseAudio && uri.endsWith('track2')) {
          return send(reply('461 Unsupported Transport'));
        }
        final transport = header(request, 'Transport') ?? '';
        return send(
          reply('200 OK', {
            'Session': sessionTimeout == null ? fakeRtspSession : '$fakeRtspSession;timeout=$sessionTimeout',
            'Transport': transport,
          }),
        );
      case 'PLAY':
        if (playStatus != 200) {
          return send(reply('$playStatus Refused'));
        }
        final base = uri.endsWith('/') ? uri : '$uri/';
        send(
          reply('200 OK', {
            'Session': fakeRtspSession,
            'Range': 'npt=0.000-',
            if (rtpInfo)
              'RTP-Info': 'url=${base}track1;seq=1000;rtptime=3000000,url=${base}track2;seq=500;rtptime=160000',
          }),
        );
        await _sendFrames(socket);
        if (!_played.isCompleted) {
          _played.complete();
        }
        return;
      case 'TEARDOWN':
        send(reply('200 OK', {'Session': fakeRtspSession}));
        if (!_tornDown.isCompleted) {
          _tornDown.complete();
        }
        return;
      default:
        return send(reply('200 OK', {'Session': fakeRtspSession}));
    }
  }

  Future<void> _sendFrames(Socket socket) async {
    final out = BytesBuilder();
    for (final (channel, packet) in frames) {
      out
        ..add([0x24, channel, packet.length >> 8, packet.length & 0xff])
        ..add(packet);
    }
    final bytes = out.takeBytes();
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      try {
        socket.add(
          Uint8List.sublistView(bytes, offset, offset + chunkSize > bytes.length ? bytes.length : offset + chunkSize),
        );
        await socket.flush();
      } catch (_) {
        return;
      }
    }
  }

  bool _valid(String authorization, String method, String uri) {
    if (!authorization.startsWith('Digest ')) {
      return false;
    }
    final fields = {
      for (final match in RegExp(r'(\w+)=(?:"([^"]*)"|([^,\s]+))').allMatches(authorization.substring(7)))
        match.group(1)!: match.group(2) ?? match.group(3)!,
    };
    final ha1 = md5Hex('$user:$fakeRtspRealm:$password');
    final ha2 = md5Hex('$method:${fields['uri']}');
    final expected = qop
        ? md5Hex('$ha1:$fakeRtspNonce:${fields['nc']}:${fields['cnonce']}:auth:$ha2')
        : md5Hex('$ha1:$fakeRtspNonce:$ha2');
    return fields['username'] == user && fields['response'] == expected && fields['uri'] == uri;
  }

  /// Cuts every connection, as a camera that restarts
  void cut() {
    for (final socket in _sockets) {
      socket.destroy();
    }
  }

  Future<void> close() async {
    cut();
    await _server.close();
  }
}
