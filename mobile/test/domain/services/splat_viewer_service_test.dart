// One viewing of the splat viewer (lots SV1 and SV4), with a fake host that does what the page does over real HTTP on
// the real media bridge: it reads session.json and the scene, posts ready, an orientation and close. The scene of a
// file of this device, of a share, and of a splat above the cap (copied from its share, reduced, kept); the endings.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_reducer.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/splat_viewer_files.dart';
import 'package:immich_mobile/domain/services/splat_viewer_host.dart';
import 'package:immich_mobile/domain/services/splat_viewer_service.dart';
import 'package:immich_mobile/domain/services/splat_viewer_session.dart';

/// Behaves as the page in a web view: GETs the session and the scene, then posts what [script] says
class _PageHost implements SplatViewerHost {
  _PageHost(this.script);

  /// The events posted once the scene is read, in order
  final List<Map<String, Object?>> script;
  Completer<SplatHostClosed>? _ended;
  Map<String, Object?>? session;
  Uint8List? scene;
  Uri? opened;
  String? title;
  int closes = 0;
  SplatHostClosed ending = SplatHostClosed.user;

  @override
  Future<SplatHostClosed> open(Uri pageUrl, {required String title}) async {
    opened = pageUrl;
    this.title = title;
    final ended = _ended = Completer<SplatHostClosed>();
    final client = HttpClient();
    try {
      Future<Uint8List> get(Uri url) async {
        final response = await (await client.getUrl(url)).close();
        expect(response.statusCode, HttpStatus.ok, reason: '$url');
        final bytes = BytesBuilder(copy: false);
        await response.forEach(bytes.add);
        return bytes.takeBytes();
      }

      final page = await get(pageUrl);
      expect(utf8.decode(page), contains('<script type="module" src="viewer.js">'));
      session = jsonDecode(utf8.decode(await get(pageUrl.resolve('session.json')))) as Map<String, Object?>;
      scene = await get(pageUrl.resolve((session!['scene']! as Map)['url']! as String));
      for (final event in script) {
        final request = await client.postUrl(pageUrl.resolve('events'));
        request.add(utf8.encode(jsonEncode(event)));
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.noContent);
      }
    } finally {
      client.close();
    }
    return ended.future;
  }

  @override
  Future<void> close() async {
    closes++;
    final ended = _ended;
    if (ended != null && !ended.isCompleted) {
      ended.complete(ending);
    }
  }
}

class _Share implements NetworkFileSystem {
  _Share(this.files);

  final Map<String, Uint8List> files;
  final Map<String, DateTime> dates = {};
  int reads = 0;
  int bytesRead = 0;

