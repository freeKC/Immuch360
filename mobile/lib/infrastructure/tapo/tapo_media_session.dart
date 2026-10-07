// The media port of a camera (8800, Tapo design 2.7, P§7): a long POST /stream exchange in multipart parts both ways.
// A first connection gets the Digest challenge (the camera closes it), a second one logs in with the password of the
// TP-Link account hashed as the challenge asks (SHA-256 upper hex when encrypt_type is "3", else MD5) and gets a
// Key-Exchange header: the encrypted parts are AES-128-CBC with key = MD5(nonce ":" hashed) and iv = MD5("admin:"
// nonce), the cipher started again for every part. The camera stops sending once 50 data parts are not acknowledged:
// every 25th is.
//
// A clip comes from the download request (about ten times real time, it stops at the end of the clip) and the picture
// of an event recording from the same request with media_type 2. A connection serves one media type: thumbnails and
// clips use separate connections. Runs in the isolates of tapo_media_worker.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_login.dart';

/// The codes a camera answers when another viewer holds its media sessions: retried later (P§7.11)
const tapoBusyCodes = {-52405, -52407, -52417, -52435};

/// Opens a TCP connection, injectable for the tests
typedef TapoSocketConnector = Future<Socket> Function(String host, int port, Duration timeout);

Future<Socket> _connect(String host, int port, Duration timeout) => Socket.connect(host, port, timeout: timeout);

const _clientBoundary = '--client-stream-boundary--';

/// One part from the camera, decrypted
class TapoMediaPart {
  const TapoMediaPart({required this.contentType, required this.headers, required this.body});

  final String contentType;

  /// Header names in lower case
  final Map<String, String> headers;
  final Uint8List body;

  /// X-Data-Sequence: the number of the data part in its session, from 0
  int? get sequence => int.tryParse(headers['x-data-sequence'] ?? '');

  /// X-Data-PTS: the wall clock of the access unit, in milliseconds since 1970
  int? get wallMs => int.tryParse(headers['x-data-pts'] ?? '');

  bool get isJson => contentType.startsWith('application/json');
}

/// One logged in connection to the media port
class TapoMediaSession {
  TapoMediaSession._(this._socket, this._reader, this._decryptor, this._boundary);

  final Socket _socket;
  final _SocketReader _reader;
  final AesCbcDecryptor _decryptor;
  final Uint8List _boundary;
  int _seq = 0;
  bool _closed = false;
  Future<void>? _closing;

  /// The session the camera gave, from its first answer
  String? sessionId;

  /// How often a data part is acknowledged: half of the window announced, as the official app does
  static const window = 50;
  static const _ackEvery = window ~/ 2;

