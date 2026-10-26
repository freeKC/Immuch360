// The AI components on a device: installation (through a local mirror folder, the downloader being tested against a
// server in ai_component_downloader_test.dart), installed.json, the copied licence, the size checked at each load,
// removal, removal refused during a conversion, the deferred deletion of a locked file (simulated everywhere, and a
// real loaded DLL on Windows), and remove all. Shared with the Quest; kept under test/desktop so that the Windows job
// runs it on a real Windows.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_licences.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:path/path.dart' as p;

final _model = Uint8List.fromList(List.generate(40 * 1024, (index) => (index * 7) % 256));
final _runtime = Uint8List.fromList(List.generate(30 * 1024, (index) => (index * 13) % 256));
final _runtimePacked = Uint8List.fromList(gzip.encode(_runtime));

final _modelComponent = AiComponent(
  id: 'test-model',
  version: 'r1',
  kind: AiComponentKind.model,
  platforms: const {AiPlatform.linuxX64, AiPlatform.windowsX64},
  assetName: 'test_model.onnx',
  installPath: 'models/test-model/test_model.onnx',
  size: _model.length,
  sha256: sha256.convert(_model).toString(),
  compression: AiCompression.none,
  licence: 'Apache-2.0',
  licenceUrl: 'https://huggingface.co/onnx-community/depth-anything-v2-small',
);

final _runtimeComponent = AiComponent(
  id: 'test-runtime',
  version: '1.31.0',
  kind: AiComponentKind.runtime,
  platforms: const {AiPlatform.linuxX64, AiPlatform.windowsX64},
  assetName: 'test-runtime.so.gz',
  installPath: 'runtime/test-runtime-1.31.0/libtest.so',
  size: _runtime.length,
  sha256: sha256.convert(_runtime).toString(),
  compression: AiCompression.gzip,
  downloadSize: _runtimePacked.length,
  licence: 'MIT',
  licenceUrl: 'https://github.com/microsoft/onnxruntime/blob/v1.31.0/LICENSE',
);

