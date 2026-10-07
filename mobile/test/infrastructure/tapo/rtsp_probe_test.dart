// The live side of "Test the camera" against a fake RTSP server on 127.0.0.1: OPTIONS, DESCRIBE refused with a Digest
// challenge, DESCRIBE again with the answer, and the codecs read from the SDP; a wrong account is told as such, and a
// server asking for Basic only never gets the account.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_probe.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';

/// What the Tapo cameras announce, synthetic values
const _sdp =
    'v=0\r\n'
    'o=- 14665860 31787219 1 IN IP4 192.0.2.30\r\n'
    's=Session streamed by "TP-LINK RTSP Server"\r\n'
    't=0 0\r\n'
    'm=video 0 RTP/AVP 96\r\n'
    'c=IN IP4 0.0.0.0\r\n'
    'a=control:track1\r\n'
    'a=rtpmap:96 H264/90000\r\n'
    'a=fmtp:96 packetization-mode=1; profile-level-id=676400\r\n'
    'm=audio 0 RTP/AVP 8\r\n'
    'a=rtpmap:8 PCMA/8000\r\n'
    'a=control:track2\r\n';

class _FakeRtsp {
  _FakeRtsp._(this._server, {required this.user, required this.password, this.qop = false, this.basicOnly = false}) {
    _server.listen((socket) {
      var buffer = '';
      socket.listen((data) {
        buffer += latin1.decode(data);
        while (buffer.contains('\r\n\r\n')) {
          final end = buffer.indexOf('\r\n\r\n');
          final request = buffer.substring(0, end);
          buffer = buffer.substring(end + 4);
          socket.add(latin1.encode(_answer(request)));
        }
      }, onError: (Object _) {});
    });
  }

  static Future<_FakeRtsp> start({
    String user = 'viewer',
    String password = 'camera-account-pw',
    bool qop = false,
    bool basicOnly = false,
  }) async => _FakeRtsp._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    user: user,
    password: password,
    qop: qop,
    basicOnly: basicOnly,
  );

  final ServerSocket _server;
  final String user;
  final String password;
  final bool qop;

  /// Asks for Basic authentication only, as a device answering in the camera's place could
  final bool basicOnly;
  final List<String> methods = [];
  final List<String> authorizations = [];
  int get port => _server.port;

  String _answer(String request) {
    final lines = request.split('\r\n');
    final parts = lines.first.split(' ');
    methods.add(parts.first);
    final cseq = lines.firstWhere((line) => line.startsWith('CSeq:')).substring(5).trim();
    if (parts.first == 'OPTIONS') {
      return 'RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nPublic: OPTIONS, DESCRIBE, SETUP, TEARDOWN, PLAY\r\n\r\n';
    }
    final authorization = lines.where((line) => line.startsWith('Authorization:')).firstOrNull;
    if (authorization != null) {
      authorizations.add(authorization);
    }
    const nonce = '0123456789abcdef';
    final challenge = basicOnly
        ? 'WWW-Authenticate: Basic realm="x"\r\n'
        : qop
        ? 'WWW-Authenticate: Digest realm="TP-Link IP-Camera", nonce="$nonce", qop="auth"\r\n'
        : 'WWW-Authenticate: Digest realm="TP-Link IP-Camera", nonce="$nonce"\r\nWWW-Authenticate: Basic realm="x"\r\n';
    if (authorization == null || basicOnly) {
      return 'RTSP/1.0 401 Unauthorized\r\nCSeq: $cseq\r\n$challenge\r\n';
    }
    final fields = {
      for (final match in RegExp(r'(\w+)="?([^",]*)"?').allMatches(authorization.substring(22)))
        match.group(1)!: match.group(2)!,
    };
    final ha1 = md5Hex('$user:TP-Link IP-Camera:$password');
    final ha2 = md5Hex('DESCRIBE:${parts[1]}');
    final expected = qop
        ? md5Hex('$ha1:$nonce:${fields['nc']}:${fields['cnonce']}:auth:$ha2')
        : md5Hex('$ha1:$nonce:$ha2');
    if (fields['username'] != user || fields['response'] != expected || fields['uri'] != parts[1]) {
      return 'RTSP/1.0 401 Unauthorized\r\nCSeq: $cseq\r\n$challenge\r\n';
    }
    return 'RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nContent-Type: application/sdp\r\nContent-Length: ${_sdp.length}\r\n\r\n$_sdp';
  }

  Future<void> close() => _server.close();
}

void main() {
  for (final qop in [false, true]) {
    test('reads the codecs of the stream with the camera account${qop ? ', qop auth' : ''}', () async {
      final server = await _FakeRtsp.start(qop: qop);
      addTearDown(server.close);
      final probe = await probeTapoRtsp('127.0.0.1', port: server.port, user: 'viewer', password: 'camera-account-pw');
      expect(probe.video, 'H264');
      expect(probe.audio, 'PCMA');
      expect(server.methods, ['OPTIONS', 'DESCRIBE', 'DESCRIBE']);
    });
  }

  test('tells a wrong camera account', () async {
    final server = await _FakeRtsp.start();
    addTearDown(server.close);
    await expectLater(
      probeTapoRtsp('127.0.0.1', port: server.port, user: 'viewer', password: 'wrong'),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.wrongPassword)),
    );
    // One try only
    expect(server.methods.where((method) => method == 'DESCRIBE'), hasLength(2));
  });

  test('never answers a Basic challenge: the account would go in clear', () async {
    final server = await _FakeRtsp.start(basicOnly: true);
    addTearDown(server.close);
    await expectLater(
      probeTapoRtsp('127.0.0.1', port: server.port, user: 'viewer', password: 'camera-account-pw'),
      throwsA(
        isA<TapoCameraException>()
            .having((e) => e.kind, 'kind', TapoErrorKind.unsupported)
            .having((e) => e.detail, 'detail', 'RTSP authentication'),
      ),
    );
    expect(server.authorizations, isEmpty);
    expect(server.methods, ['OPTIONS', 'DESCRIBE']);
  });

  test('tells a camera that does not answer', () async {
    final server = await _FakeRtsp.start();
    final port = server.port;
    await server.close();
    await expectLater(
      probeTapoRtsp('127.0.0.1', port: port, user: 'viewer', password: 'x', timeout: const Duration(seconds: 2)),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.unreachable)),
    );
  });

  test('reads the static payload types of an SDP without rtpmap', () {
    final probe = parseSdpCodecs('v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H265/90000\r\nm=audio 0 RTP/AVP 0\r\n');
    expect(probe.video, 'H265');
    expect(probe.audio, 'PCMU');
    expect(parseSdpCodecs('v=0\r\n').video, isNull);
  });

  test('never puts the account in the request line', () async {
    final requests = <String>[];
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) {
      socket.listen((data) {
        final text = latin1.decode(data);
        requests.add(text.split('\r\n').first);
        socket.add(latin1.encode('RTSP/1.0 404 Not Found\r\nCSeq: 1\r\n\r\n'));
      });
    });
    await expectLater(
      probeTapoRtsp('127.0.0.1', port: server.port, user: 'viewer', password: 'camera-account-pw'),
      throwsA(isA<TapoCameraException>()),
    );
    expect(requests, everyElement(isNot(contains('camera-account-pw'))));
    expect(requests, everyElement(isNot(contains('viewer'))));
    expect(requests.first, 'OPTIONS rtsp://127.0.0.1:${server.port}/stream1 RTSP/1.0');
  });
}
