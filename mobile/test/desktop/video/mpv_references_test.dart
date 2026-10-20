// What a video file may make libmpv open on its own (REV-SEC of phase 2a): a file of a share or of a folder can be a
// playlist (#EXTM3U) or a DASH manifest under a video name, and libmpv would then fetch what it lists from any host,
// without a click, as soon as the tile of the file asks for its thumbnail. The app's players refuse such references
// (DesktopPlayer.open); here each kind of file is opened by the thumbnail grabber, from its path and through the media
// bridge, with its references pointing at a server of this test on 127.0.0.1 that must receive nothing.
//
// On Windows the libmpv of a build of the app, on Linux the system's (libmpv_for_tests.dart):
//   flutter test test/desktop/video/mpv_references_test.dart

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/video_thumbnail_grabber.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:path/path.dart' as p;

import 'libmpv_for_tests.dart';

/// The files of a folder as a share, for the media bridge
class _FolderFileSystem implements NetworkFileSystem {
  _FolderFileSystem(this._dir);

  final Directory _dir;

  @override
  final NetworkSource source = const NetworkSource(
    id: 'references-test',
    type: NetworkSourceType.smb,
    name: 'references',
    host: 'localhost',
  );

  File _file(String path) => File(p.join(_dir.path, p.basename(path)));

  @override
  Future<List<NetworkEntry>> list(String path) async => const [];

  @override
  Future<NetworkEntry> stat(String path) async =>
      NetworkEntry(sourceId: source.id, path: path, isDirectory: false, size: await _file(path).length());

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    final file = await _file(path).open();
    try {
      await file.setPosition(offset);
      return await file.read(length);
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> close() async {}
}

/// Files with a video name whose content refers to [target]
Map<String, String> _referencingFiles(String target) => {
  // mpv's own playlist reader takes this whatever the extension
  'playlist.mp4': '#EXTM3U\n$target/from-playlist.mp4\n',
  // FFmpeg's DASH demuxer probes the content, not the name; its segments open through nested opens
  'manifest.mp4':
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-live:2011" type="static" '
      'mediaPresentationDuration="PT10S" minBufferTime="PT2S">\n'
      '  <BaseURL>$target/dash/</BaseURL>\n'
      '  <Period>\n'
      '    <AdaptationSet mimeType="video/mp4" segmentAlignment="true">\n'
      '      <Representation id="1" bandwidth="100000" width="320" height="240" codecs="avc1.42c00d">\n'
      '        <SegmentTemplate media="seg-\$Number\$.m4s" initialization="init.mp4" startNumber="1" '
      'duration="2" timescale="1"/>\n'
      '      </Representation>\n'
      '    </AdaptationSet>\n'
      '  </Period>\n'
      '</MPD>\n',
};

void main() {
  final libmpv = libmpvForTests();
  final library = libmpv.library;
  final skip = libmpv.skip ?? false;

  late HttpServer canary;
  final requests = <String>[];
  late Directory dir;
  late LocalMediaBridge bridge;
  late _FolderFileSystem folder;
  // Short waits: a file that gives no frame is what every case here expects
  final grabber = VideoThumbnailGrabber(
    openTimeout: const Duration(seconds: 6),
    frameTimeout: const Duration(seconds: 3),
  );

  setUpAll(() async {
    if (library == null) {
      return;
    }
    loadLibmpvForTests(library);

    canary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    canary.listen((request) {
      requests.add(request.uri.path);
      request.response.statusCode = HttpStatus.notFound;
      unawaited(request.response.close());
    });
    dir = await Directory.systemTemp.createTemp('immuch360_references_');
    for (final MapEntry(key: name, value: text) in _referencingFiles('http://127.0.0.1:${canary.port}').entries) {
      await File(p.join(dir.path, name)).writeAsString(text);
    }
    folder = _FolderFileSystem(dir);
    bridge = LocalMediaBridge();
    await bridge.start();
    bridge.register(folder);

    // The server of the test does see a request made to it
    final client = HttpClient();
    try {
      await (await client.getUrl(Uri.parse('http://127.0.0.1:${canary.port}/check'))).close();
    } finally {
      client.close(force: true);
    }
    expect(requests, ['/check']);
    requests.clear();
  });

  tearDownAll(() async {
    if (library == null) {
      return;
    }
    await bridge.stop();
    await canary.close(force: true);
    await dir.delete(recursive: true);
  });

  for (final name in _referencingFiles('').keys) {
    for (final through in ['path', 'bridge']) {
      test(
        '$name from its $through: libmpv opens nothing it refers to',
        () async {
          requests.clear();
          final resource = through == 'path'
              ? p.join(dir.path, name)
              : bridge.urlFor(folder.source.id, name).toString();
          final frame = await grabber.grab(
            resource,
            time: const Duration(seconds: 1),
            box: (width: 160, height: 160, cover: true),
          );
          // Time for what a reference would open after the grabber gave up on the file
          await Future<void>.delayed(const Duration(seconds: 2));
          expect(frame, isNull);
          expect(requests, isEmpty, reason: 'libmpv followed a reference of $name to ${requests.join(', ')}');
        },
        skip: skip,
        timeout: const Timeout(Duration(seconds: 60)),
      );
    }
  }
}
