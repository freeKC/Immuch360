// The files of a share the app shows, and the content type the media bridge serves them with: the raw videos of 360°
// cameras are MP4 files under names of their own, which the players only read as video/mp4. The sources as stored, a
// DLNA media server, a Plex server, a Tapo camera and the id a server announces included, and read back by older and
// newer builds: what a later build stores and this one does not know is kept and written back.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';

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

  group('Plex servers and Tapo cameras', () {
    const plexServer = NetworkSource(
      id: '0123456789abcdef',
      type: NetworkSourceType.plex,
      name: 'Test Plex',
      host: '192.0.2.20',
      rootPath: '/Photos',
      useTls: true,
      discoveryId: '0000000000000000000000000000000000000001',
      plex: PlexServerInfo(
        hash: '0123456789abcdef0123456789abcdef',
        publicHost: '203.0.113.7',
        publicPort: 32401,
        version: '1.42.1.10060-4e8b05daf',
      ),
    );

    const camera = NetworkSource(
      id: '1123456789abcdef',
      type: NetworkSourceType.tapo,
      name: 'Garden',
      host: '192.0.2.30',
      username: 'viewer',
      useTls: true,
      discoveryId: '02-00-00-00-00-01',
      camera: TapoCameraInfo(
        model: 'C200',
        firmware: '1.3.9',
        protocol: TapoLoginProtocol.v4,
        passcode: TapoPasscodeHash.sha256,
        userName: TapoUserNameForm.md5,
        zoneId: 'Europe/Paris',
        rtspPort: 1554,
        certificateSha256: '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff',
      ),
    );

    test('the stored types: the first three in the list older builds read, the later ones in their own', () {
      expect(NetworkSourceType.values.map((type) => type.name), ['smb', 'webdav', 'dlna', 'plex', 'tapo']);
      expect(NetworkSourceType.values.where((type) => type.inLegacyList), [
        NetworkSourceType.smb,
        NetworkSourceType.webdav,
        NetworkSourceType.dlna,
      ]);
    });

    test('stores a Plex server with its hash, address outside home and version, and reads it back', () {
      final json = plexServer.toJson();
      expect(json['type'], 'plex');
      expect(json['plex'], {
        'hash': '0123456789abcdef0123456789abcdef',
        'publicHost': '203.0.113.7',
        'publicPort': 32401,
        'version': '1.42.1.10060-4e8b05daf',
      });

      final read = NetworkSource.fromJson(jsonDecode(jsonEncode(json)))!;
      expect(read.type, NetworkSourceType.plex);
      expect(read.plex, plexServer.plex);
      expect(read.discoveryId, plexServer.discoveryId);
      expect(read.rootPath, '/Photos');
      expect(read.camera, isNull);
      expect(read.secretKey, 'network_source_password_0123456789abcdef');
    });

    test('drops a Plex server without a valid hash: the token could go to any server', () {
      for (final plex in [
        null,
        'not a map',
        <String, Object?>{},
        {'hash': '0123456789ABCDEF0123456789ABCDEF'},
        {'hash': '0123456789abcdef'},
        {'hash': 42},
      ]) {
        final json = {...plexServer.toJson(), 'plex': plex};
        expect(NetworkSource.fromJson(json), isNull, reason: '$plex');
      }
    });

    test('copyWith keeps or replaces the Plex part, which clears its address outside home', () {
      expect(plexServer.copyWith(name: 'Other').plex, plexServer.plex);
      final cleared = plexServer.plex!.copyWith(clearPublicHost: true, clearPublicPort: true, version: '1.43');
      expect(cleared.publicHost, isNull);
      expect(cleared.publicPort, isNull);
      expect(cleared.version, '1.43');
      expect(cleared.hash, plexServer.plex!.hash);
      expect(plexServer.copyWith(plex: cleared).plex, cleared);
      expect(cleared.toJson().containsKey('publicHost'), isFalse);
    });

    test('stores a camera with what the app learned, and reads it back', () {
      final read = NetworkSource.fromJson(jsonDecode(jsonEncode(camera.toJson())))!;

      expect(read.type, NetworkSourceType.tapo);
      expect(read.camera, camera.camera);
      expect(read.camera!.rtspPort, 1554);
      expect(read.camera!.mediaPort, TapoCameraInfo.defaultMediaPort);
      expect(read.username, 'viewer');
      expect(read.discoveryId, '02-00-00-00-00-01');
      expect(read.secretKey, 'network_source_password_1123456789abcdef');
      expect(read.cameraSecretKey, 'network_source_camera_password_1123456789abcdef');
      expect(jsonEncode(camera.toJson()), isNot(contains('password')));
    });

    test('a camera saved with its camera account only has no learned details', () {
      final json = camera.toJson()..remove('camera');

      final read = NetworkSource.fromJson(json)!;

      expect(read.type, NetworkSourceType.tapo);
      expect(read.camera, isNull);
      expect(read.toJson().containsKey('camera'), isFalse);
    });

    test('reads the enum values of a later build as unknown, and writes them back as they were', () {
      final json = {
        ...camera.toJson(),
        'camera': {
          'model': 'C211',
          'protocol': 'v5',
          'passcode': 'argon2',
          'userName': 'md5',
          'rtspPort': 554,
          'mediaPort': 8800,
          'lensCount': 2,
        },
      };

      final read = NetworkSource.fromJson(json)!;
      expect(read.camera!.protocol, isNull);
      expect(read.camera!.passcode, isNull);
      expect(read.camera!.userName, TapoUserNameForm.md5);
      expect(read.camera!.model, 'C211');

      final written = read.toJson()['camera']! as Map<String, Object?>;
      expect(written['protocol'], 'v5');
      expect(written['passcode'], 'argon2');
      expect(written['lensCount'], 2);

      // What this build learns replaces what it could not read
      final learned = read.copyWith(camera: read.camera!.copyWith(protocol: TapoLoginProtocol.v4)).toJson();
      expect((learned['camera']! as Map)['protocol'], 'v4');
      expect((learned['camera']! as Map)['passcode'], 'argon2');
    });

    test('writes back the keys of a later build, under its own known keys', () {
      final json = {
        ...camera.toJson(),
        'futureField': 'kept',
        'name': 'Garden',
        'nested': {'a': 1},
      };

      final read = NetworkSource.fromJson(json)!;
      expect(read.extraJson, {
        'futureField': 'kept',
        'nested': {'a': 1},
      });

      final renamed = read.copyWith(name: 'Front door').toJson();
      expect(renamed['futureField'], 'kept');
      expect(renamed['nested'], {'a': 1});
      expect(renamed['name'], 'Front door', reason: 'the known keys overwrite the kept ones');

      final plexJson = {
        ...plexServer.toJson(),
        'plex': {...plexServer.plex!.toJson(), 'relay': true},
      };
      final plex = NetworkSource.fromJson(plexJson)!;
      expect((plex.copyWith(name: 'Renamed').toJson()['plex']! as Map)['relay'], isTrue);
    });

    test('a stored list keeps the entries of a type it does not know, unchanged', () {
      final jellyfin = {
        'id': 'aaaaaaaaaaaaaaaa',
        'type': 'jellyfin',
        'name': 'Media',
        'host': '192.0.2.40',
        'whatever': [1, 2, 3],
      };
      final dropped = <Object?>[];
      final stored = NetworkSource.decodeStored(
        jsonEncode([
          plexServer.toJson(),
          jellyfin,
          camera.toJson(),
          {'id': 'broken', 'type': 'plex', 'name': 'No hash', 'host': '192.0.2.50'},
          'not a source',
        ]),
        onDropped: dropped.add,
      );

      expect(stored.sources.map((source) => source.id), [plexServer.id, camera.id]);
      expect(stored.unknown, [jellyfin]);
      expect(dropped, hasLength(2), reason: 'a plex entry without a hash and a string');

      final encoded = NetworkSource.encodeStored(stored.sources, stored.unknown)!;
      final again = NetworkSource.decodeStored(encoded);
      expect(again.sources.map((source) => source.id), [plexServer.id, camera.id]);
      expect(again.unknown, [jellyfin]);
      expect((jsonDecode(encoded) as List).last, jellyfin);
    });

    test('an empty stored list is no value, and a broken one reads as empty', () {
      expect(NetworkSource.encodeStored(const [], const []), isNull);
      expect(
        NetworkSource.encodeStored(const [], [
          {'type': 'jellyfin'},
        ]),
        isNotNull,
      );
      for (final json in [null, '', 'not json', '{"a": 1}']) {
        final stored = NetworkSource.decodeStored(json);
        expect(stored.sources, isEmpty, reason: json);
        expect(stored.unknown, isEmpty, reason: json);
      }
    });

    test('SMB, WebDAV and DLNA shares are stored as before', () {
      const smb = NetworkSource(
        id: 'smb',
        type: NetworkSourceType.smb,
        name: 'NAS',
        host: 'nas.local',
        share: 'media',
        username: 'alice',
      );
      expect(smb.toJson(), {
        'id': 'smb',
        'type': 'smb',
        'name': 'NAS',
        'host': 'nas.local',
        'port': null,
        'share': 'media',
        'rootPath': '/',
        'username': 'alice',
        'useTls': false,
      });
      final read = NetworkSource.decodeStored(NetworkSource.encodeList([smb])).sources.single;
      expect(read.toJson(), smb.toJson());
      expect(read.extraJson, isEmpty);
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
