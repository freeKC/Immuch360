// What libmpv is given for each source of the viewer and the network page (design 2.2, "Sources"): a path, a bridge
// URL as it is, the bridge URL of a server video; anything else is refused rather than handed over with its headers.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/network/immich_server_file_system.dart';
import 'package:immich_mobile/desktop/video/desktop_video_sources.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:native_video_player/native_video_player.dart';

const _endpoint = 'https://user:hunter22@photos.example:2283/api';

void main() {
  late LocalMediaBridge bridge;
  var made = 0;

  ImmichServerFileSystem serverFileSystem() {
    made++;
    return ImmichServerFileSystem(endpoint: () => _endpoint, client: http.Client.new);
  }

  Future<String> resolve(String path, VideoSourceType type, {Map<String, String>? headers}) async =>
      resolveDesktopVideoSource(
        await VideoSource.init(path: path, type: type, headers: headers),
        bridge: bridge,
        serverEndpoint: _endpoint,
        serverFileSystem: serverFileSystem,
      );

  setUp(() {
    bridge = LocalMediaBridge();
    made = 0;
  });

  tearDown(() => bridge.stop());

  test('a file of this computer is given as its path', () async {
    expect(await resolve(r'C:\Users\Someone\Videos\a.mp4', VideoSourceType.file), r'C:\Users\Someone\Videos\a.mp4');
    // A file URL becomes a path of the system the app runs on: toFilePath writes a Windows path on Windows
    if (Platform.isWindows) {
      expect(await resolve('file:///C:/Users/Someone/a%20b.mp4', VideoSourceType.file), r'C:\Users\Someone\a b.mp4');
    } else {
      expect(await resolve('file:///home/someone/a%20b.mp4', VideoSourceType.file), '/home/someone/a b.mp4');
    }
  });

  test('a bridge URL (a share, a Tapo recording) is given as it is, its headers dropped', () async {
    const url = 'http://127.0.0.1:41000/Zq8token/smb-1/clips/a.mp4';
    expect(await resolve(url, VideoSourceType.network, headers: {'x-custom': 'value'}), url);
    expect(made, 0);
  });

  test('a server video becomes a bridge URL, without the address, the password or the headers', () async {
    final url = await resolve(
      '$_endpoint/assets/0f1e-2d/original',
      VideoSourceType.network,
      headers: {'x-proxy-key': 'ProxySecret'},
    );
    final uri = Uri.parse(url);
    expect(uri.scheme, 'http');
    expect(uri.host, '127.0.0.1');
    expect(uri.pathSegments.skip(1), ['immich-server', 'assets', '0f1e-2d', 'original']);
    for (final leak in ['photos.example', 'hunter22', '2283', 'ProxySecret']) {
      expect(url, isNot(contains(leak)));
    }

    await resolve('$_endpoint/assets/0f1e-2d/video/playback', VideoSourceType.network);
    expect(made, 1, reason: 'registered on the bridge once');
  });

  test('any other address is refused, never handed to libmpv', () async {
    for (final url in [
      'https://elsewhere.example/video.mp4',
      '$_endpoint/users/me',
      'http://user:pw@127.0.0.1:41000/token/smb-1/a.mp4',
      'rtsp://admin:pw@192.168.1.20:554/stream1',
    ]) {
      await expectLater(resolve(url, VideoSourceType.network), throwsA(anything), reason: url);
    }
  });
}
