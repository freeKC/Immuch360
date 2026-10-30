// The versions of the photos of a share put next to their originals: made on this computer in a folder of the copies
// of the AI, then written on the share by its writer under their name or the first free "name (n)", and gone from this
// computer; kept in the folder of my choice with the words of the share when it refuses them; kept where they were made,
// with that path, when the folder of my choice refuses them too, then written by Retry; not written when the batch
// skips a name taken; a panorama kept here until its 3D version is made from it; nothing written for a job that
// failed, its folder kept for Retry; the pages of the share told that its folder changed.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/share_publisher.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/network/share_writer.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_conversion_engines.dart';
import '../fakes/fake_conversion_output.dart';
import '../fakes/fake_immersive_engine.dart';
import '../fakes/fake_panorama_engine.dart';
import '../fakes/fake_share_writer.dart';
import '../fakes/fake_stereo_panorama_engine.dart';

const _folder = ShareFolder(
  sourceId: 'nas',
  path: '/2024',
  label: r'\\nas\photos\2024',
  rootKey: 'net-//nas/photos:/',
  rootLabel: r'\\nas\photos',
);

void main() {
  late Directory root;
  late String chosen;
  late File original;
  late FakeShareWriter share;
  late ProviderContainer container;
  late FakeConversionOutput output;

  setUp(() {
    root = Directory.systemTemp.createTempSync('share_publisher');
    chosen = p.join(root.path, 'Downloads', 'Immuch360');
    original = File(p.join(root.path, 'copy', 'salon.jpg'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.generate(400, (i) => i & 0xff));
    share = FakeShareWriter();
    output = FakeConversionOutput();
    container = ProviderContainer(
      overrides: [
        conversionToolsProvider.overrideWith(
          (ref) => ConversionTools(
            engine: FakeImmersiveEngine(),
            engines: fakeConversionEngines(panorama: FakePanoramaEngine(), stereoPanorama: FakeStereoPanoramaEngine()),
            output: output,
            finder: ExistingVersionFinder(),
            creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
          ),
        ),
        shareWriterOpenerProvider.overrideWithValue((sourceId) async {
          share.opened++;
          return sourceId == 'nas' ? share : null;
        }),
      ],
    );
    // The publisher follows the queue from the start
    container.read(sharePublisherProvider);
  });

  tearDown(() {
    container.dispose();
    root.deleteSync(recursive: true);
  });

  /// A folder of its own for the version of a photo, among the copies of the AI
  String staging(String name) => (Directory(p.join(root.path, 'immuch360-ai', name))..createSync(recursive: true)).path;

  /// Completes once [test] holds for the versions followed
  Future<void> until(bool Function(Map<String, SharePublish> state) test) async {
    if (test(container.read(sharePublisherProvider))) {
      return;
    }
    final reached = Completer<void>();
    final subscription = container.listen(sharePublisherProvider, (_, next) {
      if (!reached.isCompleted && test(next)) {
        reached.complete();
      }
    });
    try {
      await reached.future.timeout(const Duration(seconds: 10));
    } finally {
      subscription.close();
    }
  }

  /// Completes once [test] holds for the queue
  Future<void> untilQueue(bool Function(ConversionQueueState state) test) async {
    if (test(container.read(conversionQueueProvider))) {
      return;
    }
    final reached = Completer<void>();
    final subscription = container.listen(conversionQueueProvider, (_, next) {
      if (!reached.isCompleted && test(next)) {
        reached.complete();
      }
    });
    try {
      await reached.future.timeout(const Duration(seconds: 10));
    } finally {
      subscription.close();
    }
  }

  List<String> add(
    String folder, {
    ConversionKind kind = ConversionKind.sbsFromPhoto,
    bool alsoStereo = false,
    bool skipWhenTaken = false,
    String? fallback,
  }) {
    final ids = container
        .read(conversionQueueProvider.notifier)
        .add(
          [
            ConversionRequest(
              source: LocalFileSource(original.path),
              target: ConversionTarget.inFolder(folder, 'salon.jpg', kind: kind),
            ),
          ],
          kind: kind,
          alsoStereo: alsoStereo,
        );
    container.read(sharePublisherProvider.notifier).follow({
      for (final id in ids)
        id: ShareVersionTarget(folder: _folder, fallbackFolder: fallback ?? chosen, skipWhenTaken: skipWhenTaken),
    });
    return ids;
  }

  bool ended(Map<String, SharePublish> state, String id) => state[id]?.state.isEnded ?? false;

  test('made here, then written next to its original on the share under its name, and gone from here', () async {
    final folder = staging('share-out-1');
    final changes = <Map<String, int>>[];
    container.listen(shareFolderChangesProvider, (_, next) => changes.add(next));

    final id = add(folder).single;
    await until((state) => ended(state, id));

    final publish = container.read(sharePublisherProvider)[id]!;
    expect(publish.state, SharePublishState.saved);
    expect(publish.path, '/2024/salon_3D_LRF_Full_SBS.jpg');
    expect(publish.shown, r'\\nas\photos\2024\salon_3D_LRF_Full_SBS.jpg');
    expect(share.files.keys, ['/2024/salon_3D_LRF_Full_SBS.jpg']);
    expect(share.files.values.single.take(2), [0xff, 0xd8], reason: 'the JPEG the engine wrote');
    expect(share.calls.first, startsWith('upload /2024/.salon_3D_LRF_Full_SBS.jpg.'));
    expect(Directory(folder).existsSync(), isFalse, reason: 'nothing of it stays on this computer');
    expect(share.closed, share.opened);
    expect(changes.last, {'nas:/2024': 1}, reason: 'the pages of the share read its folder again');
  });

  test('a name taken on the share: the first free "name (n)", the file there untouched', () async {
    share.files['/2024/salon_3D_LRF_Full_SBS.jpg'] = Uint8List(3);

    final id = add(staging('share-out-1')).single;
    await until((state) => ended(state, id));

    expect(container.read(sharePublisherProvider)[id]!.path, '/2024/salon_3D_LRF_Full_SBS (1).jpg');
    expect(share.files['/2024/salon_3D_LRF_Full_SBS.jpg'], Uint8List(3));
  });

  test('a name taken that the batch skips: nothing written, and said', () async {
    share.files['/2024/salon_3D_LRF_Full_SBS.jpg'] = Uint8List(3);
    final folder = staging('share-out-1');

    final id = add(folder, skipWhenTaken: true).single;
    await until((state) => ended(state, id));

    expect(container.read(sharePublisherProvider)[id]!.state, SharePublishState.skipped);
    expect(share.files.keys, ['/2024/salon_3D_LRF_Full_SBS.jpg']);
    expect(Directory(folder).existsSync(), isFalse);
  });

  test('the share refuses it: kept in the folder of my choice, with the words of the share', () async {
    share.failUpload = ShareWriteFailure.readOnly;
    final folder = staging('share-out-1');

    final id = add(folder).single;
    await until((state) => ended(state, id));

    final publish = container.read(sharePublisherProvider)[id]!;
    expect(publish.state, SharePublishState.keptHere);
    expect(publish.keptPath, p.join(chosen, 'salon_3D_LRF_Full_SBS.jpg'));
    expect(File(publish.keptPath!).readAsBytesSync().take(2), [0xff, 0xd8]);
    expect(publish.message, 'Access denied');
    expect(publish.failure, ShareWriteFailure.readOnly);
    expect(share.files, isEmpty);
    expect(Directory(folder).existsSync(), isFalse);
  });

  test('the share and the folder of my choice both refuse it: kept where it was made, said with its path', () async {
    share.failUpload = ShareWriteFailure.readOnly;
    final folder = staging('share-out-1');
    // The folder of my choice under a file: a drive unplugged, a folder on the same NAS that just dropped
    final blocker = File(p.join(root.path, 'blocker'))..writeAsStringSync('in the way');
    final fallback = p.join(blocker.path, 'Immuch360');

    final id = add(folder, fallback: fallback).single;
    await until((state) => ended(state, id));

    final publish = container.read(sharePublisherProvider)[id]!;
    expect(publish.state, SharePublishState.notKept);
    expect(publish.state.isOnComputer, isTrue);
    expect(publish.keptPath, p.join(folder, 'salon_3D_LRF_Full_SBS.jpg'));
    expect(File(publish.keptPath!).readAsBytesSync().take(2), [0xff, 0xd8], reason: 'the version is still there');
    expect(publish.shown, isNull, reason: 'never named as a file of the share');
    expect((publish.failure, publish.message), (ShareWriteFailure.readOnly, 'Access denied'));
    expect(share.files, isEmpty);

    // Clear finished never deletes it while the app runs
    container.read(conversionQueueProvider.notifier).clearFinished();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(File(publish.keptPath!).existsSync(), isTrue);
  });

  test('Retry of a version kept where it was made: on the share once it takes it, and gone from here', () async {
    share.failUpload = ShareWriteFailure.diskFull;
    final folder = staging('share-out-1');
    final blocker = File(p.join(root.path, 'blocker'))..writeAsStringSync('in the way');

    final id = add(folder, fallback: p.join(blocker.path, 'Immuch360')).single;
    await until((state) => ended(state, id));
    expect(container.read(sharePublisherProvider)[id]!.state, SharePublishState.notKept);

    share.failUpload = null;
    container.read(sharePublisherProvider.notifier).retry(id);
    await until((state) => state[id]?.state == SharePublishState.saved);

    final publish = container.read(sharePublisherProvider)[id]!;
    expect(publish.path, '/2024/salon_3D_LRF_Full_SBS.jpg');
    expect(publish.keptPath, isNull);
    expect(share.files.keys, ['/2024/salon_3D_LRF_Full_SBS.jpg']);
    expect(Directory(folder).existsSync(), isFalse, reason: 'nothing of it stays on this computer');
  });

  test('a panorama stays here until its 3D version is made from it, then both are on the share', () async {
    final folder = staging('share-out-1');

    final ids = add(folder, kind: ConversionKind.panoramaFromPhoto, alsoStereo: true);
    expect(ids, hasLength(2));
    await until((state) => ids.every((id) => ended(state, id)));

    final queue = container.read(conversionQueueProvider);
    expect(queue.jobs.map((job) => job.state), [ConversionState.done, ConversionState.done]);
    expect(share.files.keys.toSet(), {'/2024/salon_360.jpg', '/2024/salon_360_3D.jpg'});
    expect(Directory(folder).existsSync(), isFalse);
  });

  test('a job that fails writes nothing on the share, and keeps its folder for Retry', () async {
    final folder = staging('share-out-1');
    output.failFinish = ImmersiveErrorCode.writeFailed;

    final id = add(folder).single;
    await untilQueue((state) => state.byId(id)!.state.isEnded);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(conversionQueueProvider).byId(id)!.state, ConversionState.failed);
    expect(container.read(sharePublisherProvider)[id]!.state, SharePublishState.waiting);
    expect(share.calls, isEmpty);
    expect(Directory(folder).existsSync(), isTrue);

    output.failFinish = null;
    container.read(conversionQueueProvider.notifier).retry(id);
    await until((state) => ended(state, id));
    expect(share.files.keys, ['/2024/salon_3D_LRF_Full_SBS.jpg']);
  });
}
