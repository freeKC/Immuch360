// The live view's address and account through the libmpv of the Windows build (V-LIVE, design 5.5): FFmpeg's RTSP
// client decodes the percent-encoded account of the address (cameraRtspUrlWithAccount) and answers the camera's Digest
// challenge with it, whatever the characters of the password; a refused account is asked once; mpv's lines never
// show the account. The simulated camera is the one of the probe's tests (rtsp_probe_test.dart): OPTIONS, DESCRIBE
// refused with a Digest challenge, DESCRIBE again checked against the account, then an SDP like the cameras'. It
// sends no media: the open ends after the SETUP, which is all these checks need.
//
// Windows only, after a Windows build of the app (it holds libmpv-2.dll):
//   flutter build windows --debug -t lib/main_desktop.dart
//   flutter test test/desktop/video/camera_live_windows_test.dart
// IMMUCH360_BUILD_DIR may name another folder holding libmpv-2.dll.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/camera_live_view.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// The folder of the Windows build that holds libmpv, null when there is none
String? _buildDir() {
  final given = Platform.environment['IMMUCH360_BUILD_DIR'];
  final candidates = [
    if (given != null && given.isNotEmpty) given,
    for (final mode in ['Debug', 'Profile', 'Release']) p.join('build', 'windows', 'x64', 'runner', mode),
  ];
  for (final dir in candidates) {
    if (File(p.join(dir, 'libmpv-2.dll')).existsSync()) {
      return p.absolute(dir);
    }
  }
  return null;
}

/// What the Tapo cameras announce, synthetic values
const _sdp =
    'v=0\r\n'
    'o=- 14665860 31787219 1 IN IP4 127.0.0.1\r\n'
    's=Session streamed by "TP-LINK RTSP Server"\r\n'
    't=0 0\r\n'
    'm=video 0 RTP/AVP 96\r\n'
    'c=IN IP4 0.0.0.0\r\n'
    'a=control:track1\r\n'
    'a=rtpmap:96 H264/90000\r\n'
    'a=fmtp:96 packetization-mode=1; profile-level-id=640028; sprop-parameter-sets=Z2QAKKzZQHgCJ+XARAAAAwAEAAADAPA8YMZY,aOvjyyLA\r\n'
    'm=audio 0 RTP/AVP 8\r\n'
    'a=rtpmap:8 PCMA/8000\r\n'
    'a=control:track2\r\n';

const _realm = 'TP-Link IP-Camera';

/// A camera's RTSP server for the account checks: Digest (or Basic only, as a device answering in the camera's place
/// could ask), every request noted
class _SimulatedCamera {
  _SimulatedCamera._(this._server, this.user, this.password, {required this.basicOnly}) {
    _server.listen((socket) {
      var buffer = '';
      socket.listen((data) {
        buffer += latin1.decode(data);
        while (buffer.contains('\r\n\r\n')) {
          final end = buffer.indexOf('\r\n\r\n');
          final request = buffer.substring(0, end);
          buffer = buffer.substring(end + 4);
          final answer = _answer(request);
          if (answer == null) {
            socket.destroy();
            return;
          }
          socket.add(latin1.encode(answer));
        }
      }, onError: (Object _) {});
    });
  }

  static Future<_SimulatedCamera> start(String user, String password, {bool basicOnly = false}) async =>
      _SimulatedCamera._(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        user,
        password,
        basicOnly: basicOnly,
      );

  final ServerSocket _server;
  final String user;
  final String password;
  final bool basicOnly;

  /// Each request: its method, and how it was authorised ("none", "digest ok", "digest refused", "basic")
  final requests = <(String, String)>[];
  final _described = Completer<bool>();

  /// Completes with whether the account was accepted, at the first authorised DESCRIBE
  Future<bool> get described => _described.future;

  int get port => _server.port;

