// What the 2D panel of the Meta Quest sends for an AI relief: the depthRelief request equal to the contract, built
// from the model installed on the headset, the identity of a photo for the relief cache, and the relief cache folder
// the advanced settings size and clear.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/domain/services/ai_immersive/quest_relief.dart';
import 'package:path/path.dart' as p;

import '../../unit/factories/local_asset_factory.dart';
import '../../unit/factories/remote_asset_factory.dart';

void main() {
  final contract =
      jsonDecode(File('test/fixtures/ai_immersive/stereo_pair_contract_v1.json').readAsStringSync())
          as Map<String, dynamic>;
  Map<String, dynamic> request(int index) =>
      ((contract['depthRelief'] as List)[index] as Map<String, dynamic>)['request'] as Map<String, dynamic>;
  final cacheKeys = (contract['cacheKeys'] as List).cast<Map<String, dynamic>>();

  // The files folder of the release package on the headset, where getApplicationSupportDirectory() points
  const files = '/data/user/0/com.aprogsys.immuch360/files';
  final modelPath = p.posix.join(files, aiComponentsFolderName, depthModelTfliteComponent.installPath);

  group('the depthRelief request', () {
    test('of a photo of the server is the JSON of the contract', () {
      final relief = questReliefRequest(
        modelPath: modelPath,
        identity: cacheKeys[0]['identity'] as String,
        quarterTurns: 0,
      );

      expect(jsonDecode(relief.toJsonString()), request(0));
    });

    test('of a photo of a share turned once is the JSON of the contract', () {
      final share = cacheKeys[1]['share'] as Map<String, dynamic>;
      final identity = reliefIdentityOfShareFile(
        sourceId: share['source'] as String,
        path: share['path'] as String,
        size: share['size'] as int,
        modified: DateTime.fromMillisecondsSinceEpoch(share['modifiedMs'] as int, isUtc: true),
      );
      final relief = questReliefRequest(modelPath: modelPath, identity: identity, quarterTurns: 1);

      expect(identity, cacheKeys[1]['identity']);
      expect(jsonDecode(relief.toJsonString()), request(1));
    });

    test('of a photo of the server first shown in 2.5D is the JSON of the contract, with the same cache key', () {
      final relief = questReliefRequest(
        modelPath: modelPath,
        identity: cacheKeys[0]['identity'] as String,
        quarterTurns: 0,
        mode: ReliefViewMode.mesh25d,
      );

      expect(jsonDecode(relief.toJsonString()), request(2));
      expect(relief.cacheKey, request(0)['cacheKey']);
    });

    test('names the model of the Quest by the size and the sum of the catalogue', () {
      final relief = questReliefRequest(modelPath: modelPath, identity: 'sha1:abc=', quarterTurns: 0);

      expect(relief.model, modelPath);
      expect(relief.modelSize, depthModelTfliteComponent.size);
      expect(relief.modelId, 'depth-anything-v2-small@651415f1');
    });

    test('keys the cache with the quarter turns, from 0 to 3', () {
      final keys = {
        for (var turns = 0; turns < 4; turns++)
          questReliefRequest(modelPath: modelPath, identity: 'sha1:abc=', quarterTurns: turns).cacheKey,
      };

      expect(keys, hasLength(4));
      final five = questReliefRequest(modelPath: modelPath, identity: 'sha1:abc=', quarterTurns: 5);
      final minusThree = questReliefRequest(modelPath: modelPath, identity: 'sha1:abc=', quarterTurns: -3);
      final one = questReliefRequest(modelPath: modelPath, identity: 'sha1:abc=', quarterTurns: 1);
      expect(five.quarterTurns, 1);
      expect(minusThree.quarterTurns, 1);
      expect({five.cacheKey, minusThree.cacheKey}, {one.cacheKey});
    });
  });

  group('the identity of a photo', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('quest_relief_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('is the checksum the app holds, without reading the file', () async {
      final asset = RemoteAssetFactory.create().copyWith(checksum: 'X8tYgvibyzHDDN2yXGU/ft1XxeM=');
      var read = 0;

      final identity = await reliefIdentityOfAsset(
        asset,
        file: () async {
          read++;
          return null;
        },
      );

      expect(identity, 'sha1:X8tYgvibyzHDDN2yXGU/ft1XxeM=');
      expect(read, 0);
    });

    test('is the SHA-1 of the file in base64 when the app has no checksum yet', () async {
      final bytes = utf8.encode('a photo of the headset, not hashed yet');
      final file = File(p.join(dir.path, 'photo.jpg'))..writeAsBytesSync(bytes);
      final asset = LocalAssetFactory.create();

      final identity = await reliefIdentityOfAsset(asset, file: () async => file);

      expect(identity, 'sha1:${base64Encode(sha1.convert(bytes).bytes)}');
    });

    test('cannot be told without a checksum nor a file', () async {
      final asset = LocalAssetFactory.create();

      expect(reliefIdentityOfAsset(asset, file: () async => null), throwsStateError);
    });

    test('of a file of a share whose size or date is not known still makes a key', () {
      expect(reliefIdentityOfShareFile(sourceId: 'nas', path: '/a.jpg'), 'share:nas:/a.jpg:-1:0');
      expect(
        reliefIdentityOfShareFile(
          sourceId: 'nas',
          path: '/a.jpg',
          size: 10,
          modified: DateTime.utc(2026, 10, 27, 9, 12),
        ),
        'share:nas:/a.jpg:10:1793092320000',
      );
    });
  });

  group('the relief cache folder', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('quest_relief_cache_'));
    tearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    void write(String name, int size) => File(p.join(dir.path, name)).writeAsBytesSync(List.filled(size, 1));

    test('counts its files, partial ones included, and nothing in a folder inside', () async {
      write('${'a' * 64}.u16', 710712);
      write('${'b' * 64}.u16', 1000);
      write('${'c' * 64}.u16.123.tmp', 500);
      Directory(p.join(dir.path, 'inside')).createSync();
      File(p.join(dir.path, 'inside', 'other.bin')).writeAsBytesSync(List.filled(9999, 1));

      expect(await reliefCacheBytes(dir), 710712 + 1000 + 500);
    });

    test('is empty when it does not exist', () async {
      dir.deleteSync(recursive: true);

      expect(await reliefCacheBytes(dir), 0);
      expect(await clearReliefCache(dir), 0);
    });

    test('Clear removes its files and nothing else, and says what it freed', () async {
      write('${'a' * 64}.u16', 710712);
      write('${'c' * 64}.u16.123.tmp', 500);
      Directory(p.join(dir.path, 'inside')).createSync();
      final kept = File(p.join(dir.path, 'inside', 'other.bin'))..writeAsBytesSync(List.filled(9999, 1));
      final outside = File(p.join(dir.parent.path, '${p.basename(dir.path)}-neighbour.bin'))
        ..writeAsBytesSync(List.filled(10, 1));
      addTearDown(() => outside.existsSync() ? outside.deleteSync() : null);

      expect(await clearReliefCache(dir), 710712 + 500);
      expect(await reliefCacheBytes(dir), 0);
      expect(kept.existsSync(), isTrue);
      expect(outside.existsSync(), isTrue);
    });
  });
}
