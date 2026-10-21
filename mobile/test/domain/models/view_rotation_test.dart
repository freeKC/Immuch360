import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/view_rotation.dart';

import '../../unit/factories/local_asset_factory.dart';
import '../../unit/factories/remote_asset_factory.dart';

void main() {
  group('normalizeQuarterTurns', () {
    test('brings any number of quarter turns into 0 to 3', () {
      expect(normalizeQuarterTurns(0), 0);
      expect(normalizeQuarterTurns(1), 1);
      expect(normalizeQuarterTurns(4), 0, reason: 'four presses are back to no turn');
      expect(normalizeQuarterTurns(5), 1);
      expect(normalizeQuarterTurns(-1), 3, reason: 'one turn counter clockwise is three clockwise');
      expect(normalizeQuarterTurns(-6), 2);
    });
  });

  group('rotatedSize', () {
    test('swaps width and height for an odd number of turns only', () {
      const size = Size(400, 200);
      expect(rotatedSize(size, 0), size);
      expect(rotatedSize(size, 1), const Size(200, 400));
      expect(rotatedSize(size, 2), size);
      expect(rotatedSize(size, 3), const Size(200, 400));
      expect(rotatedSize(size, -1), const Size(200, 400));
    });
  });

  group('keys', () {
    test('an asset is kept under its server id, and found under its id on the device too', () {
      final uploaded = RemoteAssetFactory.create(localId: 'local-1');
      expect(viewRotationAssetKey(uploaded), 'a:${uploaded.id}');
      expect(viewRotationLocalKey(uploaded), 'a:local-1');
      final local = LocalAssetFactory.create();
      expect(viewRotationAssetKey(local), 'a:${local.id}');
      expect(viewRotationAssetId(viewRotationAssetKey(local)), local.id);
      expect(viewRotationAssetId(viewRotationShareKey('s1', '/a.jpg')), isNull);
    });

    test('a file of the device is kept under its id there, even once its copy is on the server', () {
      // The device albums draw the file, never what an edit of the server made of its copy
      final backedUp = LocalAssetFactory.create(remoteId: 'remote-1');
      expect(viewRotationAssetKey(backedUp), 'a:${backedUp.id}');
      expect(viewRotationLocalKey(backedUp), 'a:${backedUp.id}');
    });

    test('a file of a share is kept under its share and path', () {
      final key = viewRotationShareKey('s1', '/Photos/a.jpg');
      expect(key, 'n:s1:/Photos/a.jpg');
      expect(isViewRotationShareKeyOf(key, 's1'), isTrue);
      expect(isViewRotationShareKeyOf(key, 's'), isFalse, reason: 'another share whose id starts the same');
    });
  });

  group('JSON', () {
    test('reads back what it writes, in order', () {
      final entries = {
        'a:asset-1': const ViewRotationEntry(1),
        'n:s1:/a.jpg': const ViewRotationEntry(3, size: 1234, modifiedMs: 1700000000000),
        'a:asset-2': const ViewRotationEntry(2),
      };
      final json = encodeViewRotations(entries);
      expect(json, '{"a:asset-1":1,"n:s1:/a.jpg":{"t":3,"s":1234,"m":1700000000000},"a:asset-2":2}');
      final decoded = decodeViewRotations(json);
      expect(decoded, entries);
      expect(decoded.keys.toList(), ['a:asset-1', 'n:s1:/a.jpg', 'a:asset-2']);
    });

    test('keeps the user an asset of a server was turned under', () {
      final entries = {'a:remote-1': const ViewRotationEntry(1, userId: 'me'), 'a:local-1': const ViewRotationEntry(2)};
      final json = encodeViewRotations(entries);
      expect(json, '{"a:remote-1":{"t":1,"u":"me"},"a:local-1":2}');
      expect(decodeViewRotations(json), entries);
      expect(decodeViewRotations('{"a:bad-user":{"t":1,"u":3},"a:bad-turns":{"t":5,"u":"me"},"a:ok":{"t":3}}'), {
        'a:ok': const ViewRotationEntry(3),
      });
    });

    test('skips a damaged value, unknown kinds of keys and turns out of 1 to 3', () {
      expect(decodeViewRotations(null), isEmpty);
      expect(decodeViewRotations(''), isEmpty);
      expect(decodeViewRotations('{not json'), isEmpty);
      expect(decodeViewRotations('[1, 2]'), isEmpty);
      final decoded = decodeViewRotations(
        '{"a:ok":1,"a:zero":0,"a:four":4,"a:text":"1","x:other":2,"n:s:/bad":3,"n:s:/size":{"t":2,"s":"big"},'
        '"n:s:/good":{"t":2}}',
      );
      expect(decoded, {'a:ok': const ViewRotationEntry(1), 'n:s:/good': const ViewRotationEntry(2)});
    });
  });

  group('withViewRotation', () {
    test('puts the latest last, removes with null, and forgets the oldest past the cap', () {
      var entries = <String, ViewRotationEntry>{};
      entries = withViewRotation(entries, 'a:1', const ViewRotationEntry(1), maxEntries: 2);
      entries = withViewRotation(entries, 'a:2', const ViewRotationEntry(2), maxEntries: 2);
      entries = withViewRotation(entries, 'a:1', const ViewRotationEntry(3), maxEntries: 2);
      expect(entries.keys.toList(), ['a:2', 'a:1']);
      entries = withViewRotation(entries, 'a:3', const ViewRotationEntry(1), maxEntries: 2);
      expect(entries.keys.toList(), ['a:1', 'a:3'], reason: 'the one turned first goes');
      entries = withViewRotation(entries, 'a:1', null, maxEntries: 2);
      expect(entries.keys.toList(), ['a:3']);
    });
  });

  group('share files', () {
    test('a rotation holds for the same file only', () {
      final entries = {'n:s1:/a.jpg': const ViewRotationEntry(1, size: 10, modifiedMs: 20)};
      expect(viewRotationShareTurnsOf(entries, 's1', '/a.jpg', size: 10, modifiedMs: 20), 1);
      expect(viewRotationShareTurnsOf(entries, 's1', '/a.jpg', size: 11, modifiedMs: 20), 0);
      expect(viewRotationShareTurnsOf(entries, 's1', '/a.jpg', size: 10, modifiedMs: 21), 0);
      expect(viewRotationShareTurnsOf(entries, 's2', '/a.jpg', size: 10, modifiedMs: 20), 0);
    });
  });
}
