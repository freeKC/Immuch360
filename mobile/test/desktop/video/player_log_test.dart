// No token, password, cookie or RTSP address in any log record of the desktop video (plan 2.5, design 0.2): mpv's
// lines and errors are redacted before they reach the app's log, the server source never quotes its address, and a
// whole server video session through the bridge, failures included, leaves none of them in a record.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/network/immich_server_file_system.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/desktop_video_sources.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:logging/logging.dart';
import 'package:native_video_player/native_video_player.dart';

import 'fake_playback_engine.dart';

/// Values that must appear in no record
const _secrets = [
  'Zq8BridgeTokenAbcdefghijklmnopqr',
  'SessionSecret42',
  'hunter22',
  'camPassw0rd',
  'ApiKey0123456789',
  'ProxySecret',
];

/// A client whose requests all fail the way dart:io and package:http report it, quoting the whole URL
class _FailingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      throw http.ClientException('Connection refused', request.url);
}

void main() {
  late List<LogRecord> records;
  late Level previous;

  setUp(() {
    records = [];
    previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await subscription.cancel();
      Logger.root.level = previous;
    });
  });

  void expectNoSecret() {
    final text = records
        .map((record) => '${record.message} ${record.error ?? ''} ${record.stackTrace ?? ''}')
        .join('\n');
    for (final secret in _secrets) {
      expect(text, isNot(contains(secret)), reason: 'a log record shows $secret');
    }
  }

  test('mpv lines: URLs, header values and credentials are replaced', () {
    final lines = [
      ('error', 'cplayer', 'Failed to open http://127.0.0.1:41000/${_secrets[0]}/smb-1/clips/a.mp4.'),
      ('error', 'stream', 'rtsp://admin:${_secrets[3]}@192.168.1.20:554/stream1: Connection refused'),
      ('v', 'cplayer', 'Set property: http-header-fields=["cookie: immich_access_token=${_secrets[1]}"] -> 1'),
      ('warn', 'ffmpeg', 'http: Cookie: immich_access_token=${_secrets[1]}; other=1'),
      ('error', 'ffmpeg', 'tcp: x-api-key: ${_secrets[4]}'),
      ('error', 'ffmpeg', 'https://user:${_secrets[2]}@photos.example/api/assets/1/original 401'),
      ('fatal', 'vd', 'Authorization: Bearer ${_secrets[1]}'),
    ];
    for (final (level, prefix, text) in lines) {
      logPlayerLine(level, prefix, text);
    }
    expect(records, hasLength(lines.length));
    expectNoSecret();
    expect(records.first.message, contains('<url>'));
    expect(records.first.level, Level.WARNING);
  });

  test('redactPlayerText keeps what helps (the decoder, the error) and drops the rest', () {
    expect(redactPlayerText('vd: Using hardware decoding (d3d11va).'), 'vd: Using hardware decoding (d3d11va).');
    expect(
      redactPlayerText('Failed to open https://h.example/a?key=abc: 404 Not Found'),
      'Failed to open <url> 404 Not Found',
    );
  });

  test('a server video whose server fails: the bridge, the source and the player log no secret', () async {
    final bridge = LocalMediaBridge();
    addTearDown(bridge.stop);
    const endpoint = 'https://user:hunter22@photos.example:2283/api';
    final serverFileSystem = ImmichServerFileSystem(endpoint: () => endpoint, client: _FailingClient.new);
    final players = FakePlayers();
    final video = MediaKitVideoPlayerController(
      pool: players.pool,
      resolve: (source) => resolveDesktopVideoSource(
        source,
        bridge: bridge,
        serverEndpoint: endpoint,
        serverFileSystem: () => serverFileSystem,
      ),
    );

    await video.loadVideoSource(
      await VideoSource.init(
        path: '$endpoint/assets/v1/original',
        type: VideoSourceType.network,
        headers: {'x-proxy-key': 'ProxySecret'},
      ),
    );
    final url = players.made.single.resource!;
    expect(url, startsWith('http://127.0.0.1:'));

    // libmpv reads the bridge URL; the server cannot be reached
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(Uri.parse(url))).close();
    await response.drain<void>();
    expect(response.statusCode, HttpStatus.internalServerError);

    // and says so in its log and its error, with the bridge URL in them
    logPlayerLine('error', 'cplayer', 'Failed to open $url.');
    players.made.single.emit(PlayerEventKind.failed, redactPlayerText('loading failed for $url'));
    expect(video.onError.value, isNot(contains(Uri.parse(url).pathSegments.first)));

    expect(records.where((record) => record.loggerName == 'MediaBridge'), isNotEmpty);
    final bridgeToken = Uri.parse(url).pathSegments.first;
    final text = records.map((record) => '${record.message} ${record.error ?? ''}').join('\n');
    expect(text, isNot(contains(bridgeToken)));
    expectNoSecret();
  });
}
