// The files of a share the app shows, and the content type the media bridge serves them with: the raw videos of 360°
// cameras are MP4 files under names of their own, which the players only read as video/mp4. The sources as stored, a
// DLNA media server and the id a server announces included, and read back by older and newer builds.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';

NetworkEntry _file(String name, {String? mimeType}) =>
    NetworkEntry(sourceId: 'nas', path: '/DCIM/$name', isDirectory: false, mimeType: mimeType);

void main() {
  test('takes the raw videos of Insta360, GoPro and DJI cameras for videos, and the .36p of the MAX 2 for a photo', () {
    for (final name in ['VID_00_001.insv', 'GS010013.360', 'CAM_20250715191201_0003_D.OSV']) {
      expect(_file(name).isVideo, isTrue, reason: name);
      expect(_file(name).isMedia, isTrue, reason: name);
    }
    expect(_file('GS__0001.36P').isImage, isTrue);
    expect(_file('IMG_00_001.insp').isImage, isTrue);
  });

  test('leaves out the low resolution proxies', () {
    for (final name in ['LRV_20240908_193126_11_004.lrv', 'GL010013.LRF']) {
      expect(_file(name).isMedia, isFalse, reason: name);
    }
  });

  test('serves the MP4 files of 360° cameras as video/mp4, whatever the server says', () {
    for (final name in ['VID_00_001.insv', 'GS010013.360', 'CAM_0003_D.OSV', 'LRV_0001.lrv', 'GL010013.LRF']) {
      expect(_file(name).guessedMimeType, 'video/mp4', reason: name);
      expect(_file(name, mimeType: 'application/x-360').guessedMimeType, 'video/mp4', reason: name);
    }
    expect(_file('GS__0001.36P').guessedMimeType, 'image/jpeg');
    expect(_file('IMG_00_001.insp').guessedMimeType, 'image/jpeg');
    // Other files keep the type of the server
    expect(_file('clip.mp4', mimeType: 'video/quicktime').guessedMimeType, 'video/quicktime');
    expect(_file('clip.mp4', mimeType: 'application/octet-stream').guessedMimeType, 'video/mp4');
  });

  group('NetworkSource', () {
    const mediaServer = NetworkSource(
      id: 'dlna-1',
      type: NetworkSourceType.dlna,
      name: 'Living room',
      host: '192.168.1.10',
      port: 8096,
      share: '/dlna/7d2c/description.xml?x=1',
      rootPath: '/Video',
      discoveryId: 'uuid:4d696e69-444c-164e-9d41-b827eb000001',
    );

    test('stores a DLNA media server with its discovery id, and reads it back', () {
      final json = mediaServer.toJson();
      expect(json['type'], 'dlna');
      expect(json['discoveryId'], 'uuid:4d696e69-444c-164e-9d41-b827eb000001');

      final read = NetworkSource.decodeList(NetworkSource.encodeList([mediaServer])).single;
      expect(read.id, 'dlna-1');
      expect(read.type, NetworkSourceType.dlna);
      expect(read.name, 'Living room');
      expect(read.host, '192.168.1.10');
      expect(read.port, 8096);
      expect(read.share, '/dlna/7d2c/description.xml?x=1');
      expect(read.rootPath, '/Video');
      expect(read.username, '');
      expect(read.useTls, isFalse);
      expect(read.discoveryId, 'uuid:4d696e69-444c-164e-9d41-b827eb000001');
    });

    test('leaves the discovery id out of the JSON when there is none', () {
      final json = mediaServer.copyWith(clearDiscoveryId: true).toJson();

      expect(json.containsKey('discoveryId'), isFalse);
      expect(NetworkSource.fromJson(json)!.discoveryId, isNull);
    });

    test('reads the JSON of an older build, without a discovery id', () {
      final read = NetworkSource.decodeList(
        jsonEncode([
          {
            'id': 'nas',
            'type': 'webdav',
            'name': 'NAS',
            'host': 'nas.local',
            'port': 5005,
            'share': '/dav',
            'rootPath': '/',
            'username': 'alice',
            'useTls': false,
          },
        ]),
      ).single;

      expect(read.type, NetworkSourceType.webdav);
      expect(read.discoveryId, isNull);
      expect(read.toJson().containsKey('discoveryId'), isFalse);
    });

    test('drops a source of a type it does not know, as an older build drops a DLNA one', () {
      final sources = NetworkSource.decodeList(
        jsonEncode([
          {'id': 'a', 'type': 'ftp', 'name': 'FTP', 'host': 'nas.local'},
          {'id': 'b', 'type': 'smb', 'name': 'SMB', 'host': 'nas.local', 'share': 'media', 'discoveryId': ''},
        ]),
      );

      expect(sources.map((s) => s.id), ['b']);
      expect(sources.single.discoveryId, isNull, reason: 'an empty id is no id');
    });

    test('copyWith sets, keeps and clears the discovery id', () {
      expect(mediaServer.copyWith(name: 'Other').discoveryId, mediaServer.discoveryId);
      expect(mediaServer.copyWith(discoveryId: 'uuid:other').discoveryId, 'uuid:other');
      expect(mediaServer.copyWith(clearDiscoveryId: true).discoveryId, isNull);
      expect(mediaServer.copyWith(host: '192.168.1.11', port: 8200).type, NetworkSourceType.dlna);
    });
  });

  test('a file of a share may carry what a media server tells of it, none by default', () {
    final plain = _file('VID_0001.mp4');
    expect(plain.thumbnailUrl, isNull);
    expect(plain.width, isNull);
    expect(plain.height, isNull);
    expect(plain.durationMs, isNull);

    const indexed = NetworkEntry(
      sourceId: 'dlna-1',
      path: '/Video/VID_0001.mp4',
      isDirectory: false,
      thumbnailUrl: 'http://192.168.1.10:8200/AlbumArt/22-1.jpg',
      width: 5760,
      height: 2880,
      durationMs: 83456,
    );
    expect(indexed.thumbnailUrl, 'http://192.168.1.10:8200/AlbumArt/22-1.jpg');
    expect((indexed.width, indexed.height, indexed.durationMs), (5760, 2880, 83456));
    expect(indexed.isVideo, isTrue);
  });
}
