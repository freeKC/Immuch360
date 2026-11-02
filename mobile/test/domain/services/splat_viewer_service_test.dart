// One viewing of the splat viewer (lots SV1 and SV4), with a fake host that does what the page does over real HTTP on
// the real media bridge: it reads session.json and the scene, posts ready, an orientation and close. The scene of a
// file of this device, of a share, and of a splat above the cap (copied from its share, reduced, kept); the endings.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
  final _closed = StreamController<SplatHostClosed>.broadcast();
  Map<String, Object?>? session;
  Uint8List? scene;
  Uri? opened;
  String? title;
  int closes = 0;
  SplatHostClosed ending = SplatHostClosed.user;

  @override
  Stream<SplatHostClosed> get closed => _closed.stream;

  @override
  Future<void> open(Uri pageUrl, {required String title}) async {
    opened = pageUrl;
    this.title = title;
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
  }

  @override
  Future<void> close() async {
    closes++;
    _closed.add(ending);
  }
}

class _Share implements NetworkFileSystem {
  _Share(this.files);

  final Map<String, Uint8List> files;
  int reads = 0;

  @override
  NetworkSource get source => const NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'NAS', host: 'nas');

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    reads++;
    final bytes = files[path]!;
    return Uint8List.sublistView(bytes, offset, offset + length);
  }

  @override
  Future<NetworkEntry> stat(String path) async =>
      NetworkEntry(sourceId: 'nas', path: path, isDirectory: false, size: files[path]!.length);

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
    // The second time: the copy kept, the share not read again
    steps.clear();
    final again = _PageHost([
      {'type': 'close'},
    ]);
    await open(again);
    expect(steps, isEmpty);
    expect(share.reads, reads);
    expect(again.scene, host.scene);
    final names = Directory('${folder.path}/cache').listSync().map((entry) => entry.path.split('/').last).toList();
    expect(names, hasLength(1));
    expect(names.single, startsWith('reduced-'));
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
    File('${dir.path}/copy-x.spz').writeAsBytesSync([1]);
    await small.prune();
    final left = dir.listSync().map((entry) => entry.path.split('/').last).toList()..sort();
    expect(left, ['reduced-3.spz', 'reduced-4.spz']);
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