  /// Logs in to the media port of [host]. Throws a [TapoCameraException]: unreachable, busy, mediaLocked when the
  /// camera refuses the password (the control login worked, so the camera holds another one for its videos, P§7.2),
  /// unsupported for anything else.
  static Future<TapoMediaSession> open(
    String host,
    String password, {
    int port = 8800,
    Duration timeout = const Duration(seconds: 15),
    TapoSocketConnector connect = _connect,
  }) async {
    if (password.isEmpty) {
      throw const TapoCameraException(TapoErrorKind.mediaLocked);
    }
    Future<(Socket, _SocketReader)> connectOnce() async {
      try {
        // Closed by the callers, which take it with its reader
        // ignore: close_sinks
        final socket = await connect(host, port, timeout);
        socket.setOption(SocketOption.tcpNoDelay, true);
        return (socket, _SocketReader(socket, timeout));
      } on SocketException {
        throw TapoCameraException(TapoErrorKind.unreachable, detail: host);
      } on TimeoutException {
        throw TapoCameraException(TapoErrorKind.unreachable, detail: host);
      }
    }

    // The challenge: the camera answers 401 and closes the connection
    final (first, firstReader) = await connectOnce();
    final Map<String, String> challenge;
    try {
      first.add(_head(null));
      final (status, headers, body) = await _readHead(firstReader);
      final authenticate = headers['www-authenticate'];
      if (status != 401 || authenticate == null || !authenticate.toLowerCase().startsWith('digest')) {
        throw _refusal(status, body);
      }
      challenge = _parsePairs(authenticate.substring(6), ',');
    } finally {
      firstReader.cancel();
      first.destroy();
    }
    final realm = challenge['realm'] ?? '';
    final nonce = challenge['nonce'] ?? '';
    final hashed = challenge['encrypt_type'] == '3' ? sha256HexUpper(password) : md5HexUpper(password);
    final cnonce = hexOf(randomBytes(12));
    const nc = '00000001';
    final ha1 = md5Hex('$tapoAdminUser:$realm:$hashed');
    final ha2 = md5Hex('POST:/stream');
    final response = md5Hex('$ha1:$nonce:$nc:$cnonce:auth:$ha2');
    final authorization =
        'Digest username="$tapoAdminUser",realm="$realm",uri="/stream",algorithm=MD5,nonce="$nonce",nc=$nc,'
        'cnonce="$cnonce",qop=auth,response="$response",opaque="${challenge['opaque'] ?? ''}"';

    final (socket, reader) = await connectOnce();
    try {
      socket.add(_head(authorization));
      final (status, headers, body) = await _readHead(reader);
      if (status == 401) {
        throw const TapoCameraException(TapoErrorKind.mediaLocked, code: 401);
      }
      if (status != 200) {
        throw _refusal(status, body);
      }
      final keyExchange = headers['key-exchange'];
      if (keyExchange == null) {
        throw const TapoCameraException(TapoErrorKind.unsupported, detail: 'Key-Exchange');
      }
      final exchange = _parsePairs(keyExchange, ' ');
      final exchangeNonce = exchange['nonce'] ?? '';
      final exchangeUser = exchange['username'] ?? tapoAdminUser;
      var boundary = '--device-stream-boundary--';
      for (final piece in (headers['content-type'] ?? '').split(';')) {
        final trimmed = piece.trim();
        if (trimmed.startsWith('boundary=')) {
          boundary = trimmed.substring(9);
        }
      }
      return TapoMediaSession._(
        socket,
        reader,
        AesCbcDecryptor(
          md5Bytes(utf8.encode('$exchangeNonce:$hashed')),
          md5Bytes(utf8.encode('$exchangeUser:$exchangeNonce')),
        ),
        Uint8List.fromList(latin1.encode(boundary)),
      );
    } catch (_) {
      reader.cancel();
      socket.destroy();
      rethrow;
    }
  }

  static Uint8List _head(String? authorization) => Uint8List.fromList(
    latin1.encode(
      'POST /stream HTTP/1.1\r\n'
      'Content-Type: multipart/mixed;boundary=$_clientBoundary\r\n'
      'Connection: keep-alive\r\n'
      'Content-Length: -1\r\n'
      '${authorization == null ? '' : 'Authorization: $authorization\r\n'}'
      '\r\n',
    ),
  );

  /// The status line, the headers (names in lower case) and a short body of the answer to the head
  static Future<(int, Map<String, String>, Uint8List)> _readHead(_SocketReader reader) async {
    try {
      final block = latin1.decode(await reader.readUntil(_crlfCrlf));
      final lines = block.split('\r\n');
      final status = int.tryParse(lines.first.split(' ').elementAtOrNull(1) ?? '') ?? 0;
      final headers = _headersOf(lines.skip(1));
      var body = Uint8List(0);
      final length = int.tryParse(headers['content-length'] ?? '');
      if (status != 200 && length != null && length > 0 && length < 4096) {
        body = await reader.readExact(length);
      }
      return (status, headers, body);
    } on _ConnectionEnded {
      throw const TapoCameraException(TapoErrorKind.unsupported, detail: 'media port closed');
    } on TimeoutException {
      throw const TapoCameraException(TapoErrorKind.unreachable);
    } on SocketException {
      throw const TapoCameraException(TapoErrorKind.unreachable);
    }
  }

  /// A refused head: the busy codes come as the JSON body of a 503 (P§10.2)
  static TapoCameraException _refusal(int status, Uint8List body) {
    final code = _errorCodeOf(body);
    if (code != null && tapoBusyCodes.contains(code)) {
      return TapoCameraException(TapoErrorKind.busy, code: code);
    }
    return TapoCameraException(TapoErrorKind.unsupported, code: code, detail: 'media port HTTP $status');
  }

