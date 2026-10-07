// The HTTPS client of the control API of a camera (port 443). The cameras sign their own certificate, so no system
// root is trusted here: every certificate goes through [TapoHttpsTransport] which accepts the one pinned for the
// camera (its SHA-256, stored at the first login, see TapoCameraInfo.certificateSha256) and refuses any other before a
// byte of HTTP leaves the device. Without a pin yet (only "Test the camera" logs in then, see TapoControlClient), the
// first certificate shown is accepted and pinned for the later connections of the same transport, and the page saves
// it with the camera.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:logging/logging.dart';

final _log = Logger('TapoHttps');

/// A failure to reach the camera: no route, a time limit, a connection closed, a TLS handshake that failed for another
/// reason than the certificate. The control client tries once more, then tells it as unreachable.
class TapoNetworkException implements Exception {
  const TapoNetworkException(this.detail);

  /// What failed, never a secret nor an address with a credential
  final String detail;

  @override
  String toString() => 'TapoNetworkException($detail)';
}

/// What the control API answered
typedef TapoHttpReply = ({int status, Uint8List body});

/// The transport of the control API of one camera. Injectable for the tests, whose fake cameras answer in memory.
abstract class TapoTransport {
  String get host;

  /// The SHA-256 (lower case hex) of the certificate of the last connection, null before the first one
  String? get certificateSha256;

  /// POSTs [body] to [path] ("/" for a login, see [tapoStokPath] for the requests of a session). Throws a
  /// [TapoNetworkException] when the camera cannot be reached, a [TapoCameraException] of kind certificateChanged when
  /// it shows another certificate than the pinned one (nothing is sent then).
  Future<TapoHttpReply> post(String path, List<int> body, {required String contentType, Map<String, String> headers});

  void close();
}

/// The path of the requests of a session. The stok goes raw into the path: a camera refuses a percent-encoded one
/// with -40421 (Tapo design 2.4). Only the characters that would change the meaning of the path are escaped, as the
/// official app does.
String tapoStokPath(String stok) {
  final escaped = StringBuffer();
  for (final unit in stok.codeUnits) {
    final char = String.fromCharCode(unit);
    if (unit <= 0x20 || unit >= 0x7f || '%/?#"<>\\^`{}|[]'.contains(char)) {
      escaped.write('%${unit.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    } else {
      escaped.write(char);
    }
  }
  return '/stok=$escaped/ds';
}

/// The [TapoTransport] of a camera on its network: one keep-alive connection, the headers of the official app
class TapoHttpsTransport implements TapoTransport {
  TapoHttpsTransport(this.host, {this.port = 443, String? pinnedSha256, this.timeout = const Duration(seconds: 10)})
    : _pin = pinnedSha256?.toLowerCase();

  @override
  final String host;
  final int port;
  final Duration timeout;

  /// The certificate accepted: the stored pin, else the first one shown (trust on first use, for the tester), so that a
  /// device taking the camera's place later in the life of the session is refused
  String? _pin;

  String? _seen;

  /// The certificate refused for not being the pinned one, until the next request
  String? _refused;
  bool _closed = false;

  HttpClient? _client;

  HttpClient _http() => _client ??= HttpClient(context: SecurityContext(withTrustedRoots: false))
    ..connectionTimeout = timeout
    ..idleTimeout = const Duration(seconds: 15)
    ..maxConnectionsPerHost = 1
    ..userAgent = null
    ..badCertificateCallback = _checkCertificate;

  @override
  String? get certificateSha256 => _seen;

  /// Every certificate comes here (no root is trusted): only this camera's, and only the pinned one once there is a
  /// pin. HttpClient gives the host of the URL, which Uri lowercases: the host typed may hold capitals.
  bool _checkCertificate(X509Certificate certificate, String host, int port) {
    if (host.toLowerCase() != this.host.toLowerCase() || port != this.port) {
      return false;
    }
    final digest = hexOf(sha256Bytes(certificate.der));
    _seen = digest;
    final pin = _pin ??= digest;
    if (pin != digest) {
      _refused = digest;
      return false;
    }
    return true;
  }

  Uri _uri(String path) => Uri.parse('https://${host.contains(':') ? '[$host]' : host}:$port$path');

  @override
  Future<TapoHttpReply> post(
    String path,
    List<int> body, {
    required String contentType,
    Map<String, String> headers = const {},
  }) async {
    if (_closed) {
      throw const TapoNetworkException('closed');
    }
    _refused = null;
    final client = _http();
    HttpClientRequest? request;
    try {
      request = await client.postUrl(_uri(path)).timeout(timeout);
      request.headers
        ..set(HttpHeaders.contentTypeHeader, contentType)
        ..set(HttpHeaders.acceptHeader, contentType.split(';').first)
        ..set(HttpHeaders.userAgentHeader, 'Tapo CameraClient Android')
        ..set('requestByApp', 'true')
        ..set(HttpHeaders.refererHeader, 'https://$host:$port');
      headers.forEach(request.headers.set);
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close().timeout(timeout);
      final bytes = await response
          .fold(BytesBuilder(copy: false), (BytesBuilder builder, chunk) => builder..add(chunk))
          .timeout(timeout);
      return (status: response.statusCode, body: bytes.takeBytes());
    } on HandshakeException {
      throw _failure(client, request, 'TLS');
    } on TlsException {
      throw _failure(client, request, 'TLS');
    } on SocketException catch (error) {
      throw _failure(client, request, 'socket ${error.osError?.errorCode ?? ''}'.trim());
    } on TimeoutException {
      throw _failure(client, request, 'time limit');
    } on HttpException {
      throw _failure(client, request, 'HTTP');
    }
  }

  /// The certificate change when that is why the connection failed, else a network failure. Either way the client is
  /// dropped with its connection: a time limit only ends the wait, and with one connection per host a request the
  /// camera never answers (it rebooted after reading it) would hold every later one until the app restarts.
  Exception _failure(HttpClient client, HttpClientRequest? request, String detail) {
    request?.abort();
    if (identical(_client, client)) {
      _client = null;
    }
    client.close(force: true);
    final refused = _refused;
    if (refused != null) {
      return TapoCameraException(TapoErrorKind.certificateChanged, certificateSha256: refused);
    }
    return TapoNetworkException(detail);
  }

  @override
  void close() {
    _closed = true;
    _client?.close(force: true);
    _client = null;
  }
}

/// The SHA-256 of the certificate the camera at [host] shows now (lower case hex), null when it does not answer. The
/// handshake is refused as soon as the certificate is seen: nothing else is sent.
Future<String?> readTapoCertificate(
  String host, {
  int port = 443,
  Duration timeout = const Duration(seconds: 4),
}) async {
  final RawSocket socket;
  try {
    socket = await RawSocket.connect(host, port, timeout: timeout);
  } catch (_) {
    return null;
  }
  X509Certificate? seen;
  try {
    // The handshake has no time limit of its own
    final secure = await RawSecureSocket.secure(
      socket,
      host: host,
      context: SecurityContext(withTrustedRoots: false),
      onBadCertificate: (certificate) {
        seen = certificate;
        return false;
      },
    ).timeout(timeout);
    await secure.close();
  } on HandshakeException {
    // The expected end once the certificate was refused
  } on TimeoutException {
    return null;
  } catch (error) {
    _log.finest('TLS of a camera: ${error.runtimeType}');
  } finally {
    unawaited(socket.close().catchError((Object _) => socket));
  }
  final certificate = seen;
  return certificate == null ? null : hexOf(sha256Bytes(certificate.der));
}