  String? _answer(String request) {
    final lines = request.split('\r\n');
    final parts = lines.first.split(' ');
    final method = parts.first;
    final cseq = lines.where((line) => line.startsWith('CSeq:')).firstOrNull?.substring(5).trim() ?? '0';
    final authorization = lines.where((line) => line.toLowerCase().startsWith('authorization:')).firstOrNull;
    if (method == 'OPTIONS') {
      requests.add((method, 'none'));
      return 'RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nPublic: OPTIONS, DESCRIBE, SETUP, TEARDOWN, PLAY\r\n\r\n';
    }
    const nonce = '0123456789abcdef';
    final challenge = basicOnly
        ? 'WWW-Authenticate: Basic realm="$_realm"\r\n'
        : 'WWW-Authenticate: Digest realm="$_realm", nonce="$nonce"\r\n';
    if (method != 'DESCRIBE') {
      // No media here: the open ends
      requests.add((method, authorization == null ? 'none' : 'sent'));
      return null;
    }
    if (authorization == null) {
      requests.add((method, 'none'));
      return 'RTSP/1.0 401 Unauthorized\r\nCSeq: $cseq\r\n$challenge\r\n';
    }
    final value = authorization.substring(authorization.indexOf(':') + 1).trim();
    if (value.toLowerCase().startsWith('basic')) {
      requests.add((method, 'basic'));
      final given = utf8.decode(base64.decode(value.substring(6).trim()), allowMalformed: true);
      _complete(given == '$user:$password');
      return 'RTSP/1.0 401 Unauthorized\r\nCSeq: $cseq\r\n$challenge\r\n';
    }
    final fields = {
      for (final match in RegExp(r'(\w+)="([^"]*)"|(\w+)=([^,\s]+)').allMatches(value.substring(6)))
        (match.group(1) ?? match.group(3))!: (match.group(2) ?? match.group(4))!,
    };
    final ha1 = md5Hex('$user:$_realm:$password');
    final ha2 = md5Hex('DESCRIBE:${fields['uri']}');
    final qop = fields['qop'];
    final expected = qop == null
        ? md5Hex('$ha1:$nonce:$ha2')
        : md5Hex('$ha1:$nonce:${fields['nc']}:${fields['cnonce']}:$qop:$ha2');
    final ok = fields['username'] == user && fields['response'] == expected;
    requests.add((method, ok ? 'digest ok' : 'digest refused'));
    _complete(ok);
    if (!ok) {
      return 'RTSP/1.0 401 Unauthorized\r\nCSeq: $cseq\r\n$challenge\r\n';
    }
    return 'RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nContent-Base: rtsp://127.0.0.1:$port/stream1/\r\n'
        'Content-Type: application/sdp\r\nContent-Length: ${_sdp.length}\r\n\r\n$_sdp';
  }

  void _complete(bool ok) {
    if (!_described.isCompleted) {
      _described.complete(ok);
    }
  }

  Future<void> close() => _server.close();
}

/// A muted player set up as DesktopPlayer sets up a live one, without its texture (none in a test), given [address]
/// as DesktopPlayer.open gives it: mpv's loadfile, no list file
Future<Player> _openLive(String address, List<String> lines) async {
  final player = Player(
    configuration: PlayerConfiguration(
      muted: true,
      logLevel: MPVLogLevel.warn,
      bufferSize: DesktopPlayerOptions.liveMaxBytes,
      protocolWhitelist: DesktopPlayerOptions.protocolsFor(PlayerKind.live),
    ),
  );
  player.stream.log.listen((log) {
    lines.add(redactPlayerText('${log.level} ${log.prefix}: ${log.text}'));
    logPlayerLine(log.level, log.prefix, log.text);
  });
  final native = player.platform! as NativePlayer;
  final options = {
    ...DesktopPlayerOptions.common(PlayerKind.live),
    ...DesktopPlayerOptions.forOpen(PlayerKind.live, streamed: true),
  };
  for (final MapEntry(:key, :value) in options.entries) {
    await native.setProperty(key, value);
  }
  await player.stop();
  await native.setProperty('pause', 'yes');
  await native.command(['loadfile', address, 'replace']);
  return player;
}