  /// Sends `{"type":"request","seq":n,"params":params}`; [withSession] adds the session (the do requests)
  void request(Map<String, Object?> params, {bool withSession = false}) {
    _seq++;
    final body = utf8.encode(jsonEncode({'type': 'request', 'seq': _seq, 'params': params}));
    _sendPart({
      'X-Data-Window-Size': '$window',
      'Content-Type': 'application/json',
      if (withSession && sessionId != null) 'X-Session-Id': sessionId!,
      'Content-Length': '${body.length}',
    }, body);
  }

  void _sendPart(Map<String, String> headers, List<int> body) {
    if (_closed) {
      return;
    }
    final head = StringBuffer('--$_clientBoundary\r\n');
    headers.forEach((name, value) => head.write('$name: $value\r\n'));
    head.write('\r\n');
    _socket
      ..add(latin1.encode(head.toString()))
      ..add(body)
      ..add(const [13, 10]);
  }

  /// The next part, decrypted, null once the camera closed the connection. Acknowledges every 25th data part.
  /// Throws a [TimeoutException] when nothing comes within the time limit, a [TapoCameraException] mediaLocked when a
  /// part does not decrypt (the camera holds another password for its videos).
  Future<TapoMediaPart?> next({Duration? timeout}) async {
    try {
      await _reader.readUntil(_boundary, timeout: timeout);
      final headers = _headersOf(latin1.decode(await _reader.readUntil(_crlfCrlf, timeout: timeout)).split('\r\n'));
      final length = int.tryParse(headers['content-length'] ?? '0') ?? 0;
      var body = length > 0 ? await _reader.readExact(length, timeout: timeout) : Uint8List(0);
      if (headers['x-if-encrypt']?.trim() == '1' && body.isNotEmpty) {
        try {
          body = _decryptor.decrypt(body);
        } on FormatException {
          throw const TapoCameraException(TapoErrorKind.mediaLocked);
        }
      }
      final session = headers['x-session-id'];
      if (session != null) {
        sessionId = session;
      }
      final sequence = int.tryParse(headers['x-data-sequence'] ?? '');
      if (session != null && sequence != null && sequence > 0 && sequence % _ackEvery == 0) {
        _acknowledge(session, sequence);
      }
      return TapoMediaPart(contentType: headers['content-type'] ?? '', headers: headers, body: body);
    } on _ConnectionEnded {
      return null;
    }
  }

  void _acknowledge(String session, int sequence) {
    final body = utf8.encode('{"type":"notification","params":{"event_type":"stream_sequence"}}');
    _sendPart({
      'X-Data-Received': '$sequence',
      'X-Session-Id': session,
      'Content-Type': 'application/json',
      'Content-Length': '${body.length}',
    }, body);
  }

  /// Tells the camera to end the stream, which frees its session slot; best effort, nothing is awaited
  void stop() {
    if (sessionId == null || _closed) {
      return;
    }
    try {
      request({'stop': 'null', 'method': 'do'}, withSession: true);
    } catch (_) {
      // The connection is going anyway
    }
  }

  /// Sends what is left (a "do stop"), then closes our side and gives the camera a moment to close its own. A socket
  /// destroyed while the camera still sends (a fetch cancelled in the middle of a clip) resets the connection, and a
  /// reset drops what the camera had not read yet: the "do stop" just sent. Every caller gets the same close to wait
  /// for: the worker isolate waits for it before it ends, also when a cancel started it.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _reader.stopReading();
    try {
      await _socket.flush().timeout(_closeWait);
      await _socket.close().timeout(_closeWait);
      await _reader.ended.timeout(_closeWait);
    } catch (_) {
      // Closing anyway
    }
    _socket.destroy();
  }

  /// The longest each step of [close] waits for the camera
  static const _closeWait = Duration(seconds: 1);
}

