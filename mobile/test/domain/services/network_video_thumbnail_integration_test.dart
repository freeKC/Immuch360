// The video thumbnails of the browser against the test shares of the development machine: the real SMB and WebDAV
// clients behind the real media bridge, a stand in for MediaMetadataRetriever that reads the video by ranges as a
// demuxer does (the top level boxes, then the moov box whole), and the disk cache in a temporary folder. Only on that
// machine: IMMUCH_NET_TESTS=1, WebDAV at http://localhost:1880/ and SMB on localhost port 1445, share "media", user
// tester, password testpass. No widget binding here: it would answer every HTTP request with an error.

// ignore_for_file: invalid_use_of_internal_member

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/src/ffi/native_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/network_video_thumbnail.service.dart';
import 'package:immich_mobile/infrastructure/network/smb_file_system.dart';
import 'package:immich_mobile/infrastructure/network/video_thumbnail_disk_cache.dart';
import 'package:immich_mobile/infrastructure/network/webdav_file_system.dart';
import 'package:immich_mobile/platform/video_thumbnail_api.g.dart';

import '../../infrastructure/network/libsmb2_test_path.dart';

final _enabled = Platform.environment['IMMUCH_NET_TESTS'] == '1';
const _skipReason = 'Set IMMUCH_NET_TESTS=1 to run against the test servers of the development machine';
const _password = 'testpass';

const _webDav = NetworkSource(
  id: 'dav-test',
  type: NetworkSourceType.webdav,
  name: 'Test WebDAV',
  host: 'localhost',
  port: 1880,
  username: 'tester',
);

const _smb = NetworkSource(
  id: 'smb-test',
  type: NetworkSourceType.smb,
  name: 'Test Samba',
  host: '127.0.0.1',
  port: 1445,
  share: 'media',
  username: 'tester',
);

const _videos = ['mono-video.mp4', 'stereo-tb-video.mp4', 'vr180-sbs-3840x1920-tagged.mp4'];

/// Reads a video from its URL the way a demuxer looks for its index: the header of each top level box by a range
/// request, skipping the others, then the moov box whole. Gives a fake JPEG naming the video.
class _RangeReadingHost extends VideoThumbnailApi {
  _RangeReadingHost(this._client);

  final http.Client _client;
  int requests = 0;
  int bytesRead = 0;
  final urls = <String>[];

  @override
  Future<Uint8List> thumbnailForUrl(String url, Map<String, String> headers, int timeMs, int maxWidth) async {
    urls.add(url);
    final uri = Uri.parse(url);
    var offset = 0;
    int? total;
    while (total == null || offset + 8 <= total) {
      final (header, size) = await _range(uri, offset, 16);
      total ??= size;
      final view = ByteData.sublistView(header);
      final type = String.fromCharCodes(header.sublist(4, 8));
      var boxSize = view.getUint32(0);
      if (boxSize == 1) {
        boxSize = view.getUint64(8);
      } else if (boxSize == 0) {
        boxSize = total - offset;
      }
      if (type == 'moov') {
        await _range(uri, offset, boxSize);
        return Uint8List.fromList([0xff, 0xd8, ...url.codeUnits, 0xff, 0xd9]);
      }
      offset += boxSize;
    }
    throw StateError('No moov box in $url');
  }

  Future<(Uint8List, int)> _range(Uri uri, int offset, int length) async {
    requests++;
    final request = http.Request('GET', uri)..headers['Range'] = 'bytes=$offset-${offset + length - 1}';
    final response = await http.Response.fromStream(await _client.send(request));
    expect(response.statusCode, HttpStatus.partialContent, reason: 'the media bridge serves ranges');
    bytesRead += response.bodyBytes.length;
    final total = int.parse(response.headers['content-range']!.split('/').last);
    return (response.bodyBytes, total);
  }
}

void main() {
  for (final (source, open) in <(NetworkSource, NetworkFileSystemOpener)>[
    (_webDav, WebDavFileSystem.open),
    (_smb, SmbFileSystem.open),
  ]) {
    test('${source.type.name}: takes the frames of the videos through the media bridge, then from disk', () async {
      if (source.type == NetworkSourceType.smb) {
        debugLibSmb2PathOverride = libsmb2TestPath();
      }
      final fileSystem = await open(source, _password);
      addTearDown(fileSystem.close);
      final bridge = LocalMediaBridge();
      addTearDown(bridge.stop);
      await bridge.start();
      bridge.register(fileSystem);
      final client = http.Client();
      addTearDown(client.close);
      final directory = await Directory.systemTemp.createTemp('video_thumbnails_it_');
      addTearDown(() => directory.delete(recursive: true));
      final host = _RangeReadingHost(client);
      NetworkVideoThumbnailService service() =>
          NetworkVideoThumbnailService(api: host, diskCache: VideoThumbnailDiskCache(() async => directory));

      final entries = {
        for (final entry in await fileSystem.list('/'))
          if (_videos.contains(entry.name)) entry.name: entry,
      };
      expect(entries.keys.toSet(), _videos.toSet());
      final totalSize = entries.values.fold<int>(0, (sum, entry) => sum + (entry.size ?? 0));

      final first = service();
      final watch = Stopwatch()..start();
      final frames = await Future.wait([
        for (final entry in entries.values)
          first.thumbnail(networkMediaKey(entry), bridge.urlFor(source.id, entry.path)),
      ]);
      watch.stop();

      expect(frames, everyElement(isNotNull));
      expect(host.urls.toSet(), {for (final entry in entries.values) bridge.urlFor(source.id, entry.path).toString()});
      expect(host.bytesRead, lessThan(totalSize), reason: 'only the index of the videos is read');
      // ignore: avoid_print
      print(
        '${source.type.name}: ${entries.length} videos, $totalSize bytes; ${host.requests} range requests, '
        '${host.bytesRead} bytes read, ${watch.elapsedMilliseconds} ms',
      );

      final requests = host.requests;
      final again = await Future.wait([
        for (final entry in entries.values)
          service().thumbnail(networkMediaKey(entry), bridge.urlFor(source.id, entry.path)),
      ]);
      expect(again, frames, reason: 'from the disk cache');
      expect(host.requests, requests);
    }, skip: _enabled ? false : _skipReason);
  }
}