  @override
  NetworkSource get source => const NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'NAS', host: 'nas');

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    reads++;
    bytesRead += length;
    final bytes = files[path]!;
    return Uint8List.sublistView(bytes, offset, offset + length);
  }

  @override
  Future<NetworkEntry> stat(String path) async =>
      NetworkEntry(sourceId: 'nas', path: path, isDirectory: false, size: files[path]!.length, modified: dates[path]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SplatHead _head(Uint8List bytes) => probeSplatHead(bytes, bytes.length) as SplatHead;

void main() {
  late Directory folder;
  late LocalMediaBridge bridge;
  late SplatUprightStore uprights;
  late SplatViewerCache cache;
  final page = {for (final name in splatViewerPageFiles) name: File('$splatViewerAssetFolder/$name').readAsBytesSync()};
  final axes = File('test/fixtures/splat/axes_v2.spz').readAsBytesSync();
  final ranked = File('test/fixtures/splat/ranked.ply').readAsBytesSync();
  const look = SplatViewerLook(
    texts: {'reset': 'Reset'},
    locale: 'fr',
    dark: true,
    primary: '#4250af',
    device: 'phone',
    gyroscope: true,
    maxStdDev: 2.236,
    pixelRatioMax: 1,
  );

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('splat_viewer_service_test');
    bridge = LocalMediaBridge();
    uprights = SplatUprightStore(() async => File('${folder.path}/uprights.json'));
    cache = SplatViewerCache(() async => Directory('${folder.path}/cache'));
  });

  tearDown(() async {
    await bridge.stop();
    await folder.delete(recursive: true);
  });

  SplatViewerService service(SplatViewerHost host, {_Share? share}) => SplatViewerService(
    bridge: bridge,
    host: host,
    loadPage: () async => page,
    uprights: uprights,
    cache: cache,
    fileSystem: (sourceId) async => share!,
    shareUrl: (sourceId, path) async {
      bridge.register(share!);
      return bridge.urlFor(sourceId, path);
    },
  );

  test('a file of this device: served from disk, the session in the words of the app, the orientation kept', () async {
    final file = File('${folder.path}/axes.spz')..writeAsBytesSync(axes);
    final host = _PageHost([
      {'type': 'ready', 'loadMs': 90, 'gaussians': 686},
      {'type': 'upright', 'value': 'yUp'},
      {'type': 'close'},
    ]);
    final outcome = await service(host).show(
      source: SplatViewerSource.local(file.path),
      head: _head(axes),
      fileBytes: axes.length,
      cap: 150000,
      look: look,
    );
    expect(outcome.end, SplatViewerEnd.closed);
    expect(host.title, 'axes.spz');
    expect(host.scene, axes);
    final scene = host.session!['scene']! as Map;
    expect(scene['url'], 'scene.spz');
    expect(scene['gaussians'], 686);
    expect(scene['reduced'], isFalse);
    expect(host.session!['device'], 'phone');
    expect(host.session!['locale'], 'fr');
    expect((host.session!['texts']! as Map)['reset'], 'Reset');
    expect(host.session!['upright'], isNull);
    expect(host.closes, 1, reason: 'the page asked to close');
    expect(await uprights.read('axes.spz', axes.length), 'yUp');
    // Gone once closed
    final response = await (await HttpClient().getUrl(host.opened!)).close();
    expect(response.statusCode, HttpStatus.notFound);
    // The next opening of the same file takes the orientation chosen
    final again = _PageHost([
      {'type': 'close'},
    ]);
    await service(again).show(
      source: SplatViewerSource.local(file.path),
      head: _head(axes),
      fileBytes: axes.length,
      cap: 150000,
      look: look,
    );
    expect(again.session!['upright'], 'yUp');
  });

  test('a file of a share under the cap keeps its own URL on the bridge, nothing copied', () async {
    final share = _Share({'/splats/axes.spz': axes});
    final host = _PageHost([
      {'type': 'close'},
    ]);
    await service(host, share: share).show(
      source: const SplatViewerSource.share('nas', '/splats/axes.spz'),
      head: _head(axes),
      fileBytes: axes.length,
      cap: 150000,
      look: look,
    );
    expect((host.session!['scene']! as Map)['url'], startsWith('/'));
    expect((host.session!['scene']! as Map)['url'], endsWith('/nas/splats/axes.spz'));
    expect(host.scene, axes);
    expect(
      Directory('${folder.path}/cache').existsSync() && Directory('${folder.path}/cache').listSync().isNotEmpty,
      isFalse,
    );
  });

  test('above the cap: copied from its share, reduced to its strongest, kept for the next time', () async {
    final share = _Share({'/ranked.ply': ranked});
    final steps = <SplatPrepareStep>{};
    Future<SplatViewerOutcome> open(_PageHost host) =>
        SplatViewerService(
          bridge: bridge,
          host: host,
          loadPage: () async => page,
          uprights: uprights,
          cache: cache,
          fileSystem: (sourceId) async => share,
          shareUrl: (sourceId, path) async => bridge.urlFor(sourceId, path),
          reduce: reduceForTest,
        ).show(
          source: const SplatViewerSource.share('nas', '/ranked.ply'),
          head: _head(ranked),
          fileBytes: ranked.length,
          cap: 10,
          look: look,
          progress: (step, done) => steps.add(step),
        );
    final host = _PageHost([
      {'type': 'close'},
    ]);
    final outcome = await open(host);
    expect(outcome.end, SplatViewerEnd.closed);
    expect(steps, {SplatPrepareStep.copy, SplatPrepareStep.reduce});
    final scene = host.session!['scene']! as Map;
    expect(scene['reduced'], isTrue);
    expect(scene['shown'], 10);
    expect(scene['gaussians'], 24);
    expect(scene['url'], 'scene.ply');
    final reduced = _head(host.scene!);
    expect(reduced.gaussians, 10);
    final reads = share.reads;
    expect(reads, greaterThan(0));
    // The second time: the copy kept, the share read again for the fingerprint of the file only (this small file
    // whole, in one read), nothing copied
    steps.clear();
    final again = _PageHost([
      {'type': 'close'},
    ]);
    await open(again);
    expect(steps, isEmpty);
    expect(share.reads, reads + 1);
    expect(again.scene, host.scene);
    final names = Directory('${folder.path}/cache').listSync().map((entry) => entry.path.split('/').last).toList();
    expect(names, hasLength(1));
    expect(names.single, startsWith('reduced-'));
  });

  /// [ply] with every x moved by [dx]: another scene of the same name and the same size
  Uint8List moved(Uint8List ply, double dx) {
    final copy = Uint8List.fromList(ply);
    final header = latin1.decode(copy.sublist(0, math.min(2000, copy.length)), allowInvalid: true);
    final start = header.indexOf('end_header\n') + 'end_header\n'.length;
    final data = ByteData.sublistView(copy);
    for (var row = start; row + 56 <= copy.length; row += 56) {
      data.setFloat32(row, data.getFloat32(row, Endian.little) + dx, Endian.little);
    }
    return copy;
  }

  SplatViewerService reducing(
    SplatViewerHost host, {
    _Share? share,
    Future<int?> Function(Directory folder)? freeBytes,
  }) => SplatViewerService(
    bridge: bridge,
    host: host,
    loadPage: () async => page,
    uprights: uprights,
    cache: cache,
    fileSystem: (sourceId) async => share!,
    shareUrl: (sourceId, path) async => bridge.urlFor(sourceId, path),
    reduce: reduceForTest,
    freeBytes: freeBytes,
  );

  test(
    'two files picked under the same name and size each show their own scene, never the other one\'s copy',
    () async {
      // Review of 2 November 2026: Android copies every pick to cache/picked-splat/<its name>, and two point_cloud.ply
      // of a trainer stopped at the same count have the same size: the second showed the first one's reduced copy
      final picked = Directory('${folder.path}/picked-splat')..createSync();
      final file = File('${picked.path}/point_cloud.ply')..writeAsBytesSync(ranked);
      final other = moved(ranked, 1);
      expect(other.length, ranked.length);
      Future<Uint8List> show() async {
        final host = _PageHost([
          {'type': 'close'},
        ]);
        await reducing(host).show(
          source: SplatViewerSource.local(file.path),
          head: _head(file.readAsBytesSync()),
          fileBytes: file.lengthSync(),
          cap: 10,
          look: look,
        );
        return host.scene!;
      }

      final first = await show();
      // The second pick, written over the first one at the same place, with the same date
      final date = file.lastModifiedSync();
      file.writeAsBytesSync(other);
      file.setLastModifiedSync(date);
      final second = await show();
      expect(second, isNot(first));
      final out = File('${folder.path}/expected.ply');
      await reduceSplatFile(source: file, head: _head(other), keep: 10, out: out);
      expect(second, out.readAsBytesSync());
      // The same file once more: its copy is kept
      expect(await show(), second);
    },
  );

  test('a file of a share written again in place with the same size shows its new scene', () async {
    final share = _Share({'/scan/point_cloud.ply': ranked});
    Future<Uint8List> show() async {
      final host = _PageHost([
        {'type': 'close'},
      ]);
      await reducing(host, share: share).show(
        source: const SplatViewerSource.share('nas', '/scan/point_cloud.ply'),
        head: _head(share.files['/scan/point_cloud.ply']!),
        fileBytes: ranked.length,
        cap: 10,
        look: look,
      );
      return host.scene!;
    }

    final first = await show();
    share.files['/scan/point_cloud.ply'] = moved(ranked, 2);
    expect(await show(), isNot(first));
    // Its date alone tells another version too, where the share gives one
    share.dates['/scan/point_cloud.ply'] = DateTime(2026, 11, 2, 20);
    final third = await show();
    final names = Directory('${folder.path}/cache').listSync().map((entry) => entry.path.split('/').last).toSet();
    expect(names, hasLength(3));
    expect(await show(), third);
  });

  test('the fingerprint reads the ends and a few places between, and tells any of them apart', () async {
    final bytes = Uint8List.fromList(List.generate(3 << 20, (i) => (i * 7919) & 0xff));
    final reads = <(int, int)>[];
    Future<List<int>> read(int offset, int length) async {
      reads.add((offset, length));
      return Uint8List.sublistView(bytes, offset, offset + length);
    }

    final whole = await splatFingerprint(read, bytes.length);
    expect(reads.first, (0, 64 << 10));
    expect(reads.last, (bytes.length - (64 << 10), 64 << 10));
    expect(reads.fold<int>(0, (sum, read) => sum + read.$2), lessThan(256 << 10));
    for (final (offset, _) in reads) {
      final changed = Uint8List.fromList(bytes)..[offset] ^= 1;
      expect(
        await splatFingerprint((o, l) async => Uint8List.sublistView(changed, o, o + l), bytes.length),
        isNot(whole),
      );
    }
    // A small file is read whole
    reads.clear();
    await splatFingerprint(read, 1000);
    expect(reads, [(0, 1000)]);
  });

  test('not enough free space for the copy and the reduction: said before anything is copied', () async {
    final share = _Share({'/ranked.ply': ranked});
    Directory? asked;
    final host = _PageHost(const []);
    final outcome =
        await reducing(
          host,
          share: share,
          freeBytes: (folder) async {
            asked = folder;
            return ranked.length;
          },
        ).show(
          source: const SplatViewerSource.share('nas', '/ranked.ply'),
          head: _head(ranked),
          fileBytes: ranked.length,
          cap: 10,
          look: look,
        );
    expect(outcome.end, SplatViewerEnd.noSpace);
    expect(asked!.path, '${folder.path}/cache');
    expect(host.opened, isNull);
    // The fingerprint only: nothing copied
    expect(share.bytesRead, ranked.length);
    expect(Directory('${folder.path}/cache').listSync(), isEmpty);
    // With the room it needs, it opens
    final roomy = _PageHost([
      {'type': 'close'},
    ]);
    final opened = await reducing(roomy, share: share, freeBytes: (folder) async => 1 << 30).show(
      source: const SplatViewerSource.share('nas', '/ranked.ply'),
      head: _head(ranked),
      fileBytes: ranked.length,
      cap: 10,
      look: look,
    );
    expect(opened.end, SplatViewerEnd.closed);
  });

  test('the space a preparation needs: the copy of a share, and the reduced file at most', () {
    const ply = SplatHead(format: SplatFormat.ply, formatVersion: 1, gaussians: 4000000, shDegree: 3);
    // 248 bytes a row: a quarter of the rows
    expect(splatPrepareBytes(ply, fileBytes: 992002000, cap: 1000000, copied: false), 248000500 + (1 << 20));
    expect(splatPrepareBytes(ply, fileBytes: 992002000, cap: 1000000, copied: true), 992002000 + 248000500 + (1 << 20));
    const spz = SplatHead(format: SplatFormat.spz, formatVersion: 3, gaussians: 4000000, shDegree: 3);
    // Version 2 as the reduction writes it, uncompressed at most: 64 bytes a gaussian of degree 3
    expect(splatPrepareBytes(spz, fileBytes: 150000000, cap: 1000000, copied: false), 64000016 + (1 << 20));
  });

  test('a cancel that comes once the splat is ready still opens nothing', () async {
    final file = File('${folder.path}/ranked.ply')..writeAsBytesSync(ranked);
    final cancel = SplatPrepareCancel();
    final host = _PageHost(const []);
    final outcome = await reducing(host).show(
      source: SplatViewerSource.local(file.path),
      head: _head(ranked),
      fileBytes: ranked.length,
      cap: 10,
      look: look,
      cancel: cancel,
      progress: (step, done) {
        if (step == SplatPrepareStep.reduce && done >= 1) {
          cancel.cancel();
        }
      },
    );
    expect(outcome.end, SplatViewerEnd.cancelled);
    expect(host.opened, isNull);
  });

  test('the session gives the page the pixel ratio of the device class: 2 on computers', () async {
    final file = File('${folder.path}/axes.spz')..writeAsBytesSync(axes);
    final host = _PageHost([
      {'type': 'close'},
    ]);
    await service(host).show(
      source: SplatViewerSource.local(file.path),
      head: _head(axes),
      fileBytes: axes.length,
      cap: 1000000,
      look: SplatViewerLook(
        texts: look.texts,
        locale: 'en',
        dark: false,
        primary: '#4250af',
        device: 'computer',
        gyroscope: false,
        maxStdDev: 2.828,
        pixelRatioMax: 2,
      ),
    );
    expect(host.session!['limits'], {'pixelRatioMax': 2, 'maxStdDev': 2.828});
  });

  test('a page that never said ready is told apart from one that did, once its window closed', () async {
    final file = File('${folder.path}/axes.spz')..writeAsBytesSync(axes);
    Future<SplatViewerOutcome> open(List<Map<String, Object?>> script) =>
        SplatViewerService(
          bridge: bridge,
          host: _PageHost(script),
          loadPage: () async => page,
          uprights: uprights,
          cache: cache,
          fileSystem: (sourceId) => throw UnimplementedError(),
          shareUrl: (sourceId, path) => throw UnimplementedError(),
          noPictureAfter: Duration.zero,
        ).show(
          source: SplatViewerSource.local(file.path),
          head: _head(axes),
          fileBytes: axes.length,
          cap: 1000000,
          look: look,
        );
    final blank = await open([
      {'type': 'close'},
    ]);
    expect(blank.end, SplatViewerEnd.closed);
    expect(blank.noPicture, isTrue);
    final shown = await open([
      {'type': 'ready', 'loadMs': 90, 'gaussians': 686},
      {'type': 'close'},
    ]);
    expect(shown.noPicture, isFalse);
  });

  test('cancelled while preparing: nothing opens, nothing kept', () async {
    final file = File('${folder.path}/ranked.ply')..writeAsBytesSync(ranked);
    final cancel = SplatPrepareCancel()..cancel();
    final host = _PageHost(const []);
    final outcome =
        await SplatViewerService(
          bridge: bridge,
          host: host,
          loadPage: () async => page,
          uprights: uprights,
          cache: cache,
          fileSystem: (sourceId) => throw UnimplementedError(),
          shareUrl: (sourceId, path) => throw UnimplementedError(),
          reduce: reduceForTest,
        ).show(
          source: SplatViewerSource.local(file.path),
          head: _head(ranked),
          fileBytes: ranked.length,
          cap: 10,
          look: look,
          cancel: cancel,
        );
    expect(outcome.end, SplatViewerEnd.cancelled);
    expect(host.opened, isNull);
  });

  test('the endings: a web view that cannot, a renderer gone, no web view', () async {
    final file = File('${folder.path}/axes.spz')..writeAsBytesSync(axes);
    Future<SplatViewerOutcome> open(_PageHost host) => service(host).show(
      source: SplatViewerSource.local(file.path),
      head: _head(axes),
      fileBytes: axes.length,
      cap: 150000,
      look: look,
    );
    final unsupported = _PageHost([
      {'type': 'unsupported', 'reason': 'simd'},
      {'type': 'close'},
    ]);
    final first = await open(unsupported);
    expect(first.end, SplatViewerEnd.unsupported);
    expect(first.unsupported, 'simd');
    final gone = _PageHost([
      {'type': 'close'},
    ])..ending = SplatHostClosed.rendererGone;
    expect((await open(gone)).end, SplatViewerEnd.rendererGone);
    final none = _PageHost([
      {'type': 'close'},
    ])..ending = SplatHostClosed.noWebView;
    expect((await open(none)).end, SplatViewerEnd.noWebView);
  });

  test('the store of orientations keeps the last 500 files and only the three orientations', () async {
    await uprights.write('a.spz', 10, 'zUp');
    await uprights.write('a.spz', 10, 'sideways');
    expect(await uprights.read('a.spz', 10), 'zUp');
    final reread = SplatUprightStore(() async => File('${folder.path}/uprights.json'));
    expect(await reread.read('a.spz', 10), 'zUp');
    expect(await reread.read('a.spz', 11), isNull);
    expect(splatUprightKey('a.spz', 10), 'splatUp:10:a.spz');
  });

  test('the cache keeps the three newest reduced copies within its bytes', () async {
    final small = SplatViewerCache(() async => Directory('${folder.path}/cache'), keep: 3, maxBytes: 250);
    final dir = await small.folder();
    for (var i = 0; i < 5; i++) {
      File('${dir.path}/reduced-$i.spz')
        ..writeAsBytesSync(List.filled(100, i))
        ..setLastModifiedSync(DateTime(2026, 1, 1, i));
    }
    File('${dir.path}/copy-x.spz')
      ..writeAsBytesSync([1])
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
    File('${dir.path}/reduced-old.ply.part')
      ..writeAsBytesSync([1])
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
    // Another viewing's copy and reduction in progress (review of 2 November 2026: prune deleted them)
    File('${dir.path}/copy-y.spz').writeAsBytesSync([1]);
    File('${dir.path}/reduced-z.ply.part').writeAsBytesSync([1]);
    await small.prune();
    final left = dir.listSync().map((entry) => entry.path.split('/').last).toList()..sort();
    expect(left, ['copy-y.spz', 'reduced-3.spz', 'reduced-4.spz', 'reduced-z.ply.part']);
  });

  test('the reduction runs in an isolate of its own, with its progress; a cancel ends it and leaves nothing', () async {
    final source = File('${folder.path}/ranked.ply')..writeAsBytesSync(ranked);
    final out = File('${folder.path}/reduced.ply');
    final seen = <double>[];
    final kept = await reduceSplatInIsolate(
      source: source,
      head: _head(ranked),
      keep: 10,
      out: out,
      progress: seen.add,
    );
    expect(kept, 10);
    expect(_head(out.readAsBytesSync()).gaussians, 10);
    expect(seen.last, 1);
    final cancel = SplatPrepareCancel();
    final cancelled = File('${folder.path}/cancelled.ply');
    final running = reduceSplatInIsolate(source: source, head: _head(ranked), keep: 10, out: cancelled, cancel: cancel);
    cancel.cancel();
    await expectLater(running, throwsA(isA<SplatReduceCancelled>()));
    expect(cancelled.existsSync(), isFalse);
    expect(File('${cancelled.path}.part').existsSync(), isFalse);
  });

  test('a copy from a share is cut by a cancel and leaves nothing', () async {
    final out = File('${folder.path}/copy.ply');
    final cancel = SplatPrepareCancel();
    var reads = 0;
    await expectLater(
      copySplatFromShare(
        readRange: (offset, length) async {
          reads++;
          cancel.cancel();
          return Uint8List(length);
        },
        length: 100,
        out: out,
        chunk: 10,
        cancel: cancel,
      ),
      throwsA(isA<SplatReduceCancelled>()),
    );
    expect(reads, 1);
    expect(out.existsSync(), isFalse);
  });
}

/// The reduction of the app, in this isolate (the tests run where the isolate of the app's would not see the files)
Future<int> reduceForTest({
  required File source,
  required SplatHead head,
  required int keep,
  required File out,
  void Function(double done)? progress,
  SplatPrepareCancel? cancel,
}) {
  if (cancel?.isCancelled ?? false) {
    throw const SplatReduceCancelled();
  }
  return reduceSplatFile(source: source, head: head, keep: keep, out: out, progress: progress);
}
