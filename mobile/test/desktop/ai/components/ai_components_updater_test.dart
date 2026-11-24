// The update of the AI components (issue 21) with a downloader of the tests: Update all brings the installed components
// up to date and nothing else, asks first above the size limit or on a metered connection, pauses and resumes from
// the bytes received, stops on a cut connection with the installed versions in place, goes on after one damaged file,
// waits for the conversions, checks the drive before the first byte; and the automatic update starts by itself only
// when the setting, the connection and the size allow it. The service runs on real files.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_updater.dart';
import 'package:path/path.dart' as p;

Uint8List _bytes(int length, int seed) => Uint8List.fromList(List.generate(length, (index) => (index * seed) % 251));

AiComponent _model(String id, String version, List<int> bytes) => AiComponent(
  id: id,
  version: version,
  kind: AiComponentKind.model,
  platforms: const {AiPlatform.linuxX64, AiPlatform.windowsX64, AiPlatform.macosArm64},
  assetName: '$id-$version.onnx',
  installPath: 'models/$id/$id.onnx',
  size: bytes.length,
  sha256: sha256.convert(bytes).toString(),
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: 'https://example.org/licence',
);

/// A downloader of the tests: the bytes of each asset in memory, written half then whole through the .part, held
/// in the middle while [hold] is set, a failure given per asset; the sum is checked as the real one does
class _FakeDownloader extends AiComponentDownloader {
  _FakeDownloader(this.files);

  final Map<String, List<int>> files;
  final failures = <String, AiDownloadFailure>{};
  Completer<void>? hold;

  /// Completed once a download is held in the middle
  Completer<void> reached = Completer<void>();

  /// The ids asked, and the bytes each found in its .part when it started
  final asked = <String>[];
  final resumedFrom = <String, int>{};

  @override
  Future<Uri> download(
    AiComponent component, {
    required File target,
    required File part,
    AiDownloadCancel? cancel,
    void Function(int received, int? total)? onProgress,
  }) async {
    asked.add(component.id);
    final failure = failures[component.assetName];
    if (failure != null) {
      throw AiDownloadException(failure, 'the test says so');
    }
    final bytes = files[component.assetName]!;
    await part.parent.create(recursive: true);
    final already = part.existsSync() ? part.lengthSync() : 0;
    resumedFrom[component.id] = already;
    final half = bytes.length ~/ 2;
    if (already < half) {
      await part.writeAsBytes(bytes.sublist(already, half), mode: FileMode.append);
    }
    onProgress?.call(half, bytes.length);
    final held = hold;
    if (held != null) {
      if (!reached.isCompleted) {
        reached.complete();
      }
      await Future.any([held.future, if (cancel != null) cancel.whenCancelled]);
    }
    if (cancel?.isCancelled ?? false) {
      throw const AiDownloadException(AiDownloadFailure.cancelled);
    }
    final start = max(already, half);
    await part.writeAsBytes(bytes.sublist(start), mode: FileMode.append);
    onProgress?.call(bytes.length, bytes.length);
    if (sha256.convert(part.readAsBytesSync()).toString() != component.sha256) {
      part.deleteSync();
      throw const AiDownloadException(AiDownloadFailure.damaged, 'another sum');
    }
    await target.parent.create(recursive: true);
    await part.rename(target.path);
    return Uri.parse('https://example.org/${component.assetName}');
  }
}