/// What a JSON part of the camera says: a response error code, or the end of the stream
({bool finished, int? errorCode}) tapoControlPart(Uint8List body) {
  try {
    final message = jsonDecode(utf8.decode(body, allowMalformed: true));
    if (message is! Map) {
      return (finished: false, errorCode: null);
    }
    final params = message['params'];
    if (params is! Map) {
      return (finished: false, errorCode: null);
    }
    final code = params['error_code'];
    final errorCode = code is int ? code : int.tryParse('${code ?? ''}');
    if (message['type'] == 'response' && errorCode != null && errorCode != 0) {
      return (finished: false, errorCode: errorCode);
    }
    final finished =
        (params['event_type'] == 'stream_status' && params['status'] == 'finished') ||
        (params['event_type'] == 'stream_finish' && params['reason'] == 'finish');
    return (finished: finished, errorCode: null);
  } on FormatException {
    return (finished: false, errorCode: null);
  }
}

/// The download request of a clip (media_type 0) or of the picture of a recording (media_type 2, no end time)
Map<String, Object?> tapoDownloadParams({required int start, int? end, required String playerId, int mediaType = 0}) =>
    {
      'download': {
        'client_id': 1,
        'channels': [0],
        'media_type': mediaType,
        'start_time': '$start',
        if (end != null) 'end_time': '$end',
        'player_id': playerId,
      },
      'method': 'get',
    };

/// Pulls the clip from [start] to [end] (UTC seconds) through [onData], every video/mp2t part in order. Ends when the
/// camera says the clip is finished; throws a [TapoCameraException] busy or unsupported when it refuses the request,
/// unreachable when it goes silent or closes the connection first. [shouldStop] ends it early (true is returned only
/// for a clip the camera finished).
Future<bool> tapoDownloadClip(
  TapoMediaSession session, {
  required int start,
  required int end,
  required String playerId,
  required void Function(TapoMediaPart part) onData,
  bool Function()? shouldStop,
  Duration partTimeout = const Duration(seconds: 15),
}) async {
  session.request(tapoDownloadParams(start: start, end: end, playerId: playerId));
  while (true) {
    if (shouldStop?.call() ?? false) {
      return false;
    }
    final TapoMediaPart? part;
    try {
      part = await session.next(timeout: partTimeout);
    } on TimeoutException {
      throw const TapoCameraException(TapoErrorKind.unreachable, detail: 'media port silent');
    }
    if (part == null) {
      throw const TapoCameraException(TapoErrorKind.unreachable, detail: 'media port closed');
    }
    if (part.isJson) {
      final control = tapoControlPart(part.body);
      final code = control.errorCode;
      if (code != null) {
        throw TapoCameraException(
          tapoBusyCodes.contains(code) ? TapoErrorKind.busy : TapoErrorKind.unsupported,
          code: code,
        );
      }
      if (control.finished) {
        return true;
      }
    } else if (part.contentType.startsWith('video/mp2t')) {
      onData(part);
    }
  }
}

/// The camera's picture of the recording that starts at [start], null when it sends none. The connection may serve
/// several in a row, each request after the end of the one before.
Future<Uint8List?> tapoSnapshot(
  TapoMediaSession session, {
  required int start,
  required String playerId,
  Duration timeout = const Duration(seconds: 8),
}) async {
  session.request(tapoDownloadParams(start: start, playerId: playerId, mediaType: 2));
  final image = BytesBuilder(copy: false);
  while (true) {
    final part = await session.next(timeout: timeout);
    if (part == null) {
      throw const TapoCameraException(TapoErrorKind.unreachable, detail: 'media port closed');
    }
    if (part.contentType.startsWith('image/jpeg')) {
      // A bigger picture would come in several parts (P§7.6.2)
      image.add(part.body);
    } else if (part.isJson) {
      final control = tapoControlPart(part.body);
      final code = control.errorCode;
      if (code != null) {
        if (tapoBusyCodes.contains(code)) {
          throw TapoCameraException(TapoErrorKind.busy, code: code);
        }
        return null;
      }
      if (control.finished) {
        return image.isEmpty ? null : image.takeBytes();
      }
    }
  }
}

final Uint8List _crlfCrlf = Uint8List.fromList(const [13, 10, 13, 10]);

Map<String, String> _headersOf(Iterable<String> lines) => {
  for (final line in lines)
    if (line.indexOf(':') case final colon when colon > 0)
      line.substring(0, colon).trim().toLowerCase(): line.substring(colon + 1).trim(),
};

