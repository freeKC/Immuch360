// A fake media port of a camera (Streamd, port 8800) on 127.0.0.1, after tapo-v4-protocol/tests/test_tapo_media.py:
// the 401 with the Digest challenge on a first connection, the check of the Digest response and the Key-Exchange on a
// second one, then the answers to the download requests: the parts of a clip (encrypted video/mp2t with their
// sequence and wall clock, an acknowledgement awaited every 25 parts) or the picture of a recording, then finished.
// Busy answers and a refused password on demand. Synthetic values only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';

import 'tapo_test_streams.dart';

/// A small JPEG-like picture: what the camera sends for media_type 2
final Uint8List fakeSnapshot = Uint8List.fromList([0xff, 0xd8, ...List.filled(5000, 0x4a), 0xff, 0xd9]);

class FakeStreamd {
  FakeStreamd._(this._server, this.password);

  static Future<FakeStreamd> start({String password = 'synthetic-cloud-password'}) async =>
      FakeStreamd._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), password).._listen();

  final ServerSocket _server;
  final String password;
  int get port => _server.port;

  static const _boundary = '--device-stream-boundary--';
  final _nonce = '0123456789abcdef0123456789abcdef';
  String get _hashed => sha256HexUpper(password);

  /// The parts of the clip sent for a video download
  List<StreamPart> clip = clipParts(fixtureAccessUnits());

  /// The answer to the next download requests: an error code (-52405 busy) instead of the media
  final List<int> refuseNext = [];

  /// Refuses the Digest response
  bool refusePassword = false;

  /// Leaves a request without an answer (a continuous recording asked for its picture)
  bool silentSnapshots = false;

  /// Encrypts the parts with another key than the one the key exchange gives (a camera that holds a local access token
  /// for its videos, P§7.2)
  bool scrambleParts = false;

  // What the tests look at
  int connections = 0;
  final List<Map<String, Object?>> requests = [];
  final List<Map<String, String>> requestHeaders = [];
  final List<Map<String, String>> acks = [];
  final List<Map<String, String>> stops = [];
  int sessions = 0;
  final List<String> errors = [];

  void _listen() {
    _server.listen((socket) {
      connections++;
      unawaited(_serve(socket, connections).catchError((Object error) => errors.add('$error')));
    });
  }

  Future<void> close() => _server.close();

  Future<void> _serve(Socket socket, int number) async {
    // A client that cancels resets the connection: what is still written to it fails there, as on a camera
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
    final reader = _Reader(socket);
    final head = latin1.decode(await reader.until('\r\n\r\n'));
    final authorization = RegExp(r'Authorization: Digest (.*)').firstMatch(head)?.group(1);
    if (authorization == null) {
      socket.add(
        latin1.encode(
          'HTTP/1.0 401 Unauthorized\r\nServer: Streamd\r\nContent-Length: 0\r\nWWW-Authenticate: Digest '
          'realm="TP-Link IP-Camera",algorithm="MD5",encrypt_type="3",qop="auth",nonce="abc123",opaque="op"\r\n'
          'Connection: close\r\n\r\n',
        ),
      );
      await socket.flush();
      socket.destroy();
      return;
    }
    final fields = {
      for (final match in RegExp(r'(\w+)=("([^"]*)"|[^,]+)').allMatches(authorization))
        match.group(1)!: match.group(3) ?? match.group(2)!,
    };
    final ha1 = md5Hex('admin:TP-Link IP-Camera:$_hashed');
    final ha2 = md5Hex('POST:/stream');
    final good = md5Hex('$ha1:abc123:${fields['nc']}:${fields['cnonce']}:auth:$ha2');
    if (refusePassword || fields['response'] != good) {
      socket.add(latin1.encode('HTTP/1.0 401 Unauthorized\r\nContent-Length: 0\r\n\r\n'));
      await socket.flush();
      socket.destroy();
      return;
    }
    sessions++;
    final session = '${20 + sessions}';
    socket.add(
      latin1.encode(
        'HTTP/1.1 200 OK\r\nServer: Streamd\r\nContent-Type: multipart/mixed;boundary=$_boundary\r\n'
        'Key-Exchange: cipher="AES_128_CBC" username="admin" padding="PKCS7_16" algorithm="MD5" nonce="$_nonce"\r\n'
        'Connection: keep-alive\r\n\r\n',
      ),
    );
    var seq = 0;
    while (true) {
      final part = await reader.part();
      if (part == null) {
        break;
      }
      final (headers, body) = part;
      final message = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
      if (message['type'] == 'notification') {
        acks.add(headers);
        continue;
      }
      final params = (message['params']! as Map).cast<String, Object?>();
      if (params['method'] == 'do') {
        stops.add(headers);
        continue;
      }
      requests.add(message);
      requestHeaders.add(headers);
      if (refuseNext.isNotEmpty) {
        _send(
          socket,
          'application/json',
          utf8.encode(
            '{"type":"response", "seq":${message['seq']}, "params":{"error_code":${refuseNext.removeAt(0)}}}',
          ),
        );
        continue;
      }
      _send(
        socket,
        'application/json',
        utf8.encode('{"type":"response", "seq":${message['seq']}, "params":{"error_code":0, "session_id":"$session"}}'),
      );
      final download = (params['download']! as Map).cast<String, Object?>();
      if (download['media_type'] == 2) {
        if (silentSnapshots) {
          continue;
        }
        _send(socket, 'image/jpeg', fakeSnapshot, encrypt: true, extra: {'X-Session-Id': session});
      } else {
        final start = int.parse('${download['start_time']}');
        for (final part in clip) {
          _send(
            socket,
            'video/mp2t',
            part.ts,
            encrypt: true,
            extra: {
              'X-Session-Id': session,
              'X-Data-Sequence': '$seq',
              // The wall clock of the clip, from its start
              'X-Data-PTS': '${start * 1000 + (part.wallMs - clip.first.wallMs)}',
              if (part.isKey) 'X-If-IFrame': '1',
            },
          );
          if (seq > 0 && seq % 25 == 0) {
            // The window of 50: the camera waits for the acknowledgement of this part
            final ack = await reader.part();
            if (ack == null) {
              return;
            }
            if (_isStop(ack.$2)) {
              // A client that cancels says "do stop": the stream ends there
              stops.add(ack.$1);
              return;
            }
            acks.add(ack.$1);
          }
          seq++;
        }
      }
      _send(
        socket,
        'application/json',
        utf8.encode('{"type":"notification", "params":{"event_type":"stream_status", "status":"finished"}}'),
        extra: {'X-Session-Id': session},
      );
    }
    socket.destroy();
  }

  static bool _isStop(Uint8List body) {
    try {
      final message = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
      return message['type'] == 'request' && (message['params'] as Map?)?['method'] == 'do';
    } on FormatException {
      return false;
    }
  }

  void _send(Socket socket, String type, List<int> body, {bool encrypt = false, Map<String, String> extra = const {}}) {
    var bytes = Uint8List.fromList(body);
    if (encrypt) {
      final key = md5Bytes(utf8.encode('$_nonce:${scrambleParts ? 'other' : _hashed}'));
      final iv = md5Bytes(utf8.encode('admin:$_nonce'));
      bytes = aesCbcEncrypt(key, iv, bytes);
    }
    final head = StringBuffer('--$_boundary\r\n')
      ..write('Content-Type: $type\r\n')
      ..write('Content-Length: ${bytes.length}\r\n')
      ..write('X-If-Encrypt: ${encrypt ? 1 : 0}\r\n');
    extra.forEach((name, value) => head.write('$name: $value\r\n'));
    head.write('\r\n');
    try {
      socket
        ..add(latin1.encode(head.toString()))
        ..add(bytes)
        ..add(const [13, 10]);
    } on SocketException {
      // The client went away
    }
  }
}

