// The live side of "Test the camera": OPTIONS then DESCRIBE on the RTSP port of the camera (554) with the camera
// account, answered with Digest authentication, and the codecs of the streams read from the SDP. Nothing is played: no
// SETUP, no media. The account and the Authorization header stay in this file, never in a log. Basic authentication is
// never answered: the cameras ask for Digest, and Basic would hand the password in clear to whoever answers at the
// address.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_media_session.dart';

/// The RTSP paths of the cameras: the main stream (HD) and the sub stream (SD)
const tapoRtspHdPath = '/stream1';
const tapoRtspSdPath = '/stream2';

/// What an RTSP answer is made of
class _RtspAnswer {
  const _RtspAnswer(this.status, this.headers, this.body);

  final int status;

  /// Header names in lower case; a header given several times (WWW-Authenticate) keeps every value
  final Map<String, List<String>> headers;
  final String body;
}

/// The codecs of the stream at [path] of the camera at [host], asked with the camera account [user] and [password].
/// Throws a [TapoCameraException]: wrongPassword when the camera refuses the account, unreachable, or unsupported.
Future<TapoLiveProbe> probeTapoRtsp(
  String host, {
  int port = 554,
  String path = tapoRtspHdPath,
  required String user,
  required String password,
  Duration timeout = const Duration(seconds: 8),
  TapoSocketConnector connect = _connect,
}) async {
  final uri = 'rtsp://${host.contains(':') ? '[$host]' : host}:$port$path';
  var connection = await _RtspConnection.open(host, port, timeout, connect);
  try {
    await connection.send('OPTIONS', uri, const {});
    var answer = await connection.send('DESCRIBE', uri, const {'Accept': 'application/sdp'});
    if (answer.status == 401) {
      final authorization = _authorization(
        answer.headers['www-authenticate'] ?? const [],
        'DESCRIBE',
        uri,
        user,
        password,
      );
      if (authorization == null) {
        throw const TapoCameraException(TapoErrorKind.unsupported, detail: 'RTSP authentication');
      }
      if (connection.isClosed) {
        await connection.close();
        connection = await _RtspConnection.open(host, port, timeout, connect);
      }
      answer = await connection.send('DESCRIBE', uri, {'Accept': 'application/sdp', 'Authorization': authorization});
      if (answer.status == 401) {
        throw const TapoCameraException(TapoErrorKind.wrongPassword, code: 401);
      }
    }
    if (answer.status != 200) {
      throw TapoCameraException(TapoErrorKind.unsupported, code: answer.status, detail: 'RTSP ${answer.status}');
    }
    return parseSdpCodecs(answer.body);
  } finally {
    await connection.close();
  }
}

Future<Socket> _connect(String host, int port, Duration timeout) => Socket.connect(host, port, timeout: timeout);

/// The video and audio codecs an SDP announces ("H264", "PCMA"): the encoding of the rtpmap of the first payload type
/// of each media, or the static payload type (0 PCMU, 8 PCMA)
TapoLiveProbe parseSdpCodecs(String sdp) {
  String? video;
  String? audio;
  String? media;
  List<String> payloads = const [];
  final maps = <String, String>{};
  final firsts = <String, String>{};
  for (final raw in const LineSplitter().convert(sdp)) {
    final line = raw.trim();
    if (line.startsWith('m=')) {
      final fields = line.substring(2).split(' ');
      media = fields.first;
      payloads = fields.length > 3 ? fields.sublist(3) : const [];
      if (payloads.isNotEmpty) {
        firsts.putIfAbsent(media, () => payloads.first);
      }
    } else if (line.startsWith('a=rtpmap:') && media != null) {
      final rest = line.substring(9);
      final space = rest.indexOf(' ');
      if (space > 0) {
        maps['$media/${rest.substring(0, space)}'] = rest.substring(space + 1).split('/').first.toUpperCase();
      }
    }
  }
  String? codec(String kind) {
    final payload = firsts[kind];
    if (payload == null) {
      return null;
    }
    return maps['$kind/$payload'] ?? const {'0': 'PCMU', '8': 'PCMA'}[payload];
  }

  video = codec('video');
  audio = codec('audio');
  return TapoLiveProbe(video: video, audio: audio);
}

