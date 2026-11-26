// The updates of the AI components (issue 21) on real files, through a local mirror folder: an older version found at
// load (same id with another sum, or an older id the catalogue replaces) stays on the disk and is never handed to an
// engine; its update replaces it once the new file is checked, and a file that is not the one of the catalogue leaves
// the older version as it was (a single file and an archive, whose folder is unpacked beside its place). Then what no
// component needs any more: found with its size, left alone while it waits for its update, removed when asked; and the
// older versions taken along by a removal and by a move. Kept under test/desktop so that the Windows job runs it.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/files/zip_writer.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_enhance_manifest.dart' show sdCppSeedVr2MacArmComponent;
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_archive.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_updater.dart';
import 'package:path/path.dart' as p;

final _r1 = Uint8List.fromList(List.generate(24 * 1024, (index) => (index * 7) % 256));
final _r2 = Uint8List.fromList(List.generate(26 * 1024, (index) => (index * 11) % 256));

/// A model of the tests at [version], its file [bytes], downloaded as test_model_VERSION.onnx
AiComponent _model(
  String version,
  List<int> bytes, {
  String id = 'test-model',
  String installPath = 'models/test-model/test_model.onnx',
  List<String> replaces = const [],
}) => AiComponent(
  id: id,
  version: version,
  kind: AiComponentKind.model,
  platforms: const {AiPlatform.linuxX64, AiPlatform.windowsX64, AiPlatform.macosArm64},
  assetName: 'test_model_$version.onnx',
  installPath: installPath,
  size: bytes.length,
  sha256: sha256.convert(bytes).toString(),
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: 'https://example.org/licence',
  replaces: replaces,
);

/// An engine of the tests at [version]: an archive of [files] (path to bytes), unpacked into engines/test-engine
AiComponent _engine(String version, Uint8List zip, Map<String, List<int>> files) => AiComponent(
  id: 'test-engine',
  version: version,
  kind: AiComponentKind.archive,
  platforms: const {AiPlatform.linuxX64, AiPlatform.windowsX64},
  assetName: 'test-engine-$version.zip',
  installPath: 'engines/test-engine',
  size: zip.length,
  sha256: sha256.convert(zip).toString(),
  compression: AiCompression.none,
  licence: 'MIT',
  licenceUrl: 'https://example.org/licence',
  features: const {AiFeature.panorama},
  archiveFiles: [
    for (final MapEntry(:key, :value) in files.entries)
      AiArchiveFile(path: key, size: value.length, sha256: sha256.convert(value).toString()),
  ],
);

Uint8List _zipOf(Map<String, List<int>> files) => zipFiles([
  for (final MapEntry(:key, :value) in files.entries)
    ZipEntry(name: key, bytes: Uint8List.fromList(value), modified: DateTime.utc(1980)),
]);