void main() {
  late Directory temp;
  late Directory root;

  final depthOld = _bytes(30000, 3);
  final depthNew = _bytes(32000, 5);
  final fillOld = _bytes(20000, 7);
  final fillNew = _bytes(21000, 11);
  final otherNew = _bytes(5000, 13);

  final depth1 = _model('depth', '1', depthOld);
  final depth2 = _model('depth', '2', depthNew);
  final fill1 = _model('fill', '1', fillOld);
  final fill2 = _model('fill', '2', fillNew);
  // In the catalogue, never installed: never downloaded by an update
  final other = _model('other', '1', otherNew);

  late _FakeDownloader downloader;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('ai-components-updater');
    root = Directory(p.join(temp.path, 'ai-components'));
    downloader = _FakeDownloader({
      depth1.assetName: depthOld,
      depth2.assetName: depthNew,
      fill1.assetName: fillOld,
      fill2.assetName: fillNew,
      other.assetName: otherNew,
    });
    // What an earlier version of the app installed
    final earlier = AiComponentsService(folder: () async => root, downloader: downloader, catalogue: [depth1, fill1]);
    await earlier.install(depth1);
    await earlier.install(fill1);
    downloader.asked.clear();
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may hold a file a moment longer
    }
  });

  File at(AiComponent component) => File(p.joinAll([root.path, ...component.installPath.split('/')]));

  AiComponentsService service({bool Function()? inUse, AiFreeSpaceReader? freeSpace}) => AiComponentsService(
    folder: () async => root,
    downloader: downloader,
    catalogue: [depth2, fill2, other],
    inUse: inUse,
    freeSpace: freeSpace,
  );

  AiComponentsUpdater updater(
    AiComponentsService components, {
    bool? metered = false,
    int confirmAbove = aiUpdateConfirmBytes,
    void Function()? before,
  }) => AiComponentsUpdater(
    service: components,
    platform: AiPlatform.linuxX64,
    metered: () async => metered,
    confirmAbove: confirmAbove,
    beforeUpdate: () async => before?.call(),
  );

  test('the updates found: the installed components only, with what they download', () async {
    final updates = updater(service());
    await updates.refresh();

    expect(updates.updates.map((update) => update.component.id), ['depth', 'fill']);
    expect(updates.updateBytes, depthNew.length + fillNew.length);
    expect(updates.updates.map((update) => update.installedVersion), ['1', '1']);
  });

  test('Update all brings them up to date, one after the other, and downloads nothing else', () async {
    final components = service();
    var released = 0;
    final updates = updater(components, before: () => released++);
    final progress = <int>[];
    updates.addListener(() => progress.add(updates.receivedBytes));

    expect(await updates.updateAll(), AiUpdateOutcome.updated);

    expect(downloader.asked, ['depth', 'fill']);
    expect(at(depth2).readAsBytesSync(), depthNew);
    expect(at(fill2).readAsBytesSync(), fillNew);
    expect(components.statusOf(depth2).state, AiComponentState.installed);
    expect(components.statusOf(other).state, AiComponentState.notInstalled);
    expect(updates.phase, AiUpdatePhase.done);
    expect(updates.updates, isEmpty);
    expect(updates.totalBytes, depthNew.length + fillNew.length);
    expect(progress.last, updates.totalBytes);
    expect(released, 1);
    final entries = jsonDecode(File(p.join(root.path, 'installed.json')).readAsStringSync())['components'] as Map;
    expect(entries.keys, unorderedEquals(['depth', 'fill']));
    expect((entries['depth'] as Map)['version'], '2');
  });

  test('one component alone', () async {
    final components = service();
    final updates = updater(components);

    expect(await updates.update(fill2), AiUpdateOutcome.updated);

    expect(downloader.asked, ['fill']);
    expect(components.statusOf(depth2).state, AiComponentState.outdated);
    expect(updates.updates.map((update) => update.component.id), ['depth']);
  });

  test('above the size limit it asks first and downloads nothing until confirmed', () async {
    final updates = updater(service(), confirmAbove: 1000);

    expect(await updates.updateAll(), AiUpdateOutcome.needsConfirmation);
    expect(downloader.asked, isEmpty);
    final ask = await updates.askFor(updates.updateBytes);
    expect(ask?.bytes, depthNew.length + fillNew.length);
    expect(ask?.metered, isFalse);

    expect(await updates.updateAll(confirmed: true), AiUpdateOutcome.updated);
    expect(downloader.asked, ['depth', 'fill']);
  });

  test('on a metered connection it asks first, whatever the size', () async {
    final updates = updater(service(), metered: true);

    expect(await updates.updateAll(), AiUpdateOutcome.needsConfirmation);
    expect((await updates.askFor(10))?.metered, isTrue);
    expect(downloader.asked, isEmpty);
  });

  group('the automatic update', () {
    test('starts by itself when on, below the limit, on a connection that is not metered', () async {
      final updates = updater(service());

      expect(await updates.automatic(enabled: true), AiUpdateOutcome.updated);
      expect(downloader.asked, ['depth', 'fill']);
    });

    test('never when off, on a metered connection, or above the limit: the notice stays', () async {
      final off = updater(service());
      expect(await off.automatic(enabled: false), AiUpdateOutcome.notStarted);
      expect(off.updates, hasLength(2));
      expect(await updater(service(), metered: true).automatic(enabled: true), AiUpdateOutcome.notStarted);
      expect(await updater(service(), confirmAbove: 1000).automatic(enabled: true), AiUpdateOutcome.notStarted);
      expect(downloader.asked, isEmpty);
    });

    test('a connection the system does not tell about is not taken as metered', () async {
      final updates = updater(service(), metered: null);

      expect(await updates.automatic(enabled: true), AiUpdateOutcome.updated);
    });

    test('nothing to update says so', () async {
      final updates = updater(service());
      await updates.updateAll();

      expect(await updates.automatic(enabled: true), AiUpdateOutcome.nothing);
    });
  });

  test('Pause keeps the bytes received and the installed version; Resume goes on from them', () async {
    final components = service();
    final updates = updater(components);
    downloader.hold = Completer<void>();

    final run = updates.updateAll();
    await downloader.reached.future;
    expect(updates.phase, AiUpdatePhase.running);
    expect(updates.current?.id, 'depth');
    expect(updates.receivedBytes, depthNew.length ~/ 2);
    updates.pause();

    expect(await run, AiUpdateOutcome.paused);
    expect(updates.phase, AiUpdatePhase.paused);
    expect(at(depth2).readAsBytesSync(), depthOld);
    expect(components.statusOf(depth2).state, AiComponentState.outdated);
    expect(File(p.join(root.path, 'tmp', '${depth2.assetName}.part')).lengthSync(), depthNew.length ~/ 2);
    expect(downloader.asked, ['depth']);

    downloader.hold = null;
    expect(await updates.resume(), AiUpdateOutcome.updated);
    expect(downloader.resumedFrom['depth'], depthNew.length ~/ 2);
    expect(at(depth2).readAsBytesSync(), depthNew);
    expect(at(fill2).readAsBytesSync(), fillNew);
    expect(updates.phase, AiUpdatePhase.done);
  });

  test('without a connection it stops, the installed versions in place, and says so', () async {
    downloader.failures[depth2.assetName] = AiDownloadFailure.network;
    final components = service();
    final updates = updater(components);

    expect(await updates.updateAll(), AiUpdateOutcome.offline);

    expect(downloader.asked, ['depth']);
    expect(updates.phase, AiUpdatePhase.failed);
    expect(updates.failure?.failure, AiDownloadFailure.network);
    expect(at(depth2).readAsBytesSync(), depthOld);
    expect(at(fill2).readAsBytesSync(), fillOld);
    expect(updates.updates, hasLength(2));
  });

  test('a damaged download keeps its older version and the others go on', () async {
    // The bytes served are not those of the catalogue
    downloader.files[depth2.assetName] = _bytes(depthNew.length, 17);
    final components = service();
    final updates = updater(components);

    expect(await updates.updateAll(), AiUpdateOutcome.failed);

    expect(updates.failed.map((component) => component.id), ['depth']);
    expect(updates.failure?.failure, AiDownloadFailure.damaged);
    expect(at(depth2).readAsBytesSync(), depthOld);
    expect(components.statusOf(depth2).state, AiComponentState.outdated);
    expect(at(fill2).readAsBytesSync(), fillNew);
    expect(updates.updates.map((update) => update.component.id), ['depth']);
  });

  test('waits for the conversions: nothing downloaded while one runs', () async {
    final updates = updater(service(inUse: () => true));

    expect(await updates.updateAll(), AiUpdateOutcome.busy);
    expect(downloader.asked, isEmpty);
  });

  test('a drive without the space refuses before the first byte', () async {
    final components = service(freeSpace: (_) async => const AiFreeSpace(free: 1000, volume: '/data'));
    final updates = updater(components);

    expect(await updates.updateAll(), AiUpdateOutcome.notEnoughSpace);
    expect(updates.failure?.shortage?.volume, '/data');
    expect(downloader.asked, isEmpty);
    expect(at(depth2).readAsBytesSync(), depthOld);
  });

  test('what no component needs any more: found and removed through the updater', () async {
    final leftover = File(p.join(root.path, 'engines', 'old-engine.new', 'run'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(List.filled(64, 1));
    final updates = updater(service());
    await updates.refresh();
    expect(updates.unused.bytes, 64);

    expect(await updates.removeUnused(), AiRemoveOutcome.removed);
    expect(leftover.existsSync(), isFalse);
    expect(updates.unused.isEmpty, isTrue);
  });
}
