// The Dart port of SplatReducer.kt (lot SV4 of the splat viewer) against the fixtures and expected.json of
// make_splat_fixtures.py, which SplatReducerTest.kt reads too: the same scores, the same kept gaussians, and the same
// version 2 rewrites once inflated.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_reducer.dart';

File _fixture(String name) => File('test/fixtures/splat/$name');

SplatHead _head(String name) {
  final file = _fixture(name);
  final bytes = file.readAsBytesSync();
  final probe = probeSplatHead(Uint8List.sublistView(bytes, 0, bytes.length.clamp(0, splatHeadBytes)), bytes.length);
  return probe as SplatHead;
}

void main() {
  final expected = jsonDecode(_fixture('expected.json').readAsStringSync()) as Map<String, dynamic>;
  final reduction = expected['reduction'] as Map<String, dynamic>;
  late Directory folder;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('splat_reducer_test');
  });

  tearDown(() async {
    await folder.delete(recursive: true);
  });

  for (final name in ['ranked_v3.spz', 'ranked.ply']) {
    test('$name: the scores and the kept gaussians of expected.json', () async {
      final wanted = reduction[name] as Map<String, dynamic>;
      final scores = await scoreSplat(_fixture(name), _head(name));
      final want = (wanted['scores'] as List).cast<num>();
      expect(scores.length, want.length);
      for (var i = 0; i < scores.length; i++) {
        expect(scores[i], closeTo(want[i], 1e-5), reason: 'score $i');
      }
      final kept = selectStrongest(scores, reduction['keep'] as int);
      expect(kept.indices, (wanted['kept'] as List).cast<int>());
    });
  }

  test('a tie goes to the lower index, and keeping more than there are keeps all', () {
    final scores = Float32List.fromList([1, 3, 2, 2, 2, double.nan, 0]);
    expect(selectStrongest(scores, 3).indices, [1, 2, 3]);
    expect(selectStrongest(scores, 7).indices, [0, 1, 2, 3, 4, 5, 6]);
    expect(selectStrongest(scores, 0).indices, isEmpty);
    expect(selectStrongest(scores, 6).indices, [0, 1, 2, 3, 4, 6], reason: 'a score that is not a number comes last');
  });

  test('a PLY keeps its header with the new count and the kept rows untouched', () async {
    final out = File('${folder.path}/ranked.ply');
    final keep = reduction['keep'] as int;
    final kept = await reduceSplatFile(source: _fixture('ranked.ply'), head: _head('ranked.ply'), keep: keep, out: out);
    expect(kept, keep);
    final source = _fixture('ranked.ply').readAsBytesSync();
    final written = out.readAsBytesSync();
    final layout = SplatPlyLayout.parse(source);
    final writtenLayout = SplatPlyLayout.parse(written);
    expect(writtenLayout.count, keep);
    expect(
      latin1.decode(written.sublist(0, writtenLayout.headerBytes)),
      latin1.decode(source.sublist(0, layout.headerBytes)).replaceFirst('element vertex 24', 'element vertex $keep'),
    );
    final indices = ((reduction['ranked.ply'] as Map)['kept'] as List).cast<int>();
    for (var k = 0; k < keep; k++) {
      final from = layout.headerBytes + indices[k] * layout.rowBytes;
      final to = writtenLayout.headerBytes + k * layout.rowBytes;
      expect(written.sublist(to, to + layout.rowBytes), source.sublist(from, from + layout.rowBytes), reason: 'row $k');
    }
    expect(written.length, writtenLayout.headerBytes + keep * layout.rowBytes);
  });

  // The rewrites of the headset (moduleSpz of expected.json), every gaussian kept: the same data once inflated
  for (final (source, rewritten) in [('turns_v3.spz', 'turns_v2.spz'), ('axes_v1.spz', 'axes_v1_v2.spz')]) {
    test('$source written as version 2 is $rewritten once inflated', () async {
      final head = _head(source);
      final out = File('${folder.path}/out.spz');
      await writeKept(_fixture(source), head, selectStrongest(Float32List(head.gaussians), head.gaussians), out);
      expect(gzip.decode(out.readAsBytesSync()), gzip.decode(_fixture(rewritten).readAsBytesSync()));
    });
  }

  test('an SPZ of version 3 reduced: version 2, the kept points of every array', () async {
    final out = File('${folder.path}/ranked.spz');
    final keep = reduction['keep'] as int;
    await reduceSplatFile(source: _fixture('ranked_v3.spz'), head: _head('ranked_v3.spz'), keep: keep, out: out);
    final data = gzip.decode(out.readAsBytesSync());
    final header = ByteData.sublistView(Uint8List.fromList(data));
    expect(header.getUint32(0, Endian.little), splatSpzMagic);
    expect(header.getInt32(4, Endian.little), 2);
    expect(header.getUint32(8, Endian.little), keep);
    expect(data.length, 16 + keep * (9 + 1 + 3 + 3 + 3));
    final probe = probeSplatHead(out.readAsBytesSync(), out.lengthSync());
    expect(probe, isA<SplatHead>());
    expect((probe as SplatHead).gaussians, keep);
    expect(probe.formatVersion, 2);
    // Its scores are those of the kept points of the source
    final scores = await scoreSplat(out, probe);
    final source = ((reduction['ranked_v3.spz'] as Map)['scores'] as List).cast<num>();
    final indices = ((reduction['ranked_v3.spz'] as Map)['kept'] as List).cast<int>();
    for (var k = 0; k < keep; k++) {
      expect(scores[k], closeTo(source[indices[k]], 1e-5));
    }
  });

  test('a file cut short, or with a wrong CRC, stops as damaged and leaves nothing', () async {
    final whole = _fixture('axes_v2.spz').readAsBytesSync();
    final head = _head('axes_v2.spz');
    final cut = File('${folder.path}/cut.spz')..writeAsBytesSync(whole.sublist(0, whole.length - 30));
    final out = File('${folder.path}/out.spz');
    await expectLater(
      reduceSplatFile(source: cut, head: head, keep: 10, out: out),
      throwsA(isA<SplatReduceException>()),
    );
    expect(out.existsSync(), isFalse);
    final wrongCrc = Uint8List.fromList(whole);
    wrongCrc[wrongCrc.length - 6] ^= 0xff;
    final bad = File('${folder.path}/crc.spz')..writeAsBytesSync(wrongCrc);
    await expectLater(
      reduceSplatFile(source: bad, head: head, keep: 10, out: out),
      throwsA(isA<SplatReduceException>()),
    );
    expect(out.existsSync(), isFalse);
  });

  test('cancelled between two chunks: stops and leaves nothing', () async {
    final out = File('${folder.path}/out.ply');
    await expectLater(
      reduceSplatFile(source: _fixture('axes.ply'), head: _head('axes.ply'), keep: 10, out: out, cancelled: () => true),
      throwsA(isA<SplatReduceCancelled>()),
    );
    expect(out.existsSync(), isFalse);
  });

  test('progress goes from 0 to 1', () async {
    final seen = <double>[];
    await reduceSplatFile(
      source: _fixture('axes_v2.spz'),
      head: _head('axes_v2.spz'),
      keep: 100,
      out: File('${folder.path}/out.spz'),
      progress: seen.add,
    );
    expect(seen.first, lessThanOrEqualTo(0.5));
    expect(seen.last, 1);
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
    }
  });

  test('version 4 is not reduced here', () async {
    expect(() => scoreSplat(_fixture('axes_v4.spz'), _head('axes_v4.spz')), throwsA(isA<SplatReduceException>()));
  });
}