class _Reader {
  _Reader(Socket socket) {
    socket.listen(
      (chunk) {
        _buffer.add(chunk);
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      onError: (Object _) {
        _done = true;
        _wake();
      },
    );
  }

  final _buffer = BytesBuilder();
  Completer<void>? _waiting;
  bool _done = false;

  void _wake() {
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }

  Future<void> _more() async {
    if (_done) {
      throw const SocketException('closed');
    }
    final waiting = _waiting = Completer<void>();
    await waiting.future.timeout(const Duration(seconds: 10));
  }

  Future<Uint8List> until(String marker) async {
    final pattern = latin1.encode(marker);
    while (true) {
      final bytes = _buffer.toBytes();
      final index = _indexOf(bytes, pattern);
      if (index >= 0) {
        _buffer
          ..clear()
          ..add(bytes.sublist(index + pattern.length));
        return bytes.sublist(0, index);
      }
      await _more();
    }
  }

  Future<Uint8List> exact(int length) async {
    while (_buffer.length < length) {
      await _more();
    }
    final bytes = _buffer.toBytes();
    _buffer
      ..clear()
      ..add(bytes.sublist(length));
    return bytes.sublist(0, length);
  }

  /// The next part of the client, null once it closed the connection
  Future<(Map<String, String>, Uint8List)?> part() async {
    try {
      await until('----client-stream-boundary--\r\n');
      final headers = {
        for (final line in latin1.decode(await until('\r\n\r\n')).split('\r\n'))
          if (line.contains(':'))
            line.split(':').first.trim().toLowerCase(): line.substring(line.indexOf(':') + 1).trim(),
      };
      final body = await exact(int.parse(headers['content-length'] ?? '0'));
      return (headers, body);
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  static int _indexOf(Uint8List bytes, List<int> pattern) {
    for (var i = 0; i + pattern.length <= bytes.length; i++) {
      var match = true;
      for (var j = 0; j < pattern.length; j++) {
        if (bytes[i + j] != pattern[j]) {
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
}