void main() {
  late Directory temp;
  late Directory root;
  late Directory mirror;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('ai-components-update');
    root = Directory(p.join(temp.path, 'ai-components'));
    mirror = Directory(p.join(temp.path, 'mirror'))..createSync();
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may hold a file a moment longer
    }
  });

  /// Puts [bytes] in the mirror as the asset of [component]
  void serve(AiComponent component, List<int> bytes) =>
      File(p.join(mirror.path, component.assetName)).writeAsBytesSync(bytes);

  AiComponentsService service(List<AiComponent> catalogue, {bool Function()? inUse, int? release}) =>
      AiComponentsService(
        folder: () async => root,
        downloader: AiComponentDownloader(mirror: () => Uri.directory(mirror.path).toString()),
        catalogue: catalogue,
        inUse: inUse,
        now: () => DateTime.utc(2026, 11, 24, 12),
        catalogueRelease: release ?? aiComponentsCatalogueRelease,
      );

  Map<String, dynamic> installedJson([Directory? folder]) {
    final file = File(p.join((folder ?? root).path, 'installed.json'));
    if (!file.existsSync()) {
      return {'components': <String, dynamic>{}, 'pendingDeletes': <String>[]};
    }
    return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  }

  Map<String, dynamic> entries([Directory? folder]) => installedJson(folder)['components'] as Map<String, dynamic>;

  File at(String path, [Directory? folder]) => File(p.joinAll([(folder ?? root).path, ...path.split('/')]));

  /// Installs [component] as an earlier version of the app would have
  Future<void> installEarlier(AiComponent component, List<int> bytes) async {
    serve(component, bytes);
    await service([component]).install(component);
  }

  final r1 = _model('r1', _r1);
  final r2 = _model('r2', _r2);

  group('the detection, at load', () {
    test('an older version stays on the disk, outdated, and is never handed to an engine', () async {
      await installEarlier(r1, _r1);

      final components = service([r2]);
      await components.load();

      expect(components.statusOf(r2).state, AiComponentState.outdated);
      expect(await components.verifiedFile(r2), isNull);
      expect(at(r2.installPath).readAsBytesSync(), _r1);
      expect((entries()['test-model'] as Map)['version'], 'r1');
      final updates = components.updates();
      expect(updates.map((update) => update.component.id), ['test-model']);
      expect(updates.single.installedVersion, 'r1');
      expect(updates.single.downloadBytes, _r2.length);
      expect(components.installedVersionOf(r2), 'r1');
    });

    test('only what is installed is an update: a component never installed is not, nor one up to date', () async {
      await installEarlier(r1, _r1);
      final other = _model('o1', utf8.encode('another model'), id: 'other-model', installPath: 'models/other/o.onnx');
      final current = _model('c1', utf8.encode('up to date'), id: 'current-model', installPath: 'models/c/c.onnx');
      await installEarlier(current, utf8.encode('up to date'));

      final components = service([r2, other, current]);
      await components.load();

      expect(components.updates().map((update) => update.component.id), ['test-model']);
      expect(components.statusOf(other).state, AiComponentState.notInstalled);
      expect(components.statusOf(current).state, AiComponentState.installed);
    });

    test('the updates of another system are left out', () async {
      await installEarlier(r1, _r1);
      final components = service([r2]);
      await components.load();

      expect(components.updates(platform: AiPlatform.linuxX64), hasLength(1));
      expect(components.updates(platform: AiPlatform.questArm64), isEmpty);
    });

    test('an older version whose file is gone is forgotten: not installed, nothing to update', () async {
      await installEarlier(r1, _r1);
      at(r1.installPath).deleteSync();

      final components = service([r2]);
      await components.load();

      expect(components.statusOf(r2).state, AiComponentState.notInstalled);
      expect(components.updates(), isEmpty);
      expect(entries().containsKey('test-model'), isFalse);
    });

    test('an older id the catalogue replaces makes its component an update', () async {
      final old = _model('1.30.0', _r1, id: 'test-runtime-1.30.0', installPath: 'runtime/test-runtime-1.30.0/lib.so');
      await installEarlier(old, _r1);
      final next = _model(
        '1.31.0',
        _r2,
        id: 'test-runtime-1.31.0',
        installPath: 'runtime/test-runtime-1.31.0/lib.so',
        replaces: ['test-runtime-1.30.0'],
      );

      final components = service([next]);
      await components.load();

      expect(components.statusOf(next).state, AiComponentState.outdated);
      expect(components.updates().single.installedVersion, '1.30.0');
      expect(at(old.installPath).existsSync(), isTrue);
    });

    test('an entry of the catalogue without its sum tells no version: no update, the file stays', () async {
      await installEarlier(r1, _r1);
      final held = AiComponent(
        id: r1.id,
        version: 'r2',
        kind: r1.kind,
        platforms: r1.platforms,
        assetName: r1.assetName,
        installPath: r1.installPath,
        size: null,
        sha256: null,
        compression: r1.compression,
        licence: r1.licence,
        licenceUrl: r1.licenceUrl,
      );

      final components = service([held]);
      await components.load();

      expect(components.statusOf(held).state, isNot(AiComponentState.outdated));
      expect(components.updates(), isEmpty);
      expect(at(r1.installPath).readAsBytesSync(), _r1);
      expect(entries().keys, ['test-model']);
    });
  });

  group('the update', () {
    test('replaces the older file once the new one is checked, with its entry and its licence', () async {
      await installEarlier(r1, _r1);
      serve(r2, _r2);
      final components = service([r2]);
      await components.load();
      final states = <AiComponentState>[];
      components.addListener(() => states.add(components.statusOf(r2).state));

      await components.install(r2);

      expect(at(r2.installPath).readAsBytesSync(), _r2);
      expect(components.statusOf(r2).state, AiComponentState.installed);
      expect(states, contains(AiComponentState.downloading));
      expect((entries()['test-model'] as Map)['version'], 'r2');
      expect(installedJson()['pendingDeletes'], isEmpty);
      expect(at('licenses/test-model.txt').readAsStringSync(), contains('version r2'));
      expect(await components.verifiedFile(r2), isNotNull);
      expect(components.updates(), isEmpty);
      expect(Directory(p.join(root.path, 'tmp')).listSync(), isEmpty);
    });

    test('a file that is not the one of the catalogue leaves the older version as it was', () async {
      await installEarlier(r1, _r1);
      // The mirror serves bytes whose sum is not the one of the catalogue
      serve(r2, Uint8List.fromList(List.generate(_r2.length, (index) => 42)));
      final components = service([r2]);

      await expectLater(
        components.install(r2),
        throwsA(isA<AiDownloadException>().having((error) => error.failure, 'failure', AiDownloadFailure.damaged)),
      );

      expect(at(r2.installPath).readAsBytesSync(), _r1);
      expect((entries()['test-model'] as Map)['version'], 'r1');
      expect(components.statusOf(r2).state, AiComponentState.outdated);
      expect(components.statusOf(r2).failure?.failure, AiDownloadFailure.damaged);
      expect(at('licenses/test-model.txt').readAsStringSync(), contains('version r1'));
      // The bytes received are gone, nothing waits in tmp/
      final tmp = Directory(p.join(root.path, 'tmp'));
      expect(tmp.existsSync() ? tmp.listSync() : const <FileSystemEntity>[], isEmpty);

      // The right file afterwards updates it
      serve(r2, _r2);
      await components.install(r2);
      expect(at(r2.installPath).readAsBytesSync(), _r2);
    });

    test('an older id goes once the new one is installed: its files, its licence, its entry', () async {
      final old = _model('1.30.0', _r1, id: 'test-runtime-1.30.0', installPath: 'runtime/test-runtime-1.30.0/lib.so');
      await installEarlier(old, _r1);
      final next = _model(
        '1.31.0',
        _r2,
        id: 'test-runtime-1.31.0',
        installPath: 'runtime/test-runtime-1.31.0/lib.so',
        replaces: ['test-runtime-1.30.0'],
      );
      serve(next, _r2);
      final components = service([next]);

      await components.install(next);

      expect(at(next.installPath).readAsBytesSync(), _r2);
      expect(Directory(p.join(root.path, 'runtime', 'test-runtime-1.30.0')).existsSync(), isFalse);
      expect(at('licenses/test-runtime-1.30.0.txt').existsSync(), isFalse);
      expect(entries().keys, ['test-runtime-1.31.0']);
      expect(installedJson()['pendingDeletes'], isEmpty);
      expect(components.statusOf(next).state, AiComponentState.installed);
    });

    test('an older version the system holds goes at the next start', () async {
      final old = _model('1.30.0', _r1, id: 'test-runtime-1.30.0', installPath: 'runtime/test-runtime-1.30.0/lib.so');
      await installEarlier(old, _r1);
      final next = _model(
        '1.31.0',
        _r2,
        id: 'test-runtime-1.31.0',
        installPath: 'runtime/test-runtime-1.31.0/lib.so',
        replaces: ['test-runtime-1.30.0'],
      );
      serve(next, _r2);
      // A loaded DLL on Windows: its deletion is refused
      final components = AiComponentsService(
        folder: () async => root,
        downloader: AiComponentDownloader(mirror: () => Uri.directory(mirror.path).toString()),
        catalogue: [next],
        delete: (entity) async {
          if (entity.path.contains('test-runtime-1.30.0${p.separator}')) {
            throw FileSystemException('in use', entity.path);
          }
          await (entity is Link ? entity.delete() : entity.delete(recursive: true));
        },
      );

      await components.install(next);

      expect(components.statusOf(next).state, AiComponentState.installed);
      expect(installedJson()['pendingDeletes'], ['runtime/test-runtime-1.30.0/lib.so']);
      expect(entries().keys, ['test-runtime-1.31.0']);

      AiComponentsService.resetStartPassForTests();
      await AiComponentsService.freePendingAtStart(() async => root);
      AiComponentsService.resetStartPassForTests();
      expect(at(old.installPath).existsSync(), isFalse);
      expect(installedJson()['pendingDeletes'], isEmpty);
    });

    test('an archive keeps its older folder until the new one is unpacked and every file checked', () async {
      final v1Files = {'run': utf8.encode('program one ' * 40), 'lib/a.so': utf8.encode('library one ' * 30)};
      final v1 = _engine('1', _zipOf(v1Files), v1Files);
      await installEarlier(v1, _zipOf(v1Files));
      final v2Files = {'run': utf8.encode('program two ' * 40), 'lib/a.so': utf8.encode('library two ' * 30)};
      final v2Zip = _zipOf(v2Files);
      // The catalogue of v2 names another library than the one its archive holds: the unpacking refuses it
      final wrong = _engine('2', v2Zip, {...v2Files, 'lib/a.so': utf8.encode('the library of the catalogue ' * 9)});
      serve(wrong, v2Zip);
      final components = service([wrong]);

      await expectLater(components.install(wrong), throwsA(isA<AiDownloadException>()));

      expect(at('engines/test-engine/run').readAsBytesSync(), v1Files['run']);
      expect(Directory(p.join(root.path, 'engines', 'test-engine.new')).existsSync(), isFalse);
      expect(components.statusOf(wrong).state, AiComponentState.outdated);

      final v2 = _engine('2', v2Zip, v2Files);
      serve(v2, v2Zip);
      final fixed = service([v2]);
      await fixed.install(v2);
      expect(at('engines/test-engine/run').readAsBytesSync(), v2Files['run']);
      expect(fixed.statusOf(v2).state, AiComponentState.installed);
      expect((entries()['test-engine'] as Map)['version'], '2');
    });
  });

  group('what no component needs any more', () {
    test('an id this version does not know and the leftovers of an unpacking: found with their size', () async {
      await installEarlier(r1, _r1);
      final gone = _model('g1', utf8.encode('a component dropped since'), id: 'gone', installPath: 'models/gone/g.bin');
      await installEarlier(gone, utf8.encode('a component dropped since'));
      at('engines/test-engine.new/run')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(List.filled(100, 1));

      final components = service([r1]);
      final unused = await components.unusedFiles();

      expect(unused.entries, ['gone']);
      expect(unused.paths, ['engines/test-engine.new/run', 'licenses/gone.txt', 'models/gone/g.bin']);
      expect(unused.bytes, 100 + 'a component dropped since'.length + at('licenses/gone.txt').lengthSync());
      // What the catalogue needs is not counted
      expect(unused.paths.any((path) => path.contains('test-model')), isFalse);
    });

    test('an older version waiting for its update is not unused', () async {
      await installEarlier(r1, _r1);
      final components = service([r2]);

      expect((await components.unusedFiles()).isEmpty, isTrue);
    });

    test('an older id left after its component was installed is unused', () async {
      final old = _model('1.30.0', _r1, id: 'test-runtime-1.30.0', installPath: 'runtime/test-runtime-1.30.0/lib.so');
      await installEarlier(old, _r1);
      final next = _model(
        '1.31.0',
        _r2,
        id: 'test-runtime-1.31.0',
        installPath: 'runtime/test-runtime-1.31.0/lib.so',
        replaces: ['test-runtime-1.30.0'],
      );
      // Installed by a build that could not delete the older one, as if installed.json kept it
      await installEarlier(next, _r2);
      final json = installedJson();
      (json['components'] as Map<String, dynamic>)['test-runtime-1.30.0'] = {
        'version': '1.30.0',
        'path': old.installPath,
        'size': _r1.length,
        'sha256': old.sha256,
      };
      at(old.installPath)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(_r1);
      File(p.join(root.path, 'installed.json')).writeAsStringSync(jsonEncode(json));

      final components = service([next]);
      final unused = await components.unusedFiles();

      expect(unused.entries, ['test-runtime-1.30.0']);
      expect(unused.paths, contains(old.installPath));
      expect(components.statusOf(next).state, AiComponentState.installed);
    });

    test('removed when asked: the entries first, then the files and the folders they leave empty', () async {
      await installEarlier(r1, _r1);
      final gone = _model('g1', utf8.encode('dropped'), id: 'gone', installPath: 'models/gone/g.bin');
      await installEarlier(gone, utf8.encode('dropped'));
      at('engines/test-engine.new/run')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(List.filled(10, 1));
      final components = service([r1]);

      expect(await components.removeUnused(listed: await components.unusedFiles()), AiRemoveOutcome.removed);

      expect(entries().keys, ['test-model']);
      expect(Directory(p.join(root.path, 'models', 'gone')).existsSync(), isFalse);
      expect(Directory(p.join(root.path, 'engines', 'test-engine.new')).existsSync(), isFalse);
      expect(at('licenses/gone.txt').existsSync(), isFalse);
      expect(at(r1.installPath).readAsBytesSync(), _r1);
      expect(installedJson()['pendingDeletes'], isEmpty);
      expect((await components.unusedFiles()).isEmpty, isTrue);
      expect(components.statusOf(r1).state, AiComponentState.installed);
    });

    test('the Metal engine of a Mac, once installed, is never unused (release 53)', () async {
      // As the app writes it once the archive is published: its entry, its program and its licence
      const engine = sdCppSeedVr2MacArmComponent;
      at('${engine.installPath}/sd-cli')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(List.filled(16, 7));
      at('licenses/${engine.id}.txt')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('See ${engine.licenceUrl}\n');
      final json = installedJson();
      (json['components'] as Map<String, dynamic>)[engine.id] = {
        'version': engine.version,
        'path': engine.installPath,
        'size': 18223800,
        'sha256': 'c86fbae15d35b91bc56ccf905bc8849065e7433c53cb61980eb3b9809a1e93a0',
      };
      root.createSync(recursive: true);
      File(p.join(root.path, 'installed.json')).writeAsStringSync(jsonEncode(json));

      final unused = await service(aiComponents).unusedFiles();

      expect(aiComponents, contains(engine));
      expect(unused.entries, isNot(contains(engine.id)));
      expect(unused.paths.where((path) => path.startsWith(engine.installPath)), isEmpty);
      expect(unused.paths, isNot(contains('licenses/${engine.id}.txt')));
      // A catalogue without it (the head before the review of 25 November 2026) offered to delete it
      final without = [
        for (final component in aiComponents)
          if (component != engine) component,
      ];
      final before = await service(without).unusedFiles();
      expect(before.entries, contains(engine.id));
      expect(before.paths, contains('${engine.installPath}/sd-cli'));
    });

    test('refused while a conversion runs', () async {
      final gone = _model('g1', utf8.encode('dropped'), id: 'gone', installPath: 'models/gone/g.bin');
      await installEarlier(gone, utf8.encode('dropped'));

      final components = service([r1], inUse: () => true);

      expect(await components.removeUnused(listed: await components.unusedFiles()), AiRemoveOutcome.busy);
      expect(at(gone.installPath).existsSync(), isTrue);
    });
  });

  group('another version of the app sharing the folder (review of issue 21)', () {
    test('each entry names the release of the catalogue that installed it', () async {
      serve(r1, _r1);
      await service([r1], release: 52).install(r1);
      expect((entries()['test-model'] as Map)['catalogue'], 52);
    });

    test('a file a newer version of the app installed is never offered as an update back to an older one', () async {
      serve(r2, _r2);
      await service([r2], release: 53).install(r2);

      final older = service([r1], release: 52);
      await older.load();

      expect(older.updates(), isEmpty, reason: 'no badge, no Update all, no automatic update');
      expect(at(r1.installPath).readAsBytesSync(), _r2);
      expect((await older.unusedFiles()).isEmpty, isTrue);
      final updates = AiComponentsUpdater(service: older);
      expect(await updates.automatic(enabled: true), AiUpdateOutcome.nothing);
      expect(at(r1.installPath).readAsBytesSync(), _r2);
    });

    test('an entry written before release 52 (no release) is older and still offered', () async {
      await installEarlier(r1, _r1);
      final json = installedJson();
      ((json['components'] as Map<String, dynamic>)['test-model'] as Map).remove('catalogue');
      File(p.join(root.path, 'installed.json')).writeAsStringSync(jsonEncode(json));

      final components = service([r2], release: 52);
      await components.load();
      expect(components.updates().map((update) => update.component.id), ['test-model']);
    });

    test('the components of a newer version of the app are not unused for an older one', () async {
      final newer = _model('n1', utf8.encode('newer'), id: 'newer-only', installPath: 'models/newer-only/n.bin');
      serve(newer, utf8.encode('newer'));
      await service([newer], release: 53).install(newer);
      final dropped = _model('d1', utf8.encode('dropped'), id: 'dropped', installPath: 'models/dropped/d.bin');
      serve(dropped, utf8.encode('dropped'));
      await service([dropped], release: 51).install(dropped);

      final unused = await service([r1], release: 52).unusedFiles();

      expect(unused.entries, ['dropped']);
      expect(unused.paths, isNot(contains(newer.installPath)));
      expect(unused.paths, isNot(contains('licenses/newer-only.txt')));
    });

    test('Remove takes only what the user was shown, not what came since', () async {
      final shown = _model('s1', utf8.encode('shown'), id: 'shown', installPath: 'models/shown/s.bin');
      await installEarlier(shown, utf8.encode('shown'));
      final components = service([r1]);
      final listed = await components.unusedFiles();
      expect(listed.entries, ['shown']);
      at('engines/test-engine.new/run')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(List.filled(10, 1));

      expect(await components.removeUnused(listed: listed), AiRemoveOutcome.removed);

      expect(at(shown.installPath).existsSync(), isFalse);
      expect(at('engines/test-engine.new/run').existsSync(), isTrue);
      expect((await components.unusedFiles()).paths, ['engines/test-engine.new/run']);
    });
  });

  group('the swap of an archive folder (review of issue 21)', () {
    final v1Files = {'run': utf8.encode('program one ' * 40)};
    final v2Files = {'run': utf8.encode('program two ' * 40)};
    final v2Zip = _zipOf(v2Files);
    final v2 = _engine('2', v2Zip, v2Files);
    late Directory folder;
    late File archive;

    setUp(() {
      folder = Directory(p.join(root.path, 'engines', 'test-engine'))..createSync(recursive: true);
      File(p.join(folder.path, 'run')).writeAsBytesSync(v1Files['run']!);
      archive = File(p.join(temp.path, 'v2.zip'))..writeAsBytesSync(v2Zip);
    });

    test('the new folder in place, nothing left beside it', () async {
      await installAiArchive(archive, folder, v2.archiveFiles);
      expect(File(p.join(folder.path, 'run')).readAsBytesSync(), v2Files['run']);
      expect(
        root.listSync(recursive: true).map((entity) => p.basename(entity.path)),
        isNot(contains('test-engine.old')),
      );
      expect(Directory('${folder.path}.new').existsSync(), isFalse);
    });

    test('a new folder that cannot take its place puts the old one back', () async {
      var calls = 0;
      Future<void> failSecond(Directory from, String to) async {
        calls++;
        if (calls == 2) {
          throw const FileSystemException('held by the system');
        }
        await from.rename(to);
      }

      await expectLater(
        installAiArchive(archive, folder, v2.archiveFiles, renameFolder: failSecond),
        throwsA(isA<AiDownloadException>().having((error) => error.failure, 'failure', AiDownloadFailure.writeFailed)),
      );

      expect(File(p.join(folder.path, 'run')).readAsBytesSync(), v1Files['run']);
      expect(Directory('${folder.path}.old').existsSync(), isFalse);
      expect(Directory('${folder.path}.new').existsSync(), isFalse);
    });

    test('an old folder the system holds (it cannot be renamed) stays as it was', () async {
      Future<void> failFirst(Directory from, String to) async {
        if (from.path == folder.path) {
          throw const FileSystemException('a file inside is held');
        }
        await from.rename(to);
      }

      await expectLater(
        installAiArchive(archive, folder, v2.archiveFiles, renameFolder: failFirst),
        throwsA(isA<AiDownloadException>()),
      );

      expect(File(p.join(folder.path, 'run')).readAsBytesSync(), v1Files['run']);
      expect(Directory('${folder.path}.new').existsSync(), isFalse);
    });
  });

  group('the older versions elsewhere', () {
    test('a removal takes the older version along, under its older id too', () async {
      final old = _model('1.30.0', _r1, id: 'test-runtime-1.30.0', installPath: 'runtime/test-runtime-1.30.0/lib.so');
      await installEarlier(old, _r1);
      final next = _model(
        '1.31.0',
        _r2,
        id: 'test-runtime-1.31.0',
        installPath: 'runtime/test-runtime-1.31.0/lib.so',
        replaces: ['test-runtime-1.30.0'],
      );
      final components = service([next]);
      await components.load();

      expect(await components.remove(next), AiRemoveOutcome.removed);

      expect(at(old.installPath).existsSync(), isFalse);
      expect(entries(), isEmpty);
      expect(components.statusOf(next).state, AiComponentState.notInstalled);
    });

    test('a move takes the older version along as it is, still to update', () async {
      await installEarlier(r1, _r1);
      final components = service([r2]);
      await components.load();
      final target = Directory(p.join(temp.path, 'drive-d', 'ai-components'));

      final result = await components.moveTo(target, remember: (_) async {});

      expect(result.outcome, AiMoveOutcome.moved);
      expect(at(r2.installPath, target).readAsBytesSync(), _r1);
      expect(at('licenses/test-model.txt', target).existsSync(), isTrue);
      expect((entries(target)['test-model'] as Map)['version'], 'r1');
      expect(components.statusOf(r2).state, AiComponentState.outdated);
    });
  });
}