void main() {
  late Directory temp;
  late Directory root;
  late Directory mirror;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('ai-components-service');
    root = Directory(p.join(temp.path, 'ai-components'));
    mirror = Directory(p.join(temp.path, 'mirror'))..createSync();
    File(p.join(mirror.path, _modelComponent.assetName)).writeAsBytesSync(_model);
    File(p.join(mirror.path, _runtimeComponent.assetName)).writeAsBytesSync(_runtimePacked);
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // A DLL the Windows test loaded stays locked until the end of the process
    }
  });

  AiComponentsService service({
    bool Function()? inUse,
    Future<void> Function(FileSystemEntity entity)? delete,
    List<AiComponent>? catalogue,
  }) => AiComponentsService(
    folder: () async => root,
    downloader: AiComponentDownloader(mirror: () => Uri.directory(mirror.path).toString()),
    catalogue: catalogue ?? [_runtimeComponent, _modelComponent],
    inUse: inUse,
    delete: delete,
    now: () => DateTime.utc(2026, 10, 26, 22),
  );

  /// installed.json, or what an absent one means (the service deletes it once nothing is left to say)
  Map<String, dynamic> installedJson() {
    final file = File(p.join(root.path, 'installed.json'));
    if (!file.existsSync()) {
      return {'components': <String, dynamic>{}, 'pendingDeletes': <String>[]};
    }
    return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  }

  File installedFile(AiComponent component) => File(p.joinAll([root.path, ...component.installPath.split('/')]));

  group('installing', () {
    test('installs the file, notes it in installed.json and copies its licence', () async {
      final components = service();
      final states = <AiComponentState>[];
      components.addListener(() => states.add(components.statusOf(_modelComponent).state));

      await components.install(_modelComponent);

      expect(installedFile(_modelComponent).readAsBytesSync(), _model);
      expect(components.statusOf(_modelComponent).state, AiComponentState.installed);
      expect(states, contains(AiComponentState.downloading));
      expect(states.last, AiComponentState.installed);
      final entry = (installedJson()['components'] as Map)['test-model'] as Map;
      expect(entry['version'], 'r1');
      expect(entry['path'], 'models/test-model/test_model.onnx');
      expect(entry['size'], _model.length);
      expect(entry['sha256'], _modelComponent.sha256);
      expect(entry['installedAt'], '2026-10-26T22:00:00.000Z');
      expect(entry['source'], Uri.file(p.join(mirror.path, 'test_model.onnx')).toString());
      final licence = await components.licenceOf(_modelComponent);
      expect(licence.path, p.join(root.path, 'licenses', 'test-model.txt'));
      final text = licence.readAsStringSync();
      expect(text, startsWith('Immuch360 AI component: test-model, version r1\n'));
      expect(text, contains('SHA-256: ${_modelComponent.sha256}'));
      expect(text, endsWith(apacheLicence2));
      expect(await components.verifiedFile(_modelComponent), isNotNull);
      expect(Directory(p.join(root.path, 'tmp')).listSync(), isEmpty);
    });

    test('a gzip runtime is unpacked to its place, with the MIT licence and the notices of ONNX Runtime', () async {
      final components = service();

      await components.install(_runtimeComponent);

      expect(installedFile(_runtimeComponent).readAsBytesSync(), _runtime);
      final text = (await components.licenceOf(_runtimeComponent)).readAsStringSync();
      expect(text, contains('https://github.com/microsoft/onnxruntime/blob/v1.31.0/ThirdPartyNotices.txt'));
      expect(text, endsWith(onnxRuntimeLicence));
    });

    test('the sizes: before from the catalogue, after from the disk', () async {
      final components = service();
      expect(
        AiComponentsService.downloadBytesOf([_runtimeComponent, _modelComponent]),
        _runtimePacked.length + _model.length,
      );
      expect(AiComponentsService.diskBytesOf([_runtimeComponent, _modelComponent]), _runtime.length + _model.length);
      expect(await components.spaceUsed(), 0);

      await components.install(_runtimeComponent);
      await components.install(_modelComponent);

      final licences = Directory(
        p.join(root.path, 'licenses'),
      ).listSync().whereType<File>().fold<int>(0, (sum, file) => sum + file.lengthSync());
      final json = File(p.join(root.path, 'installed.json')).lengthSync();
      expect(await components.spaceUsed(), _runtime.length + _model.length + licences + json);
    });

    test('a damaged file is not installed and its failure is kept for the screens', () async {
      File(p.join(mirror.path, _modelComponent.assetName)).writeAsBytesSync(_runtime);
      final components = service();

      await expectLater(
        components.install(_modelComponent),
        throwsA(isA<AiDownloadException>().having((error) => error.failure, 'failure', AiDownloadFailure.damaged)),
      );

      final status = components.statusOf(_modelComponent);
      expect(status.state, AiComponentState.notInstalled);
      expect(status.failure?.failure, AiDownloadFailure.damaged);
      expect(installedFile(_modelComponent).existsSync(), isFalse);
      expect(File(p.join(root.path, 'installed.json')).existsSync(), isFalse);
    });

    test('a file already in place with the sum of the catalogue is kept without downloading', () async {
      installedFile(_modelComponent)
        ..createSync(recursive: true)
        ..writeAsBytesSync(_model);
      File(p.join(mirror.path, _modelComponent.assetName)).deleteSync();
      final components = service();

      await components.install(_modelComponent);

      expect(components.statusOf(_modelComponent).state, AiComponentState.installed);
      expect((installedJson()['components'] as Map)['test-model'], containsPair('source', 'already on disk'));
    });

    test('an incomplete component of the catalogue is refused', () async {
      final components = service(catalogue: aiComponents);

      await expectLater(
        components.install(onnxRuntimeLinuxComponent),
        throwsA(isA<AiDownloadException>().having((error) => error.failure, 'failure', AiDownloadFailure.incomplete)),
      );
    });

    test('two calls for the same component make one download', () async {
      final components = service();

      await Future.wait([components.install(_modelComponent), components.install(_modelComponent)]);

      expect(components.statusOf(_modelComponent).state, AiComponentState.installed);
    });
  });

  group('loading', () {
    test('the size is checked at each load: a file that changed is damaged and not given to the engine', () async {
      await service().install(_modelComponent);
      installedFile(_modelComponent).writeAsBytesSync(_model.sublist(1));

      final later = service();
      await later.load();

      expect(later.statusOf(_modelComponent).state, AiComponentState.damaged);
      expect(await later.verifiedFile(_modelComponent), isNull);
    });

    test('a file deleted behind the app is damaged too', () async {
      final components = service();
      await components.install(_modelComponent);
      installedFile(_modelComponent).deleteSync();

      expect(await components.verifiedFile(_modelComponent), isNull);
      expect(components.statusOf(_modelComponent).state, AiComponentState.damaged);
    });

    test('an older version of a component is deleted at load; an id this version does not know is kept', () async {
      await service().install(_modelComponent);
      final json = installedJson();
      final entries = json['components'] as Map<String, dynamic>;
      entries['test-model'] = {...(entries['test-model'] as Map), 'version': 'r0', 'sha256': 'f' * 64};
      entries['future-model'] = {'version': '9', 'path': 'models/future/future.bin', 'size': 3, 'sha256': 'e' * 64};
      File(p.join(root.path, 'installed.json')).writeAsStringSync(jsonEncode(json));

      final later = service();
      await later.load();

      expect(later.statusOf(_modelComponent).state, AiComponentState.notInstalled);
      expect(installedFile(_modelComponent).existsSync(), isFalse);
      expect((installedJson()['components'] as Map).keys, ['future-model']);
    });

    test('a broken installed.json is read as empty', () async {
      root.createSync(recursive: true);
      File(p.join(root.path, 'installed.json')).writeAsStringSync('{not json');
      final components = service();

      await components.load();

      expect(components.statusOf(_modelComponent).state, AiComponentState.notInstalled);
    });

    test('unpacking leftovers and files of unknown assets are cleaned from tmp, a .part is kept to resume', () async {
      final tmp = Directory(p.join(root.path, 'tmp'))..createSync(recursive: true);
      File(p.join(tmp.path, 'test_model.onnx.part')).writeAsBytesSync(_model.sublist(0, 10));
      File(p.join(tmp.path, 'test-runtime.so.gz.part.unpack')).writeAsBytesSync([1, 2]);
      File(p.join(tmp.path, 'other.part')).writeAsBytesSync([1, 2]);

      await service().load();

      expect(tmp.listSync().map((entity) => p.basename(entity.path)), ['test_model.onnx.part']);
    });
  });

  group('removing', () {
    test('removes the file, its licence and its entry', () async {
      final components = service();
      await components.install(_modelComponent);

      expect(await components.remove(_modelComponent), AiRemoveOutcome.removed);

      expect(installedFile(_modelComponent).existsSync(), isFalse);
      expect((await components.licenceOf(_modelComponent)).existsSync(), isFalse);
      expect(File(p.join(root.path, 'installed.json')).existsSync(), isFalse);
      expect(components.statusOf(_modelComponent).state, AiComponentState.notInstalled);
    });

    test('is refused while a conversion runs', () async {
      var converting = true;
      final components = service(inUse: () => converting);
      await components.install(_modelComponent);

      expect(await components.remove(_modelComponent), AiRemoveOutcome.busy);
      expect(await components.removeAll(), AiRemoveOutcome.busy);
      expect(installedFile(_modelComponent).existsSync(), isTrue);

      converting = false;
      expect(await components.remove(_modelComponent), AiRemoveOutcome.removed);
    });

    test('a locked file is noted and deleted at the next start, before anything loads it', () async {
      await service().install(_runtimeComponent);
      final locked = installedFile(_runtimeComponent);
      final components = service(
        delete: (entity) async {
          if (p.equals(entity.path, locked.path)) {
            throw FileSystemException('locked', entity.path, const OSError('Access is denied.', 5));
          }
          await entity.delete(recursive: true);
        },
      );
      await components.load();

      expect(await components.remove(_runtimeComponent), AiRemoveOutcome.nextStart);

      expect(components.statusOf(_runtimeComponent).state, AiComponentState.removedNextStart);
      expect(locked.existsSync(), isTrue);
      expect(installedJson()['pendingDeletes'], ['runtime/test-runtime-1.31.0/libtest.so']);
      expect(installedJson()['components'], isEmpty);
      expect((await components.licenceOf(_runtimeComponent)).existsSync(), isFalse);

      // The next start
      final next = service();
      await next.load();

      expect(locked.existsSync(), isFalse);
      expect(installedJson()['pendingDeletes'], isEmpty);
      expect(next.statusOf(_runtimeComponent).state, AiComponentState.notInstalled);
    });

    test('installing again a file still waiting for its deletion keeps it when its sum is right', () async {
      await service().install(_runtimeComponent);
      final locked = installedFile(_runtimeComponent);
      final components = service(
        delete: (entity) async => p.equals(entity.path, locked.path)
            ? throw FileSystemException('locked', entity.path, const OSError('Access is denied.', 5))
            : entity.delete(recursive: true),
      );
      expect(await components.remove(_runtimeComponent), AiRemoveOutcome.nextStart);

      await components.install(_runtimeComponent);

      expect(components.statusOf(_runtimeComponent).state, AiComponentState.installed);
      expect(installedJson()['pendingDeletes'], isEmpty);
    });

    test(
      'the pass of the start frees the noted files once per process, before the service reads installed.json',
      () async {
        await service().install(_modelComponent);
        final file = installedFile(_modelComponent);
        root.createSync(recursive: true);
        final json = installedJson()
          ..['components'] = <String, dynamic>{}
          ..['pendingDeletes'] = ['models/test-model/test_model.onnx', '../outside.txt'];
        File(p.join(root.path, 'installed.json')).writeAsStringSync(jsonEncode(json));
        final outside = File(p.join(temp.path, 'outside.txt'))..writeAsStringSync('not ours');

        AiComponentsService.resetStartPassForTests();
        final pass = AiComponentsService.freePendingAtStart(() async => root);
        expect(AiComponentsService.freePendingAtStart(() async => root), same(pass));
        await pass;

        expect(file.existsSync(), isFalse);
        expect(outside.existsSync(), isTrue, reason: 'a path out of the folder is never touched');
        expect(installedJson()['pendingDeletes'], isEmpty);
        AiComponentsService.resetStartPassForTests();
      },
    );

    test('remove all empties the folder, the .part files included', () async {
      final components = service();
      await components.install(_runtimeComponent);
      await components.install(_modelComponent);
      File(p.join(root.path, 'tmp', 'test_model.onnx.part')).writeAsBytesSync([1, 2, 3]);

      expect(await components.removeAll(), AiRemoveOutcome.removed);

      expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
      expect(await components.spaceUsed(), 0);
      expect(components.statusOf(_runtimeComponent).state, AiComponentState.notInstalled);
      expect(components.statusOf(_modelComponent).state, AiComponentState.notInstalled);
    });

    test('remove all with a locked file says the space comes back at the next start', () async {
      await service().install(_runtimeComponent);
      final locked = installedFile(_runtimeComponent);
      final components = service(
        delete: (entity) async => p.equals(entity.path, locked.path)
            ? throw FileSystemException('locked', entity.path, const OSError('Access is denied.', 5))
            : entity.delete(recursive: true),
      );

      expect(await components.removeAll(), AiRemoveOutcome.nextStart);

      expect(installedJson()['pendingDeletes'], ['runtime/test-runtime-1.31.0/libtest.so']);
      expect(components.statusOf(_runtimeComponent).state, AiComponentState.removedNextStart);
    });

    test('a service that goes away stops its downloads and tells nobody', () async {
      final components = service();
      final install = components.install(_modelComponent);
      components.dispose();

      await expectLater(
        install,
        throwsA(isA<AiDownloadException>().having((error) => error.failure, 'failure', AiDownloadFailure.cancelled)),
      );
    });

    test('a download under way is cancelled', () async {
      final components = service();
      final install = components.install(_modelComponent);
      components.cancel(_modelComponent);

      await expectLater(
        install,
        throwsA(isA<AiDownloadException>().having((error) => error.failure, 'failure', AiDownloadFailure.cancelled)),
      );
      expect(components.statusOf(_modelComponent).state, AiComponentState.notInstalled);
    });
  });

  test('on Windows, a loaded DLL cannot be deleted: its removal waits for the next start', () async {
    final dll = File(p.join(root.path, 'runtime', 'test-runtime-1.31.0', 'test.dll'));
    final system = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final bytes = File(p.join(system, 'System32', 'version.dll')).readAsBytesSync();
    final component = AiComponent(
      id: 'test-runtime',
      version: '1.31.0',
      kind: AiComponentKind.runtime,
      platforms: const {AiPlatform.windowsX64},
      assetName: 'test-runtime.dll',
      installPath: 'runtime/test-runtime-1.31.0/test.dll',
      size: bytes.length,
      sha256: sha256.convert(bytes).toString(),
      compression: AiCompression.none,
      licence: 'MIT',
      licenceUrl: 'https://github.com/microsoft/onnxruntime/blob/v1.31.0/LICENSE',
    );
    File(p.join(mirror.path, 'test-runtime.dll')).writeAsBytesSync(bytes);
    final components = service(catalogue: [component]);
    await components.install(component);
    DynamicLibrary.open(dll.path);

    expect(await components.remove(component), AiRemoveOutcome.nextStart);
    expect(dll.existsSync(), isTrue);

    // Still loaded at this "next start": it stays noted, nothing fails
    final next = service(catalogue: [component]);
    await next.load();
    expect(installedJson()['pendingDeletes'], ['runtime/test-runtime-1.31.0/test.dll']);
    expect(next.statusOf(component).state, AiComponentState.removedNextStart);
  }, skip: Platform.isWindows ? null : 'a loaded library locks its file on Windows only');
}