/// The Authorization of the first Digest challenge (MD5, with or without qop auth), null without one
String? _authorization(List<String> challenges, String method, String uri, String user, String password) {
  for (final challenge in challenges) {
    if (!challenge.toLowerCase().startsWith('digest')) {
      continue;
    }
    final params = <String, String>{
      for (final match in RegExp(r'(\w+)\s*=\s*(?:"([^"]*)"|([^,\s]+))').allMatches(challenge.substring(6)))
        match.group(1)!.toLowerCase(): match.group(2) ?? match.group(3)!,
    };
    final realm = params['realm'];
    final nonce = params['nonce'];
    if (realm == null || nonce == null) {
      continue;
    }
    final ha1 = md5Hex('$user:$realm:$password');
    final ha2 = md5Hex('$method:$uri');
    final qop = params['qop']?.split(',').map((value) => value.trim()).contains('auth') ?? false;
    final cnonce = hexOf(randomBytes(8));
    final response = qop ? md5Hex('$ha1:$nonce:00000001:$cnonce:auth:$ha2') : md5Hex('$ha1:$nonce:$ha2');
    final opaque = params['opaque'];
    return 'Digest username="$user", realm="$realm", nonce="$nonce", uri="$uri", response="$response"'
        '${opaque == null ? '' : ', opaque="$opaque"'}'
        '${qop ? ', qop=auth, nc=00000001, cnonce="$cnonce"' : ''}';
  }
  return null;
}

class _RtspConnection {
  _RtspConnection(this._socket, this._timeout) {
    _subscription = _socket.listen(
      (chunk) {
        _buffer.add(chunk);
        _wake();
      },
      onError: (Object _) {
        _closed = true;
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
      cancelOnError: true,
    );
  }

  static Future<_RtspConnection> open(String host, int port, Duration timeout, TapoSocketConnector connect) async {
    try {
      return _RtspConnection(await connect(host, port, timeout), timeout);
    } on SocketException {
      throw TapoCameraException(TapoErrorKind.unreachable, detail: host);
    } on TimeoutException {
      throw TapoCameraException(TapoErrorKind.unreachable, detail: host);
    }
  }

  final Socket _socket;
  final Duration _timeout;
  late final StreamSubscription<Uint8List> _subscription;
  final _buffer = BytesBuilder();
  Completer<void>? _waiting;
  bool _closed = false;
  int _sequence = 0;

  bool get isClosed => _closed;

  void _wake() {
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }

  Future<_RtspAnswer> send(String method, String uri, Map<String, String> headers) async {
    if (_closed) {
      throw const TapoCameraException(TapoErrorKind.unreachable, detail: 'RTSP closed');
    }
    _sequence++;
    final request = StringBuffer('$method $uri RTSP/1.0\r\nCSeq: $_sequence\r\nUser-Agent: Immuch360\r\n');
    headers.forEach((name, value) => request.write('$name: $value\r\n'));
    request.write('\r\n');
    _socket.add(utf8.encode(request.toString()));
    try {
      return await _answer();
    } on TimeoutException {
      throw const TapoCameraException(TapoErrorKind.unreachable, detail: 'RTSP silent');
    }
  }

  Future<_RtspAnswer> _answer() async {
    while (true) {
      final bytes = _buffer.toBytes();
      final end = _indexOf(bytes, const [13, 10, 13, 10]);
      if (end >= 0) {
        final lines = latin1.decode(Uint8List.sublistView(bytes, 0, end)).split('\r\n');
        final status = int.tryParse(lines.first.split(' ').elementAtOrNull(1) ?? '') ?? 0;
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
        if (bytes.length >= end + 4 + length) {
          final body = utf8.decode(Uint8List.sublistView(bytes, end + 4, end + 4 + length), allowMalformed: true);
          final rest = Uint8List.sublistView(bytes, end + 4 + length);
          _buffer
            ..clear()
            ..add(rest);
          return _RtspAnswer(status, headers, body);
        }
      }
      if (_closed) {
        throw const TapoCameraException(TapoErrorKind.unreachable, detail: 'RTSP closed');
      }
      final waiting = _waiting = Completer<void>();
      await waiting.future.timeout(_timeout);
    }
  }

  static int _indexOf(Uint8List bytes, List<int> marker) {
    for (var i = 0; i + marker.length <= bytes.length; i++) {
      var match = true;
      for (var j = 0; j < marker.length; j++) {
        if (bytes[i + j] != marker[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        return i;
      }
    }
    return -1;
  }

  Future<void> close() async {
    _closed = true;
    await _subscription.cancel();
    _socket.destroy();
  }
}