/// `a="1", b=2` into a map, the values without their quotes
Map<String, String> _parsePairs(String text, String separator) => {
  for (final item in text.split(separator))
    if (item.indexOf('=') case final equals when equals > 0)
      item.substring(0, equals).trim(): item.substring(equals + 1).trim().replaceAll('"', ''),
};

int? _errorCodeOf(Uint8List body) {
  if (body.isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(utf8.decode(body, allowMalformed: true));
    if (decoded is! Map) {
      return null;
    }
    final params = decoded['params'];
    final code = decoded['error_code'] ?? (params is Map ? params['error_code'] : null);
    return code is int ? code : int.tryParse('${code ?? ''}');
  } on FormatException {
    return null;
  }
}

class _ConnectionEnded implements Exception {
  const _ConnectionEnded();
}

/// Reads a socket by markers and lengths, without copying what is already buffered more than once
class _SocketReader {
  _SocketReader(Socket socket, this._timeout) {
    _subscription = socket.listen(
      (chunk) {
        if (_dropping) {
          return;
        }
        _append(chunk);
        _wake();
      },
      onError: (Object error) {
        _error = error;
        _markEnded();
        _wake();
      },
      onDone: () {
        _done = true;
        _markEnded();
        _wake();
      },
      cancelOnError: true,
    );
  }

  final _ended = Completer<void>();

  /// Completes once the camera closed its side
  Future<void> get ended => _ended.future;

  /// Read and dropped from now on, see TapoMediaSession.close
  bool _dropping = false;

  void _markEnded() {
    if (!_ended.isCompleted) {
      _ended.complete();
    }
  }

  final Duration _timeout;
  late final StreamSubscription<Uint8List> _subscription;
  Uint8List _buffer = Uint8List(64 * 1024);
  int _start = 0;
  int _end = 0;

  /// Where the search of the current marker goes on from
  int _searched = 0;
  bool _done = false;
  Object? _error;
  Completer<void>? _waiting;

  void _append(Uint8List chunk) {
    if (_end + chunk.length > _buffer.length) {
      // What was read goes away, and the buffer grows when what is left needs it
      final kept = _end - _start;
      final capacity = max(_buffer.length, (kept + chunk.length) * 2);
      final next = Uint8List(capacity)..setRange(0, kept, _buffer, _start);
      _searched = max(0, _searched - _start);
      _buffer = next;
      _start = 0;
      _end = kept;
    }
    _buffer.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  void _wake() {
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }

  Future<void> _more(Duration? timeout) async {
    final error = _error;
    if (error != null) {
      throw error is SocketException ? error : SocketException('$error');
    }
    if (_done) {
      throw const _ConnectionEnded();
    }
    final waiting = _waiting = Completer<void>();
    await waiting.future.timeout(timeout ?? _timeout);
  }

  /// The bytes before the next [marker], which is consumed as well
  Future<Uint8List> readUntil(Uint8List marker, {Duration? timeout}) async {
    _searched = _start;
    while (true) {
      final found = _indexOf(marker);
      if (found >= 0) {
        final out = Uint8List.fromList(Uint8List.sublistView(_buffer, _start, found));
        _start = found + marker.length;
        return out;
      }
      _searched = (_end - marker.length + 1).clamp(_start, _end);
      await _more(timeout);
    }
  }

  int _indexOf(Uint8List marker) {
    final last = _end - marker.length;
    final first = marker[0];
    for (var i = _searched; i <= last; i++) {
      if (_buffer[i] != first) {
        continue;
      }
      var match = true;
      for (var j = 1; j < marker.length; j++) {
        if (_buffer[i + j] != marker[j]) {
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

  Future<Uint8List> readExact(int length, {Duration? timeout}) async {
    while (_end - _start < length) {
      await _more(timeout);
    }
    final out = Uint8List.fromList(Uint8List.sublistView(_buffer, _start, _start + length));
    _start += length;
    return out;
  }

  void cancel() {
    unawaited(_subscription.cancel());
    _done = true;
    _wake();
  }

  /// Ends the reads waited for, as a closed connection would, and drops what still comes without leaving it unread
  void stopReading() {
    _dropping = true;
    _done = true;
    _wake();
  }
}