void main() {
  final buildDir = Platform.isWindows ? _buildDir() : null;
  final skip = !Platform.isWindows
      ? 'libmpv of the Windows build: Windows only'
      : buildDir == null
      ? 'no Windows build with libmpv-2.dll (flutter build windows first, or set IMMUCH360_BUILD_DIR)'
      : false;

  late List<LogRecord> records;

  setUpAll(() {
    if (buildDir == null) {
      return;
    }
    final setDllDirectory = DynamicLibrary.open(
      'kernel32.dll',
    ).lookupFunction<Int32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('SetDllDirectoryW');
    using((arena) => setDllDirectory(buildDir.toNativeUtf16(allocator: arena)));
    MediaKit.ensureInitialized(libmpv: p.join(buildDir, 'libmpv-2.dll'));
  });

  setUp(() {
    records = [];
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
  });

  /// Opens the simulated camera's stream with [password] (the camera's own: [cameraPassword]) and waits for its
  /// verdict on the account; the requests it got and mpv's lines, redacted
  Future<(bool, List<(String, String)>, List<String>)> attempt(
    String password, {
    String? cameraPassword,
    bool basicOnly = false,
  }) async {
    const user = 'cam.viewer';
    final camera = await _SimulatedCamera.start(user, cameraPassword ?? password, basicOnly: basicOnly);
    final lines = <String>[];
    Player? player;
    try {
      for (final secret in {user, password}) {
        hidePlayerSecret(secret);
      }
      final address = cameraRtspUrlWithAccount('rtsp://127.0.0.1:${camera.port}/stream1', user, password)!;
      player = await _openLive(address, lines);
      final accepted = await camera.described.timeout(const Duration(seconds: 20), onTimeout: () => false);
      // FFmpeg's answer to the last refusal, and mpv's lines about it
      await Future<void>.delayed(const Duration(seconds: 2));
      return (accepted, List.of(camera.requests), lines);
    } finally {
      await player?.dispose();
      await camera.close();
    }
  }

  void expectNoSecret(List<String> lines, String password) {
    final text = [...lines, for (final record in records) '${record.message} ${record.error ?? ''}'].join('\n');
    expect(text, isNot(contains(password)));
    expect(text, isNot(contains(Uri.encodeComponent(password))));
    expect(text, isNot(contains('cam.viewer')));
    expect(text, isNot(contains('rtsp://')));
  }

  // Every character class a camera account may hold: spaces, the separators of an address, percent signs, plus
  // signs (a space in a form), non ASCII letters
  const passwords = ['plainPassw0rd', 'p@ss w:rd/+%#é', 'a+b c%20d', '[x]?y&z=1;!*\'()~'];
  for (final password in passwords) {
    test(
      'FFmpeg answers the Digest challenge with the decoded account: ${password.length} characters',
      () async {
        final (accepted, requests, lines) = await attempt(password);
        expect(accepted, isTrue, reason: 'requests: $requests');
        expect(requests.map((request) => request.$2), isNot(contains('basic')));
        expect(requests.first.$1, 'OPTIONS');
        expectNoSecret(lines, password);
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }

  test(
    'a refused account is asked once, and mpv says why without the account',
    () async {
      const password = 'wrong p@ss';
      final (accepted, requests, lines) = await attempt(password, cameraPassword: 'right p@ss');
      expect(accepted, isFalse);
      final authorised = requests.where((request) => request.$1 == 'DESCRIBE' && request.$2 != 'none');
      expect(authorised, hasLength(1), reason: 'requests: $requests');
      // What the live view reads to tell a refusal (_refused): printed for the report
      for (final line in lines) {
        // ignore: avoid_print
        print('MPV $line');
      }
      expectNoSecret(lines, password);
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a server asking for Basic only: what FFmpeg sends',
    () async {
      const password = 'basic-check-pw';
      final (_, requests, lines) = await attempt(password, basicOnly: true);
      // Media3 answers Basic too on the phones; printed for the report rather than asserted
      // ignore: avoid_print
      print('BASIC requests: $requests');
      expectNoSecret(lines, password);
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
